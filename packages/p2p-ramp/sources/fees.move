module p2p_ramp::fees;

// === Imports ===

use std::string::String;
use std::type_name::{Self, TypeName};
use sui::{
    coin::Coin,
    vec_map::{Self, VecMap},
    vec_set::{Self, VecSet},
};

// === Errors ===

const ERecipientAlreadyExists: u64 = 0;
const ERecipientDoesNotExist: u64 = 1;
const ETotalFeesTooHigh: u64 = 2;
const ECoinTypeNotWhitelisted: u64 = 3;
const EFiatTypeNotWhitelisted: u64 = 4;

// === Constants ===

const FEE_DENOMINATOR: u64 = 10_000;

// === Structs ===

public struct Fees has key {
    id: UID,
    // Map of addresses to their fees in bps
    collectors: VecMap<address, u64>,
    // Set of allowed coin typestep vov
    allowed_coins: VecSet<TypeName>,
    // Set of allowed fiat currencies
    allowed_fiat: VecSet<String>
}

public struct AdminCap has key, store {
    id: UID
}

// === Public Functions ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(Fees {
        id: object::new(ctx),
        collectors: vec_map::empty(),
        allowed_coins: vec_set::empty(),
        allowed_fiat: vec_set::empty()
    });
    // we only need one admin cap since it will be held by the dev multisig
    transfer::public_transfer(
        AdminCap { id: object::new(ctx) },
        ctx.sender()
    );
}

// === View Functions ===

public fun collectors(fees: &Fees): VecMap<address, u64> {
    fees.collectors
}

public fun allowed_coins(fees: &Fees): VecSet<TypeName> {
    fees.allowed_coins
}

// === Package Functions ===

public(package) fun collect<CoinType>(
    fees: &Fees,
    coin: &mut Coin<CoinType>,
    ctx: &mut TxContext
) {
    let total_amount = coin.value();
    let mut fees = fees.collectors;

    while (!fees.is_empty()) {
        let (recipient, bps) = fees.pop();
        let fee_amount = (total_amount * bps) / FEE_DENOMINATOR;
        transfer::public_transfer(coin.split(fee_amount, ctx), recipient);
    };
}

// === Admin Functions ===

public fun add_collector(
    _: &AdminCap,
    fees: &mut Fees,
    recipient: address,
    bps: u64
) {
    assert!(!fees.collectors.contains(&recipient), ERecipientAlreadyExists);
    fees.collectors.insert(recipient, bps);
    fees.assert_fees_not_too_high();
}

public fun edit_collector(
    _: &AdminCap,
    fees: &mut Fees,
    recipient: address,
    bps: u64
) {
    assert!(fees.collectors.contains(&recipient), ERecipientDoesNotExist);
    *fees.collectors.get_mut(&recipient) = bps;
    fees.assert_fees_not_too_high();
}

public fun remove_collector(
    _: &AdminCap,
    fees: &mut Fees,
    recipient: address
) {
    assert!(fees.collectors.contains(&recipient), ERecipientDoesNotExist);
    fees.collectors.remove(&recipient);
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

public fun allow_fiat(
    _: &AdminCap,
    fees: &mut Fees,
    fiat_code: String
) {
    fees.allowed_fiat.insert(fiat_code);
}

public fun disallow_fiat(
    _: &AdminCap,
    fees: &mut Fees,
    fiat_code: String
) {
    fees.allowed_fiat.remove(&fiat_code);
}

public fun is_fiat_allowed(
    fees: &Fees,
    fiat_code: String,
): bool {
    fees.allowed_fiat.contains(&fiat_code)
}

public fun assert_fiat_allowed(
    fees: &Fees,
    fiat_code: String,
) {
    assert!(is_fiat_allowed(fees, fiat_code), EFiatTypeNotWhitelisted)
}

// === Private Functions ===

fun assert_fees_not_too_high(fees: &Fees) {
    let (mut fees, mut total_bps) = (fees.collectors, 0);

    while (!fees.is_empty()) {
        let (_, bps) = fees.pop();
        total_bps = total_bps + bps;
    };

    assert!(total_bps < FEE_DENOMINATOR / 2, ETotalFeesTooHigh);
}

// == Test Functions ==

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

