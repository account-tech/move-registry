module account_multisig::fees;

// === Imports ===

use sui::{
    coin::Coin,
    sui::SUI,
};

// === Errors ===

const EWrongAmount: u64 = 0;

// === Constants ===

const DECIMALS: u64 = 1_000_000_000; // 10^9

// === Structs ===

public struct Fees has key {
    id: UID,
    // Amount of fees to be paid.
    amount: u64,
    // Recipient of the fees.
    recipient: address,
}

public struct AdminCap has key, store {
    id: UID,
}

// === Public Functions ===

fun init(ctx: &mut TxContext) {
    transfer::public_transfer(
        AdminCap { id: object::new(ctx) }, 
        ctx.sender()
    );

    transfer::share_object(Fees {
        id: object::new(ctx),
        amount: 10 * DECIMALS, // 10 SUI
        recipient: ctx.sender(),
    });
}

// === View Functions ===

public fun amount(fees: &Fees): u64 {
    fees.amount
}

public fun recipient(fees: &Fees): address {
    fees.recipient
}

// === Package Functions ===

public(package) fun process(
    fees: &Fees,
    coin: Coin<SUI>,
) {
    assert!(coin.value() == fees.amount, EWrongAmount);

    if (coin.value() > 0) {
        transfer::public_transfer(coin, fees.recipient);
    } else {
        coin.destroy_zero();
    };
}

// === Admin Functions ===

public fun set_amount(
    fees: &mut Fees, 
    _: &AdminCap, 
    amount: u64
) {
    fees.amount = amount;
}

public fun set_recipient(
    fees: &mut Fees, 
    _: &AdminCap, 
    recipient: address
) {
    fees.recipient = recipient;
}

// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun set_fees_for_testing(
    fees: &mut Fees,
    amount: u64,
    recipient: address,
) {
    fees.amount = amount;
    fees.recipient = recipient;
}
