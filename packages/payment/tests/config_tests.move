#[test_only]
#[allow(implicit_const_copy)]
module account_payment::config_tests;

// === Imports ===

use std::string::String;
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
};
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::Account,
    intents,
};
use account_payment::{
    payment::{Self, Payment, Pending},
    config,
    version,
};

// === Constants ===

const OWNER: address = @0xCAFE;

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
    full_role.append_utf8(b"::config");
    full_role
}

// === Tests ===

#[test]
fun test_config_payment() {
    let (mut scenario, extensions, mut account, clock) = start();
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );

    config::request_config_payment(
        auth,
        &mut account, 
        params,
        outcome,
        vector[OWNER, @0xBABE], 
        vector[vector[full_role()], vector[]], 
        scenario.ctx()
    );

    payment::approve_intent(&mut account, b"config".to_string(), scenario.ctx());
    let mut executable = payment::execute_intent(&mut account, b"config".to_string(), &clock);
    config::execute_config_payment(&mut executable, &mut account);
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<_, Pending>(b"config".to_string());
    config::delete_config_payment(&mut expired);
    expired.destroy_empty();

    let members = account.config().members();
    assert!(members[&OWNER].contains(&full_role()));
    assert!(members[&@0xBABE].is_empty());

    end(scenario, extensions, account, clock);
}

#[test]
fun test_config_payment_deletion() {
    let (mut scenario, extensions, mut account, mut clock) = start();
    clock.increment_for_testing(1);
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );

    config::request_config_payment(
        auth,
        &mut account,
        params,
        outcome,
        vector[OWNER, @0xBABE], 
        vector[vector[full_role()], vector[]], 
        scenario.ctx()
    );

    let mut expired = account.delete_expired_intent<_, Pending>(b"config".to_string(), &clock);
    config::delete_config_payment(&mut expired);
    expired.destroy_empty();

    end(scenario, extensions, account, clock);
}

#[test, expected_failure(abort_code = payment::ENotRole)]
fun test_error_config_payment_not_role() {
    let (mut scenario, extensions, mut account, clock) = start();
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx(),
    );

    config::request_config_payment(
        auth,
        &mut account,
        params,
        outcome,
        vector[OWNER, @0xBABE], 
        vector[vector[full_role()], vector[]], 
        scenario.ctx()
    );

    
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().get_mut(&OWNER).remove(&full_role());
    payment::approve_intent(&mut account, b"config".to_string(), scenario.ctx());
    let mut executable = payment::execute_intent(&mut account, b"config".to_string(), &clock);
    config::execute_config_payment(&mut executable, &mut account);
    account.confirm_execution(executable);

    end(scenario, extensions, account, clock);
}