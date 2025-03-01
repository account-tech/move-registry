module account_payment::fees;

// === Imports ===

use sui::vec_map::{Self, VecMap};
use sui::coin::Coin;
// === Errors ===

const ERecipientAlreadyExists: u64 = 0;
const ERecipientDoesNotExist: u64 = 1;

// === Constants ===

const FEE_DENOMINATOR: u64 = 10_000;

// === Structs ===

public struct Fees has key {
    id: UID,
    // Whether the fees are active.
    active: bool,
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
        active: true,
        inner: vec_map::empty(),
    });
}

// === View Functions ===

public fun inner(fees: &Fees): VecMap<address, u64> {
    fees.inner
}

public fun active(fees: &Fees): bool {
    fees.active
}

// === Package Functions ===

public(package) fun process<CoinType>(
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

public fun set_active(
    _: &AdminCap, 
    fees: &mut Fees, 
    active: bool
) {
    fees.active = active;
}

public fun add_fee(
    _: &AdminCap, 
    fees: &mut Fees, 
    recipient: address, 
    bps: u64
) {
    assert!(!fees.inner.contains(&recipient), ERecipientAlreadyExists);
    fees.inner.insert(recipient, bps);
}

public fun edit_fee(
    _: &AdminCap, 
    fees: &mut Fees, 
    recipient: address, 
    bps: u64
) {
    assert!(fees.inner.contains(&recipient), ERecipientDoesNotExist);
    *fees.inner.get_mut(&recipient) = bps;
}

public fun remove_fee(
    _: &AdminCap, 
    fees: &mut Fees, 
    recipient: address
) {
    assert!(fees.inner.contains(&recipient), ERecipientDoesNotExist);
    fees.inner.remove(&recipient);
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
