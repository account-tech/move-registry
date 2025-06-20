module p2p_ramp::orders;

// === Imports ===

use std::string::String;
use sui::{
    balance::Balance,
    coin::Coin,
    event,
    vec_set::{Self, VecSet},
    vec_map::{Self, VecMap},
    table::{Self, Table},
    clock::Clock
};
use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    intent_interface,
    intents::{Self},
};

use p2p_ramp::{
    p2p_ramp::{Self, P2PRamp, Handshake},
    policy::{Policy, AdminCap},
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
const EMaxOrderLimitExceeds: u64 = 9;
const EBuyFillCoinSenderLimitExceeds: u64 = 10;
const ESellFillFiatSenderLimitExceeds: u64 = 11;
const EFillNotFound: u64 = 12;

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

/// Central registry for orders
public struct OrderRegistry has key {
    id: UID,
    orders: Table<address, VecSet<address>>, // acc_addr <> order_id[]
    fills: Table<address, VecMap<address, address>> // fill_manager <> <acc_addr, order_id>
}

// === Public functions ===
fun init(ctx: &mut TxContext) {
    transfer::share_object(OrderRegistry {
        id: object::new(ctx),
        orders: table::new(ctx),
        fills: table::new(ctx),
    });
}

/// Merchant creates an order
public fun create_order<CoinType>(
    registry: &mut OrderRegistry,
    auth: Auth,
    policy: &Policy,
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
    let addr = account.addr();
    if (registry.orders.contains(addr)) assert!(registry.orders.borrow(addr).size() < policy.max_orders(), EMaxOrderLimitExceeds);
    account.verify(auth);
    // Only whitelisted currency are allowed for orders
    policy.assert_fiat_allowed(fiat_code);
    policy.assert_coin_allowed<CoinType>();

    // the minimum deadline must be 15 mins
    assert!(fill_deadline_ms >= policy.min_fill_deadline_ms(), EDeadlineTooShort);

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

    if(registry.orders.contains(account.addr())) {
        let order_ids = registry.orders.borrow_mut(account.addr());
        order_ids.insert(order_id);
    } else {
        registry.orders.add(account.addr(), vec_set::singleton(order_id));
    };

    order_id
}

#[allow(lint(self_transfer))]
public fun destroy_order<CoinType>(
    registry: &mut OrderRegistry,
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

    let account_addr = account.addr();
    if (registry.orders.contains(account_addr)) {
        let order_set_ref = table::borrow(&registry.orders, account_addr);
        if (vec_set::contains(order_set_ref, &order_id)) {
            let mut order_set = table::remove(&mut registry.orders, account_addr);
            vec_set::remove(&mut order_set, &order_id);
            if (!vec_set::is_empty(&order_set)) {
                table::add(&mut registry.orders, account_addr, order_set);
            } else {
                vector::destroy_empty(order_set.into_keys());
            }
        }
    };

    event::emit(DestroyOrderEvent {
        by: account.addr(),
        order_id
    });

    if (coin_balance.value() > 0) {
        transfer::public_transfer(coin_balance.into_coin(ctx), ctx.sender());
    } else {
        coin_balance.destroy_zero();
    }
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
    registry: &mut OrderRegistry,
    mut outcome: Handshake,
    account: &mut Account<P2PRamp>,
    order_id: address,
    coin: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(outcome.coin_senders().size() == 1, EBuyFillCoinSenderLimitExceeds);
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

    let params = intents::new_params(
        ctx.sender().to_string(),
        b"".to_string(),
        vector[0],
        clock.timestamp_ms() + (7 * 24 * 60 * 60 * 1000),
        clock,
        ctx,
    );

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        FillBuyIntent(),
        ctx,
        |intent, iw| intent.add_action(FillBuyAction { order_id, coin, taker: ctx.sender() }, iw)
    );

    record_fill(registry, outcome.coin_senders().keys(), account.addr(), order_id);
}

/// Customer requests to get coins by paying with fiat
public fun request_fill_sell_order<CoinType>(
    registry: &mut OrderRegistry,
    mut outcome: Handshake,
    account: &mut Account<P2PRamp>,
    order_id: address,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(outcome.fiat_senders().size() == 1, ESellFillFiatSenderLimitExceeds);
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

    let params = intents::new_params(
        ctx.sender().to_string(),
        b"".to_string(),
        vector[0],
        clock.timestamp_ms() + (7 * 24 * 60 * 60 * 1000),
        clock,
        ctx,
    );

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        FillSellIntent(),
        ctx,
        |intent, iw| intent.add_action(FillSellAction { order_id, amount, taker: ctx.sender() }, iw)
    );

    record_fill(registry, outcome.fiat_senders().keys(), account.addr(), order_id);
}

public fun execute_fill_buy_order<CoinType>(
    registry: &mut OrderRegistry,
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    policy: &mut Policy,
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
    let coin_senders = outcome.coin_senders().keys();
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

    policy.collect(&mut coin, ctx);
    order.coin_balance.join(coin.into_balance());

    event::emit(FillCompletedEvent {
        is_buy: true,
        key,
        order_id,
        completed_by: ctx.sender(),
    });

    // update accounts' reputation
    p2p_ramp::record_successful_trade<CoinType>(account, order.fiat_code, fiat_amount, coin_amount, release_time);
    unrecord_fill(registry, coin_senders, account.addr(), order_id);

    expired.destroy_empty();
}

