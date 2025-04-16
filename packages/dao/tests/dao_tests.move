#[test_only]
module account_dao::dao_tests;

// === Imports ===

use std::{
    string::String,
    type_name::{Self, TypeName},
};
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
    user,
    intents,
    intent_interface,
};
use account_dao::{
    dao::{Self, Dao, Votes, Registry},
    version,
};

// === Constants ===

const ALICE: address = @0xA11CE;
const BOB: address = @0xB0B;
const DECIMALS: u64 = 1_000_000_000; // 10^9

// acts as a dynamic enum for the voting rule
const VOTING_RULE: u8 = LINEAR | QUADRATIC;
const LINEAR: u8 = 0;
const QUADRATIC: u8 = 1;
// answers for the vote
const ANSWER: u8 = NO | YES | ABSTAIN;
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

fun create_and_add_dummy_intent(
    scenario: &mut Scenario,
    account: &mut Account<Dao>, 
    clock: &Clock,
) {
    let params = intents::new_params(
        b"dummy".to_string(), 
        b"description".to_string(), 
        vector[0],
        1, 
        clock,
        scenario.ctx(),
    );
    let outcome = dao::empty_votes_outcome(1, 2, clock);
    intent_interface::build_intent!<Dao, _, _>(
        account,
        params,
        outcome, 
        b"Degen".to_string(),
        version::current(),
        DummyIntent(), 
        scenario.ctx(),
        |intent, iw| intent.add_action(true, iw)
    );
}

fun create_and_add_other_intent(
    scenario: &mut Scenario,
    account: &mut Account<Dao>,
    clock: &Clock,
) {
    let outcome = dao::empty_votes_outcome(1, 2, clock);
    let params = intents::new_params(
        b"other".to_string(), 
        b"description".to_string(), 
        vector[0],
        1, 
        clock,
        scenario.ctx(),
    );
    intent_interface::build_intent!<Dao, _, _>(
        account,
        params,
        outcome, 
        b"Degen".to_string(),
        version::current(),
        DummyIntent(), 
        scenario.ctx(),
        |intent, iw| intent.add_action(true, iw)
    );
}

// === Tests ===

