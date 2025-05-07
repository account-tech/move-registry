module p2p_ramp::orders;

// === Imports ===

use std::string::String;
use sui::{
    balance::{Self, Balance},
    coin::Coin,
    event,
};
use account_protocol::{
    account::{Account, Auth},
    executable::Executable,
    intents::{Params, Expired},
    intent_interface,
};
use sui::vec_map::{Self, VecMap};
use p2p_ramp::{
    p2p_ramp::{P2PRamp, Active},
    fees::{Self, Fees, AdminCap},
    version,
};

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===

const ENotConfirmed: u64 = 0;
const ENotActive: u64 = 1;
const EWrongValue: u64 = 2;
const ENotPending: u64 = 3;
const ENotWrongCaller: u64 = 4;
const ENotDisputed: u64 = 5;
const ENotRecipient: u64 = 6;
const EFillOutOfRange: u64 = 7;

// === Constants ===

const MUL: u64 = 1_000_000_000;

// === Events ===

public struct DisputeEvent has copy, drop {
    order_id: address,
    caller: address,
}

// === Structs ===

/// Intent witness for buy orders
public struct BuyIntent() has copy, drop;
/// Intent witness for sell orders
public struct SellIntent() has copy, drop;

/// Action struct for buy orders
public struct BuyAction has store {
    // order key
    order_id: address,
}
/// Action struct for sell orders
public struct SellAction has store {
    // order key
    order_id: address,
}

/// Df key for order
public struct OrderKey(address) has copy, drop, store;
/// Df for order escrow
public struct Order<phantom CoinType> has store {
    // is buy order
    is_buy: bool,
    // orders' fill lowest bound
    min_fill: u64,
    // orders' fill highest bound
    max_fill: u64,
    // buying fiat amount
    fiat_amount: u64,
    // fiat currency code
    fiat_code: String,
    // selling coin value
    coin_amount: u64,
    // balance to be bought or sold
    coin_balance: Balance<CoinType>,
    // orders placed
    asks: VecMap<address, Ask>,
}

public struct Ask has store, drop {
    // customers' order quantity
    amount: u64,
    // order status
    status: Status,
}

/// Enum for tracking order status
public enum Status has copy, drop, store {
    // order can be filled
    Active,
    // order being filled by a customer, waiting for resolution
    Pending,
    // approved by customer, maker is in the intent
    Confirmed,
    // order disputed, one party has disputed the order
    Disputed,
}

// === Public functions ===

/// maker posts buy order
public fun request_buy<CoinType>(
    auth: Auth,
    params: Params,
    outcome: Active,
    account: &mut Account<P2PRamp>,
    fiat_amount: u64,
    fiat_code: String,
    coin_amount: u64,
    min_fill: u64,
    max_fill: u64,
    fees: &Fees,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    // Only whitelisted fiat allowed for orders
    fees.assert_fiat_allowed(fiat_code);

    let order_id = create_order(
        account, 
        true, 
        fiat_amount, 
        fiat_code, 
        coin_amount, 
        min_fill, 
        max_fill, 
        balance::zero<CoinType>(), 
        vec_map::empty(), 
        ctx
    );
    
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        BuyIntent(),
        ctx,
        |intent, iw| intent.add_action(BuyAction { order_id }, iw)
    );
}

/// maker posts sell order
public fun request_sell<CoinType>(
    auth: Auth,
    params: Params,
    outcome: Active,
    account: &mut Account<P2PRamp>,
    fiat_amount: u64,
    fiat_code: String,
    coin: Coin<CoinType>,
    min_fill: u64,
    max_fill: u64,
    fees: &Fees,
    ctx: &mut TxContext,
) {
    account.verify(auth);
    // Only whitelisted fiat allowed for orders
    fees.assert_fiat_allowed(fiat_code);

    let order_id = create_order(
        account, 
        false, 
        fiat_amount, 
        fiat_code, 
        coin.value(), 
        min_fill, 
        max_fill, 
        coin.into_balance(), 
        vec_map::empty(), 
        ctx
    );

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        SellIntent(),
        ctx,
        |intent, iw| intent.add_action(SellAction { order_id }, iw)
    );
}

public fun customer_fills_buy_order<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    let order = get_order_mut<CoinType>(account, order_id);
    
    order.assert_can_be_filled(coin.value());
    
    order.asks.insert(ctx.sender(), Ask {
        amount: coin.value(),
        status: Status::Pending,
    });

    order.coin_balance.join(coin.into_balance());
}

public fun customer_fills_sell_order<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
    amount: u64,
    ctx: &mut TxContext,
) {
    let order = get_order_mut<CoinType>(account, order_id);
    
    order.assert_can_be_filled(amount);

    order.asks.insert(ctx.sender(), Ask {
        amount,
        status: Status::Pending,
    });
}

public fun customer_confirms_order<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
    ctx: &mut TxContext,
) {
    let order = get_order_mut<CoinType>(account, order_id);
    let ask = order.asks.get_mut(&ctx.sender());

    assert!(ask.status == Status::Pending, ENotPending);
    ask.status = Status::Confirmed;
}

/// Merchant confirms order by approving the intent

