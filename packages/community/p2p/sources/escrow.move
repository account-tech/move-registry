/// This module handles merchant and user escrow services

module p2p::escrow;

// === Imports ===

use sui::balance::Self;
use sui::coin::{Self, Coin};

use p2p::coin::{Self as custom_coin, CoinWhitelist};
use p2p::sell_ad;
use p2p::sell_ad::SellAd;

// === Errors ===

#[error]
const ENotCreator: vector<u8> = b"The caller is not the creator";

#[error]
const EInvalidReductionAmount: vector<u8> = b"The reduction amount is invalid";

#[error]
const ENoBalance: vector<u8> = b"No balance available";

#[error]
const ECoinTypeNotWhitelisted: vector<u8> = b"The specified coin type is not whitelisted";

// === Structs ===

public struct Escrow<phantom T> has key {
    id: UID,
    asset: SellAd<T>,
    creator: address,
}

// === Public mutative functions ===

public(package) fun create_escrow<T>(
    whitelist: &CoinWhitelist,
    asset: SellAd<T>,
    ctx: &mut TxContext
): Escrow<T> {
    assert!(custom_coin::is_coin_whitelisted<T>(whitelist), ECoinTypeNotWhitelisted);

    let escrow = Escrow {
        id: object::new(ctx),
        asset,
        creator: ctx.sender(),
    };

    escrow
}

public(package) fun share<T>(
    escrow: Escrow<T>,
) {
    transfer::share_object(escrow);
}


public(package) fun reduce_amount<T>(
    escrow: &mut Escrow<T>,
    amount: u64,
    ctx: &mut TxContext
): Coin<T> {
    let sell = sell_ad::get_balance_mut<T>(&mut escrow.asset);
    let balance_value = sell.value();
    assert!(balance_value >= amount, EInvalidReductionAmount);
    coin::take(sell, amount, ctx)
}

public(package) fun add_coins<T>(
    whitelist: &CoinWhitelist,
    escrow: &mut Escrow<T>,
    coin: Coin<T>,
    _ctx: &mut TxContext
) {
    assert!(custom_coin::is_coin_whitelisted<T>(whitelist), ECoinTypeNotWhitelisted);

    let coin_balance = coin::into_balance(coin);
    sell_ad::get_balance_mut<T>(&mut escrow.asset).join(coin_balance);
}

public(package) fun destroy_escrow<T>(
    escrow: Escrow<T>,
    ctx: &mut TxContext
): Coin<T> {
    assert!(escrow.creator == ctx.sender(), ENotCreator);

    let Escrow { id, creator, asset } = escrow;

    let mut b = sell_ad::take_balance<T>(asset);
    let balance_value = b.value();
    assert!(balance_value > 0, ENoBalance);

    let remaining_coin = coin::take(&mut b, balance_value, ctx);

    balance::destroy_zero<T>(b);
    object::delete(id);

    remaining_coin
}

public fun get_balance<T>(escrow: &Escrow<T>): u64 {
    sell_ad::get_balance<T>(&escrow.asset).value()
}