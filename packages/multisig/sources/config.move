/// This module contains the logic for modifying the Multisig configuration via an intent.

module account_multisig::config;

// === Imports ===

use std::string::String;
use account_protocol::{
    intents::{Params, Expired},
    executable::Executable,
    account::{Account, Auth},
    intent_interface,
};
use account_multisig::{
    multisig::{Self, Multisig, Approvals},
    version,
};

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Structs ===

/// Intent to modify the members and thresholds of the account.
public struct ConfigMultisigIntent() has copy, drop;

/// Action wrapping a Multisig struct into an action.
public struct ConfigMultisigAction has drop, store {
    config: Multisig,
}

// === Public functions ===

/// No actions are defined as changing the config isn't supposed to be composable for security reasons

/// Requests new Multisig settings.
public fun request_config_multisig(
    auth: Auth,
    account: &mut Account<Multisig>, 
    params: Params,
    outcome: Approvals,
    // members 
    addresses: vector<address>,
    weights: vector<u64>,
    roles: vector<vector<String>>,
    // thresholds 
    global: u64,
    role_names: vector<String>,
    role_thresholds: vector<u64>,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let config = multisig::new_config(addresses, weights, roles, global, role_names, role_thresholds);

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        ConfigMultisigIntent(),
        ctx,
        |intent, iw| intent.add_action(ConfigMultisigAction { config }, iw)
    );
}

/// Executes the action and modifies the Account Multisig.
public fun execute_config_multisig(
    executable: &mut Executable<Approvals>,
    account: &mut Account<Multisig>, 
) {
    account.process_intent!(
        executable, 
        version::current(),   
        ConfigMultisigIntent(), 
        |executable, iw| {
            let action = executable.next_action<Approvals, ConfigMultisigAction, _>(iw);
            *multisig::config_mut(account) = action.config;
        }
    );
}

/// Deletes the action in an expired intent.
public fun delete_config_multisig(expired: &mut Expired) {
    let ConfigMultisigAction { .. } = expired.remove_action();
}