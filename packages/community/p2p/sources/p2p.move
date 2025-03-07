/// This module handles the deployers business

module p2p::p2p;

// === Structs ===

public struct AdminCap has key, store {
    id: UID
}

fun init(ctx: &mut TxContext) {
    transfer::transfer(
        AdminCap {
            id: object::new(ctx)
        },
        ctx.sender()
    );
}