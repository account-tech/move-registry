/// This module defines the DAO configuration and Votes proposal logic for account.tech.
/// Proposals can be executed once the role threshold is reached (similar to multisig) or if the DAO rules are met.
///
/// The DAO can be configured with: 
/// - a specific asset type for voting
/// - a cooldown for unstaking (this will decrease the voting power linearly over time)
/// - a voting rule (linear or quadratic, more can be added in the future)
/// - a maximum voting power that can be used in a single vote
/// - a minimum number of votes needed to pass a proposal (can be 0)
/// - a global voting threshold between (0, 1e9], If 50% votes needed, then should be > 500_000_000
/// 
/// Participants have to stake their assets to construct a Vote object.
/// They can stake their assets at any time, but they will have to wait for the cooldown period to pass before they can unstake them.
/// Staked assets can be pushed into a Vote object, to vote on a proposal. This object can be unpacked once the vote ends.
/// New assets can be added during vote, and vote can be changed. 
/// 
/// Alternatively, roles can be added to the DAO with a specific threshold, then roles can be assigned to members
/// Members with the role can approve the proposals which can be executed once the role threshold is reached

module account_dao::dao;

// === Imports ===

use std::{
    string::String,
    type_name::{Self, TypeName},
};
use sui::{
    vec_set::{VecSet},
    table::{Self, Table},
    clock::Clock,
    vec_map::{Self, VecMap},
    coin::{Self, Coin},
};
use account_extensions::extensions::Extensions;
use account_protocol::{
    account::{Account, Auth},
    executable::Executable,
    deps,
    user::User,
    account_interface,
};
use account_dao::{
    version,
    math,
};

// === Aliases ===

use fun account_interface::create_auth as Account.create_auth;
use fun account_interface::resolve_intent as Account.resolve_intent;
use fun account_interface::execute_intent as Account.execute_intent;

// === Constants ===

const MUL: u64 = 1_000_000_000;
// acts as a dynamic enum for the voting rule
const LINEAR: u8 = 1;
const QUADRATIC: u8 = 2;
// answers for the vote
const ANSWER: u8 = NO | YES | ABSTAIN;
const NO: u8 = 0;
const YES: u8 = 1;
const ABSTAIN: u8 = 2;

// === Errors ===

const EThresholdNotReached: u64 = 0;
const ENotUnstaked: u64 = 1;
const EProposalNotActive: u64 = 2;
const EInvalidAccount: u64 = 3;
const EInvalidVotingRule: u64 = 4;
const EInvalidAnswer: u64 = 5;
const EAlreadyUnstaked: u64 = 6;
const ENotFungible: u64 = 7;
const ENotNonFungible: u64 = 8;
const EVoteNotEnded: u64 = 9;

// === Structs ===

public struct ConfigWitness() has drop;

/// Parent struct protecting the config
public struct Dao has copy, drop, store {
    // object type allowed for voting
    asset_type: TypeName,
    // voting power required to authenticate as a member (submit proposal, open vault, etc)
    auth_voting_power: u64,
    // groups and associated data
    groups: vector<Group>,
    // cooldown when unstaking, voting power decreases linearly over time
    unstaking_cooldown: u64,
    // type of voting mechanism, u8 so we can add more in the future
    voting_rule: u8,
    // maximum voting power that can be used in a single vote (can be max_u64)
    max_voting_power: u64,
    // minimum number of votes needed to pass a proposal (can be 0 if not important)
    minimum_votes: u64,
    // global voting threshold between (0, 1e9], If 50% votes needed, then should be > 500_000_000
    voting_quorum: u64, 
}

/// Groups are multisig like, they have a threshold, members and roles corresponding to the intents they can approve
public struct Group has copy, drop, store {
    // threshold for the group
    threshold: u64,
    // members of the group
    addrs: VecSet<address>,
    // roles that have been attributed to the group
    roles: VecSet<String>,
}

