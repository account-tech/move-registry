/// This module contains the logic for modifying the P2PRamp configuration via an intent.

module p2p_ramp::config;

// === Imports ===

use std::string::String;
use account_protocol::{
    intents::Expired,
    executable::Executable,
    account::{Account, Auth},
};
use p2p_ramp::{
    p2p_ramp::{Self, P2PRamp, Active},
    version,
};

// === Structs ===

/// Intent to modify the members of the account.
public struct ConfigP2PRampIntent() has copy, drop;

/// Action wrapping a P2PRamp struct into an action.
public struct ConfigP2PRampAction has drop, store {
    config: P2PRamp,
}

// === Public functions ===

/// No actions are defined as changing the config isn't supposed to be composable for security reasons

/// Requests new P2PRamp settings.
public fun request_config_p2p_ramp(
    auth: Auth,
    outcome: Active,
    account: &mut Account<P2PRamp, Active>, 
    key: String,
    description: String,
    execution_time: u64,
    expiration_time: u64,
    addrs: vector<address>,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let mut intent = account.create_intent(
        key,
        description,
        vector[execution_time],
        expiration_time,
        b"".to_string(),
        outcome,
        version::current(),
        ConfigP2PRampIntent(),
        ctx
    );

    let config = p2p_ramp::new_config(addrs);

    account.add_action(&mut intent, ConfigP2PRampAction { config }, version::current(), ConfigP2PRampIntent());
    account.add_intent(intent, version::current(), ConfigP2PRampIntent());
}

/// Executes the action and modifies the Account P2PRamp.
public fun execute_config_p2p_ramp(
    mut executable: Executable,
    account: &mut Account<P2PRamp, Active>, 
) {
    let action: &ConfigP2PRampAction = account.process_action(&mut executable, version::current(), ConfigP2PRampIntent());
    *p2p_ramp::config_mut(account) = action.config;
    account.confirm_execution(executable, version::current(), ConfigP2PRampIntent());
}

/// Deletes the action in an expired intent.
public fun delete_config_p2p_ramp(expired: &mut Expired) {
    let ConfigP2PRampAction { .. } = expired.remove_action();
}