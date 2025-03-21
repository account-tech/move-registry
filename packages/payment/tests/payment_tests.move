#[test_only]
#[allow(implicit_const_copy)]
module account_payment::payment_tests;

// === Imports ===

use std::string::String;
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    vec_set,
};
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::Account,
    user::{Self, Invite},
    intents,
    intent_interface,
};
use account_payment::{
    payment::{Self, Payment, Pending},
    version,
};

// === Constants ===

const OWNER: address = @0xCAFE;
const ALICE: address = @0xA11CE;

// === Structs ===

public struct Witness() has drop;
public struct DummyIntent() has copy, drop;

// === Helpers ===

fun start(): (Scenario, Extensions, Account<Payment>, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    extensions::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    // add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"AccountPayment".to_string(), @account_payment, 1);
    // Account generic types are dummy types (bool, bool)
    let mut account = payment::new_account(&extensions, scenario.ctx());
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().get_mut(&OWNER).insert(full_role());
    let clock = clock::create_for_testing(scenario.ctx());
    // create world
    destroy(cap); 
    (scenario, extensions, account, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<Payment>, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

fun full_role(): String {
    let mut full_role = @account_payment.to_string();
    full_role.append_utf8(b"::payment_tests::Degen");
    full_role
}

fun create_and_add_dummy_intent(
    scenario: &mut Scenario,
    account: &mut Account<Payment>, 
    clock: &Clock,
) {
    let params = intents::new_params(
        b"dummy".to_string(), 
        b"description".to_string(), 
        vector[0],
        1, 
        clock,
    );
    let outcome = payment::empty_outcome();
    intent_interface::build_intent!<Payment, _, _>(
        account,
        params,
        outcome, 
        b"Degen".to_string(),
        version::current(),
        DummyIntent(), 
        scenario.ctx(),
        |intent, iw| intent.add_action(true, iw)
    );
}

// === Tests ===

#[test]
fun test_join_and_leave() {
    let (mut scenario, extensions, account, clock) = start();
    let mut user = user::new(scenario.ctx());

    payment::join(&mut user, &account, scenario.ctx());
    assert!(user.all_ids() == vector[account.addr()]);
    payment::leave(&mut user, &account);
    assert!(user.all_ids() == vector[]);

    destroy(user);
    end(scenario, extensions, account, clock);
}

#[test]  
fun test_invite_and_accept() {
    let (mut scenario, extensions, mut account, clock) = start();

    let user = user::new(scenario.ctx());
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().insert(ALICE, vec_set::empty());
    payment::send_invite(&account, ALICE, scenario.ctx());

    scenario.next_tx(ALICE);
    let invite = scenario.take_from_sender<Invite>();
    user::refuse_invite(invite);
    assert!(user.all_ids() == vector[]);

    destroy(user);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_invite_and_refuse() {
    let (mut scenario, extensions, mut account, clock) = start();

    let mut user = user::new(scenario.ctx());
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().insert(ALICE, vec_set::empty());
    payment::send_invite(&account, ALICE, scenario.ctx());

    scenario.next_tx(ALICE);
    let invite = scenario.take_from_sender<Invite>();
    user.accept_invite(invite);
    assert!(user.all_ids() == vector[account.addr()]);

    destroy(user);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_members_accessors() {
    let (mut scenario, extensions, account, clock) = start();

    assert!(account.config().members().keys() == vector[OWNER]);
    account.config().assert_is_member(scenario.ctx());
    account.config().assert_has_role(full_role(), scenario.ctx());

    end(scenario, extensions, account, clock);
}

#[test]
fun test_intent_approval() {
    let (mut scenario, extensions, mut account, clock) = start();

    // create intent
    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    // approve
    payment::approve_intent(&mut account, b"dummy".to_string(), scenario.ctx());
    let outcome = account.intents().get<Pending>(b"dummy".to_string()).outcome();
    assert!(outcome.approved_by() == option::some(OWNER));
    // disapprove
    payment::disapprove_intent(&mut account, b"dummy".to_string(), scenario.ctx());
    let outcome = account.intents().get<Pending>(b"dummy".to_string()).outcome();
    assert!(outcome.approved_by() == option::none());

    end(scenario, extensions, account, clock);
}

#[test]
fun test_intent_execution() {
    let (mut scenario, extensions, mut account, clock) = start();

    // create intent
    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    // approve
    payment::approve_intent(&mut account, b"dummy".to_string(), scenario.ctx());
    // execute intent
    let mut executable = payment::execute_intent(&mut account, b"dummy".to_string(), &clock);
    executable.next_action<Pending, bool, _>(DummyIntent());
    account.confirm_execution(executable);

    let expired = account.destroy_empty_intent<_, Pending>(b"dummy".to_string());

    destroy(expired);
    end(scenario, extensions, account, clock);
}

#[test]
fun test_intent_deletion() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    clock.increment_for_testing(1);

    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    let expired = account.delete_expired_intent<_, Pending>(b"dummy".to_string(), &clock);

    destroy(expired);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotMember)]
fun test_error_approve_not_member() {
    let (mut scenario, extensions, mut account, clock) = start();

    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().remove(&OWNER);
    payment::approve_intent(&mut account, b"dummy".to_string(), scenario.ctx());

    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotRole)]
fun test_error_approve_not_role() {
    let (mut scenario, extensions, mut account, clock) = start();

    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().get_mut(&OWNER).remove(&full_role());
    payment::approve_intent(&mut account, b"dummy".to_string(), scenario.ctx());

    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::EAlreadyApproved)]
