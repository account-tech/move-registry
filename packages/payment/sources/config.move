/// This module contains the logic for modifying the Payment configuration via an intent.

module account_payment::config;

// === Imports ===

use std::string::String;
use account_protocol::{
    intents::Expired,
    executable::Executable,
    account::{Account, Auth},
};
use account_payment::{
    payment::{Self, Payment, Pending},
    version,
};

// === Structs ===

/// Intent to modify the members of the account.
public struct ConfigPaymentIntent() has copy, drop;

/// Action wrapping a Payment struct into an action.
public struct ConfigPaymentAction has drop, store {
    config: Payment,
}

// === Public functions ===

/// No actions are defined as changing the config isn't supposed to be composable for security reasons

/// Requests new Payment settings.
public fun request_config_payment(
    auth: Auth,
    outcome: Pending,
    account: &mut Account<Payment, Pending>, 
    key: String,
    description: String,
    execution_time: u64,
    expiration_time: u64,
    // members 
    addrs: vector<address>,
    roles: vector<vector<String>>,
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
        ConfigPaymentIntent(),
        ctx
    );

    let config = payment::new_config(addrs, roles);

    account.add_action(&mut intent, ConfigPaymentAction { config }, version::current(), ConfigPaymentIntent());
    account.add_intent(intent, version::current(), ConfigPaymentIntent());
}

/// Executes the action and modifies the Account Payment.
public fun execute_config_payment(
    mut executable: Executable,
    account: &mut Account<Payment, Pending>, 
) {
    let action: &ConfigPaymentAction = account.process_action(&mut executable, version::current(), ConfigPaymentIntent());
    *payment::config_mut(account) = action.config;
    account.confirm_execution(executable, version::current(), ConfigPaymentIntent());
}

/// Deletes the action in an expired intent.
public fun delete_config_payment(expired: &mut Expired) {
    let ConfigPaymentAction { .. } = expired.remove_action();
}