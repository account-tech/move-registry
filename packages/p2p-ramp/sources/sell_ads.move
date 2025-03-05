/// This module handles all sell ads

module p2p_ramp::sell_ads;

use sui::vec_set::{Self, VecSet};

public struct SellAds has key {
    id: UID,
    list: VecSet<ID>
}

fun init(ctx: &mut TxContext) {
    transfer::share_object(
        SellAds {
            id: object::new(ctx),
            list: vec_set::empty()
        }
    );
}

public(package) fun add(
    ads: &mut SellAds,
    ad: ID
) {
    ads.list.insert(ad);
}

public(package) fun remove(
    ads: &mut SellAds,
    ad: &ID
) {
    ads.list.remove(ad);
}

// === View functions ===

public fun size(ads: &SellAds): u64 {
    ads.list.size()
}