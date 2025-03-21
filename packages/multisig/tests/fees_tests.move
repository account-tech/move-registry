#[test_only]
module account_multisig::fees_tests;

use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    coin::{Self, Coin},
    sui::SUI,
};
use account_multisig::fees::{Self, Fees, AdminCap};

// === Constants ===

const OWNER: address = @0xCAFE;
const DECIMALS: u64 = 1_000_000_000; // 10^9

// === Structs ===

public struct Witness() has drop;
public struct DummyIntent() has copy, drop;

// === Helpers ===

fun start(): (Scenario, Fees, AdminCap) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    fees::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(OWNER);
    let cap = scenario.take_from_sender<AdminCap>();
    let fees = scenario.take_shared<Fees>();

    (scenario, fees, cap)
}

fun end(scenario: Scenario, fees: Fees, cap: AdminCap) {
    destroy(fees);
    destroy(cap);
    ts::end(scenario);
}

// === Tests ===

#[test]
fun test_getters() {
    let (scenario, fees, cap) = start();
    
    assert!(fees.amount() == 10 * DECIMALS);
    assert!(fees.recipient() == OWNER);

    end(scenario, fees, cap);
}

#[test]
fun test_process() {
    let (mut scenario, fees, cap) = start();
    
    let coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());
    fees::process(&fees, coin);

    scenario.next_tx(OWNER);
    let coin = scenario.take_from_sender<Coin<SUI>>();
    assert!(coin.value() == 10 * DECIMALS);

    destroy(coin);
    end(scenario, fees, cap);
}

#[test]
fun test_set_amount() {
    let (mut scenario, mut fees, cap) = start();
    
    scenario.next_tx(OWNER);
    cap.set_amount(&mut fees, 20 * DECIMALS);

    assert!(fees.amount() == 20 * DECIMALS);

    end(scenario, fees, cap);
}

#[test, expected_failure(abort_code = fees::EWrongAmount)]
fun test_process_wrong_amount() {
    let (mut scenario, fees, cap) = start();
    
    let coin = coin::mint_for_testing<SUI>(9 * DECIMALS, scenario.ctx());
    fees::process(&fees, coin);

    end(scenario, fees, cap);
}

