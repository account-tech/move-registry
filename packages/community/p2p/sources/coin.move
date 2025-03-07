/// This module handles supported coin types

module p2p::coin;

// === Imports ===

use std::type_name::{Self, TypeName};

use sui::vec_set::{Self, VecSet};

use p2p::p2p::AdminCap;

#[error]
const ECoinTypeNotWhitelisted: vector<u8> = b"Coin Type Not Whitelisted";


// === Structs ===

public struct CoinWhitelist has key {
    id: UID,
    allowed_coins: VecSet<TypeName>
}

// === Public mutative functions ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(CoinWhitelist {
        id: object::new(ctx),
        allowed_coins: vec_set::empty()
    });
}

public fun whitelist_coin<T>(
    _: &AdminCap,
    whitelist: &mut CoinWhitelist,
) {
    let type_name = type_name::get<T>();
    whitelist.allowed_coins.insert(type_name);
}

public fun delist_coin_from_whitelist<T>(
    _: &AdminCap,
    whitelist: &mut CoinWhitelist
) {
    let type_name = type_name::get<T>();
    whitelist.allowed_coins.remove(&type_name);
}

public fun is_coin_whitelisted<T>(whitelist: &CoinWhitelist): bool {
    let type_name = type_name::get<T>();
    whitelist.allowed_coins.contains(&type_name)
}

public fun asset_is_coin_whitelisted<T>(whitelist: &CoinWhitelist) {
    assert!(is_coin_whitelisted<T>(whitelist), ECoinTypeNotWhitelisted)
}