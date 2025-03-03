/// This module handles coin buy ads

module p2p::buy_ad;

// === Imports ===

use p2p::coin::{Self, CoinWhitelist};

// === Errors ===

#[error]
const ECoinTypeNotWhitelisted: vector<u8> = b"Coin Type Not Whitelisted";

// === Structs ===

public struct BuyAd has key {
    id: UID,
    min_sell: u64,
    max_sell: u64,
    process_time: u64,
    active: bool
}

// === Public functions ===

public fun create<T>(
    whitelist: &mut CoinWhitelist,
    min_sell: u64,
    max_sell: u64,
    process_time: u64,
    ctx: &mut TxContext
): BuyAd {
    assert!(coin::is_coin_whitelisted<T>(whitelist), ECoinTypeNotWhitelisted);
    BuyAd {
        id: object::new(ctx),
        min_sell,
        max_sell,
        process_time,
        active: true
    }
}

public fun transfer(
    ad: BuyAd,
    ctx: &mut TxContext
) {
    transfer::transfer(ad, ctx.sender());
}
