/// Core module for managing everything related to merchant businesses.
/// Provides APIs for creating merchant accounts
/// as well as posting, completing, and closing ads.

module p2p::merchant;

// === Imports ===

use std::string::{Self, String};

use sui::clock::Clock;
use sui::coin::Coin;

use account_actions::vault;
use account_multisig::config;
use account_multisig::multisig::{Multisig, Approvals};
use account_multisig::multisig;
use account_extensions::extensions::Extensions;
use account_protocol::account::Account;

use p2p::buy_ads::BuyAds;
use p2p::coin::{Self as def_coin, CoinWhitelist};
use p2p::escrow_intents;

// === Errors ====

// === Constants ===

const CREATOR_WEIGHT: u64 = 2;
const RECOVERY_WEIGHT: u64 = 1;
const DEFAULT_THRESHOLD: u64 = 2;

const ADMIN_ROLE: vector<u8> = b"admin";
const RECOVERY_ROLE: vector<u8> = b"recovery";
const MULTISIG_KEY: vector<u8> = b"init";

// === Structs ===

public struct MerchantCap has key, store {
    id: UID,
    account_addr: address
}

// === [COMMAND] Public functions ===

/// Support merchants with smart accounts
public fun create(
    extensions: &Extensions,
    recovery_addresses: vector<address>,
    clock: &Clock,
    ctx: &mut TxContext
): (Account<Multisig, Approvals>, MerchantCap) {
    let mut account = multisig::new_account(extensions, ctx);
    let account_addr = account.addr();

    let mut members = vector<address>[ctx.sender()];
    let mut weights = vector[CREATOR_WEIGHT];
    let mut roles = vector<vector<String>>[];

    let mut creator_roles = vector::empty<String>();
    creator_roles.push_back(string::utf8(ADMIN_ROLE));
    creator_roles.push_back(string::utf8(RECOVERY_ROLE));
    roles.push_back(creator_roles);

    let mut i = 0;
    while (i < recovery_addresses.length()) {
        let recovery_addr = vector::borrow(&recovery_addresses, i);
        members.push_back(*recovery_addr);
        weights.push_back(RECOVERY_WEIGHT);

        let mut recovery_roles = vector::empty<String>();
        recovery_roles.push_back(string::utf8(RECOVERY_ROLE));
        roles.push_back(recovery_roles);

        i = i + 1;
    };

    let role_names = vector<String>[
        string::utf8(ADMIN_ROLE),
        string::utf8(RECOVERY_ROLE)
    ];

    let role_thresholds = vector<u64>[
        CREATOR_WEIGHT,
        RECOVERY_WEIGHT * 2
    ];

    let auth = multisig::authenticate(&account, ctx);

    config::request_config_multisig(
        auth,
        multisig::empty_outcome(),
        &mut account,
        string::utf8(MULTISIG_KEY),
        b"Initialize merchant account with social recovery".to_string(),
        clock.timestamp_ms(),
        clock.timestamp_ms(),
        members,
        weights,
        roles,
        DEFAULT_THRESHOLD,
        role_names,
        role_thresholds,
        ctx
    );

    multisig::approve_intent(&mut account, string::utf8(MULTISIG_KEY), ctx);
    let executable = multisig::execute_intent(&mut account, string::utf8(MULTISIG_KEY), clock);
    config::execute_config_multisig(executable, &mut account);

    open_vault(&mut account, b"default".to_string(), ctx);

    let merchant_cap = MerchantCap {
        id: object::new(ctx),
        account_addr
    };

    (account, merchant_cap)
}

/// Merchants can open several vaults in addition to the `default`
public fun open_vault(
    account: &mut Account<Multisig, Approvals>,
    vault_name: String,
    ctx: &mut TxContext
) {
    let auth = multisig::authenticate(account, ctx);
    vault::open<Multisig, Approvals>(
        auth,
        account,
        vault_name,
        ctx
    );
}

/// Merchants can deposit to their vaults
public fun deposit_to_vault<CoinType: drop>(
    account: &mut Account<Multisig, Approvals>,
    vault_name: String,
    asset: Coin<CoinType>,
    ctx: &mut TxContext
) {
    let auth = multisig::authenticate(account, ctx);
    vault::deposit<Multisig, Approvals, CoinType>(
        auth,
        account,
        vault_name,
        asset
    );
}

/// Merchant post sell ads
public fun post_sell_advert<CoinType: drop>(
    _merchant: &MerchantCap,
    account: &mut Account<Multisig, Approvals>,
    whitelist: &mut CoinWhitelist,
    min_buy: u64,
    max_buy: u64,
    key: String,
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    vault_name: String,
    amount: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    def_coin::asset_is_coin_whitelisted<CoinType>(whitelist);

    let auth = multisig::authenticate(account, ctx);
    let outcome = multisig::empty_outcome();

    escrow_intents::request_advertise_sell<Multisig, Approvals, CoinType>(
        auth,
        outcome,
        account,
        key,
        description,
        execution_times,
        expiration_time,
        vault_name,
        amount,
        ctx
    );

    multisig::approve_intent(account, key, ctx);

    let mut executable = multisig::execute_intent(account, key, clock);

    escrow_intents::execute_advertise_sell<Multisig, Approvals, CoinType>(
        whitelist,
        min_buy,
        max_buy,
        clock,
        &mut executable,
        account,
        ctx
    );

    escrow_intents::complete_advertise_sell<Multisig, Approvals>(executable, account);
}

/// Merchants post buy ads
public fun post_buy_advert<CoinType: drop>(
    _merchant: &MerchantCap,
    account: &mut Account<Multisig, Approvals>,
    key: String,
    description: String,
    execution_times: vector<u64>,
    expiration_time: u64,
    vault_name: String,
    whitelist: &mut CoinWhitelist,
    ads: &mut BuyAds,
    min_sell: u64,
    max_sell: u64,
    process_time: u64,
    clock: &Clock,
    ctx: &mut TxContext
) {
    def_coin::asset_is_coin_whitelisted<CoinType>(whitelist);

    let auth = multisig::authenticate(account, ctx);
    let outcome = multisig::empty_outcome();

    escrow_intents::request_advertise_buy<Multisig, Approvals, CoinType>(
        auth,
        outcome,
        account,
        key,
        description,
        execution_times,
        expiration_time,
        vault_name,
        min_sell,
        max_sell,
        process_time,
        ctx,
    );

    multisig::approve_intent(account, key, ctx);

    let mut executable = multisig::execute_intent(account, key, clock);

    escrow_intents::execute_advertise_buy<Multisig, Approvals, CoinType>(whitelist, ads, &mut executable, account, ctx);

    escrow_intents::complete_advertise_buy<Multisig, Approvals>(executable, account);
}