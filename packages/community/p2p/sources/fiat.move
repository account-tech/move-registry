module p2p::fiat;

// === Imports ===

use std::string::String;
use std::uq64_64::{Self, UQ64_64};

use p2p::p2p::AdminCap;

// === Errors ===

#[error]
const EBaseCurrencyDisabled: vector<u8> = b"The base currency is disabled";

public struct BaseCurrencies has key {
    id: UID,
    list: vector<ID>
}

public struct BaseCurrency has key {
    id: UID,
    code: String,
    exchange_rate: UQ64_64,
    enabled: bool
}

fun init(
    ctx: &mut TxContext
) {
    transfer::share_object(
        BaseCurrencies {
            id: object::new(ctx),
            list: vector::empty()
        }
    );
}

public fun new_listing(
    _admin: &AdminCap,
    bases: &mut BaseCurrencies,
    code: String,
    units_per_dollar: u64,
    decimals: u8,
    ctx: &mut TxContext
) {
    let numerator = uq64_64::from_int(units_per_dollar);
    let denominator = uq64_64::from_int(pow_10(decimals));

    let exchange_rate = uq64_64::div(numerator, denominator);

    let base_currency = BaseCurrency {
        id: object::new(ctx),
        code,
        exchange_rate,
        enabled: true,
    };

    let id = object::id(&base_currency);
    bases.list.push_back(id);

    transfer::share_object(base_currency);
}

public fun toggle_base_currency(
    _admin: &AdminCap,
    base: &mut BaseCurrency,
) {
    base.enabled = !base.enabled;
}

public fun is_enabled(base: &BaseCurrency): bool {
    base.enabled
}

public fun get_code(base: &BaseCurrency): &String {
    &base.code
}

public fun assert_enabled(base: &BaseCurrency) {
    assert!(base.enabled, EBaseCurrencyDisabled);
}

fun pow_10(decimals: u8): u64 {
    let mut result = 1;
    let mut i = 0;
    while (i < decimals) {
        result = result * 10;
        i = i + 1;
    };
    result
}
