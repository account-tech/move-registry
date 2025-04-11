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
    intents::{Params, Expired},
    executable::Executable,
    account::{Account, Auth},
    intent_interface,
};
use account_payment::{
    payment::{Payment, Pending},
    fees::Fees,
    version,
};

// === Aliases ===

use fun intent_interface::build_intent as Account.build_intent;
use fun intent_interface::process_intent as Account.process_intent;

// === Errors ===

const EWrongAmount: u64 = 0;

// === Events ===

public struct PayEvent<phantom CoinType> has copy, drop {
    // payment id
    payment_id: String,
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
    account: &mut Account<Payment>, 
    params: Params,
    outcome: Pending,
    amount: u64,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let action = PayAction<CoinType> { 
        amount, 
        issued_by: ctx.sender() 
    };

    account.build_intent!(
        params,
        outcome,
        b"".to_string(),
        version::current(),
        PayIntent(),
        ctx,
        |intent, iw| intent.add_action(action, iw)
    );
}

/// Customer executes the action and transfer coin.
public fun execute_pay<CoinType>(
    executable: &mut Executable<Pending>,
    account: &Account<Payment>, 
    mut coin: Coin<CoinType>,
    fees: &Fees,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    account.process_intent!(
        executable, 
        version::current(),   
        PayIntent(), 
        |executable, iw| {
            let action = executable.next_action<_, PayAction<CoinType>, _>(iw);
            assert!(coin.value() >= action.amount, EWrongAmount);

            let tips = coin.value() - action.amount;
            transfer::public_transfer(coin.split(tips, ctx), action.issued_by); 
            // fees are not taken on tips
            fees.collect(&mut coin, ctx);
            transfer::public_transfer(coin, account.addr());
            
            event::emit(PayEvent<CoinType> {
                payment_id: executable.intent().key(),
                timestamp: clock.timestamp_ms(),
                amount: action.amount,
                tips,
                issued_by: action.issued_by,
            });
        }
    );
}

/// Deletes the action in an expired intent.
public fun delete_pay<CoinType>(expired: &mut Expired) {
    let PayAction<CoinType> { .. } = expired.remove_action();
}