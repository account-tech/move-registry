module p2p_ramp::policy;

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
const ETotalPolicyTooHigh: u64 = 2;
const ECoinTypeNotWhitelisted: u64 = 3;
const EFiatTypeNotWhitelisted: u64 = 4;
const EMinFillDeadlineTooLow: u64 = 5;

// === Constants ===

const FEE_DENOMINATOR: u64 = 10_000;
const MIN_FILL_DEADLINE_MS: u64 = 900_000;
const MAX_ORDERS: u64 = 4;

// === Structs ===

public struct Policy has key {
    id: UID,
    // Map of addresses to their policy in bps
    collectors: VecMap<address, u64>,
    // Set of allowed coin typestep vov
    allowed_coins: VecSet<TypeName>,
    // Set of allowed fiat currencies
    allowed_fiat: VecSet<String>,
    // The minimum time a merchant can set for a fill deadline.
    min_fill_deadline_ms: u64,
    // the max no_ of orders a merchant can create
    max_orders: u64,
}

public struct AdminCap has key, store {
    id: UID
}

// === Public Functions ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(Policy {
        id: object::new(ctx),
        collectors: vec_map::empty(),
        allowed_coins: vec_set::empty(),
        allowed_fiat: vec_set::empty(),
        min_fill_deadline_ms: MIN_FILL_DEADLINE_MS,
        max_orders: MAX_ORDERS,
    });
    // we only need one admin cap since it will be held by the dev multisig
    transfer::public_transfer(
        AdminCap { id: object::new(ctx) },
        ctx.sender()
    );
}

// === View Functions ===

public fun collectors(policy: &Policy): VecMap<address, u64> {
    policy.collectors
}

public fun allowed_coins(policy: &Policy): VecSet<TypeName> {
    policy.allowed_coins
}

public fun allowed_fiat(policy: &Policy): VecSet<String> {
    policy.allowed_fiat
}

public fun min_fill_deadline_ms(policy: &Policy): u64 {
    policy.min_fill_deadline_ms
}

public fun max_orders(policy: &Policy): u64 {
    policy.max_orders
}

// === Package Functions ===

public(package) fun collect<CoinType>(
    policy: &Policy,
    coin: &mut Coin<CoinType>,
    ctx: &mut TxContext
) {
    let total_amount = coin.value();
    let mut policy = policy.collectors;

    while (!policy.is_empty()) {
        let (recipient, bps) = policy.pop();
        let fee_amount = (total_amount * bps) / FEE_DENOMINATOR;
        transfer::public_transfer(coin.split(fee_amount, ctx), recipient);
    };
}

// === Admin Functions ===

public fun add_collector(
    _: &AdminCap,
    policy: &mut Policy,
    recipient: address,
    bps: u64
) {
    assert!(!policy.collectors.contains(&recipient), ERecipientAlreadyExists);
    policy.collectors.insert(recipient, bps);
    policy.assert_policy_not_too_high();
}

public fun edit_collector(
    _: &AdminCap,
    policy: &mut Policy,
    recipient: address,
    bps: u64
) {
    assert!(policy.collectors.contains(&recipient), ERecipientDoesNotExist);
    *policy.collectors.get_mut(&recipient) = bps;
    policy.assert_policy_not_too_high();
}

public fun remove_collector(
    _: &AdminCap,
    policy: &mut Policy,
    recipient: address
) {
    assert!(policy.collectors.contains(&recipient), ERecipientDoesNotExist);
    policy.collectors.remove(&recipient);
}

public fun allow_coin<T>(
    _: &AdminCap,
    policy: &mut Policy,
) {
    let type_name = type_name::get<T>();
    policy.allowed_coins.insert(type_name);
}

public fun disallow_coin<T>(
    _: &AdminCap,
    policy: &mut Policy
) {
    let type_name = type_name::get<T>();
    policy.allowed_coins.remove(&type_name);
}

public fun is_coin_allowed<T>(policy: &Policy): bool {
    let type_name = type_name::get<T>();
    policy.allowed_coins.contains(&type_name)
}

public fun assert_coin_allowed<T>(policy: &Policy) {
    assert!(is_coin_allowed<T>(policy), ECoinTypeNotWhitelisted)
}

public fun allow_fiat(
    _: &AdminCap,
    policy: &mut Policy,
    fiat_code: String,
) {
    policy.allowed_fiat.insert(fiat_code);
}

public fun disallow_fiat(
    _: &AdminCap,
    policy: &mut Policy,
    fiat_code: String,
) {
    policy.allowed_fiat.remove(&fiat_code);
}

public fun is_fiat_allowed(
    policy: &Policy,
    fiat_code: String,
): bool {
    policy.allowed_fiat.contains(&fiat_code)
}

public fun assert_fiat_allowed(
    policy: &Policy,
    fiat_code: String,
) {
    assert!(is_fiat_allowed(policy, fiat_code), EFiatTypeNotWhitelisted)
}

public fun set_min_fill_deadline_ms(
    _: &AdminCap,
    policy: &mut Policy,
    new_min_fill_deadline_ms: u64,
) {
    assert_min_fill_deadline_too_low(new_min_fill_deadline_ms);
    policy.min_fill_deadline_ms = new_min_fill_deadline_ms;
}


public fun assert_min_fill_deadline_too_low(
    new_min_fill_deadline_ms: u64
) {
    assert!(new_min_fill_deadline_ms >= MIN_FILL_DEADLINE_MS, EMinFillDeadlineTooLow);
}

// === Private Functions ===

fun assert_policy_not_too_high(policy: &Policy) {
    let (mut policy, mut total_bps) = (policy.collectors, 0);

    while (!policy.is_empty()) {
        let (_, bps) = policy.pop();
        total_bps = total_bps + bps;
    };

    assert!(total_bps < FEE_DENOMINATOR / 2, ETotalPolicyTooHigh);
}

// == Test Functions ==

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