public fun execute_fill_sell_order<CoinType>(
    registry: &mut OrderRegistry,
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    policy: &mut Policy,
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
    let fiat_senders = outcome.fiat_senders().keys();
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

    policy.collect(&mut coin, ctx);
    transfer::public_transfer(coin, taker);

    event::emit(FillCompletedEvent {
        is_buy: false,
        key,
        order_id,
        completed_by: ctx.sender(),
    });

    // update accounts' reputation
    p2p_ramp::record_successful_trade<CoinType>(account, order.fiat_code, coin_for_fiat, coin_amount, release_time);
    unrecord_fill(registry, fiat_senders, account.addr(), order_id);

    expired.destroy_empty();
}

public fun resolve_dispute_buy_order<CoinType>(
    _: &AdminCap,
    registry: &mut OrderRegistry,
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    policy: &mut Policy,
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
    let outcome = intents::outcome(executable.intent());
    let coin_senders = outcome.coin_senders().keys();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillBuyAction<CoinType> { order_id, mut coin, taker } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - coin.value();

    policy.collect(&mut coin, ctx);

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
    unrecord_fill(registry, coin_senders, account.addr(), order_id);

    expired.destroy_empty();
}

public fun resolve_dispute_sell_order<CoinType>(
    _: &AdminCap,
    registry: &mut OrderRegistry,
    mut executable: Executable<Handshake>,
    account: &mut Account<P2PRamp>,
    policy: &mut Policy,
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
    let outcome = intents::outcome(executable.intent());
    let fiat_senders = outcome.fiat_senders().keys();
    account.confirm_execution(executable);
    let mut expired = account.destroy_empty_intent<_, Handshake>(key);
    let FillSellAction { order_id, amount, taker } = expired.remove_action();

    let order = get_order_mut<CoinType>(account, order_id);
    order.pending_fill = order.pending_fill - amount;

    let coin_for_fiat = order.get_price_ratio() * amount / MUL;
    let mut coin = order.coin_balance.split(coin_for_fiat).into_coin(ctx);

    policy.collect(&mut coin, ctx);

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
    unrecord_fill(registry, fiat_senders, account.addr(), order_id);

    expired.destroy_empty();
}

public fun resolve_expired_buy_order_fill<CoinType>(
    registry: &mut OrderRegistry,
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
    let outcome = intents::outcome(executable.intent());
    let coin_senders = outcome.coin_senders().keys();
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

    p2p_ramp::record_failed_trade(account);
    unrecord_fill(registry, coin_senders, account.addr(), order_id);

    expired.destroy_empty();
}

public fun resolve_expired_sell_order_fill<CoinType>(
    registry: &mut OrderRegistry,
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
    let outcome = intents::outcome(executable.intent());
    let fiat_senders = outcome.fiat_senders().keys();
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

    unrecord_fill(registry, fiat_senders, account.addr(), order_id);

    expired.destroy_empty();
}

/// Allow a merchant to cancel a fill on their own BUY order
/// before they have sent payment. Returns the taker's locked coins to them.
public fun merchant_cancel_buy_fill<CoinType>(
    registry: &mut OrderRegistry,
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
    let outcome = intents::outcome(executable.intent());
    let coin_senders = outcome.coin_senders().keys();
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
    unrecord_fill(registry, coin_senders, account.addr(), order_id);

    expired.destroy_empty();
}

/// NEW: Public function for a taker to cancel their fill on a SELL order
/// before they have sent payment. Refunds their gas_bond.
public fun taker_cancel_sell_order_fill<CoinType>(
    registry: &mut OrderRegistry,
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
    let outcome = intents::outcome(executable.intent());
    let fiat_senders = outcome.fiat_senders().keys();
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
    unrecord_fill(registry, fiat_senders, account.addr(), order_id);
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

public fun get_order_ids_by_account(
    registry: &OrderRegistry,
    account_addr: address
): vector<address> {
    if (registry.orders.contains(account_addr)) {
        let order_set = registry.orders.borrow(account_addr);
        let mut orders_copy = vector::empty<address>();
        vector::do_ref!(order_set.keys(), |k| {
            orders_copy.push_back(*k);
        });
        orders_copy
    } else {
        vector::empty<address>()
    }
}

public fun get_fill_ids_by_filler(
    registry: &OrderRegistry,
    filler_addr: address
): &VecMap<address, address> {
    assert!(registry.fills.contains(filler_addr), EFillNotFound);
    registry.fills.borrow(filler_addr)
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

fun record_fill(
    registry: &mut OrderRegistry,
    keys: &vector<address>,
    account_addr: address,
    order_id: address,
) {
    vector::do_ref!(keys, |k| {
        if (table::contains(&registry.fills, *k)) {
            let fill_map = registry.fills.borrow_mut(*k);
            if (fill_map.contains(&account_addr)) {
                fill_map.insert(account_addr, order_id);
            }
        } else {
            let new_fill_map = vec_map::from_keys_values(vector[account_addr], vector[order_id]);
            registry.fills.add(*k, new_fill_map);
         };
    });
}

/// The opposite of `record_fill`.
/// Removes an `order_id` from the `fills` registry for a given vector of keys.
/// If removing the `order_id` results in an empty set for a key, the key's
/// entire entry is removed from the table to clean up storage.
public fun unrecord_fill(
    registry: &mut OrderRegistry,
    keys: &vector<address>,
    account_addr: address,
    _order_id: address,
) {
    vector::do_ref!(keys, |k| {
        if (table::contains(&registry.fills, *k)) {
            let mut fill_map = table::remove(&mut registry.fills, *k);
            if (fill_map.contains(&account_addr)) {
                fill_map.remove(&account_addr);
                if (fill_map.is_empty()) {
                    fill_map.destroy_empty();
                } else {
                    registry.fills.add(*k, fill_map);
                }
            } else {
                registry.fills.add(*k, fill_map);
           }
        }
  });
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

// == Test Functions ==

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}