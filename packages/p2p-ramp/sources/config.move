/// This module contains the logic for modifying the P2PRamp configuration via an intent.

module p2p_ramp::config;

// === Imports ===

use account_protocol::{
    intents::{Params, Expired},
    executable::Executable,
    account::{Account, Auth},
    intent_interface,
};
use p2p_ramp::{
    p2p_ramp::{Self, P2PRamp, Approved},
    version,
};

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

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
    params: Params,
    outcome: Approved,
    account: &mut Account<P2PRamp>, 
    addrs: vector<address>,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let config = p2p_ramp::new_config(addrs);
    
    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        ConfigP2PRampIntent(),
        ctx,
        |intent, iw| intent.add_action(ConfigP2PRampAction { config }, iw)
    );
}

/// Executes the action and modifies the Account P2PRamp.
public fun execute_config_p2p_ramp(
    executable: &mut Executable<Approved>,
    account: &mut Account<P2PRamp>, 
) {
    account.process_intent!(
        executable,
        version::current(),   
        ConfigP2PRampIntent(), 
        |executable, iw| {
            let action = executable.next_action<Approved, ConfigP2PRampAction, _>(iw);
            *p2p_ramp::config_mut(account) = action.config;
        }
    );
}

/// Deletes the action in an expired intent.
public fun delete_config_p2p_ramp(expired: &mut Expired) {
    let ConfigP2PRampAction { .. } = expired.remove_action();
}