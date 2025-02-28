/// This module contains the interface for:
/// - the PayAction to compose intents 
/// - the PayIntent to make a simple payment

module account_payment::pay;

// === Imports ===

use std::string::String;
use sui::{
    coin::Coin,
    event,
    clock::Clock,
};
use account_protocol::{
    intents::Expired,
    executable::Executable,
    account::{Account, Auth},
};
use account_payment::{
    payment::{Payment, Pending},
    version,
};

// === Errors ===

const EWrongAmount: u64 = 0;

// === Events ===

public struct PayEvent<phantom CoinType> has copy, drop {
    // payment id
    payment_id: address,
    // time when the intent was executed (payment made)
    timestamp: u64,
    // payment amount without tips
    amount: u64, 
    // optional additional tip amount 
    tips: u64,
    // creator of the intent and recipient of the tips
    issued_by: address,
}

// === Structs ===

/// Intent to make a payment.
public struct PayIntent() has copy, drop;

/// Action wrapping a Payment struct into an action.
public struct PayAction<phantom CoinType> has drop, store {
    // random id to identify payment
    payment_id: address,
    // amount to be paid
    amount: u64,
    // creator address
    issued_by: address,
}

// === Public functions ===

/// No actions are defined as changing the config isn't supposed to be composable for security reasons

/// Requests to make a payment. 
/// Must be immediately approved in the same PTB to enable customer to execute payment.
public fun request_pay<CoinType>(
    auth: Auth,
    outcome: Pending,
    account: &mut Account<Payment, Pending>, 
    key: String,
    description: String,
    execution_time: u64,
    expiration_time: u64,
    amount: u64,
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
        PayIntent(),
        ctx
    );

    let action = PayAction<CoinType> { 
        payment_id: ctx.fresh_object_address(),
        amount, 
        issued_by: ctx.sender() 
    };

    account.add_action(&mut intent, action, version::current(), PayIntent());
    account.add_intent(intent, version::current(), PayIntent());
}

/// Customer executes the action and transfer coin.
public fun execute_pay<CoinType>(
    mut executable: Executable,
    account: &Account<Payment, Pending>, 
    mut coin: Coin<CoinType>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let action: &PayAction<CoinType> = account.process_action(&mut executable, version::current(), PayIntent());
    assert!(coin.value() >= action.amount, EWrongAmount);
    
    event::emit(PayEvent<CoinType> {
        payment_id: action.payment_id,
        timestamp: clock.timestamp_ms(),
        amount: action.amount,
        tips: coin.value() - action.amount,
        issued_by: action.issued_by,
    });

    transfer::public_transfer(coin.split(action.amount, ctx), account.addr());
    transfer::public_transfer(coin, action.issued_by); // tips

    account.confirm_execution(executable, version::current(), PayIntent());
}

/// Deletes the action in an expired intent.
public fun delete_pay<CoinType>(expired: &mut Expired) {
    let PayAction<CoinType> { .. } = expired.remove_action();
}