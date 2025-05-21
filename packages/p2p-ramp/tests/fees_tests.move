#[test_only]
#[allow(implicit_const_copy)]
module p2p_ramp::fees_tests;

// === Imports ===

use std::type_name::{Self};
use p2p_ramp::fees::{Self, Fees, AdminCap};
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    coin::{Self, Coin},
    sui::SUI,
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
    // retrive objs
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

    assert!(fees.collectors().is_empty());
    assert!(fees.allowed_coins().is_empty());
    assert!(fees.allowed_fiat().is_empty());

    end(scenario, fees, cap);
}

#[test]
fun test_add_edit_remove_collector() {
    let (scenario, mut fees, cap) = start();

    cap.add_collector(&mut fees, ALICE, 1000);
    assert!(fees.collectors().contains(&ALICE));
    assert!(fees.collectors().get(&ALICE) == 1000);

    cap.add_collector(&mut fees, BOB, 2000);
    assert!(fees.collectors().size() == 2);
    assert!(fees.collectors().contains(&BOB));
    assert!(fees.collectors().get(&BOB) == 2000);

    cap.edit_collector(&mut fees, ALICE, 2500);
    assert!(fees.collectors().get(&ALICE) == 2500);

    cap.remove_collector(&mut fees, BOB);
    assert!(fees.collectors().size() == 1);
    assert!(!fees.collectors().contains(&BOB));

    end(scenario, fees, cap)
}

#[test]
fun test_allow_disallow_coin() {
    let (scenario, mut fees, cap) = start();

    cap.allow_coin<SUI>(&mut fees);
    assert!(fees.allowed_coins().contains(&type_name::get<SUI>()));

    cap.disallow_coin<SUI>(&mut fees);
    assert!(fees.allowed_coins().size() == 0);

    end(scenario, fees, cap);
}

#[test]
fun test_allow_disallow_fiat() {
    let (scenario, mut fees, cap) = start();

    cap.allow_fiat(&mut fees, b"UGX".to_string());
    assert!(fees.allowed_fiat().contains(&b"UGX".to_string()));

    cap.disallow_fiat(&mut fees, b"UGX".to_string());
    assert!(fees.allowed_fiat().size() == 0);

    end(scenario, fees, cap);
}

#[test]
fun test_process_fees_active() {
    let (mut scenario, mut fees, cap) = start();

    cap.add_collector(&mut fees, ALICE, 1000);
    cap.add_collector(&mut fees, BOB, 2000);

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
fun test_add_collector_recipient_already_exists() {
    let (scenario, mut fees, cap) = start();

    cap.add_collector(&mut fees, ALICE, 10);
    cap.add_collector(&mut fees, ALICE, 10);
    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ERecipientDoesNotExist)]
fun test_edit_collector_recipient_does_not_exist() {
    let (scenario, mut fees, cap) = start();

    cap.add_collector(&mut fees, ALICE, 10);
    cap.edit_collector(&mut fees, BOB, 10);

    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ERecipientDoesNotExist)]
fun test_remove_collector_recipient_does_not_exist() {
    let (scenario, mut fees, cap) = start();

    cap.add_collector(&mut fees, ALICE, 10);
    cap.remove_collector(&mut fees, BOB);

    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ETotalFeesTooHigh)]
fun test_add_collector_total_fees_too_high() {
    let (scenario, mut fees, cap) = start();

    cap.add_collector(&mut fees, ALICE, 5000);

    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::ETotalFeesTooHigh)]
fun test_edit_collectors_total_fees_too_high() {
    let (scenario, mut fees, cap) = start();

    cap.add_collector(&mut fees, ALICE, 2500);
    cap.edit_collector(&mut fees, ALICE, 5000);

    end(scenario, fees, cap);
}