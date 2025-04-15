/// This module contains the logic for modifying the Dao configuration via an intent.

module account_dao::config;

// === Imports ===

use account_protocol::{
    intents::{Params, Expired},
    executable::Executable,
    account::{Account, Auth},
    intent_interface,
};
use account_dao::{
    dao::{Self, Dao, Votes},
    version,
};

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Structs ===

/// Intent to modify the members and thresholds of the account.
public struct ConfigDaoIntent() has copy, drop;

/// Action wrapping a Dao struct into an action.
public struct ConfigDaoAction has drop, store {
    config: Dao,
}

// === Public functions ===

/// No actions are defined as changing the config isn't supposed to be composable for security reasons

/// Requests new DAO settings.
public fun request_config_dao<AssetType>(
    auth: Auth,
    account: &mut Account<Dao>, 
    params: Params,
    outcome: Votes,
    // dao rules
    unstaking_cooldown: u64,
    voting_rule: u8,
    max_voting_power: u64,
    minimum_votes: u64,
    voting_quorum: u64,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let config = dao::new_config<AssetType>(
        unstaking_cooldown, voting_rule, max_voting_power, minimum_votes, voting_quorum
    );    
    
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        ConfigDaoIntent(),
        ctx,
        |intent, iw| intent.add_action(ConfigDaoAction { config }, iw)
    );
}

// Executes the action and modify Account Dao
public fun execute_config_dao(
    executable: &mut Executable<Votes>,
    account: &mut Account<Dao>, 
) {
    account.process_intent!(
        executable, 
        version::current(),   
        ConfigDaoIntent(), 
        |executable, iw| {
            let action = executable.next_action<Votes, ConfigDaoAction, _>(iw);
            *dao::config_mut(account) = action.config;
        }
    );
}

/// Deletes the action in an expired intent.
public fun delete_config_dao(expired: &mut Expired) {
    let ConfigDaoAction { .. } = expired.remove_action();
}