/// Outcome field for the Intents, voters are holders of the asset
/// Intent is validated when group threshold is reached or dao rules are met
/// Must be validated before destruction
public struct Votes has store {
    // voting start time 
    start_time: u64,
    // voting end time
    end_time: u64,
    // who has approved the proposal => (answer, voting_power)
    voted: Table<address, Voted>,
    // results of the votes, answer => total_voting_power
    results: VecMap<u8, u64>,
}

/// Tuple struct for storing the answer and voting power of a voter
public struct Voted(u8, u64) has copy, drop, store;

/// Object wrapping the staked assets used for voting in a specific dao
/// Staked assets cannot be retrieved during the voting period
public struct Vote<Asset: store> has key, store {
    id: UID,
    // id of the dao account
    dao_addr: address,
    // the intent voted on
    intent_key: String,
    // answer chosen for the vote
    voted: Voted,
    // timestamp when the vote ends and when this object can be unpacked
    vote_end: u64,
    // staked assets with metadata
    staked: Staked<Asset>,
}

/// Staked asset, can be unstaked after the vote ends, according to the DAO cooldown
public struct Staked<Asset: store> has key, store {
    id: UID,
    // id of the dao account
    dao_addr: address,
    // value of the staked asset (Coin.value if Coin or 1 if Object)
    value: u64,
    // unstaking time, if none then staked
    unstaked: Option<u64>,
    // staked asset
    asset: Adapter<Asset>,
}

public enum Adapter<Asset: store> has store {
    Fungible(Asset), // Asset is Coin<CoinType>
    NonFungible(vector<Asset>), // Asset is object type
}

// === [ACCOUNT] Public functions ===

/// Init and returns a new Account object
public fun new_account<AssetType>(
    extensions: &Extensions,
    auth_voting_power: u64,
    unstaking_cooldown: u64,
    voting_rule: u8,
    max_voting_power: u64,
    voting_quorum: u64,
    minimum_votes: u64,
    ctx: &mut TxContext,
): Account<Dao> {
    let config = Dao {
        groups: vector[],
        asset_type: type_name::get<AssetType>(),
        auth_voting_power,
        unstaking_cooldown,
        voting_rule,
        max_voting_power,
        voting_quorum,
        minimum_votes,
    };

    account_interface::create_account!(
        config,
        version::current(),
        ConfigWitness(),
        ctx,
        || deps::new_latest_extensions(
            extensions,
            vector[b"AccountProtocol".to_string(), b"AccountDao".to_string(), b"AccountActions".to_string()]
        )
    )
}

/// Authenticates the caller as a member (!= participant) of the DAO 
public fun authenticate<Asset: store>(
    staked: Staked<Asset>,
    account: &Account<Dao>,
    clock: &Clock,
): Auth {
    let voting_power = staked.get_voting_power(account, clock);

    account.create_auth!(
        version::current(),
        ConfigWitness(),
        || voting_power >= account.config().auth_voting_power
    )
}

/// Creates a new outcome to initiate a proposal
public fun empty_votes_outcome(
    start_time: u64,
    end_time: u64,
    ctx: &mut TxContext
): Votes {
    Votes {
        start_time,
        end_time,
        voted: table::new(ctx),
        results: vec_map::from_keys_values(
            vector[NO, YES, ABSTAIN], 
            vector[0, 0, 0],
        ),
    }
}

/// Stakes a coin and get its value
public fun new_staked_coin<CoinType: store>(
    account: &mut Account<Dao>,
    ctx: &mut TxContext
): Staked<Coin<CoinType>> {
    Staked {
        id: object::new(ctx),
        dao_addr: account.addr(),
        value: 0,
        unstaked: option::none(),
        asset: Adapter::Fungible(coin::zero<CoinType>(ctx)),
    }
}

/// Stakes the asset and adds 1 as value
public fun new_staked_object<Asset: key + store>(
    account: &mut Account<Dao>,
    ctx: &mut TxContext
): Staked<Asset> {
    Staked {
        id: object::new(ctx),
        dao_addr: account.addr(),
        value: 1,
        unstaked: option::none(),
        asset: Adapter::NonFungible(vector[]),
    }
}

