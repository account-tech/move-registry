module p2p_ramp::fees;

// === Imports ===

use std::type_name::{Self, TypeName};
use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID};
use sui::sui::SUI;
use sui::transfer;
use sui::tx_context::TxContext;
use sui::vec_map::{Self, VecMap};
use sui::vec_set::{Self, VecSet};

use p2p_ramp::p2p::AdminCap;

// === Errors ===

const ERecipientAlreadyExists: u64 = 0;
const ERecipientDoesNotExist: u64 = 1;
const ETotalFeesTooHigh: u64 = 2;
const ECoinTypeNotWhitelisted: u64 = 3;

// === Constants ===

const FEE_DENOMINATOR: u64 = 10_000;

// === Structs ===

public struct Fees has key {
    id: UID,
    // Map of addresses to their fees in bps
    inner: VecMap<address, u64>,
    // Set of allowed coin typestep vov
    allowed_coins: VecSet<TypeName>
}

// === Public Functions ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(Fees {
        id: object::new(ctx),
        inner: vec_map::empty(),
        allowed_coins: vec_set::empty(),
    });
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

public fun allow_coin<T>(
    _: &AdminCap,
    fees: &mut Fees,
) {
    let type_name = type_name::get<T>();
    fees.allowed_coins.insert(type_name);
}

public fun disallow_coin<T>(
    _: &AdminCap,
    fees: &mut Fees
) {
    let type_name = type_name::get<T>();
    fees.allowed_coins.remove(&type_name);
}

public fun is_coin_allowed<T>(fees: &Fees): bool {
    let type_name = type_name::get<T>();
    fees.allowed_coins.contains(&type_name)
}

public fun assert_coin_allowed<T>(fees: &Fees) {
    assert!(is_coin_allowed<T>(fees), ECoinTypeNotWhitelisted)
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