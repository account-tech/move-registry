#[test_only]
#[allow(implicit_const_copy)]
module account_payment::fees_tests;

// === Imports ===

use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    sui::SUI,
    coin::{Self, Coin},
};
use account_payment::{
    fees::{Self, Fees, AdminCap},
};

// === Constants ===

const OWNER: address = @0xCAFE;
const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B; 

// === Helpers ===

fun start(): (Scenario, Fees, AdminCap) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    fees::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let fees = scenario.take_shared<Fees>();
    let cap = scenario.take_from_sender<AdminCap>();

    (scenario, fees, cap)
}

fun end(scenario: Scenario, fees: Fees, cap: AdminCap) {
    destroy(fees);
    destroy(cap);
    ts::end(scenario);
}

#[test]
fun test_getters() {
    let (scenario, fees, cap) = start();

    assert!(fees.inner().is_empty());

    end(scenario, fees, cap);
}

#[test]
fun test_add_edit_remove_fee() {
    let (scenario, mut fees, cap) = start();

    cap.add_fee(&mut fees, ALICE, 1000);
    assert!(fees.inner().contains(&ALICE));
    assert!(fees.inner().get(&ALICE) == 1000);

    cap.add_fee(&mut fees, BOB, 2000);
    assert!(fees.inner().size() == 2);
    assert!(fees.inner().contains(&BOB));
    assert!(fees.inner().get(&BOB) == 2000);

    cap.edit_fee(&mut fees, ALICE, 2500);
    assert!(fees.inner().get(&ALICE) == 2500);

    cap.remove_fee(&mut fees, BOB);
    assert!(fees.inner().size() == 1);
    assert!(!fees.inner().contains(&BOB));

    end(scenario, fees, cap);
}

#[test]
fun test_process_fees_active() {
    let (mut scenario, mut fees, cap) = start();

    cap.add_fee(&mut fees, ALICE, 1000);
    cap.add_fee(&mut fees, BOB, 2000);

    let mut coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    fees.collect(&mut coin, scenario.ctx());

    assert!(coin.value() == 700);
    scenario.next_tx(ALICE);
    let coin_alice = scenario.take_from_sender<Coin<SUI>>();
    assert!(coin_alice.value() == 100);
    scenario.next_tx(BOB);
    let coin_bob = scenario.take_from_sender<Coin<SUI>>();
    assert!(coin_bob.value() == 200);

    destroy(coin);
    destroy(coin_alice);
    destroy(coin_bob);
    end(scenario, fees, cap);
}

#[test]
fun test_collect_fees_empty() {
    let (mut scenario, fees, cap) = start();

    let mut coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    fees.collect(&mut coin, scenario.ctx());

    assert!(coin.value() == 1000);

    destroy(coin);
    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ERecipientAlreadyExists)]
fun test_add_fees_recipient_already_exists() {
    let (scenario, mut fees, cap) = start();

    cap.add_fee(&mut fees, ALICE, 10);
    cap.add_fee(&mut fees, ALICE, 10);
    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ERecipientDoesNotExist)]
fun test_edit_fees_recipient_does_not_exist() {
    let (scenario, mut fees, cap) = start();

    cap.add_fee(&mut fees, ALICE, 10);
    cap.edit_fee(&mut fees, BOB, 10);

    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ERecipientDoesNotExist)]
fun test_remove_fees_recipient_does_not_exist() {
    let (scenario, mut fees, cap) = start();

    cap.add_fee(&mut fees, ALICE, 10);
    cap.remove_fee(&mut fees, BOB);
    
    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ETotalFeesTooHigh)]
fun test_add_fees_total_fees_too_high() {
    let (scenario, mut fees, cap) = start();

    cap.add_fee(&mut fees, ALICE, 5000);

    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ETotalFeesTooHigh)]
fun test_edit_fees_total_fees_too_high() {
    let (scenario, mut fees, cap) = start();

    cap.add_fee(&mut fees, ALICE, 2500);
    cap.edit_fee(&mut fees, ALICE, 5000);

    end(scenario, fees, cap);
}