public fun stake_coin<CoinType: store>(
    staked: &mut Staked<Coin<CoinType>>,
    coin: Coin<CoinType>,
) {
    match (&mut staked.asset) {
        Adapter::Fungible(staked_coin) => {
            staked.value = staked.value + coin.value();
            staked_coin.join(coin);
        },
        _ => abort ENotFungible,
    }
}

public fun stake_object<Asset: key + store>(
    staked: &mut Staked<Asset>,
    asset: Asset,
) {
    match (&mut staked.asset) {
        Adapter::NonFungible(assets) => {
            staked.value = staked.value + 1;
            assets.push_back(asset);
        },
        _ => abort ENotNonFungible,
    }
}

/// Starts cooldown for the staked asset
public fun unstake<Asset: store>(
    staked: &mut Staked<Asset>,
    clock: &Clock,
) {
    assert!(staked.unstaked.is_none(), EAlreadyUnstaked);
    staked.unstaked = option::some(clock.timestamp_ms());    
}

/// Retrieves the staked asset after cooldown
public fun claim<Asset: key + store>(
    staked: Staked<Asset>,
    account: &mut Account<Dao>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let Staked { id, dao_addr, mut unstaked, asset, .. } = staked;
    id.delete();
    
    assert!(dao_addr == account.addr(), EInvalidAccount);
    assert!(unstaked.is_some(), ENotUnstaked);
    assert!(clock.timestamp_ms() > account.config().unstaking_cooldown + unstaked.extract(), ENotUnstaked);

    match (asset) {
        Adapter::Fungible(coin) => {
            transfer::public_transfer(coin, ctx.sender());
        },
        Adapter::NonFungible(assets) => {
            assets.do!(|asset| {
                transfer::public_transfer(asset, ctx.sender());
            });
        },
    }
}

public fun new_vote<Asset: store>(
    account: &mut Account<Dao>,
    intent_key: String,
    answer: u8,
    staked: Staked<Asset>,
    clock: &Clock,
    ctx: &mut TxContext
): Vote<Asset> {
    assert!(answer == ANSWER, EInvalidAnswer);

    Vote {
        id: object::new(ctx),
        dao_addr: account.addr(),
        intent_key,
        voted: Voted(answer, staked.get_voting_power(account, clock)),
        vote_end: account.intents().get<Votes>(intent_key).outcome().end_time,
        staked,
    }
}

/// Votes or changes vote on a proposal
public fun vote<Asset: store>(
    vote: &mut Vote<Asset>,
    account: &mut Account<Dao>,
    key: String,
    answer: u8,
    clock: &Clock,
) {
    assert!(answer == ANSWER, EInvalidAnswer);
    assert!(
        clock.timestamp_ms() > account.intents().get<Votes>(key).outcome().start_time &&
        clock.timestamp_ms() < account.intents().get<Votes>(key).outcome().end_time, 
        EProposalNotActive
    );

    vote.voted.0 = answer;

    account.resolve_intent!<_, Votes, _>(
        key, 
        version::current(), 
        ConfigWitness(),
        |outcome| {
            if (outcome.voted.contains(vote.addr())) {
                let Voted(prev_answer, prev_power) = outcome.voted.remove(vote.addr());
                *outcome.results.get_mut(&prev_answer) = *outcome.results.get_mut(&prev_answer) - prev_power;
            };

            outcome.voted.add(vote.addr(), Voted(answer, vote.voted.1)); // throws if already approved
            *outcome.results.get_mut(&answer) = *outcome.results.get_mut(&answer) + vote.voted.1;
        }
    );
}

public fun destroy_vote<Asset: store>(
    vote: Vote<Asset>,
    clock: &Clock,
): Staked<Asset> {
    let Vote { id, vote_end, staked, .. } = vote;

    assert!(clock.timestamp_ms() > vote_end, EVoteNotEnded);
    id.delete();

    staked
}

public fun execute_votes_intent(
    account: &mut Account<Dao>, 
    key: String, 
    clock: &Clock,
): Executable<Votes> {
    account.execute_intent!<_, Votes, _>(key, clock, version::current(), ConfigWitness())
}

