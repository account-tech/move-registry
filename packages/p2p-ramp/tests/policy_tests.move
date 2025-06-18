#[test_only]
#[allow(implicit_const_copy)]
module p2p_ramp::policy_tests;

// === Imports ===

use std::type_name::{Self};
use p2p_ramp::policy::{Self, Policy, AdminCap};
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

const MIN_FILL_DEADLINE_MS: u64 = 900_000;

// === Helpers ===

fun start(): (Scenario, Policy, AdminCap) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    policy::init_for_testing(scenario.ctx());
    // retrive objs
    scenario.next_tx(OWNER);
    let policy = scenario.take_shared<Policy>();
    let cap = scenario.take_from_sender<AdminCap>();

    (scenario, policy, cap)
}

fun end(scenario: Scenario, policy: Policy, cap: AdminCap) {
    destroy(policy);
    destroy(cap);
    ts::end(scenario);
}

#[test]
fun test_getters() {
    let (scenario, policy, cap) = start();

    assert!(policy.collectors().is_empty());
    assert!(policy.allowed_coins().is_empty());
    assert!(policy.allowed_fiat().is_empty());
    assert!(policy.min_fill_deadline_ms() == MIN_FILL_DEADLINE_MS);

    end(scenario, policy, cap);
}

#[test]
fun test_add_edit_remove_collector() {
    let (scenario, mut policy, cap) = start();

    cap.add_collector(&mut policy, ALICE, 1000);
    assert!(policy.collectors().contains(&ALICE));
    assert!(policy.collectors().get(&ALICE) == 1000);

    cap.add_collector(&mut policy, BOB, 2000);
    assert!(policy.collectors().size() == 2);
    assert!(policy.collectors().contains(&BOB));
    assert!(policy.collectors().get(&BOB) == 2000);

    cap.edit_collector(&mut policy, ALICE, 2500);
    assert!(policy.collectors().get(&ALICE) == 2500);

    cap.remove_collector(&mut policy, BOB);
    assert!(policy.collectors().size() == 1);
    assert!(!policy.collectors().contains(&BOB));

    end(scenario, policy, cap)
}

#[test]
fun test_allow_disallow_coin() {
    let (scenario, mut policy, cap) = start();

    cap.allow_coin<SUI>(&mut policy);
    assert!(policy.allowed_coins().contains(&type_name::get<SUI>()));

    cap.disallow_coin<SUI>(&mut policy);
    assert!(policy.allowed_coins().size() == 0);

    end(scenario, policy, cap);
}

#[test]
fun test_allow_disallow_fiat() {
    let (scenario, mut policy, cap) = start();

    cap.allow_fiat(&mut policy, b"UGX".to_string());
    assert!(policy.allowed_fiat().contains(&b"UGX".to_string()));

    cap.disallow_fiat(&mut policy, b"UGX".to_string());
    assert!(policy.allowed_fiat().size() == 0);

    end(scenario, policy, cap);
}

#[test]
fun test_process_policy_active() {
    let (mut scenario, mut policy, cap) = start();

    cap.add_collector(&mut policy, ALICE, 1000);
    cap.add_collector(&mut policy, BOB, 2000);

    let mut coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    policy.collect(&mut coin, scenario.ctx());

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
    end(scenario, policy, cap);
}

#[test]
fun test_collect_policy_empty() {
    let (mut scenario, policy, cap) = start();

    let mut coin = coin::mint_for_testing<SUI>(1000, scenario.ctx());
    policy.collect(&mut coin, scenario.ctx());

    assert!(coin.value() == 1000);

    destroy(coin);
    end(scenario, policy, cap);
}

#[test, expected_failure(abort_code = policy::ERecipientAlreadyExists)]
fun test_add_collector_recipient_already_exists() {
    let (scenario, mut policy, cap) = start();

    cap.add_collector(&mut policy, ALICE, 10);
    cap.add_collector(&mut policy, ALICE, 10);
    end(scenario, policy, cap);
}

#[test, expected_failure(abort_code = policy::ERecipientDoesNotExist)]
fun test_edit_collector_recipient_does_not_exist() {
    let (scenario, mut policy, cap) = start();

    cap.add_collector(&mut policy, ALICE, 10);
    cap.edit_collector(&mut policy, BOB, 10);

    end(scenario, policy, cap);
}

#[test, expected_failure(abort_code = policy::ERecipientDoesNotExist)]
fun test_remove_collector_recipient_does_not_exist() {
    let (scenario, mut policy, cap) = start();

    cap.add_collector(&mut policy, ALICE, 10);
    cap.remove_collector(&mut policy, BOB);

    end(scenario, policy, cap);
}

#[test, expected_failure(abort_code = policy::ETotalPolicyTooHigh)]
fun test_add_collector_total_policy_too_high() {
    let (scenario, mut policy, cap) = start();

    cap.add_collector(&mut policy, ALICE, 5000);

    end(scenario, policy, cap);
}

#[test, expected_failure(abort_code = policy::ETotalPolicyTooHigh)]
fun test_edit_collectors_total_policy_too_high() {
    let (scenario, mut policy, cap) = start();

    cap.add_collector(&mut policy, ALICE, 2500);
    cap.edit_collector(&mut policy, ALICE, 5000);

    end(scenario, policy, cap);
}

#[test]
fun test_set_min_fill_deadline_ms() {
    let (scenario, mut policy, cap) = start();

    cap.set_min_fill_deadline_ms(&mut policy, 1_800_000);
    assert!(policy.min_fill_deadline_ms() == 1_800_000);

    end(scenario, policy, cap);
}

#[test, expected_failure(abort_code = policy::EMinFillDeadlineTooLow)]
fun test_set_min_fill_deadline_ms_too_low() {
    let (scenario, mut policy, cap) = start();

    cap.set_min_fill_deadline_ms(&mut policy, 450_000);

    end(scenario, policy, cap);
}