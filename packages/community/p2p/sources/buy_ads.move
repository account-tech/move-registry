/// This module handles all buy ads

module p2p::buy_ads;

use sui::vec_set::{Self, VecSet};

// === Structs ===

public struct BuyAds has key {
    id: UID,
    list: VecSet<ID>
}

// === Public mutative functions ===

fun init(ctx: &mut TxContext) {
    transfer::share_object(
        BuyAds {
            id: object::new(ctx),
            list: vec_set::empty()
        }
    )
}

public(package) fun add(
    ads: &mut BuyAds,
    ad: ID
) {
    ads.list.insert(ad);
}

public(package) fun remove(
    ads: &mut BuyAds,
    ad: &ID
) {
    ads.list.remove(ad);
}

// === View functions ===

public fun size(ads: &BuyAds): u64 {
    ads.list.size()
}