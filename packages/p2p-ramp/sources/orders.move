module p2p_ramp::orders;

// === Imports ===

use std::string::String;
use sui::{
    balance::Balance,
    coin::Coin,
    event,
};
use account_protocol::{
    account::{Account, Auth},
    executable::Executable,
    intents::Params,
    intent_interface,
};
use p2p_ramp::{
    p2p_ramp::{P2PRamp, Handshake},
    fees::{Fees, AdminCap},
    version,
};

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===

const EFillOutOfRange: u64 = 1;
const EWrongValue: u64 = 2;
const ENotBuyOrder: u64 = 3;
const ENotSellOrder: u64 = 4;
const ENotFiatSender: u64 = 5;
const ENotCoinSender: u64 = 6;
const ECannotDestroyOrder: u64 = 7;

// === Constants ===

const MUL: u64 = 1_000_000_000;

// === Events ===

public struct FillRequestEvent has copy, drop {
    is_buy: bool,
    order_id: address,
    fiat_amount: u64,
    coin_amount: u64,
    taker: address,
}

// === Structs ===

/// Intent witness for filling buy orders
public struct FillBuyIntent() has drop;
/// Intent witness for filling sell orders
public struct FillSellIntent() has drop;

/// Action struct for filling buy orders
#[allow(lint(coin_field))] // bc not sure balance will be merged (if disputed)
public struct FillBuyAction<phantom CoinType> has store {
    // order key
    order_id: address,
    // customers' order quantity
    coin: Coin<CoinType>,
    // customer address
    taker: address,
}
/// Action struct for filling sell orders
public struct FillSellAction has store {
    // order key
    order_id: address,
    // customers' order quantity
    amount: u64,
    // customer address
    taker: address,
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
    // amount being filled
    pending_fill: u64,
}

// === Public functions ===

/// Merchant creates an order
public fun create_order<CoinType>(
    auth: Auth,
    fees: &Fees,
    account: &mut Account<P2PRamp>,
    is_buy: bool,
    fiat_amount: u64,
    fiat_code: String,
    coin_amount: u64,
    min_fill: u64,
    max_fill: u64,
    coin_balance: Balance<CoinType>, // 0 if buy
    ctx: &mut TxContext,
) {
    if (is_buy) assert!(coin_balance.value() == 0, EWrongValue);
    account.verify(auth);
    // Only whitelisted currency are allowed for orders
    fees.assert_fiat_allowed(fiat_code);
    fees.assert_coin_allowed<CoinType>();

    let order_id = ctx.fresh_object_address();
    let order = Order<CoinType> {
        is_buy,
        fiat_amount,
        fiat_code,
        coin_amount,
        min_fill,
        max_fill,
        coin_balance,
        pending_fill: 0,
    };

    account.add_managed_data(
        OrderKey(order_id),
        order,
        version::current()
    );
}

#[allow(lint(self_transfer))]
public fun destroy_order<CoinType>(
    auth: Auth,
    account: &mut Account<P2PRamp>,
    order_id: address,
    ctx: &mut TxContext,
) {
    account.verify(auth);

    let Order<CoinType> {
        coin_balance,
        pending_fill,
        ..
    } = account.remove_managed_data(OrderKey(order_id), version::current());

    assert!(pending_fill == 0, ECannotDestroyOrder);
    transfer::public_transfer(coin_balance.into_coin(ctx), ctx.sender());
}

public fun get_order<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
): &Order<CoinType> {
    account.borrow_managed_data(OrderKey(order_id), version::current())
}

// Intents

/// Customer deposits coin to get fiat
public fun request_fill_buy_order<CoinType>(
    params: Params,
    outcome: Handshake,
    account: &mut Account<P2PRamp>,
    order_id: address,
    coin: Coin<CoinType>,
    ctx: &mut TxContext,
) {
    assert!(outcome.coin_sender() == ctx.sender(), ENotCoinSender);
    assert!(account.config().members().contains(&outcome.fiat_sender()), ENotFiatSender);

    let order_mut = get_order_mut<CoinType>(account, order_id);

    assert!(order_mut.is_buy, ENotBuyOrder);
    order_mut.assert_can_be_filled(coin.value());

    order_mut.pending_fill = order_mut.pending_fill + coin.value();

    event::emit(FillRequestEvent {
        is_buy: true,
        order_id,
        fiat_amount: order_mut.get_price_ratio() * coin.value() / MUL,
        coin_amount: coin.value(),
        taker: ctx.sender(),
    });

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        FillBuyIntent(),
        ctx,
        |intent, iw| intent.add_action(FillBuyAction { order_id, coin, taker: ctx.sender() }, iw)
    );
}

