#[test_only]
#[allow(implicit_const_copy)]
module p2p_ramp::p2p_ramp_tests;

use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::Account,
    user::{Self, Invite},
};
use p2p_ramp::{
    p2p_ramp::{Self, P2PRamp, AccountRegistry},
    policy::{Self, Policy},
    version
};
use std::type_name::{Self};
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    coin::{Self},
    sui::SUI,
};

const OWNER: address = @0xCAFE;
const ALICE: address = @0xA11CE;
const DECIMALS: u64 = 1_000_000_000;

fun start(): (Scenario, Extensions, Account<P2PRamp>, AccountRegistry, Policy, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    p2p_ramp::init_for_testing(scenario.ctx());
    extensions::init_for_testing(scenario.ctx());
    policy::init_for_testing(scenario.ctx());
    // retrieve objs
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    let mut acc_registry = scenario.take_shared<AccountRegistry>();
    let policy = scenario.take_shared<Policy>();
    // add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"P2PRamp".to_string(), @p2p_ramp, 1);

    let account = p2p_ramp::new_account(&mut acc_registry, &extensions, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    destroy(cap);

    (scenario, extensions, account, acc_registry, policy, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<P2PRamp>, acc_registry: AccountRegistry, policy: Policy, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(acc_registry);
    destroy(policy);
    destroy(clock);
    ts::end(scenario);
}

// account reputation getters tested in next test

#[test]
fun test_init_reputation() {
    let (scenario, extensions, account, acc_registry, policy, clock) = start();

    let rep = p2p_ramp::reputation(&account);

    assert!(rep.successful_trades() == 0);
    assert!(rep.failed_trades() == 0);
    assert!(rep.total_coin_volume().is_empty());
    assert!(rep.total_fiat_volume().is_empty());
    assert!(rep.total_release_time_ms() == 0);
    assert!(rep.disputes_won() == 0);
    assert!(rep.disputes_lost() == 0);
    assert!(rep.avg_release_time_ms() == 0);
    assert!(rep.completion_rate() == 0);

    end(scenario, extensions, account, acc_registry, policy, clock);
}

#[test]
fun test_record_successful_trade() {
    let (mut scenario, extensions, mut account, acc_registry, policy, clock) = start();

    let coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());
    let type_name = type_name::get<SUI>();

    p2p_ramp::record_successful_trade<SUI>(
        &mut account,
        b"USD".to_string(),
        1_000,
        coin.value(),
        300_000
    );

    let rep = p2p_ramp::reputation(&account);

    assert!(rep.successful_trades() == 1);
    assert!(rep.failed_trades() == 0);
    assert!(!rep.total_coin_volume().is_empty());
    assert!(rep.total_coin_volume().get(&type_name) == coin.value());
    assert!(!rep.total_fiat_volume().is_empty());
    assert!(rep.total_fiat_volume().get(&b"USD".to_string()) == 1_000);
    assert!(rep.total_release_time_ms() == 300_000);
    assert!(rep.disputes_won() == 0);
    assert!(rep.disputes_lost() == 0);
    assert!(rep.avg_release_time_ms() == 300_000);
    assert!(rep.completion_rate() == 100);

    destroy(coin);
    end(scenario, extensions, account, acc_registry, policy, clock);
}

#[test]
fun test_record_failed_trade() {
    let (scenario, extensions, mut account, acc_registry, policy, clock) = start();

    p2p_ramp::record_failed_trade(&mut account);

    let rep = p2p_ramp::reputation(&account);
    assert!(rep.failed_trades() == 1);

    end(scenario, extensions, account, acc_registry, policy, clock);
}

#[test]
fun test_record_dispute_outcome_won() {
    let (scenario, extensions, mut account, acc_registry, policy, clock) = start();

    p2p_ramp::record_dispute_outcome(&mut account, OWNER);

    let rep = p2p_ramp::reputation(&account);
    assert!(rep.disputes_won() == 1);

    end(scenario, extensions, account, acc_registry, policy, clock);
}

#[test]
fun test_record_dispute_outcome_lost() {
    let (scenario, extensions, mut account, acc_registry, policy, clock) = start();

    p2p_ramp::record_dispute_outcome(&mut account, ALICE);

    let rep = p2p_ramp::reputation(&account);
    assert!(rep.disputes_lost() == 1);

    end(scenario, extensions, account, acc_registry, policy, clock);
}


#[test]
fun test_join_and_leave() {
    let (mut scenario, extensions, account, acc_registry, policy, clock) = start();
    let mut user = user::new(scenario.ctx());

    p2p_ramp::join(&mut user, &account, scenario.ctx());
    assert!(user.all_ids() == vector[account.addr()]);
    p2p_ramp::leave(&mut user, &account);
    assert!(user.all_ids() == vector[]);

    destroy(user);
    end(scenario, extensions, account, acc_registry, policy, clock);
}

#[test]
fun test_invite_and_accept() {
    let (mut scenario, extensions, mut account, acc_registry, policy, clock) = start();

    let user = user::new(scenario.ctx());
    account.config_mut(version::current(), p2p_ramp::config_witness()).add_member(ALICE);
    p2p_ramp::send_invite(&account, ALICE, scenario.ctx());

    scenario.next_tx(ALICE);
    let invite = scenario.take_from_sender<Invite>();
    user::refuse_invite(invite);
    assert!(user.all_ids() == vector[]);

    destroy(user);
    end(scenario, extensions, account, acc_registry, policy, clock);
}

#[test]
fun test_members_accessors() {
    let (mut scenario, extensions, account, acc_registry, policy, clock) = start();

    assert!(account.config().members().size() == 1);
    assert!(account.config().members().contains(&OWNER));
    account.config().assert_is_member(scenario.ctx());

    end(scenario, extensions, account, acc_registry, policy, clock);
}