#[test]
fun test_dao_getters() {
    let (scenario, extensions, registry, account, clock) = start();
    let dao = account.config();
    
    assert!(dao.asset_type() == type_name::get<Coin<SUI>>());
    assert!(dao.auth_voting_power() == 1);
    assert!(dao.unstaking_cooldown() == 0);
    assert!(dao.voting_rule() == LINEAR);
    assert!(dao.max_voting_power() == 10);
    assert!(dao.voting_quorum() == 3);
    assert!(dao.minimum_votes() == 5);

    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_deps() {
    let (scenario, extensions, registry, account, clock) = start();
    let deps = account.deps();

    assert!(deps.length() == 3);
    assert!(deps.get_by_idx(0).name() == b"AccountProtocol".to_string());
    assert!(deps.get_by_idx(1).name() == b"AccountDao".to_string());
    assert!(deps.get_by_idx(2).name() == b"AccountActions".to_string());

    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_authenticate() {
    let (mut scenario, extensions, registry, mut account, clock) = start();
    
    let mut staked = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());
    staked.stake_coin(coin::mint_for_testing<SUI>(10, scenario.ctx()));
    
    let auth = staked.authenticate(&account, &clock);

    destroy(auth);
    destroy(staked);
    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_stake_unstake_coin() {
    let (mut scenario, extensions, registry, mut account, clock) = start();
    
    let mut staked = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());
    assert!(staked.dao_addr() == account.addr());
    assert!(staked.value() == 0);
    assert!(staked.unstaked() == option::none());
    
    staked.stake_coin(coin::mint_for_testing<SUI>(10, scenario.ctx()));
    assert!(staked.value() == 10);
    staked.stake_coin(coin::mint_for_testing<SUI>(10, scenario.ctx()));
    assert!(staked.value() == 20);

    staked.unstake(&clock);
    assert!(staked.unstaked() == option::some(0));
    staked.claim(&mut account, &clock, scenario.ctx());

    scenario.next_tx(BOB);
    let coin = scenario.take_from_sender<Coin<SUI>>();
    assert!(coin.value() == 20);

    destroy(coin);
    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_stake_unstake_object() {
    let (mut scenario, extensions, registry, mut account, clock) = start();
    
    let mut staked = dao::new_staked_object<Obj>(&mut account, scenario.ctx());
    assert!(staked.dao_addr() == account.addr());
    assert!(staked.value() == 0);
    assert!(staked.unstaked() == option::none());
    
    staked.stake_object(Obj { id: object::new(scenario.ctx()) });
    assert!(staked.value() == 1);
    staked.stake_object(Obj { id: object::new(scenario.ctx()) });
    assert!(staked.value() == 2);

    staked.unstake(&clock);
    assert!(staked.unstaked() == option::some(0));
    staked.claim(&mut account, &clock, scenario.ctx());

    scenario.next_tx(BOB);
    let obj = scenario.take_from_sender<Obj>();

    destroy(obj);
    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_merge_staked_coin() {
    let (mut scenario, extensions, registry, mut account, clock) = start();
    
    let mut staked1 = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());    
    staked1.stake_coin(coin::mint_for_testing<SUI>(10, scenario.ctx()));
    assert!(staked1.value() == 10);
    
    let mut staked2 = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());    
    staked2.stake_coin(coin::mint_for_testing<SUI>(20, scenario.ctx()));
    assert!(staked2.value() == 20);

    staked1.merge_staked_coin(staked2);
    assert!(staked1.value() == 30);

    destroy(staked1);
    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_merge_staked_object() {
    let (mut scenario, extensions, registry, mut account, clock) = start();
    
    let mut staked1 = dao::new_staked_object<Obj>(&mut account, scenario.ctx());
    staked1.stake_object(Obj { id: object::new(scenario.ctx()) });
    assert!(staked1.value() == 1);

    let mut staked2 = dao::new_staked_object<Obj>(&mut account, scenario.ctx());
    staked2.stake_object(Obj { id: object::new(scenario.ctx()) });
    staked2.stake_object(Obj { id: object::new(scenario.ctx()) });
    assert!(staked2.value() == 2);

    staked1.merge_staked_object(staked2);
    assert!(staked1.value() == 3);

    destroy(staked1);
    end(scenario, extensions, registry, account, clock);
}

#[allow(implicit_const_copy)]
#[test]
fun test_vote_flow_with_coin() {
    let (mut scenario, extensions, registry, mut account, mut clock) = start();
    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);

    let mut bob_staked = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());
    bob_staked.stake_coin(coin::mint_for_testing<SUI>(10, scenario.ctx()));
    
    clock.increment_for_testing(1);
    let mut bob_vote = dao::new_vote<Coin<SUI>>(
        &mut account, 
        b"dummy".to_string(), 
        bob_staked, 
        scenario.ctx()
    );

    assert!(bob_vote.dao_addr() == account.addr());
    assert!(bob_vote.intent_key() == b"dummy".to_string());
    let voted = bob_vote.voted();
    assert!(voted.is_none());
    assert!(bob_vote.vote_end() == 2);

    bob_vote.vote(&mut account, YES, &clock); 
    let (answer, power) = bob_vote.voted().extract().values();
    assert!(answer == YES);
    assert!(power == 10);
    let votes = account.intents().get<Votes>(b"dummy".to_string()).outcome();    
    assert!(votes.results().get(&YES) == 10);
    assert!(votes.results().get(&NO) == 0);
    assert!(votes.results().get(&ABSTAIN) == 0);

    scenario.next_tx(ALICE); // other participant

    let mut alice_staked = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());
    alice_staked.stake_coin(coin::mint_for_testing<SUI>(1, scenario.ctx()));
    
    let mut alice_vote = dao::new_vote<Coin<SUI>>(
        &mut account, 
        b"dummy".to_string(), 
        alice_staked, 
        scenario.ctx()
    );

    alice_vote.vote(&mut account, YES, &clock); // same answer
    let votes = account.intents().get<Votes>(b"dummy".to_string()).outcome();
    assert!(votes.results().get(&YES) == 11);

    clock.increment_for_testing(1);
    let alice_staked = alice_vote.destroy_vote(&clock);
    let bob_staked = bob_vote.destroy_vote(&clock);

    destroy(alice_staked);
    destroy(bob_staked);
    end(scenario, extensions, registry, account, clock);
}

