module p2p_ramp::orders;

// === Imports ===

use std::string::String;
use sui::{
    balance::{Self, Balance},
    coin::Coin,
};
use account_protocol::{
    account::{Account, Auth},
    executable::Executable
};
use p2p_ramp::{
    p2p_ramp::{P2PRamp, Active},
    fees::{Fees, AdminCap},
    version,
};

// === Errors ===

const ENotConfirmed: u64 = 0;
const ENotActive: u64 = 1;
const EWrongValue: u64 = 2;
const ENotPending: u64 = 3;
const ENotWrongCaller: u64 = 4;
const ENotDisputed: u64 = 5;
const ENotRecipient: u64 = 6;

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
    // buying fiat amount
    fiat_amount: u64,
    // fiat currency code
    fiat_code: String,
    // selling coin value
    coin_amount: u64,    
    // balance to be bought
    coin_balance: Balance<CoinType>,
    // order status
    status: Status,
    // taker of the order
    taker: Option<address>,
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
    outcome: Active,
    account: &mut Account<P2PRamp, Active>,
    key: String,
    description: String,
    execution_time: u64,
    expiration_time: u64,
    fiat_amount: u64,
    fiat_code: String,
    coin_amount: u64,
    ctx: &mut TxContext,
) {
    account.verify(auth);

    let mut intent = account.create_intent(
        key,
        description,
        vector[execution_time],
        expiration_time,
        b"".to_string(),
        outcome,
        version::current(),
        BuyIntent(),
        ctx
    );

    let order_id = create_order(account, true, fiat_amount, fiat_code, coin_amount, balance::zero<CoinType>(), ctx);

    account.add_action(&mut intent, BuyAction { order_id }, version::current(), BuyIntent());
    account.add_intent(intent, version::current(), BuyIntent());
}

/// maker posts sell order
public fun request_sell<CoinType>(
    auth: Auth,
    outcome: Active,
    account: &mut Account<P2PRamp, Active>,
    key: String,
    description: String,
    execution_time: u64,
    expiration_time: u64,
    fiat_amount: u64,
    fiat_code: String,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    account.verify(auth);

    let mut intent = account.create_intent(
        key,
        description,
        vector[execution_time],
        expiration_time,
        b"".to_string(),
        outcome,
        version::current(),
        SellIntent(),
        ctx
    );

    let coin_amount = coin.value();
    let order_id = create_order(account, false, fiat_amount, fiat_code, coin_amount, coin.into_balance(), ctx);

    account.add_action(&mut intent, SellAction { order_id }, version::current(), SellIntent());
    account.add_intent(intent, version::current(), SellIntent());
}

public fun customer_fills_buy_order<CoinType>(
    account: &mut Account<P2PRamp, Active>,
    order_id: address,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    let order = get_order_mut<CoinType>(account, order_id);

    assert!(order.status == Status::Active, ENotActive);
    assert!(order.coin_amount == coin.value(), EWrongValue);
    
    order.status = Status::Pending;
    order.taker = option::some(ctx.sender());
    order.coin_balance.join(coin.into_balance());
}

public fun customer_fills_sell_order<CoinType>(
    account: &mut Account<P2PRamp, Active>,
    order_id: address,
    ctx: &mut TxContext,
) {
    let order = get_order_mut<CoinType>(account, order_id);

    assert!(order.status == Status::Active, ENotActive);
    
    order.status = Status::Pending;
    order.taker = option::some(ctx.sender());
}

public fun customer_confirms_order<CoinType>(
    account: &mut Account<P2PRamp, Active>,
    order_id: address,
    ctx: &mut TxContext,
) {
    let order = get_order_mut<CoinType>(account, order_id);

    assert!(order.status == Status::Pending, ENotPending);
    assert!(order.taker.contains(&ctx.sender()), ENotWrongCaller);

    order.status = Status::Confirmed;
}

/// Merchant confirms order by approving the intent

