#[test_only]
#[allow(implicit_const_copy)]
module account_payment::pay_tests;

// === Imports ===

use std::string::String;
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    sui::SUI,
    coin::{Self, Coin},
};
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::Account,
    intents,
};
use account_payment::{
    payment::{Self, Payment, Pending},
    pay,
    fees::{Self, Fees},
    version,
};

// === Constants ===

const OWNER: address = @0xCAFE;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const CUSTOMER: address = @0xBABE;

// === Helpers ===

fun start(): (Scenario, Extensions, Account<Payment>, Fees, Clock) {
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
    extensions.add(&cap, b"account_protocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"account_payment".to_string(), @account_payment, 1);
    // Account generic types are dummy types (bool, bool)
    let mut account = payment::new_account(&extensions, scenario.ctx());
    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().get_mut(&OWNER).insert(full_role());
    let clock = clock::create_for_testing(scenario.ctx());
    // create world
    destroy(cap);
    (scenario, extensions, account, fees, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<Payment>, fees: Fees, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(fees);
    destroy(clock);
    ts::end(scenario);
}

fun full_role(): String {
    let mut full_role = @account_payment.to_string();
    full_role.append_utf8(b"::pay");
    full_role
}

// === Tests ===

#[test]
fun test_request_execute_pay_no_fees() {
    let (mut scenario, extensions, mut account, fees, clock) = start();
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx()
    );

    pay::request_pay<SUI>(
        auth,
        &mut account,
        params,
        outcome,
        10,
        scenario.ctx()
    );
    payment::approve_intent(&mut account, b"config".to_string(), scenario.ctx());

    // customer pays
    scenario.next_tx(CUSTOMER);
    let mut executable = payment::execute_intent(&mut account, b"config".to_string(), &clock);
    let coin = coin::mint_for_testing<SUI>(10, scenario.ctx());
    pay::execute_pay(&mut executable, &account, coin, &fees, &clock, scenario.ctx());
    account.confirm_execution(executable); 

    let mut expired = account.destroy_empty_intent<_, Pending>(b"config".to_string());
    pay::delete_pay<SUI>(&mut expired);
    expired.destroy_empty();
    
    scenario.next_tx(OWNER);
    let coin = scenario.take_from_address<Coin<SUI>>(account.addr());
    assert!(coin.value() == 10);

    destroy(coin);
    end(scenario, extensions, account, fees, clock);
}

#[test]
fun test_request_execute_pay_with_fees() {
    let (mut scenario, extensions, mut account, mut fees, clock) = start();
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx()
    );

    pay::request_pay<SUI>(
        auth,
        &mut account,
        params,
        outcome,
        10,
        scenario.ctx()
    );
    payment::approve_intent(&mut account, b"config".to_string(), scenario.ctx());

    // add fees
    fees.set_fees_for_testing(vector[ALICE, BOB], vector[1000, 2000]);
    // customer pays
    scenario.next_tx(CUSTOMER);
    let mut executable = payment::execute_intent(&mut account, b"config".to_string(), &clock);
    let coin = coin::mint_for_testing<SUI>(10, scenario.ctx());
    pay::execute_pay(&mut executable, &account, coin, &fees, &clock, scenario.ctx());
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<_, Pending>(b"config".to_string());
    pay::delete_pay<SUI>(&mut expired);
    expired.destroy_empty();
    
    scenario.next_tx(OWNER);
    let coin_account = scenario.take_from_address<Coin<SUI>>(account.addr());
    assert!(coin_account.value() == 7);
    scenario.next_tx(ALICE);
    let coin_alice = scenario.take_from_sender<Coin<SUI>>();
    assert!(coin_alice.value() == 1);
    scenario.next_tx(BOB);
    let coin_bob = scenario.take_from_sender<Coin<SUI>>();
    assert!(coin_bob.value() == 2);

    destroy(coin_account);
    destroy(coin_alice);
    destroy(coin_bob);
    end(scenario, extensions, account, fees, clock);
}

#[test]
fun test_request_execute_pay_with_tips_no_fees() {
    let (mut scenario, extensions, mut account, fees, clock) = start();
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx()
    );

    pay::request_pay<SUI>(
        auth,
        &mut account,
        params,
        outcome,
        10,
        scenario.ctx()
    );
    payment::approve_intent(&mut account, b"config".to_string(), scenario.ctx());

    // customer pays
    scenario.next_tx(CUSTOMER);
    let mut executable = payment::execute_intent(&mut account, b"config".to_string(), &clock);
    let coin = coin::mint_for_testing<SUI>(11, scenario.ctx());
    pay::execute_pay(&mut executable, &account, coin, &fees, &clock, scenario.ctx());
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<_, Pending>(b"config".to_string());
    pay::delete_pay<SUI>(&mut expired);
    expired.destroy_empty();
    
    scenario.next_tx(OWNER);
    let coin = scenario.take_from_address<Coin<SUI>>(account.addr());
    assert!(coin.value() == 10);
    let tips = scenario.take_from_sender<Coin<SUI>>();
    assert!(tips.value() == 1);

    destroy(coin);
    destroy(tips);
    end(scenario, extensions, account, fees, clock);
}

