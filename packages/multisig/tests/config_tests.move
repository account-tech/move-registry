#[test_only]
module account_multisig::config_tests;

// === Imports ===

use std::string::String;
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    coin,
    sui::SUI,
};
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::Account,
    intents,
};
use account_multisig::{
    multisig::{Self, Multisig, Approvals},
    config,
    fees::{Self, Fees},
    version,
};

// === Constants ===

const OWNER: address = @0xCAFE;
const DECIMALS: u64 = 1_000_000_000; // 10^9

// === Helpers ===

fun start(): (Scenario, Extensions, Account<Multisig>, Fees, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    extensions::init_for_testing(scenario.ctx());
    fees::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    let fees = scenario.take_shared<Fees>();
    // add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"AccountMultisig".to_string(), @account_multisig, 1);
    extensions.add(&cap, b"AccountActions".to_string(), @0x0, 1);

    let mut account = multisig::new_account(&extensions, &fees, coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx()), scenario.ctx());
    account.config_mut(version::current(), multisig::config_witness()).add_role_to_multisig(full_role(), 1);
    account.config_mut(version::current(), multisig::config_witness()).member_mut(OWNER).add_role_to_member(full_role());
    let clock = clock::create_for_testing(scenario.ctx());

    destroy(cap);
    (scenario, extensions, account, fees, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<Multisig>, fees: Fees, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(fees);
    destroy(clock);
    ts::end(scenario);
}

fun full_role(): String {
    let mut full_role = @account_multisig.to_string();
    full_role.append_utf8(b"::multisig_tests::Degen");
    full_role
}

// === Tests ===

#[test]
fun test_config_multisig() {
    let (mut scenario, extensions, mut account, fees, clock) = start();
    let auth = multisig::authenticate(&account, scenario.ctx());

    let params = intents::new_params(
        b"config".to_string(), 
        b"description".to_string(), 
        vector[0],
        1, 
        &clock,
    );
    let outcome = multisig::empty_outcome();
    config::request_config_multisig(
        auth,
        &mut account,
        params,
        outcome,
        vector[OWNER, @0xBABE], 
        vector[2, 1], 
        vector[vector[full_role()], vector[]], 
        2, 
        vector[full_role()], 
        vector[1], 
        scenario.ctx()
    );
    multisig::approve_intent(&mut account, b"config".to_string(), scenario.ctx());
    let mut executable = multisig::execute_intent(&mut account, b"config".to_string(), &clock);
    config::execute_config_multisig(&mut executable, &mut account);
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<_, Approvals>(b"config".to_string());
    config::delete_config_multisig(&mut expired);
    expired.destroy_empty();

    assert!(account.config().addresses() == vector[OWNER, @0xBABE]);
    assert!(account.config().member(OWNER).weight() == 2);
    assert!(account.config().member(OWNER).roles() == vector[full_role()]);
    assert!(account.config().member(@0xBABE).weight() == 1);
    assert!(account.config().member(@0xBABE).roles() == vector[]);
    assert!(account.config().get_global_threshold() == 2);
    assert!(account.config().get_role_threshold(full_role()) == 1);

    end(scenario, extensions, account, fees, clock);
}

#[test]
fun test_config_multisig_deletion() {
    let (mut scenario, extensions, mut account, fees, mut clock) = start();
    clock.increment_for_testing(1);
    let auth = multisig::authenticate(&account, scenario.ctx());
    
    let params = intents::new_params(
        b"config".to_string(), 
        b"description".to_string(), 
        vector[0],
        1, 
        &clock,
    );
    let outcome = multisig::empty_outcome();
    config::request_config_multisig(
        auth,
        &mut account,
        params,
        outcome,
        vector[OWNER, @0xBABE], 
        vector[2, 1], 
        vector[vector[full_role()], vector[]], 
        2, 
        vector[full_role()], 
        vector[1], 
        scenario.ctx()
    );
    let mut expired = account.delete_expired_intent<_, Approvals>(b"config".to_string(), &clock);
    config::delete_config_multisig(&mut expired);
    expired.destroy_empty();

    end(scenario, extensions, account, fees, clock);
}