
module account_payment::payment;

// === Imports ===

use std::string::String;
use sui::{
    vec_set::{Self, VecSet},
    vec_map::{Self, VecMap},
    clock::Clock,
};
use account_extensions::extensions::Extensions;
use account_protocol::{
    account::{Self, Account, Auth},
    executable::Executable,
    user::User,
};
use account_payment::version;

// === Errors ===

const ENotMember: u64 = 0;
const ENotApproved: u64 = 1;
const EAlreadyApproved: u64 = 2;
const EWrongCaller: u64 = 3;
const ENotRole: u64 = 4;

// === Structs ===

/// Config Witness.
public struct Witness() has drop;

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
/// AccountProtocol and AccountPayment are added as dependencies.
public fun new_account(
    extensions: &Extensions,
    ctx: &mut TxContext,
): Account<Payment, Pending> {
    let config = Payment {
        members: vec_map::empty(),
    };

    let (protocol_addr, protocol_version) = extensions.get_latest_for_name(b"AccountProtocol".to_string());
    let (payment_addr, payment_version) = extensions.get_latest_for_name(b"AccountPayment".to_string());
    // add AccountProtocol and AccountPayment, minimal dependencies for the Multisig Account to work
    account::new(
        extensions, 
        config, 
        false, // unverified deps not authorized by default
        vector[b"AccountProtocol".to_string(), b"AccountPayment".to_string()], 
        vector[protocol_addr, payment_addr], 
        vector[protocol_version, payment_version], 
        ctx)
}

/// Authenticates the caller as an owner or member of the payment account.
public fun authenticate(
    account: &Account<Payment, Pending>,
    ctx: &TxContext
): Auth {
    account.config().assert_is_member(ctx);
    account.new_auth(version::current(), Witness())
}

/// Creates a new outcome to initiate an intent.
public fun empty_outcome(): Pending {
    Pending { approved_by: option::none() }
}

/// Only a member with the required role can approve the intent.
public fun approve(
    account: &mut Account<Payment, Pending>,
    key: String,
    ctx: &TxContext,
) {
    account.config().assert_is_member(ctx);

    let intent_mut = account.intents_mut(version::current(), Witness()).get_mut(key);
    account.config().assert_has_role(ctx.sender(), intent_mut.role());

    assert!(intent_mut.outcome_mut().approved_by.is_none(), EAlreadyApproved);
    
    intent_mut.outcome_mut().approved_by.fill(ctx.sender());
}

/// Disapproves an intent.
public fun disapprove(
    account: &mut Account<Payment, Pending>,
    key: String,
    ctx: &TxContext,
) {
    account.config().assert_is_member(ctx);

    let outcome_mut = account.intents_mut(version::current(), Witness()).get_mut(key).outcome_mut();
    assert!(outcome_mut.approved_by.is_some(), ENotApproved);
    
    let addr = outcome_mut.approved_by.extract();
    assert!(addr == ctx.sender(), EWrongCaller);
}

/// Anyone can execute an intent, this allows to automate the execution of intents.
public fun execute_intent(
    account: &mut Account<Payment, Pending>, 
    key: String, 
    clock: &Clock,
): Executable {
    let (executable, outcome) = account.execute_intent(key, clock, version::current(), Witness());
    assert!(outcome.approved_by.is_some(), ENotApproved);

    executable
}

/// Inserts account_id in User, aborts if already joined.
public fun join(user: &mut User, account: &Account<Payment, Pending>, ctx: &mut TxContext) {
    account.config().assert_is_member(ctx);
    user.add_account(account, Witness());
}

/// Removes account_id from User, aborts if not joined.
public fun leave(user: &mut User, account: &Account<Payment, Pending>) {
    user.remove_account(account, Witness());
}

// === View functions ===

public fun get_members(payment: &Payment): VecMap<address, VecSet<String>> {
    payment.members
}

public fun assert_has_role(payment: &Payment, addr: address, role: String) {
    assert!(payment.members.get(&addr).contains(&role), ENotRole);
}

public fun assert_is_member(payment: &Payment, ctx: &TxContext) {
    assert!(payment.members.contains(&ctx.sender()), ENotMember);
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
public(package) fun config_mut(account: &mut Account<Payment, Pending>): &mut Payment {
    account.config_mut(version::current(), Witness())
}