#[test]
fun test_request_execute_pay_with_tips_with_fees() {
    let (mut scenario, extensions, mut account, mut fees, clock) = start();
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx()
    );

    pay::request_pay<SUI>(
        auth,
        &mut account,
        params,
        outcome,
        10,
        scenario.ctx()
    );
    payment::approve_intent(&mut account, b"config".to_string(), scenario.ctx());

    // add fees
    fees.set_fees_for_testing(vector[ALICE, BOB], vector[1000, 2000]);
    // customer pays
    scenario.next_tx(CUSTOMER);
    let mut executable = payment::execute_intent(&mut account, b"config".to_string(), &clock);
    let coin = coin::mint_for_testing<SUI>(11, scenario.ctx());
    pay::execute_pay(&mut executable, &account, coin, &fees, &clock, scenario.ctx());
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<_, Pending>(b"config".to_string());
    pay::delete_pay<SUI>(&mut expired);
    expired.destroy_empty();
    
    scenario.next_tx(OWNER);
    let coin_account = scenario.take_from_address<Coin<SUI>>(account.addr());
    assert!(coin_account.value() == 7);
    let tips = scenario.take_from_sender<Coin<SUI>>();
    assert!(tips.value() == 1);
    scenario.next_tx(ALICE);
    let coin_alice = scenario.take_from_sender<Coin<SUI>>();
    assert!(coin_alice.value() == 1);
    scenario.next_tx(BOB);
    let coin_bob = scenario.take_from_sender<Coin<SUI>>();
    assert!(coin_bob.value() == 2);

    destroy(coin_account);
    destroy(tips);
    destroy(coin_alice);
    destroy(coin_bob);
    end(scenario, extensions, account, fees, clock);
}

#[test]
fun test_request_delete_pay() {
    let (mut scenario, extensions, mut account, fees, mut clock) = start();
    clock.increment_for_testing(1);
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx()
    );

    pay::request_pay<SUI>(
        auth,
        &mut account,
        params,
        outcome,
        10,
        scenario.ctx()
    );

    let mut expired = account.delete_expired_intent<_, Pending>(b"config".to_string(), &clock);
    pay::delete_pay<SUI>(&mut expired);
    expired.destroy_empty();

    end(scenario, extensions, account, fees, clock);
}

#[test, expected_failure(abort_code = pay::EWrongAmount)]
fun test_request_execute_pay_not_enough() {
    let (mut scenario, extensions, mut account, fees, clock) = start();
    let auth = payment::authenticate(&account, scenario.ctx());

    let outcome = payment::empty_outcome();
    let params = intents::new_params(
        b"config".to_string(),
        b"description".to_string(),
        vector[0],
        1,
        &clock,
        scenario.ctx()
    );

    pay::request_pay<SUI>(
        auth,
        &mut account,
        params,
        outcome,
        10,
        scenario.ctx()
    );
    payment::approve_intent(&mut account, b"config".to_string(), scenario.ctx());

    // customer pays
    scenario.next_tx(CUSTOMER);
    let mut executable = payment::execute_intent(&mut account, b"config".to_string(), &clock);
    let coin = coin::mint_for_testing<SUI>(9, scenario.ctx());
    pay::execute_pay(&mut executable, &account, coin, &fees, &clock, scenario.ctx());
    account.confirm_execution(executable);

    end(scenario, extensions, account, fees, clock);
}

#[test, expected_failure(abort_code = payment::ENotRole)]
fun test_error_pay_not_role() {
    let (mut scenario, extensions, mut account, fees, clock) = start();
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

    pay::request_pay<SUI>(
        auth,
        &mut account,
        params,
        outcome,
        10,
        scenario.ctx()
    );

    account.config_mut(version::current(), payment::config_witness()).members_mut_for_testing().get_mut(&OWNER).remove(&full_role());
    payment::approve_intent(&mut account, b"config".to_string(), scenario.ctx());
    
    // customer pays
    scenario.next_tx(CUSTOMER);
    let mut executable = payment::execute_intent(&mut account, b"config".to_string(), &clock);
    let coin = coin::mint_for_testing<SUI>(10, scenario.ctx());
    pay::execute_pay(&mut executable, &account, coin, &fees, &clock, scenario.ctx());
    account.confirm_execution(executable);

    end(scenario, extensions, account, fees, clock);
}