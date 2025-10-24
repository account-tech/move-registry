
module account_payment::payment;

// === Imports ===

use std::{
    string::String,
    type_name,
};
use sui::{
    vec_set::{Self, VecSet},
    vec_map::{Self, VecMap},
    clock::Clock,
};
use account_extensions::extensions::Extensions;
use account_protocol::{
    account::{Account, Auth},
    deps,
    executable::Executable,
    user::{Self, User},
    account_interface,
};
use account_payment::version;

// === Aliases ===

use fun account_interface::create_auth as Account.create_auth;
use fun account_interface::resolve_intent as Account.resolve_intent;
use fun account_interface::execute_intent as Account.execute_intent;

// === Errors ===

const ENotMember: u64 = 0;
const ENotApproved: u64 = 1;
const EAlreadyApproved: u64 = 2;
const EWrongCaller: u64 = 3;
const ENotRole: u64 = 4;

// === Structs ===

/// Config Witness.
public struct ConfigWitness() has drop;

/// Config struct with the members
public struct Payment has copy, drop, store {
    // addresses with roles 
    members: VecMap<address, VecSet<String>>,
}

/// Outcome struct with the approved address
public struct Pending has copy, drop, store {
    // None if not approved yet
    approved_by: Option<address>, 
}

// === Public functions ===

/// Init and returns a new Account object.
/// Creator is added by default.
/// account_protocol and account_payment are added as dependencies.
public fun new_account(
    extensions: &Extensions,
    ctx: &mut TxContext,
): Account<Payment> {
    let config = Payment {
        members: vec_map::from_keys_values(vector[ctx.sender()], vector[vec_set::empty()]),
    };

    account_interface::create_account!(
        config,
        version::current(),
        ConfigWitness(),
        ctx,
        || deps::new_latest_extensions(
            extensions,
            vector[b"account_protocol".to_string(), b"account_payment".to_string()]
        )
    )
}

/// Authenticates the caller as an owner or member of the payment account.
public fun authenticate(
    account: &Account<Payment>,
    ctx: &TxContext
): Auth {
    account.create_auth!(
        version::current(),
        ConfigWitness(),
        || account.config().assert_is_member(ctx)
    )
}

/// Creates a new outcome to initiate an intent.
public fun empty_outcome(): Pending {
    Pending { approved_by: option::none() }
}

/// Only a member with the required role can approve the intent.
public fun approve_intent(
    account: &mut Account<Payment>,
    key: String,
    ctx: &TxContext,
) {
    account.config().assert_is_member(ctx);
    // get the initial package id to get the intent type
    let mut config_intent_type = type_name::with_defining_ids<ConfigWitness>().get_address().to_string();
    config_intent_type.append_utf8(b"::config::ConfigPaymentIntent");
    // config intent can be executed by any member
    if (account.intents().get<Pending>(key).type_().into_string().to_string() != config_intent_type) {
        account.config().assert_has_role(account.intents().get<Pending>(key).role(), ctx);
    };
        
    account.resolve_intent!<_, Pending, _>(
        key, 
        version::current(), 
        ConfigWitness(),
        |outcome| {
            assert!(outcome.approved_by.is_none(), EAlreadyApproved);
            outcome.approved_by.fill(ctx.sender());
        }
    );
}

/// Disapproves an intent.
public fun disapprove_intent(
    account: &mut Account<Payment>,
    key: String,
    ctx: &TxContext,
) {
    account.config().assert_is_member(ctx);
    
    account.resolve_intent!<_, Pending, _>(
        key, 
        version::current(), 
        ConfigWitness(),
        |outcome| {
            assert!(outcome.approved_by.is_some(), ENotApproved);
            assert!(outcome.approved_by.extract() == ctx.sender(), EWrongCaller);
        }
    );
}

/// Anyone can execute an intent, this allows to automate the execution of intents.
public fun execute_intent(
    account: &mut Account<Payment>, 
    key: String, 
    clock: &Clock,
): Executable<Pending> {
    account.execute_intent!<_, Pending, _>(
        key, 
        clock, 
        version::current(), 
        ConfigWitness(),
        |outcome| {
            outcome.validate_outcome()
        }
    )
}

public use fun validate_outcome as Pending.validate;
public fun validate_outcome(outcome: Pending) {
    let Pending { approved_by } = outcome;
    assert!(approved_by.is_some(), ENotApproved);
}

/// Inserts account_id in User, aborts if already joined.
public fun join(user: &mut User, account: &Account<Payment>, ctx: &mut TxContext) {
    account.config().assert_is_member(ctx);
    user.add_account(account, ConfigWitness());
}

/// Removes account_id from User, aborts if not joined.
public fun leave(user: &mut User, account: &Account<Payment>) {
    user.remove_account(account, ConfigWitness());
}

/// Invites can be sent by a Multisig member when added to the Multisig.
public fun send_invite(account: &Account<Payment>, recipient: address, ctx: &mut TxContext) {
    // user inviting must be member
    account.config().assert_is_member(ctx);
    // invited user must be member
    assert!(account.config().members().contains(&recipient), ENotMember);

    user::send_invite(account, recipient, ConfigWitness(), ctx);
}

// === View functions ===

public fun members(payment: &Payment): VecMap<address, VecSet<String>> {
    payment.members
}

public fun assert_has_role(payment: &Payment, role: String, ctx: &TxContext) {
    assert!(payment.members.get(&ctx.sender()).contains(&role), ENotRole);
}

public fun assert_is_member(payment: &Payment, ctx: &TxContext) {
    assert!(payment.members.contains(&ctx.sender()), ENotMember);
}

public fun approved_by(pending: &Pending): Option<address> {
    pending.approved_by
}

// === Package functions ===

/// Creates a new Payment configuration.
public(package) fun new_config(
    addrs: vector<address>,
    roles: vector<vector<String>>,
): Payment {
    let mut members = vec_map::empty();
    addrs.zip_do!(roles, |addr, roles| {
        members.insert(addr, vec_set::from_keys(roles));
    });

    Payment { members }
}

/// Returns a mutable reference to the Payment configuration.
public(package) fun config_mut(account: &mut Account<Payment>): &mut Payment {
    account.config_mut(version::current(), ConfigWitness())
}

// === Test functions ===

#[test_only]
public fun config_witness(): ConfigWitness {
    ConfigWitness()
}

#[test_only]
public fun members_mut_for_testing(payment: &mut Payment): &mut VecMap<address, VecSet<String>> {
    &mut payment.members
}