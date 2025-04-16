#[test_only]
module account_dao::config_tests;

// === Imports ===

use std::type_name;
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    clock::{Self, Clock},
    coin::{Self, Coin},
    sui::SUI,
};
use account_extensions::extensions::{Self, Extensions, AdminCap};
use account_protocol::{
    account::Account,
    intents,
};
use account_dao::{
    dao::{Self, Dao, Votes, Registry},
    config,
};

// === Constants ===

const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;

const LINEAR: u8 = 0;
const QUADRATIC: u8 = 1;

const NO: u8 = 0;
const YES: u8 = 1;
const ABSTAIN: u8 = 2;

// === Structs ===

public struct Witness() has drop;
public struct DummyIntent() has copy, drop;

public struct Obj has key, store {
    id: UID,
}

// === Helpers ===

fun start(): (Scenario, Extensions, Registry, Account<Dao>, Clock) {
    let mut scenario = ts::begin(BOB);
    // publish package
    extensions::init_for_testing(scenario.ctx());
    dao::init_for_testing(scenario.ctx());
    // retrieve objects
    scenario.next_tx(BOB);
    let mut registry = scenario.take_shared<Registry>();
    let mut extensions = scenario.take_shared<Extensions>();
    let cap = scenario.take_from_sender<AdminCap>();
    // add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"AccountDao".to_string(), @account_dao, 1);
    extensions.add(&cap, b"AccountActions".to_string(), @0xAC, 1);

    let account = dao::new_account<Coin<SUI>>(&mut registry, &extensions, 1,0,LINEAR,10,3,5,scenario.ctx());
    let clock = clock::create_for_testing(scenario.ctx());

    destroy(cap);
    (scenario, extensions, registry, account, clock)
}

fun end(scenario: Scenario, extensions: Extensions, registry: Registry, account: Account<Dao>, clock: Clock) {
    destroy(extensions);
    destroy(registry);
    destroy(account);
    destroy(clock);
    ts::end(scenario);
}

// === Tests ===

#[test]
fun test_config_dao() {
    let (mut scenario, extensions, registry, mut account, mut clock) = start();

    let mut staked = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());
    staked.stake_coin(coin::mint_for_testing<SUI>(10, scenario.ctx()));
    let auth = staked.authenticate(&account, &clock);

    let params = intents::new_params(
        b"config".to_string(), 
        b"description".to_string(), 
        vector[0],
        1, 
        &clock,
        scenario.ctx(),
    );
    let outcome = dao::empty_votes_outcome(1, 2, &clock);
    config::request_config_dao<Obj>(
        auth,
        &mut account,
        params,
        outcome,
        // dao rules
        2,
        1,
        QUADRATIC,
        11,
        4,
        6,
        scenario.ctx()
    );

    clock.increment_for_testing(1);
    let mut vote = dao::new_vote(&mut account, b"config".to_string(), staked, scenario.ctx());
    vote.vote(&mut account, YES, &clock);
    
    let mut executable = dao::execute_votes_intent(&mut account, b"config".to_string(), &clock);
    config::execute_config_dao(&mut executable, &mut account);
    account.confirm_execution(executable);

    let mut expired = account.destroy_empty_intent<_, Votes>(b"config".to_string());
    config::delete_config_dao(&mut expired);
    expired.destroy_empty();
    
    let dao = account.config();
    assert!(dao.asset_type() == type_name::get<Obj>());
    assert!(dao.auth_voting_power() == 2);
    assert!(dao.unstaking_cooldown() == 1);
    assert!(dao.voting_rule() == QUADRATIC);
    assert!(dao.max_voting_power() == 11);
    assert!(dao.minimum_votes() == 4);
    assert!(dao.voting_quorum() == 6);

    destroy(vote);
    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_config_dao_deletion() {
    let (mut scenario, extensions, registry, mut account, mut clock) = start();

    let mut staked = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());
    staked.stake_coin(coin::mint_for_testing<SUI>(10, scenario.ctx()));
    let auth = staked.authenticate(&account, &clock);

    let params = intents::new_params(
        b"config".to_string(), 
        b"description".to_string(), 
        vector[0],
        1, 
        &clock,
        scenario.ctx(),
    );
    let outcome = dao::empty_votes_outcome(1, 2, &clock);
    config::request_config_dao<Obj>(
        auth,
        &mut account,
        params,
        outcome,
        // dao rules
        2,
        1,
        QUADRATIC,
        11,
        4,
        6,
        scenario.ctx()
    );

    clock.increment_for_testing(1);
    let mut expired = account.delete_expired_intent<_, Votes>(b"config".to_string(), &clock);
    config::delete_config_dao(&mut expired);
    expired.destroy_empty();

    destroy(staked);
    end(scenario, extensions, registry, account, clock);
}