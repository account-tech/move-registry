
module p2p_ramp::p2p_ramp;

// === Imports ===

use std::{
    string::String,
    type_name::{Self, TypeName}
};
use sui::{
    vec_set::{Self, VecSet},
    clock::Clock,
    table::{Self, Table},
    vec_map::{Self, VecMap},
    event,
};
use account_extensions::extensions::Extensions;
use account_protocol::{
    account::{Account, Auth},
    executable::Executable,
    user::{Self, User},
    deps,
    account_interface,
};

use p2p_ramp::{
    fees::AdminCap,
    version
};

// === Aliases ===

use fun account_interface::create_auth as Account.create_auth;
use fun account_interface::resolve_intent as Account.resolve_intent;
use fun account_interface::execute_intent as Account.execute_intent;

// === Errors ===

const ENotMember: u64 = 0;
const ENotApproved: u64 = 1;
const EAlreadyApproved: u64 = 2;
const ENotRequested: u64 = 3;
const ENotPaid: u64 = 4;
const ENotFiatSender: u64 = 5;
const ENotCoinSender: u64 = 6;
const ECannotDispute: u64 = 7;
const ENotSettled: u64 = 8;
const ENotDisputed: u64 = 9;
const EPaymentWindowExpired: u64 = 10;
const EPaymentWindowNotExpired: u64 = 11;

// === Events ===

public struct FillEvent has copy, drop {
    status: Status,
    key: String,
    by: address
}

// === Structs ===

/// Config ConfigWitness.
public struct ConfigWitness() has drop;

/// Central registry for all merchant accounts
public struct Registry has key {
    id: UID,
    merchants: Table<address, bool>
}

/// Config struct with the members
public struct P2PRamp has copy, drop, store {
    // addresses that can manage the account 
    members: VecSet<address>,
}

public struct Reputation has store {
    successful_trades: u64,
    failed_trades: u64,
    total_coin_volume: VecMap<TypeName, u64>,
    total_fiat_volume: VecMap<String, u64>,
    total_release_time_ms: u128,
    disputes_won: u64,
    disputes_lost: u64,
}

/// Df key for Reputation
public struct ReputationKey() has copy, drop, store;

/// Outcome struct with the approved address
public struct Approved has copy, drop, store {
    // if owner approved the intent
    approved: bool,
}

/// Outcome for resolving an order
public struct Handshake has copy, drop, store {
    // addresses of the party that will send the fiat
    fiat_senders: VecSet<address>,
    // addresses of the party that will send the coin
    coin_senders: VecSet<address>,
    // status of the handshake
    status: Status,
    // ms by which payment must be flagged. Whatever the taker passes to this will be overwritten
    // by the order authority
    payment_deadline_ms: u64,
    // timestamp of when the fiat sender confirmed payment.
    paid_timestamp_ms: u64,
    // timestamp of when the coin sender confirmed receipt of fiat.
    settled_timestamp_ms: u64,
}

/// Enum for tracking request status
public enum Status has copy, drop, store {
    // customer requested to fill an order partially
    Requested,
    // fiat payment has been sent by concerned party
    Paid,
    // fiat payment has been confirmed as received, intent can be executed
    Settled,
    // order disputed, one party has disputed the order, blocking the intent until resolution
    Disputed,
}

// === Public functions ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(Registry {
        id: object::new(ctx),
        merchants: table::new(ctx),
    });
}

/// Init and returns a new Account object.
/// Creator is added by default.
/// AccountProtocol and P2PRamp are added as dependencies.
public fun new_account(
    registry: &mut Registry,
    extensions: &Extensions,
    ctx: &mut TxContext,
): Account<P2PRamp> {
    let config = P2PRamp {
        members: vec_set::from_keys(vector[ctx.sender()]),
    };

   let mut account = account_interface::create_account!(
        config,
        version::current(),
        ConfigWitness(),
        ctx,
        || deps::new_latest_extensions(
            extensions,
            vector[b"AccountProtocol".to_string(), b"P2PRamp".to_string()]
        )
    );

    // we initialize key metrics for this account
    account.add_managed_data(
        ReputationKey(),
        Reputation {
            successful_trades: 0,
            failed_trades: 0,
            total_coin_volume: vec_map::empty(),
            total_fiat_volume: vec_map::empty(),
            total_release_time_ms: 0,
            disputes_won: 0,
            disputes_lost: 0,
        },
        version::current(),
    );

    // we'll use the bool for toggling availability
    registry.merchants.add(account.addr(), true);

    account
}