#[allow(implicit_const_copy)]
#[test]
fun test_vote_flow_with_object() {
    let (mut scenario, extensions, registry, mut account, mut clock) = start();
    dao::set_asset_type_for_testing<Obj>(&mut account);
    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);

    let mut bob_staked = dao::new_staked_object<Obj>(&mut account, scenario.ctx());
    bob_staked.stake_object(Obj { id: object::new(scenario.ctx()) });
    bob_staked.stake_object(Obj { id: object::new(scenario.ctx()) });
    
    clock.increment_for_testing(1);
    let mut bob_vote = dao::new_vote<Obj>(
        &mut account, 
        b"dummy".to_string(), 
        bob_staked, 
        scenario.ctx()
    );

    assert!(bob_vote.dao_addr() == account.addr());
    assert!(bob_vote.intent_key() == b"dummy".to_string());
    let voted = bob_vote.voted();
    assert!(voted.is_none());
    assert!(bob_vote.vote_end() == 2);

    bob_vote.vote(&mut account, YES, &clock);
    let (answer, power) = bob_vote.voted().extract().values();
    assert!(answer == YES);
    assert!(power == 2);

    let votes = account.intents().get<Votes>(b"dummy".to_string()).outcome();    
    assert!(votes.results().get(&YES) == 2);
    assert!(votes.results().get(&NO) == 0);
    assert!(votes.results().get(&ABSTAIN) == 0);

    scenario.next_tx(ALICE); // other participant

    let mut alice_staked = dao::new_staked_object<Obj>(&mut account, scenario.ctx());
    alice_staked.stake_object(Obj { id: object::new(scenario.ctx()) });
    
    let mut alice_vote = dao::new_vote<Obj>(
        &mut account, 
        b"dummy".to_string(), 
        alice_staked, 
        scenario.ctx()
    );

    alice_vote.vote(&mut account, YES, &clock); 
    let votes = account.intents().get<Votes>(b"dummy".to_string()).outcome();
    assert!(votes.results().get(&YES) == 3);

    clock.increment_for_testing(1);
    let alice_staked = alice_vote.destroy_vote(&clock);
    let bob_staked = bob_vote.destroy_vote(&clock);

    destroy(alice_staked);
    destroy(bob_staked);
    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_join_and_leave() {
    let (mut scenario, extensions, registry, account, clock) = start();
    let mut user = user::new(scenario.ctx());

    dao::join(&mut user, &account);
    assert!(user.all_ids() == vector[account.addr()]);
    dao::leave(&mut user, &account);
    assert!(user.all_ids() == vector[]);

    destroy(user);
    end(scenario, extensions, registry, account, clock);
}

#[test]
fun test_intent_execution() {
    let (mut scenario, extensions, registry, mut account, mut clock) = start();

    // create intent
    create_and_add_dummy_intent(&mut scenario, &mut account, &clock);

    let mut staked = dao::new_staked_coin<SUI>(&mut account, scenario.ctx());
    staked.stake_coin(coin::mint_for_testing<SUI>(10, scenario.ctx()));
    
    clock.increment_for_testing(1);
    let mut bob_vote = dao::new_vote<Coin<SUI>>(
        &mut account, 
        b"dummy".to_string(), 
        staked,
        scenario.ctx()
    );
    bob_vote.vote(&mut account, YES, &clock);

    // execute intent
    let mut executable = dao::execute_votes_intent(&mut account, b"dummy".to_string(), &clock);
    executable.next_action<_, bool, _>(DummyIntent());
    account.confirm_execution(executable); 

    let expired = account.destroy_empty_intent<_, Votes>(b"dummy".to_string());

    clock.increment_for_testing(1);
    let staked = bob_vote.destroy_vote(&clock);

    destroy(expired);
    destroy(staked);
    end(scenario, extensions, registry, account, clock);
}