public fun dispute_order<CoinType>(
    account: &mut Account<P2PRamp, Active>,
    order_id: address,
    ctx: &mut TxContext,
) {
    let order = get_order_mut<CoinType>(account, order_id);

    assert!(
        order.taker.contains(&ctx.sender()) || // taker disputes
        account.config().is_member(ctx.sender()), // maker disputes
        ENotWrongCaller
    );

    order.status = Status::Disputed;
}

public fun execute_buy_order<CoinType>(
    executable: Executable,
    account: &mut Account<P2PRamp, Active>,
    fees: &mut Fees,
    ctx: &mut TxContext,
) {
    let action: &BuyAction = account.process_action(&mut executable, version::current(), BuyIntent());
    let order = get_order_mut<CoinType>(account, action.order_id);
    // Executable ensures the maker approved, just need to ensure the taker approved
    assert!(order.status == Status::Confirmed, ENotConfirmed); 

    let mut coin = order.coin_balance.withdraw_all().into_coin(ctx);
    fees.collect(&mut coin, ctx);
    
    transfer::public_transfer(coin, account.addr());
    destroy_order<CoinType>(account, action.order_id);
    account.confirm_execution(executable, version::current(), BuyIntent())
}

public fun execute_sell_order<CoinType>(
    executable: Executable,
    account: &mut Account<P2PRamp, Active>,
    fees: &mut Fees,
    ctx: &mut TxContext,
) {
    let action: &SellAction = account.process_action(&mut executable, version::current(), SellIntent());
    let order = get_order_mut<CoinType>(account, action.order_id);
    // Executable ensures the maker approved, just need to ensure the taker approved
    assert!(order.status == Status::Confirmed, ENotConfirmed); 

    let mut coin = order.coin_balance.withdraw_all().into_coin(ctx);
    fees.collect(&mut coin, ctx);

    transfer::public_transfer(coin, order.taker.extract());
    destroy_order<CoinType>(account, action.order_id);
    account.confirm_execution(executable, version::current(), SellIntent())
}

public fun resolve_dispute<CoinType>(
    _: &AdminCap,
    account: &mut Account<P2PRamp, Active>,
    order_id: address,
    recipient: address,
    ctx: &mut TxContext,
) {
    let order = get_order_mut<CoinType>(account, order_id);

    assert!(order.status == Status::Disputed, ENotDisputed);
    assert!(recipient == order.taker.extract() || recipient == account.addr(), ENotRecipient);

    transfer::public_transfer(order.coin_balance.withdraw_all().into_coin(ctx), recipient);
    destroy_order<CoinType>(account, order_id);
    // need to flag the intent as "to be deleted by maker"
}

// === View functions ===

public fun get_order<CoinType>(
    account: &mut Account<P2PRamp, Active>,
    order_id: address,
): &Order<CoinType> {
    account.borrow_managed_data(OrderKey(order_id), version::current())
}

// === Private functions ===

fun create_order<CoinType>(
    account: &mut Account<P2PRamp, Active>,
    is_buy: bool,
    fiat_amount: u64,
    fiat_code: String,
    coin_amount: u64,
    coin_balance: Balance<CoinType>,
    ctx: &mut TxContext,
): address {
    let order_id = ctx.fresh_object_address();

    let order = Order<CoinType> {
        is_buy,
        fiat_amount,
        fiat_code,
        coin_amount,
        coin_balance,
        status: Status::Active,
        taker: option::none(),
    };
    
    account.add_managed_data(
        OrderKey(order_id),
        order,
        version::current()
    );

    order_id
}

fun get_order_mut<CoinType>(
    account: &mut Account<P2PRamp, Active>,
    order_id: address,
): &mut Order<CoinType> {
    account.borrow_managed_data_mut(OrderKey(order_id), version::current())
}

fun destroy_order<CoinType>(
    account: &mut Account<P2PRamp, Active>,
    order_id: address,
) {
    let Order<CoinType> {
        coin_balance,
        ..
    } = account.remove_managed_data(OrderKey(order_id), version::current());

    coin_balance.destroy_zero();
}