/// Authenticates the caller as an owner of the P2PRamp account.
public fun authenticate(
    account: &Account<P2PRamp>,
    ctx: &TxContext
): Auth {
    account.create_auth!(
        version::current(),
        ConfigWitness(),
        || account.config().assert_is_member(ctx)
    )
}

// Approved intents

/// Creates a new outcome to initiate a standard intent.
public fun empty_approved_outcome(): Approved {
    Approved { approved: false }
}

/// Only a member with the required role can approve the intent.
public fun approve_intent(
    account: &mut Account<P2PRamp>,
    key: String,
    ctx: &TxContext,
) {
    account.config().assert_is_member(ctx);

    account.resolve_intent!<_, Approved, _>(
        key,
        version::current(),
        ConfigWitness(),
        |outcome| {
            assert!(!outcome.approved, EAlreadyApproved);
            outcome.approved = true;
        }
    );
}

/// Disapproves an intent.
public fun disapprove_intent(
    account: &mut Account<P2PRamp>,
    key: String,
    ctx: &TxContext,
) {
    account.config().assert_is_member(ctx);

    account.resolve_intent!<_, Approved, _>(
        key,
        version::current(),
        ConfigWitness(),
        |outcome| {
            assert!(outcome.approved, ENotApproved);
            outcome.approved = false
        }
    );
}

/// Anyone can execute an intent, this allows to automate the execution of intents.
public fun execute_approved_intent(
    account: &mut Account<P2PRamp>,
    key: String,
    clock: &Clock,
): Executable<Approved> {
    account.execute_intent!<_, Approved, _>(
        key,
        clock,
        version::current(),
        ConfigWitness(),
        |outcome| assert!(outcome.approved == true, ENotApproved)
    )
}

/// Allows a merchant to execute a cancellation on a BUY ORDER fill
/// that they have not yet paid for.
public fun execute_merchant_cancellation_intent(
    account: &mut Account<P2PRamp>,
    key: String,
    clock: &Clock,
    ctx: &TxContext,
): Executable<Handshake> {
    account.config().assert_is_member(ctx);

    account.execute_intent!<_, Handshake, _>(
        key,
        clock,
        version::current(),
        ConfigWitness(),
        |outcome| {
            assert!(outcome.status == Status::Requested, ENotRequested);
            assert!(outcome.fiat_senders.contains(&ctx.sender()), ENotFiatSender);
        }
    )
}

public fun execute_sell_order_taker_cancellation(
    account: &mut Account<P2PRamp>,
    key: String,
    clock: &Clock,
    ctx: &mut TxContext,
): Executable<Handshake> {
    account.execute_intent!<_, Handshake, _>(
        key,
        clock,
        version::current(),
        ConfigWitness(),
        |outcome| {
            assert!(outcome.status == Status::Requested, ENotRequested);
            assert!(outcome.fiat_senders.contains(&ctx.sender()), ENotFiatSender);
        }
    )
}

// Handshake (order) intents

public fun requested_handshake_outcome(
    fiat_senders: vector<address>,
    coin_senders: vector<address>,
): Handshake {
    Handshake {
        fiat_senders: vec_set::from_keys(fiat_senders),
        coin_senders: vec_set::from_keys(coin_senders),
        payment_deadline_ms: 0,
        paid_timestamp_ms: 0,
        settled_timestamp_ms: 0,
        status: Status::Requested,
    }
}

public fun flag_as_paid(
    account: &mut Account<P2PRamp>,
    key: String,
    clock: &Clock,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    account.resolve_intent!<_, Handshake, _>(
        key,
        version::current(),
        ConfigWitness(),
        |outcome| {
            assert!(outcome.status == Status::Requested, ENotRequested);
            assert!(outcome.fiat_senders.contains(&sender), ENotFiatSender);
            assert!(clock.timestamp_ms() <= outcome.payment_deadline_ms, EPaymentWindowExpired);
            outcome.paid_timestamp_ms = clock.timestamp_ms();
            outcome.status = Status::Paid;
        }
    );

    event::emit(FillEvent {
        status: Status::Paid,
        key,
        by: sender
    });

}

