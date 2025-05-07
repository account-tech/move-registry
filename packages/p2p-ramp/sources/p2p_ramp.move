
module p2p_ramp::p2p_ramp;

// === Imports ===

use std::string::String;
use sui::{
    vec_set::{Self, VecSet},
    clock::Clock,
};
use account_extensions::extensions::Extensions;
use account_protocol::{
    account::{Account, Auth},
    executable::Executable,
    user::{Self, User},
    deps,
    account_interface,
};
use p2p_ramp::version;

// === Aliases ===

use fun account_interface::create_auth as Account.create_auth;
use fun account_interface::resolve_intent as Account.resolve_intent;
use fun account_interface::execute_intent as Account.execute_intent;

// === Errors ===

const ENotMember: u64 = 0;
const ENotApproved: u64 = 1;
const EAlreadyApproved: u64 = 2;

// === Structs ===

/// Config ConfigWitness.
public struct ConfigWitness() has drop;

/// Config struct with the members
public struct P2PRamp has copy, drop, store {
    // addresses that can manage the account 
    members: VecSet<address>,
}

/// Outcome struct with the approved address
public struct Active has copy, drop, store {
    // if owner approved the intent
    approved: bool, 
}

// === Public functions ===

/// Init and returns a new Account object.
/// Creator is added by default.
/// AccountProtocol and P2PRamp are added as dependencies.
public fun new_account(
    extensions: &Extensions,
    ctx: &mut TxContext,
): Account<P2PRamp> {
    let config = P2PRamp {
        members: vec_set::from_keys(vector[ctx.sender()]),
    };
    
    account_interface::create_account!(
        config,
        version::current(),
        ConfigWitness(),
        ctx,
        || deps::new_latest_extensions(
            extensions,
            vector[b"AccountProtocol".to_string(), b"P2PRamp".to_string()]
        )
    )
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

/// Creates a new outcome to initiate an intent.
public fun empty_outcome(): Active {
    Active { approved: false }
}

/// Only a member with the required role can approve the intent.
public fun approve_intent(
    account: &mut Account<P2PRamp>,
    key: String,
    ctx: &TxContext,
) {
    account.config().assert_is_member(ctx);

    account.resolve_intent!<_, Active, _>(
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

    account.resolve_intent!<_, Active, _>(
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
public fun execute_intent(
    account: &mut Account<P2PRamp>, 
    key: String, 
    clock: &Clock,
): Executable<Active> {
    account.execute_intent!<_, Active, _>(
        key, 
        clock, 
        version::current(), 
        ConfigWitness(),
        |outcome| assert!(outcome.approved == true, ENotApproved)
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

public fun approved(active: &Active): bool {
    active.approved
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
public fun config_witness(): ConfigWitness {
    ConfigWitness()
}

#[test_only]
public fun members_mut_for_testing(ramp: &mut P2PRamp): &mut VecSet<address> {
    &mut ramp.members
}