/// Customer requests to get coins by paying with fiat
public fun request_fill_sell_order<CoinType>(
    params: Params,
    outcome: Handshake,
    account: &mut Account<P2PRamp>,
    order_id: address,
    amount: u64,
    ctx: &mut TxContext,
) {
    assert!(outcome.fiat_sender() == ctx.sender(), ENotFiatSender);
    assert!(account.config().members().contains(&outcome.coin_sender()), ENotCoinSender);

    let order_mut = get_order_mut<CoinType>(account, order_id);

    assert!(!order_mut.is_buy, ENotSellOrder);
    order_mut.assert_can_be_filled(amount);

    order_mut.pending_fill = order_mut.pending_fill + amount;

    event::emit(FillRequestEvent {
        is_buy: false,
        order_id,
        fiat_amount: amount,
        coin_amount: order_mut.get_price_ratio() * amount / MUL,
        taker: ctx.sender(),
    });

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        FillSellIntent(),
        ctx,
        |intent, iw| intent.add_action(FillSellAction { order_id, amount, taker: ctx.sender() }, iw)
    );
}

public fun execute_fill_buy_order<CoinType>(
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    fees: &mut Fees,
    ctx: &mut TxContext,
) {
    account.process_intent!<_, Handshake, _>(
        &mut executable,
        version::current(),   
        FillBuyIntent(), 
        |executable, iw| executable.next_action<_, FillBuyAction<CoinType>, _>(iw)
    );

    let key = executable.intent().key();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillBuyAction<CoinType> { order_id, mut coin, .. } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - coin.value();

    fees.collect(&mut coin, ctx);
    order.coin_balance.join(coin.into_balance());

    expired.destroy_empty();
}

public fun execute_fill_sell_order<CoinType>(
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    fees: &mut Fees,
    ctx: &mut TxContext,
) {
    account.process_intent!<_, Handshake, _>(
        &mut executable,
        version::current(),   
        FillSellIntent(), 
        |executable, iw| executable.next_action<_, FillSellAction, _>(iw)
    );

    let key = executable.intent().key();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillSellAction { order_id, amount, taker } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - amount;

    let coin_for_fiat = order.get_price_ratio() * amount / MUL;
    let mut coin = order.coin_balance.split(coin_for_fiat).into_coin(ctx);

    fees.collect(&mut coin, ctx);
    transfer::public_transfer(coin, taker);

    expired.destroy_empty();
}

public fun resolve_dispute_buy_order<CoinType>(
    _: &AdminCap,
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    fees: &mut Fees,
    recipient: address,
    ctx: &mut TxContext,
) {
    account.process_intent!<_, Handshake, _>(
        &mut executable,
        version::current(),   
        FillBuyIntent(), 
        |executable, iw| executable.next_action<_, FillBuyAction<CoinType>, _>(iw)
    );

    let key = executable.intent().key();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillBuyAction<CoinType> { order_id, mut coin, taker } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - coin.value();

    fees.collect(&mut coin, ctx);

    if (taker == recipient) {
        transfer::public_transfer(coin, recipient);
    } else {
        order.coin_balance.join(coin.into_balance());
    };

    expired.destroy_empty();
}

public fun resolve_dispute_sell_order<CoinType>(
    _: &AdminCap,
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    fees: &mut Fees,
    recipient: address,
    ctx: &mut TxContext,
) {
    account.process_intent!<_, Handshake, _>(
        &mut executable,
        version::current(),   
        FillSellIntent(), 
        |executable, iw| executable.next_action<_, FillSellAction, _>(iw)
    );

    let key = executable.intent().key();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillSellAction { order_id, amount, taker } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - amount;

    let coin_for_fiat = order.get_price_ratio() * amount / MUL;
    let mut coin = order.coin_balance.split(coin_for_fiat).into_coin(ctx);

    fees.collect(&mut coin, ctx);

    if (taker == recipient) {
        transfer::public_transfer(coin, recipient);
    } else {
        order.coin_balance.join(coin.into_balance());
    };

    expired.destroy_empty();
}

// === Private functions ===

fun get_order_mut<CoinType>(
    account: &mut Account<P2PRamp>,
    order_id: address,
): &mut Order<CoinType> {
    account.borrow_managed_data_mut(OrderKey(order_id), version::current())
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

    assert!(
        if (order.is_buy) {
            amount + order.pending_fill <= order.coin_amount
        } else {
            amount + order.pending_fill <= order.fiat_amount
        },
        EFillOutOfRange
    );
}