public fun flag_as_settled(
    account: &mut Account<P2PRamp>,
    key: String,
    clock: &Clock,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    account.resolve_intent!<_, Handshake, _>(
        key,
        version::current(),
        ConfigWitness(),
        |outcome| {
            assert!(outcome.status == Status::Paid, ENotPaid);
            assert!(outcome.coin_senders.contains(&sender), ENotCoinSender);
            outcome.settled_timestamp_ms = clock.timestamp_ms();
            outcome.status = Status::Settled;
        }
    );

    event::emit(FillEvent {
        status: Status::Settled,
        key,
        by: sender,
    });
}

public fun flag_as_disputed(
    account: &mut Account<P2PRamp>,
    key: String,
    ctx: &TxContext,
) {
    let sender = ctx.sender();
    account.resolve_intent!<_, Handshake, _>(
        key,
        version::current(),
        ConfigWitness(),
        |outcome| {
            assert!(
                (outcome.status == Status::Requested ||
                outcome.status == Status::Paid) &&
                (outcome.coin_senders.contains(&sender) ||
                outcome.fiat_senders.contains(&sender)),
                ECannotDispute
            );
            outcome.status = Status::Disputed;
        }
    );

    event::emit(FillEvent {
        status: Status::Disputed,
        key,
        by: sender,
    });
}

public fun execute_handshake_intent(
    account: &mut Account<P2PRamp>,
    key: String,
    clock: &Clock,
): Executable<Handshake> {
    account.execute_intent!<_, Handshake, _>(
        key,
        clock,
        version::current(),
        ConfigWitness(),
        |outcome| assert!(outcome.status == Status::Settled, ENotSettled)
    )
}

public fun resolve_handshake_intent(
    _: &AdminCap,
    account: &mut Account<P2PRamp>,
    key: String,
    clock: &Clock,
): Executable<Handshake> {
    account.execute_intent!<_, Handshake, _>(
        key,
        clock,
        version::current(),
        ConfigWitness(),
        |outcome| assert!(outcome.status == Status::Disputed, ENotDisputed)
    )
}

public fun resolve_handshake_intent_expired_fill(
    account: &mut Account<P2PRamp>,
    key: String,
    clock: &Clock,
) : Executable<Handshake> {
    account.execute_intent!<_, Handshake, _>(
        key,
        clock,
        version::current(),
        ConfigWitness(),
        |outcome|  {
            assert!(clock.timestamp_ms() > outcome.payment_deadline_ms, EPaymentWindowNotExpired);
            assert!(outcome.status == Status::Requested, ENotRequested);
        }
    )
}

/// Inserts account_id in User, aborts if already joined.
public fun join(user: &mut User, account: &Account<P2PRamp>, ctx: &mut TxContext) {
    account.config().assert_is_member(ctx);
    user.add_account(account, ConfigWitness());
}

/// Removes account_id from User, aborts if not joined.
public fun leave(user: &mut User, account: &Account<P2PRamp>) {
    user.remove_account(account, ConfigWitness());
}

/// Invites can be sent by a Multisig member when added to the Multisig.
public fun send_invite(account: &Account<P2PRamp>, recipient: address, ctx: &mut TxContext) {
    // user inviting must be member
    account.config().assert_is_member(ctx);
    // invited user must be member
    assert!(account.config().members().contains(&recipient), ENotMember);

    user::send_invite(account, recipient, ConfigWitness(), ctx);
}

// === View functions ===

public fun members(ramp: &P2PRamp): VecSet<address> {
    ramp.members
}

public fun is_member(ramp: &P2PRamp, addr: address): bool {
    ramp.members.contains(&addr)
}

public fun assert_is_member(ramp: &P2PRamp, ctx: &TxContext) {
    assert!(is_member(ramp, ctx.sender()), ENotMember);
}

public fun approved(active: &Approved): bool {
    active.approved
}

public fun fiat_senders(handshake: &Handshake): VecSet<address> {
    handshake.fiat_senders
}

public fun coin_senders(handshake: &Handshake): VecSet<address> {
    handshake.coin_senders
}

public fun payment_deadline_ms(handshake: &Handshake): u64 {
    handshake.payment_deadline_ms
}

public fun paid_timestamp_ms(handshake: &Handshake): u64 {
    handshake.paid_timestamp_ms
}

public fun settled_timestamp_ms(handshake: &Handshake): u64 {
    handshake.settled_timestamp_ms
}

public fun status(handshake: &Handshake): Status {
    handshake.status
}

