#[test_only]
module p2p_ramp::config_tests;

// === Imports ===

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
use p2p_ramp::{
    p2p_ramp::{P2PRamp, Approved},
    fees::{Self, Fees},
    config
};

// === Constants ===

const OWNER: address = @0xCAFE;

// === Helpers ===

fun start(): (Scenario, Extensions, Account<P2PRamp>, Fees, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    extensions::init_for_testing(scenario.ctx());
    fees::init_for_testing(scenario.ctx());
    //retrieve objs
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    let fees = scenario.take_shared<Fees>();
    //add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"P2PRamp".to_string(), @p2p_ramp, 1);

    let account = p2p_ramp::p2p_ramp::new_account(&extensions, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    destroy(cap);

    (scenario, extensions, account, fees, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<P2PRamp>, fees: Fees, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(fees);
    destroy(clock);
    ts::end(scenario);
}

// === Tests ===

#[test]
fun test_config_p2p_ramp() {
    let (mut scenario, extensions, mut account, fees, clock) = start();
    let auth = p2p_ramp::p2p_ramp::authenticate(&account, scenario.ctx());

    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx()
    );
    let outcome = p2p_ramp::p2p_ramp::empty_approved_outcome();

    config::request_config_p2p_ramp(
        auth,
        params,
        outcome,
        &mut account,
        vector[OWNER, @0xFEE],
        scenario.ctx()
    );

    p2p_ramp::p2p_ramp::approve_intent(&mut account, b"config".to_string(), scenario.ctx());
    let mut executable = p2p_ramp::p2p_ramp::execute_approved_intent(&mut account, b"config".to_string(), &clock);
    config::execute_config_p2p_ramp(&mut executable, &mut account);
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<_, Approved>(b"config".to_string());
    config::delete_config_p2p_ramp(&mut expired);
    expired.destroy_empty();

    let exact_owner = OWNER;

    assert!(account.config().members().contains(&exact_owner));
    assert!(account.config().members().contains(&@0xFEE));

    end(scenario, extensions, account, fees, clock);
}

#[test]
fun test_config_p2p_ramp_deletion() {
    let (mut scenario, extensions, mut account, fees, mut clock) = start();
    clock.increment_for_testing(1);
    let auth = p2p_ramp::p2p_ramp::authenticate(&account, scenario.ctx());

    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx()
    );
    let outcome = p2p_ramp::p2p_ramp::empty_approved_outcome();

    config::request_config_p2p_ramp(
        auth,
        params,
        outcome,
        &mut account,
        vector[OWNER, @0xFEE],
        scenario.ctx()
    );

    p2p_ramp::p2p_ramp::approve_intent(&mut account, b"config".to_string(), scenario.ctx());
    let mut executable = p2p_ramp::p2p_ramp::execute_approved_intent(&mut account, b"config".to_string(), &clock);
    config::execute_config_p2p_ramp(&mut executable, &mut account);
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<_, Approved>(b"config".to_string());
    config::delete_config_p2p_ramp(&mut expired);
    expired.destroy_empty();

    end(scenario, extensions, account, fees, clock);
}