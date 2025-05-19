
module p2p_ramp::p2p_ramp;

// === Imports ===

use std::string::String;
use sui::{
    vec_set::{Self, VecSet},
    clock::Clock,
    table::{Self, Table}
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

/// Outcome struct with the approved address
public struct Approved has copy, drop, store {
    // if owner approved the intent
    approved: bool, 
}

/// Outcome for resolving an order
public struct Handshake has copy, drop, store {
    // address of the party that will send the fiat
    fiat_sender: address, 
    // address of the party that will send the coin
    coin_sender: address, 
    // status of the handshake
    status: Status,
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
    
   let account = account_interface::create_account!(
        config,
        version::current(),
        ConfigWitness(),
        ctx,
        || deps::new_latest_extensions(
            extensions,
            vector[b"AccountProtocol".to_string(), b"P2PRamp".to_string()]
        )
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

// Handshake (order) intents

public(package) fun requested_handshake_outcome(
    fiat_sender: address,
    coin_sender: address,
): Handshake {
    Handshake { 
        fiat_sender,
        coin_sender,
        status: Status::Requested,
    }
}

public fun flag_as_paid(
    account: &mut Account<P2PRamp>,
    key: String,
    ctx: &TxContext,
) {

    account.resolve_intent!<_, Handshake, _>(
        key, 
        version::current(), 
        ConfigWitness(), 
        |outcome| {
            assert!(outcome.status == Status::Requested, ENotRequested);
            assert!(outcome.fiat_sender == ctx.sender(), ENotFiatSender);
            outcome.status = Status::Paid;
        }
    );
}

public fun flag_as_settled(
    account: &mut Account<P2PRamp>,
    key: String,
    ctx: &TxContext,
) {
    account.resolve_intent!<_, Handshake, _>(
        key, 
        version::current(), 
        ConfigWitness(), 
        |outcome| {
            assert!(outcome.status == Status::Paid, ENotPaid);
            assert!(outcome.coin_sender == ctx.sender(), ENotCoinSender);
            outcome.status = Status::Settled;
        }
    );
}

public fun flag_as_disputed(
    account: &mut Account<P2PRamp>,
    key: String,
    ctx: &TxContext,
) {
    account.resolve_intent!<_, Handshake, _>(
        key, 
        version::current(), 
        ConfigWitness(), 
        |outcome| {
            assert!(
                (outcome.status == Status::Requested ||
                outcome.status == Status::Paid) &&
                (outcome.coin_sender == ctx.sender() || 
                outcome.fiat_sender == ctx.sender()), 
                ECannotDispute
            );
            outcome.status = Status::Disputed;
        }
    );
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

public fun fiat_sender(handshake: &Handshake): address {
    handshake.fiat_sender
}

public fun coin_sender(handshake: &Handshake): address {
    handshake.coin_sender
}

public fun status(handshake: &Handshake): Status {
    handshake.status
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