public fun reputation(account: &Account<P2PRamp>): &Reputation {
    account.borrow_managed_data(ReputationKey(), version::current())
}

public fun successful_trades(rep: &Reputation) : u64 {
    rep.successful_trades
}

public fun total_coin_volume(rep: &Reputation): VecMap<TypeName, u64> {
    return rep.total_coin_volume
}

public fun total_fiat_volume(rep: &Reputation): VecMap<String, u64> {
    return rep.total_fiat_volume
}

public fun total_release_time_ms(rep: &Reputation): u128 {
    return rep.total_release_time_ms
}

public fun disputes_won(rep: &Reputation): u64 {
    return rep.disputes_won
}

public fun disputes_lost(rep: &Reputation): u64 {
    return rep.disputes_lost
}

/// Calculates and returns the average release time for a given Account.
public fun avg_release_time_ms(rep: &Reputation): u64 {

    if (rep.successful_trades == 0) {
        return 0
    };

    (rep.total_release_time_ms / (rep.successful_trades as u128)) as u64
}

/// Calculates and returns the merchant's completion rate for a given Account.
public fun completion_rate(rep: &Reputation): u8 {

    let successful = rep.successful_trades;
    let failed = rep.failed_trades;
    let total = successful + failed;

    if (total == 0) {
        return 0
    };

    let rate = (successful * 100) / total;

    rate as u8
}

// === Package functions ===

/// Creates a new P2PRamp configuration.
public(package) fun new_config(
    addrs: vector<address>,
): P2PRamp {
    P2PRamp { members: vec_set::from_keys(addrs) }
}

/// Returns a mutable reference to the P2PRamp configuration.
public(package) fun config_mut(account: &mut Account<P2PRamp>): &mut P2PRamp {
    account.config_mut(version::current(), ConfigWitness())
}

/// Returns a mutable reference to the account reputation
public(package) fun get_rep_mut(
    account: &mut Account<P2PRamp>,
) : &mut Reputation {
    account.borrow_managed_data_mut(ReputationKey(), version::current())
}

public(package) fun set_payment_deadline(
    handshake: &mut Handshake,
    new_deadline: u64,
) {
    handshake.payment_deadline_ms = new_deadline;
}

/// Updates accounts' reputation for successful trades
public(package) fun record_successful_trade<CoinType>(
    account: &mut Account<P2PRamp>,
    fiat_code: String,
    fiat_amount: u64,
    coin_amount: u64,
    release_time_ms: u64,
) {
    let rep = get_rep_mut(account);
    let coin_type_name = type_name::get<CoinType>();
    rep.successful_trades = rep.successful_trades + 1;

    if (rep.total_fiat_volume.contains(&fiat_code)) {
        let current_fiat_vol = rep.total_fiat_volume.get_mut(&fiat_code);
        *current_fiat_vol = *current_fiat_vol + fiat_amount;
    } else {
        rep.total_fiat_volume.insert(fiat_code, fiat_amount);
    };

    if (rep.total_coin_volume.contains(&coin_type_name)) {
        let current_coin_vol = rep.total_coin_volume.get_mut(&coin_type_name);
        *current_coin_vol = *current_coin_vol + coin_amount;
    } else {
        rep.total_coin_volume.insert(coin_type_name, coin_amount);
    };

    rep.total_release_time_ms = rep.total_release_time_ms + (release_time_ms as u128);
}

public(package) fun record_dispute_outcome(
    account: &mut Account<P2PRamp>,
    winner: address,
) {
    let members = account.config().members();
    let rep = get_rep_mut(account);

    if (members.contains(&winner)) {
        rep.disputes_won = rep.disputes_won + 1;
    } else {
        rep.disputes_lost = rep.disputes_lost + 1;
        rep.failed_trades = rep.failed_trades + 1;
    }
}

public(package) fun record_failed_trade(account: &mut Account<P2PRamp>) {
    let rep = get_rep_mut(account);
    rep.failed_trades = rep.failed_trades + 1;
}

// === Test functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun config_witness(): ConfigWitness {
    ConfigWitness()
}

#[test_only]
public fun members_mut_for_testing(ramp: &mut P2PRamp): &mut VecSet<address> {
    &mut ramp.members
}

#[test_only]
public fun add_member(
    account: &mut P2PRamp,
    addr: address,
) {
    account.members.insert(addr);
}