public use fun validate_votes_outcome as Votes.validate_outcome;
#[allow(implicit_const_copy)]
public fun validate_votes_outcome(
    outcome: Votes, 
    dao: &Dao, 
    _role: String, // useless but to respect the interface
) {
    let Votes { voted, results, .. } = outcome;
    voted.drop();

    let total_votes = results[&YES] + results[&NO] + results[&ABSTAIN];

    assert!(
        total_votes >= dao.minimum_votes && 
        math::mul_div_down(results[&YES], MUL, total_votes) >= dao.voting_quorum * MUL, 
        EThresholdNotReached
    );
}

/// Inserts account_id in User, aborts if already joined
public fun join(user: &mut User, account: &Account<Dao>) {
    user.add_account(account, ConfigWitness());
}

/// Removes account_id from User, aborts if not joined
public fun leave(user: &mut User, account: &Account<Dao>) {
    user.remove_account(account, ConfigWitness());
}

// === Accessors ===

public fun addr<Asset: store>(vote: &Vote<Asset>): address {
    object::id(vote).to_address()
}

public fun asset_type(dao: &Dao): TypeName {
    dao.asset_type
}

public fun is_coin(dao: &Dao): bool {
    let addr = dao.asset_type.get_address();
    let module_name = dao.asset_type.get_module();

    let str_bytes = dao.asset_type.into_string().as_bytes();
    let mut struct_name = vector[];
    4u64.do!(|i| {
        struct_name.push_back(str_bytes[i + 72]); // starts at 0x2::coin::
    });
    
    addr == @0x0000000000000000000000000000000000000000000000000000000000000002.to_ascii_string() &&
    module_name == b"coin".to_ascii_string() &&
    struct_name == b"Coin"
}

// outcome functions
public fun start_time(outcome: &Votes): u64 {
    outcome.start_time
}

public fun end_time(outcome: &Votes): u64 {
    outcome.end_time
}

public fun voted(outcome: &Votes, vote: address): (u8, u64) {
    let voted = outcome.voted.borrow(vote);
    (voted.0, voted.1)
}

public fun results(outcome: &Votes): &VecMap<u8, u64> {
    &outcome.results
}

// === Package functions ===

/// Creates a new DAO configuration.
public(package) fun new_config<AssetType>(
    unstaking_cooldown: u64,
    voting_rule: u8,
    max_voting_power: u64,
    minimum_votes: u64,
    voting_quorum: u64,
): Dao {
    Dao { 
        asset_type: type_name::get<AssetType>(),
        auth_voting_power: 0,
        groups: vector[],
        unstaking_cooldown, 
        voting_rule, 
        max_voting_power, 
        minimum_votes, 
        voting_quorum
    }
}

/// Returns a mutable reference to the DAO configuration.
public(package) fun config_mut(account: &mut Account<Dao>): &mut Dao {
    account.config_mut(version::current(), ConfigWitness())
}

// === Private functions ===

/// Returns the voting multiplier depending on the cooldown [0, 1e9]
fun get_voting_power<Asset: store>(
    staked: &Staked<Asset>,
    account: &Account<Dao>,
    clock: &Clock,
): u64 {
    assert!(staked.dao_addr == account.addr(), EInvalidAccount);

    let cooldown = account.config().unstaking_cooldown;
    // find coef according to the cooldown
    let mut coef = if (staked.unstaked.is_none()) {
        MUL
    } else {
        let time_passed = clock.timestamp_ms() - *staked.unstaked.borrow();
        if (time_passed > cooldown) 0 else
            math::mul_div_down(cooldown - time_passed, MUL, cooldown)
    };

    // apply the voting rule to get the voting power
    let voting_power = if (account.config().voting_rule == LINEAR) {
        coef * staked.value / MUL
    } else if (account.config().voting_rule == QUADRATIC) {
        math::sqrt_down(coef * staked.value) / MUL
    } else {
        abort EInvalidVotingRule
    }; // can add other voting rules in the future

    // cap the voting power
    math::min(voting_power, account.config().max_voting_power)
}