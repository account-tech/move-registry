/// This module handles the merchants buy post actions

module p2p_ramp::buy_actions;

// === Imports ===

use account_protocol::account::Account;
use account_protocol::executable::Executable;
use account_protocol::intents::Intent;
use account_protocol::version_witness::VersionWitness;

use p2p::buy_ad;
use p2p::buy_ads::{Self, BuyAds};
use p2p::coin::CoinWhitelist;

// === Structs ===

public struct BuyAction has store {
    min_sell: u64,
    max_sell: u64,
    process_time: u64,
}

// === Public functions ===

public fun new_buy_action<Config, Outcome, IW: drop>(
    intent: &mut Intent<Outcome>,
    account: &Account<Config, Outcome>,
    min_sell: u64,
    max_sell: u64,
    process_time: u64,
    version_witness: VersionWitness,
    intent_witness: IW
) {
    account.add_action(intent, BuyAction {
        min_sell,
        max_sell,
        process_time,
    }, version_witness, intent_witness);
}

public fun do_buy_action<Config, Outcome, CoinType: drop, IW: drop>(
    executable: &mut Executable,
    account: &mut Account<Config, Outcome>,
    whitelist: &mut CoinWhitelist,
    ads: &mut BuyAds,
    version_witness: VersionWitness,
    intent_witness: IW,
    ctx: &mut TxContext
) {
    let action: &BuyAction = account.process_action(executable, version_witness, intent_witness);
    let ad = buy_ad::create<CoinType>(whitelist, action.min_sell, action.max_sell, action.process_time, ctx);
    buy_ads::add(ads, object::id(&ad));
    buy_ad::transfer(ad, ctx);
}