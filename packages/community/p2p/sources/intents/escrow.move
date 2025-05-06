/// This module handles merchants' buy and sell proposals

module p2p::escrow_intents;

// === Imports ===

use std::string::String;

use sui::clock::Clock;
use sui::coin;
use sui::coin::Coin;

use account_protocol::{
    account::{Account, Auth},
    executable::Executable,
};

use account_actions::vault;

use p2p::buy_actions::Self;
use p2p::buy_ads::BuyAds;
use p2p::coin::CoinWhitelist;
use p2p::escrow::{Self, Escrow};
use p2p::sell_ad::Self;
use p2p::version;

// === Errors ===

#[error]
const EInsufficientFunds: vector<u8> = b"Insufficient funds for this coin type in vault";
#[error]
const ECoinTypeDoesntExist: vector<u8> = b"Coin type doesn't exist in vault";

// === Structs ===

public struct AdvertiseSellIntent() has copy, drop;
public struct CloseSellAdvertIntent() has copy, drop;

public struct AdvertiseBuyIntent() has copy, drop;
public struct CloseBuyAdvertIntent() has copy, drop;

public fun request_advertise_sell<Config, Outcome, CoinType: drop>(
    auth: Auth,
    outcome: Outcome,
    account: &mut Account<Config, Outcome>,
    key: String,
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    vault_name: String,
    amount: u64,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let vault = vault::borrow_vault(account, vault_name);

    assert!(vault.coin_type_exists<CoinType>(), ECoinTypeDoesntExist);

    if (vault.coin_type_value<CoinType>() < amount) assert!(
        amount <= vault.coin_type_value<CoinType>(),
        EInsufficientFunds
    );

    let mut intent = account.create_intent(
        key,
        description,
        execution_times,
        expiration_time,
        vault_name,
        outcome,
        version::current(),
        AdvertiseSellIntent(),
        ctx);

    vault::new_spend<_, _, CoinType, _>(
        &mut intent,
        account,
        vault_name,
        amount,
        version::current(),
        AdvertiseSellIntent()
    );
    account.add_intent(intent, version::current(), AdvertiseSellIntent());
}

public fun execute_advertise_sell<Config, Outcome, CoinType: drop>(
    whitelist: &mut CoinWhitelist,
    min_buy: u64,
    max_buy: u64,
    clock: &Clock,
    executable: &mut Executable,
    account: &mut Account<Config, Outcome>,
    ctx: &mut TxContext
) {
    let coin: Coin<CoinType> = vault::do_spend(executable, account, version::current(), AdvertiseSellIntent(), ctx);
    let ad = sell_ad::create_from_balance<CoinType>(coin::into_balance(coin), min_buy, max_buy, whitelist, clock);
    let create_escrow = escrow::create_escrow<CoinType>(whitelist, ad, ctx);
    escrow::share(create_escrow);
}

public fun complete_advertise_sell<Config, Outcome>(
    executable: Executable,
    account: &Account<Config, Outcome>,
) {
    account.confirm_execution(executable, version::current(), AdvertiseSellIntent());
}

public fun request_close_sell_advert<Config, Outcome, CoinType: drop>(
    auth: Auth,
    outcome: Outcome,
    account: &mut Account<Config, Outcome>,
    key: String,
    description: String,
    execution_time: u64,
    expiration_time: u64,
    vault_name: String,
    amount: u64,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let mut intent = account.create_intent(
        key,
        description,
        vector[execution_time],
        expiration_time,
        vault_name,
        outcome,
        version::current(),
        CloseSellAdvertIntent(),
        ctx
    );

    vault::new_deposit<Config, Outcome, CoinType, CloseSellAdvertIntent>(
        &mut intent,
        account,
        vault_name,
        amount,
        version::current(),
        CloseSellAdvertIntent()
    );
    account.add_intent(intent, version::current(), CloseSellAdvertIntent());
}


public fun execute_close_sell_advert<Config, Outcome, CoinType: drop>(
    escrow: Escrow<CoinType>,
    executable: &mut Executable,
    account: &mut Account<Config, Outcome>,
    ctx: &mut TxContext
) {
    let coin = escrow::destroy_escrow<CoinType>(
        escrow,
        ctx
    );

    vault::do_deposit<Config, Outcome, CoinType, CloseSellAdvertIntent>(
        executable,
        account,
        coin,
        version::current(),
        CloseSellAdvertIntent(),
    );
}

public fun complete_close_sell_advert<Config, Outcome>(
    executable: Executable,
    account: &Account<Config, Outcome>,
) {
    account.confirm_execution(executable, version::current(), CloseSellAdvertIntent());
}


public fun request_advertise_buy<Config, Outcome, CoinType: drop>(
    auth: Auth,
    outcome: Outcome,
    account: &mut Account<Config, Outcome>,
    key: String,
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    vault_name: String,
    min_sell: u64,
    max_sell: u64,
    process_time: u64,
    ctx: &mut TxContext
) {
    account.verify(auth);

    let mut intent = account.create_intent(
        key,
        description,
        execution_times,
        expiration_time,
        vault_name,
        outcome,
        version::current(),
        AdvertiseBuyIntent(),
        ctx);

    buy_actions::new_buy_action<Config, Outcome, AdvertiseBuyIntent>(
        &mut intent,
        account,
        min_sell,
        max_sell,
        process_time,
        version::current(),
        AdvertiseBuyIntent()
    );

    account.add_intent(intent, version::current(), AdvertiseBuyIntent());
}

public fun execute_advertise_buy<Config, Outcome, CoinType: drop>(
    whitelist: &mut CoinWhitelist,
    ads: &mut BuyAds,
    executable: &mut Executable,
    account: &mut Account<Config, Outcome>,
    ctx: &mut TxContext
) {
    buy_actions::do_buy_action<Config, Outcome, CoinType, AdvertiseBuyIntent>(
        executable,
        account,
        whitelist,
        ads,
        version::current(),
        AdvertiseBuyIntent(),
        ctx
    );
}

public fun complete_advertise_buy<Config, Outcome>(
    executable: Executable,
    account: &Account<Config, Outcome>,
) {
    account.confirm_execution(executable, version::current(), AdvertiseBuyIntent());
}