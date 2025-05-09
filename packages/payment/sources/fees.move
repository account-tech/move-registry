module account_payment::fees;

// === Imports ===

use sui::vec_map::{Self, VecMap};
use sui::coin::Coin;
// === Errors ===

const ERecipientAlreadyExists: u64 = 0;
const ERecipientDoesNotExist: u64 = 1;
const ETotalFeesTooHigh: u64 = 2;

// === Constants ===

const FEE_DENOMINATOR: u64 = 10_000;

// === Structs ===

public struct Fees has key {
    id: UID,
    // Recipients and their corresponding basis points.
    inner: VecMap<address, u64>,
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
        inner: vec_map::empty(),
    });
}

// === View Functions ===

public fun inner(fees: &Fees): VecMap<address, u64> {
    fees.inner
}

// === Package Functions ===

public(package) fun collect<CoinType>(
    fees: &Fees,
    coin: &mut Coin<CoinType>,
    ctx: &mut TxContext
) {
    let total_amount = coin.value();
    let mut fees = fees.inner;

    while (!fees.is_empty()) {
        let (recipient, bps) = fees.pop();
        let fee_amount = (total_amount * bps) / FEE_DENOMINATOR;
        transfer::public_transfer(coin.split(fee_amount, ctx), recipient);
    };
}

// === Admin Functions ===

public fun add_fee(
    _: &AdminCap, 
    fees: &mut Fees, 
    recipient: address, 
    bps: u64
) {
    assert!(!fees.inner.contains(&recipient), ERecipientAlreadyExists);
    fees.inner.insert(recipient, bps);
    fees.assert_fees_not_too_high();
}

public fun edit_fee(
    _: &AdminCap, 
    fees: &mut Fees, 
    recipient: address, 
    bps: u64
) {
    assert!(fees.inner.contains(&recipient), ERecipientDoesNotExist);
    *fees.inner.get_mut(&recipient) = bps;
    fees.assert_fees_not_too_high();
}

public fun remove_fee(
    _: &AdminCap, 
    fees: &mut Fees, 
    recipient: address
) {
    assert!(fees.inner.contains(&recipient), ERecipientDoesNotExist);
    fees.inner.remove(&recipient);
}

// === Private Functions ===

fun assert_fees_not_too_high(fees: &Fees) {
    let (mut fees, mut total_bps) = (fees.inner, 0);

    while (!fees.is_empty()) {
        let (_, bps) = fees.pop();
        total_bps = total_bps + bps;
    };

    assert!(total_bps < FEE_DENOMINATOR / 2, ETotalFeesTooHigh);
}
// === Test Functions ===

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun set_fees_for_testing(
    fees: &mut Fees,
    addrs: vector<address>,
    bps: vector<u64>
) {
    fees.inner = vec_map::from_keys_values(addrs, bps);
}