fun test_error_approve_already_approved() {
    let (mut scenario, extensions, mut account, clock) = start();

    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    payment::approve_intent(&mut account, b"dummy".to_string(), scenario.ctx());
    payment::approve_intent(&mut account, b"dummy".to_string(), scenario.ctx());

    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotMember)]
fun test_error_disapprove_not_member() {
    let (mut scenario, extensions, mut account, clock) = start();

    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().remove(&OWNER);

    payment::approve_intent(&mut account, b"dummy".to_string(), scenario.ctx());
    payment::disapprove_intent(&mut account, b"dummy".to_string(), scenario.ctx());

    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotApproved)]
fun test_error_disapprove_not_approved() {
    let (mut scenario, extensions, mut account, clock) = start();

    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    payment::disapprove_intent(&mut account, b"dummy".to_string(), scenario.ctx());

    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::EWrongCaller)]
fun test_error_disapprove_wrong_caller() {
    let (mut scenario, extensions, mut account, clock) = start();
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().insert(@0xB0B, vec_set::empty());

    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    payment::approve_intent(&mut account, b"dummy".to_string(), scenario.ctx());

    scenario.next_tx(@0xB0B);
    payment::disapprove_intent(&mut account, b"dummy".to_string(), scenario.ctx());

    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotApproved)]
fun test_error_execute_not_approved() {
    let (mut scenario, extensions, mut account, clock) = start();

    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);
    let executable = payment::execute_intent(&mut account, b"dummy".to_string(), &clock);

    destroy(executable);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotMember)]
fun test_error_join_not_member() {
    let (mut scenario, extensions, mut account, clock) = start();
    let mut user = user::new(scenario.ctx());

    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().remove(&OWNER);
    payment::join(&mut user, &account, scenario.ctx());

    destroy(user);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotMember)]  
fun test_invite_not_member() {
    let (mut scenario, extensions, mut account, clock) = start();
    let user = user::new(scenario.ctx());

    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().remove(&OWNER);
    payment::send_invite(&account, ALICE, scenario.ctx());

    destroy(user);
    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotMember)]  
fun test_invite_recipient_not_member() {
    let (mut scenario, extensions, account, clock) = start();
    let user = user::new(scenario.ctx());

    payment::send_invite(&account, ALICE, scenario.ctx());

    destroy(user);
    end(scenario, extensions, account, clock);
}