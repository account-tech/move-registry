module p2p::order;

public struct Order has key, store {
    id: UID,
    size: u64,
}

public fun create(
    ctx: &mut TxContext,
    size: u64
): Order {
    Order {
        id: object::new(ctx),
        size
    }
}