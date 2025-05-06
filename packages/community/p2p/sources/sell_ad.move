/// This module handles coin sell ads

module p2p::sell_ad;

// === Imports ===

use sui::balance::Balance;
use sui::clock::Clock;
use sui::coin as scoin;
use sui::coin::Coin;

use p2p::coin::{Self, CoinWhitelist};

#[error]
const ECoinTypeNotWhitelisted:  vector<u8> = b"Coin Type Not Whitelisted";

// === Structs ===

public struct SellAd<phantom T> has store {
    balance: Balance<T>,
    min_buy: u64,
    max_buy: u64,
    created: u64,
    active: bool,
}

// [COMMAND] Public functions ===

public fun create<T>(
    asset: &mut Coin<T>,
    amount: u64,
    min_buy: u64,
    max_buy: u64,
    whitelist: &mut CoinWhitelist,
    clock: &Clock,
    ctx: &mut TxContext
): SellAd<T> {
    assert!(coin::is_coin_whitelisted<T>(whitelist), ECoinTypeNotWhitelisted);
    let coin = asset.split<T>(amount, ctx);
    let balance = scoin::into_balance<T>(coin);
    SellAd {
        balance,
        min_buy,
        max_buy,
        created: clock.timestamp_ms(),
        active: true
    }
}

public fun create_from_balance<T>(
    balance: Balance<T>,
    min_buy: u64,
    max_buy: u64,
    whitelist: &mut CoinWhitelist,
    clock: &Clock,
) : SellAd<T> {
    assert!(coin::is_coin_whitelisted<T>(whitelist), ECoinTypeNotWhitelisted);
    SellAd {
        balance,
        min_buy,
        max_buy,
        created: clock.timestamp_ms(),
        active: true
    }
}

public fun take_balance<T>(ad: SellAd<T>) : Balance<T> {
    let SellAd { balance, min_buy, max_buy, created, active } = ad;
    balance
}

public fun get_balance<T>(
    ad: &SellAd<T>,
) : &Balance<T> {
    &ad.balance
}

public fun get_balance_mut<T>(
    ad: &mut SellAd<T>,
) : &mut Balance<T> {
    &mut ad.balance
}