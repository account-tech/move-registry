/// This module contains the logic for modifying the Payment configuration via an intent.

module account_payment::config;

// === Imports ===

use std::string::String;
use account_protocol::{
    intents::{Params, Expired},
    executable::Executable,
    account::{Account, Auth},
    intent_interface,
};
use account_payment::{
    payment::{Self, Payment, Pending},
    version,
};

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

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
    account: &mut Account<Payment>, 
    params: Params,
    outcome: Pending,
    // members 
    addrs: vector<address>,
    roles: vector<vector<String>>,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let config = payment::new_config(addrs, roles);

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        ConfigPaymentIntent(),
        ctx,
        |intent, iw| intent.add_action(ConfigPaymentAction { config }, iw)
    );
}

/// Executes the action and modifies the Account Payment.
public fun execute_config_payment(
    executable: &mut Executable<Pending>,
    account: &mut Account<Payment>, 
) {
    account.process_intent!(
        executable, 
        version::current(),   
        ConfigPaymentIntent(), 
        |executable, iw| {
            let action = executable.next_action<Pending, ConfigPaymentAction, _>(iw);
            *payment::config_mut(account) = action.config;
        }
    );
}

/// Deletes the action in an expired intent.
public fun delete_config_payment(expired: &mut Expired) {
    let ConfigPaymentAction { .. } = expired.remove_action();
}