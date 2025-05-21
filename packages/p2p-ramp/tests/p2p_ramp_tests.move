#[test_only]
#[allow(implicit_const_copy)]
module p2p_ramp::p2p_ramp_tests;

use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::Account,
    user::{Self, Invite},
};
use p2p_ramp::{
    p2p_ramp::{Self, P2PRamp, Registry},
    fees::{Self, Fees},
    version
};
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock}
};

const OWNER: address = @0xCAFE;
const ALICE: address = @0xA11CE;

fun start(): (Scenario, Extensions, Account<P2PRamp>, Registry, Fees, Clock) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    p2p_ramp::init_for_testing(scenario.ctx());
    extensions::init_for_testing(scenario.ctx());
    fees::init_for_testing(scenario.ctx());
    // retrieve objs
    scenario.next_tx(OWNER);
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    let mut registry = scenario.take_shared<Registry>();
    let fees = scenario.take_shared<Fees>();
    // add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"P2PRamp".to_string(), @p2p_ramp, 1);

    let account = p2p_ramp::new_account(&mut registry, &extensions, scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    destroy(cap);

    (scenario, extensions, account, registry, fees, clock)
}

fun end(scenario: Scenario, extensions: Extensions, account: Account<P2PRamp>, registry: Registry, fees: Fees, clock: Clock) {
    destroy(extensions);
    destroy(account);
    destroy(registry);
    destroy(fees);
    destroy(clock);
    ts::end(scenario);
}

#[test]
fun test_join_and_leave() {
    let (mut scenario, extensions, account, registry, fees, clock) = start();
    let mut user = user::new(scenario.ctx());

    p2p_ramp::join(&mut user, &account, scenario.ctx());
    assert!(user.all_ids() == vector[account.addr()]);
    p2p_ramp::leave(&mut user, &account);
    assert!(user.all_ids() == vector[]);

    destroy(user);
    end(scenario, extensions, account, registry, fees, clock);
}

#[test]
fun test_invite_and_accept() {
    let (mut scenario, extensions, mut account, registry, fees, clock) = start();

    let user = user::new(scenario.ctx());
    account.config_mut(version::current(), p2p_ramp::config_witness()).add_member(ALICE);
    p2p_ramp::send_invite(&account, ALICE, scenario.ctx());

    scenario.next_tx(ALICE);
    let invite = scenario.take_from_sender<Invite>();
    user::refuse_invite(invite);
    assert!(user.all_ids() == vector[]);

    destroy(user);
    end(scenario, extensions, account, registry, fees, clock);
}

#[test]
fun test_members_accessors() {
    let (mut scenario, extensions, account, registry, fees, clock) = start();

    assert!(account.config().members().size() == 1);
    assert!(account.config().members().contains(&OWNER));
    account.config().assert_is_member(scenario.ctx());

    end(scenario, extensions, account, registry, fees, clock);
}