public fun dispute_order<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
    ctx: &mut TxContext,
) {
    let config = *account.config();
    let order = get_order_mut<CoinType>(account, order_id);

    assert!(
        order.asks.get(&ctx.sender()).taker.contains(&ctx.sender()) || // taker disputes
        config.is_member(ctx.sender()), // maker disputes
        ENotWrongCaller
    );

    event::emit(DisputeEvent { order_id, caller: ctx.sender() });

    order.asks.get_mut(&ctx.sender()).status = Status::Disputed;
}

public fun execute_buy_order<CoinType>(
    mut executable: Executable<Active>,
    account: &mut Account<P2PRamp>,
    seller: address,
    fees: &mut Fees,
    ctx: &mut TxContext,
) {
    let order_id = account.process_action<_, _, BuyAction, _>(&mut executable, version::current(), BuyIntent()).order_id;
    let account_addr = account.addr();
    let order = get_order_mut<CoinType>(account, order_id);
    let order_item = order.asks.get_mut(&seller);
    // Executable ensures the maker approved, just need to ensure the taker approved
    assert!(order_item.status == Status::Confirmed, ENotConfirmed);

    let mut coin = order.coin_balance.split(order_item.quantity).into_coin(ctx);
    fees.collect(&mut coin, ctx);

    transfer::public_transfer(coin, account_addr);
    // remove specific match
    order.asks.remove(&seller);

    // TODO(as the buy action might still have asks, get around destroying action and executable)
    // destroy_order<CoinType>(account, order_id);
    account.confirm_execution(executable, version::current(), BuyIntent())
}

public fun execute_sell_order<CoinType>(
    mut executable: Executable,
    account: &mut Account<P2PRamp>,
    buyer: address,
    fees: &mut Fees,
    ctx: &mut TxContext,
) {
    let order_id = account.process_action<_, _, SellAction, _>(&mut executable, version::current(), SellIntent()).order_id;
    let order = get_order_mut<CoinType>(account, order_id);
    let order_item = order.asks.get_mut(&buyer);
    // Executable ensures the maker approved, just need to ensure the taker approved
    assert!(order_item.status == Status::Confirmed, ENotConfirmed);

    let mut coin = order.coin_balance.split(order_item.quantity).into_coin(ctx);
    fees.collect(&mut coin, ctx);

    transfer::public_transfer(coin, order_item.taker.extract());

    // remove specific match
    order.asks.remove(&buyer);

    // TODO(as the sell action might still have asks, get around destroying action and executable)
    // destroy_order<CoinType>(account, order_id);
    account.confirm_execution(executable, version::current(), SellIntent())
}

public fun resolve_dispute<CoinType>(
    _: &AdminCap,
    account: &mut Account<P2PRamp>,
    order_id: address,
    recipient: address,
    ctx: &mut TxContext,
) {
    let acc_addr = account.addr();
    let order = get_order_mut<CoinType>(account, order_id);
    let order_item = order.asks.get_mut(&recipient);

    assert!(order_item.status == Status::Disputed, ENotDisputed);
    assert!(recipient == order_item.taker.extract() || recipient == acc_addr, ENotRecipient);

    transfer::public_transfer(order.coin_balance.withdraw_all().into_coin(ctx), recipient);
    destroy_order<CoinType>(account, order_id);
    // need to flag the intent as "to be deleted by maker"
}

// === View functions ===

public fun get_order<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
): &Order<CoinType> {
    account.borrow_managed_data(OrderKey(order_id), version::current())
}

// === Private functions ===

fun create_order<CoinType>(
    account: &mut Account<P2PRamp>,
    is_buy: bool,
    fiat_amount: u64,
    fiat_code: String,
    coin_amount: u64,
    min_fill: u64,
    max_fill: u64,
    coin_balance: Balance<CoinType>,
    orders: VecMap<address, Ask>,
    ctx: &mut TxContext,
): address {
    let order_id = ctx.fresh_object_address();

    let order = Order<CoinType> {
        is_buy,
        fiat_amount,
        fiat_code,
        coin_amount,
        min_fill,
        max_fill,
        coin_balance,
        asks: orders,
        state: State::Enabled
    };

    account.add_managed_data(
        OrderKey(order_id),
        order,
        version::current()
    );

    order_id
}

fun get_order_mut<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
): &mut Order<CoinType> {
    account.borrow_managed_data_mut(OrderKey(order_id), version::current())
}

fun destroy_order<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
) {
    let Order<CoinType> {
        coin_balance,
        ..
    } = account.remove_managed_data(OrderKey(order_id), version::current());

    coin_balance.destroy_zero();
}

fun get_price_ratio<CoinType>(order: &Order<CoinType>): u64 {
    if (order.is_buy) {
        order.fiat_amount * MUL / order.coin_amount // fiat per coin
    } else {
        order.coin_amount * MUL / order.fiat_amount // coin per fiat
    }
}

fun assert_can_be_filled<CoinType>(order: &Order<CoinType>, amount: u64) {
    assert!(
        amount >= order.min_fill && amount <= order.max_fill, 
        EFillOutOfRange
    );
    
    let (mut i, mut filled) = (0, 0);
    while (i < order.asks.size()) {
        let (_, ask) = order.asks.get_entry_by_idx(i);
        filled = filled + ask.amount;
        i = i + 1;
    };

    assert!(
        if (order.is_buy) {
            amount + filled <= order.coin_amount
        } else {
            amount + filled <= order.fiat_amount
        },
        EFillOutOfRange
    );
}
