module p2p_ramp::orders;

// === Imports ===

use std::string::String;
use sui::{
    balance::Balance,
    coin::Coin,
    event,
    vec_set,
    clock::Clock
};
use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    intents::Params,
    intent_interface,
    intents::{Self},
};

use p2p_ramp::{
    p2p_ramp::{Self, P2PRamp, Handshake},
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
const EDeadlineTooShort: u64 = 8;

// === Constants ===

const MUL: u64 = 1_000_000_000;

// === Events ===

public struct CreateOrderEvent has copy, drop {
    is_buy: bool,
    fiat_amount: u64,
    fiat_code: String,
    coin_amount: u64,
    min_fill: u64,
    max_fill: u64,
    fill_deadline_ms: u64,
    order_id: address
}

public struct DestroyOrderEvent has copy, drop {
    by: address,
    order_id: address
}

public struct FillRequestEvent has copy, drop {
    is_buy: bool,
    order_id: address,
    fiat_amount: u64,
    coin_amount: u64,
    taker: address,
    fill_deadline_ms: u64,
}

public struct FillCompletedEvent has copy, drop {
    is_buy: bool,
    key: String,
    order_id: address,
    completed_by: address,
}

public struct FillCancelledEvent has copy, drop {
    kind: CancellationKind,
    is_buy: bool,
    key: String,
    order_id: address,
    cancelled_by: address,
    reason: String,
}

public struct DisputeResolvedEvent has copy, drop {
    is_buy: bool,
    key: String,
    order_id: address,
    winner: address,
    losser: address,
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
    // The time in ms a taker has to mark a fill as 'Paid'
    fill_deadline_ms: u64,
    // balance to be bought or sold
    coin_balance: Balance<CoinType>,
    // amount being filled
    pending_fill: u64,
    // amount already successfully filled
    completed_fill: u64,
}

public enum CancellationKind has copy, drop {
    Expired,
    VoluntaryByTaker,
    VoluntaryByMerchant,
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
    fill_deadline_ms: u64,
    coin_balance: Balance<CoinType>, // 0 if buy
    ctx: &mut TxContext,
) : address {
    if (is_buy) assert!(coin_balance.value() == 0, EWrongValue) else assert!(coin_balance.value() > 0, EWrongValue);
    account.verify(auth);
    // Only whitelisted currency are allowed for orders
    fees.assert_fiat_allowed(fiat_code);
    fees.assert_coin_allowed<CoinType>();

    // the minimum deadline must be 15 mins
    assert!(fill_deadline_ms >= fees.min_fill_deadline_ms(), EDeadlineTooShort);

    let order_id = ctx.fresh_object_address();
    let order = Order<CoinType> {
        is_buy,
        fiat_amount,
        fiat_code,
        coin_amount,
        min_fill,
        max_fill,
        fill_deadline_ms,
        coin_balance,
        pending_fill: 0,
        completed_fill: 0,
    };

    event::emit(CreateOrderEvent {
        is_buy,
        fiat_amount,
        fiat_code,
        coin_amount,
        min_fill,
        max_fill,
        fill_deadline_ms,
        order_id
    });

    account.add_managed_data(
        OrderKey(order_id),
        order,
        version::current()
    );

    order_id
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

    event::emit(DestroyOrderEvent {
        by: account.addr(),
        order_id
    });

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
    mut outcome: Handshake,
    account: &mut Account<P2PRamp>,
    order_id: address,
    coin: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(outcome.coin_senders().contains(&ctx.sender()), ENotCoinSender);
    assert!(contains_any!(&account.config().members(), &outcome.fiat_senders()), ENotFiatSender);

    let order_mut = get_order_mut<CoinType>(account, order_id);

    assert!(order_mut.is_buy, ENotBuyOrder);
    order_mut.assert_can_be_filled(coin.value());

    order_mut.pending_fill = order_mut.pending_fill + coin.value();

    // --- AUTHORITATIVE DEADLINE OVERWRITE ---
    let correct_deadline = clock.timestamp_ms() + order_mut.fill_deadline_ms;
    p2p_ramp::set_payment_deadline(&mut outcome, correct_deadline);

    event::emit(FillRequestEvent {
        is_buy: true,
        order_id,
        fiat_amount: order_mut.get_price_ratio() * coin.value() / MUL,
        coin_amount: coin.value(),
        taker: ctx.sender(),
        fill_deadline_ms: correct_deadline,
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
    mut outcome: Handshake,
    account: &mut Account<P2PRamp>,
    order_id: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(outcome.fiat_senders().contains(&ctx.sender()), ENotFiatSender);
    assert!(contains_any!(&account.config().members(), &outcome.coin_senders()), ENotCoinSender);

    let order_mut = get_order_mut<CoinType>(account, order_id);

    assert!(!order_mut.is_buy, ENotSellOrder);
    order_mut.assert_can_be_filled(amount);

    order_mut.pending_fill = order_mut.pending_fill + amount;

    // --- AUTHORITATIVE DEADLINE OVERWRITE ---
    let correct_deadline = clock.timestamp_ms() + order_mut.fill_deadline_ms;
    p2p_ramp::set_payment_deadline(&mut outcome, correct_deadline);

    event::emit(FillRequestEvent {
        is_buy: false,
        order_id,
        fiat_amount: amount,
        coin_amount: order_mut.get_price_ratio() * amount / MUL,
        taker: ctx.sender(),
        fill_deadline_ms:correct_deadline,
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
    let outcome = intents::outcome(executable.intent());
    let paid_time = outcome.paid_timestamp_ms();
    let settled_time = outcome.settled_timestamp_ms();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillBuyAction<CoinType> { order_id, mut coin, .. } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - coin.value();
    order.completed_fill = order.completed_fill + coin.value();

    let fiat_amount = get_price_ratio<CoinType>(order) * coin.value() / MUL;
    let coin_amount = coin.value();
    let release_time = settled_time - paid_time;

    fees.collect(&mut coin, ctx);
    order.coin_balance.join(coin.into_balance());

    event::emit(FillCompletedEvent {
        is_buy: true,
        key,
        order_id,
        completed_by: ctx.sender(),
    });

    // update accounts' reputation
    p2p_ramp::record_successful_trade<CoinType>(account, order.fiat_code, fiat_amount, coin_amount, release_time);

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
    let outcome = intents::outcome(executable.intent());
    let paid_time = outcome.paid_timestamp_ms();
    let settled_time = outcome.settled_timestamp_ms();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillSellAction { order_id, amount, taker } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - amount;
    order.completed_fill = order.completed_fill + amount;

    let coin_for_fiat = order.get_price_ratio() * amount / MUL;
    let mut coin = order.coin_balance.split(coin_for_fiat).into_coin(ctx);

    let coin_amount = coin.value();
    let release_time = settled_time - paid_time;

    fees.collect(&mut coin, ctx);
    transfer::public_transfer(coin, taker);

    event::emit(FillCompletedEvent {
        is_buy: false,
        key,
        order_id,
        completed_by: ctx.sender(),
    });

    // update accounts' reputation
    p2p_ramp::record_successful_trade<CoinType>(account, order.fiat_code, coin_for_fiat, coin_amount, release_time);

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

    let (winner, losser) = if (taker == recipient) {
        transfer::public_transfer(coin, recipient);
        (taker, account::addr(account))
    } else {
        order.coin_balance.join(coin.into_balance());
        (account::addr(account), taker)
    };

    event::emit(DisputeResolvedEvent {
        is_buy: true,
        key,
        order_id,
        winner,
        losser
    });

    p2p_ramp::record_dispute_outcome(account, recipient);

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

    let (winner, losser) = if (taker == recipient) {
        transfer::public_transfer(coin, recipient);
        (taker, account::addr(account))
    } else {
        order.coin_balance.join(coin.into_balance());
        (account::addr(account), taker)
    };

    event::emit(DisputeResolvedEvent {
        is_buy: false,
        key,
        order_id,
        winner,
        losser
    });

    p2p_ramp::record_dispute_outcome(account, recipient);

    expired.destroy_empty();
}

public fun resolve_expired_buy_order_fill<CoinType>(
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
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
    let FillBuyAction<CoinType> { order_id, coin, taker } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - coin.value();

    event::emit(FillCancelledEvent {
        kind: CancellationKind::Expired,
        is_buy: true,
        key,
        order_id,
        cancelled_by: ctx.sender(),
        reason: b"system".to_string(),
    });

    transfer::public_transfer(coin, taker);

    expired.destroy_empty();
}

public fun resolve_expired_sell_order_fill<CoinType>(
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    ctx: &mut TxContext,
) {
    account.process_intent!<_, Handshake, _>(
        &mut executable,
        version::current(),
        FillSellIntent(),
|       executable, iw| executable.next_action<_, FillSellAction, _>(iw)
    );

    let key = executable.intent().key();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillSellAction { order_id, amount, .. } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - amount;

    let coin_for_fiat = order.get_price_ratio() * amount / MUL;
    let coin = order.coin_balance.split(coin_for_fiat).into_coin(ctx);

    order.coin_balance.join(coin.into_balance());

    event::emit(FillCancelledEvent {
        kind: CancellationKind::Expired,
        is_buy: false,
        key,
        order_id,
        cancelled_by: ctx.sender(),
        reason: b"system".to_string(),
    });

    expired.destroy_empty();
}

/// Allow a merchant to cancel a fill on their own BUY order
/// before they have sent payment. Returns the taker's locked coins to them.
public fun merchant_cancel_fill<CoinType>(
    auth: Auth,
    account: &mut Account<P2PRamp>,
    reason: String,
    mut executable: Executable<Handshake>,
    ctx: &mut TxContext,
) {
    account.verify(auth);

    account.process_intent!<_, Handshake, _>(
        &mut executable,
        version::current(),
        FillBuyIntent(),
        |executable, iw| executable.next_action<_, FillBuyAction<CoinType>, _>(iw)
    );

    let key = executable.intent().key();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillBuyAction<CoinType> { order_id, coin, taker } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    // Revert the pending fill amount on the order.
    order.pending_fill = order.pending_fill - coin.value();

    event::emit(FillCancelledEvent {
        kind: CancellationKind::VoluntaryByMerchant,
        is_buy: order.is_buy,
        key,
        order_id,
        cancelled_by: ctx.sender(),
        reason,
    });

    // CRITICAL: Return the locked coins to the taker, making them whole.
    transfer::public_transfer(coin, taker);

    p2p_ramp::record_failed_trade(account);

    expired.destroy_empty();
}

/// NEW: Public function for a taker to cancel their fill on a SELL order
/// before they have sent payment. Refunds their gas_bond.
public fun taker_cancel_sell_order_fill<CoinType>(
    account: &mut Account<P2PRamp>,
    reason: String,
    mut executable: Executable<Handshake>,
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

    assert!(ctx.sender() == taker, ENotFiatSender);

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - amount;

    event::emit(FillCancelledEvent {
        kind: CancellationKind::VoluntaryByTaker,
        is_buy: order.is_buy,
        key,
        order_id,
        cancelled_by: taker,
        reason,
    });

    // CRITICAL: Return the taker's good-faith deposit to them
    // transfer::public_transfer(gas_bond, taker, ctx);

    expired.destroy_empty();
}

// === View functions ===

public fun is_buy<CoinType>(
    order: &Order<CoinType>
) : bool {
    order.is_buy
}

public fun min_fill<CoinType>(
    order: &Order<CoinType>
) : u64 {
    order.min_fill
}

public fun max_fill<CoinType>(
    order: &Order<CoinType>
) : u64 {
    order.max_fill
}

public fun fiat_amount<CoinType>(
    order: &Order<CoinType>
) : u64 {
    order.fiat_amount
}

public fun fiat_code<CoinType>(
    order: &Order<CoinType>
) : String {
    order.fiat_code
}

public fun coin_amount<CoinType>(
    order: &Order<CoinType>
) : u64 {
    order.coin_amount
}

public fun fill_deadline_ms<CoinType>(
    order: &Order<CoinType>
) : u64 {
    order.fill_deadline_ms
}

public fun coin_balance<CoinType>(
    order: &Order<CoinType>
) : u64 {
    order.coin_balance.value()
}

public fun pending_fill<CoinType>(
    order: &Order<CoinType>
) : u64 {
    order.pending_fill
}

public fun completed_fill<CoinType>(
    order: &Order<CoinType>
) : u64 {
    order.completed_fill
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

    let total_committed = order.pending_fill + order.completed_fill;

    assert!(
        if (order.is_buy) {
            amount + total_committed <= order.coin_amount
        } else {
            amount + total_committed <= order.fiat_amount
        },
        EFillOutOfRange
    );
}


macro fun contains_any<$K: copy + drop>($a: &vec_set::VecSet<$K>, $b: &vec_set::VecSet<$K>): bool {
    let keys_b = vec_set::keys($b);
    let len = vector::length(keys_b);
    let mut i = 0;
    while (i < len) {
        let key = &keys_b[i];
        if (vec_set::contains($a, key)) {
            return true
        };
        i = i + 1;
    };
    false
}

