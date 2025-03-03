module p2p::fees;

// === Imports ===

use sui::balance::{Self, Balance};
use sui::coin::{Self, Coin};
use sui::event;
use sui::object::{Self, UID};
use sui::sui::SUI;
use sui::transfer;
use sui::tx_context::TxContext;

use p2p::p2p::AdminCap;

// === Errors ===

#[error]
const EInsufficientBalance: vector<u8> = b"Insufficient balance to perform this operation";
#[error]
const EInvalidFeePercentage: vector<u8> = b"Fee percentage is invalid or out of range";
#[error]
const EFeeCalculationOverflow: vector<u8> = b"Fee calculation resulted in an overflow";
#[error]
const EInvalidFixedFee: vector<u8> = b"Specified fixed fee is invalid";

// === Constants ===

const FIXED_FEE: u8 = 0;
const PERCENTAGE_FEE: u8 = 1;

// === Structs ===

public struct FeeConfig has key, store {
    id: UID,
    fee_type: u8,
    fixed_fee_amount: u64,
    percentage_fee_bps: u16,
    treasury: Balance<SUI>
}

public struct FeeCollected has copy, drop {
    fee_type: u8,
    amount: u64,
    timestamp: u64
}

public struct FeeUpdated has copy, drop {
    fee_type: u8,
    new_value: u64,
    timestamp: u64
}


fun init(ctx: &mut TxContext) {
    let fee_config = FeeConfig {
        id: object::new(ctx),
        fee_type: FIXED_FEE,
        fixed_fee_amount: 1000,
        percentage_fee_bps: 30,
        treasury: balance::zero(),
    };
    transfer::public_transfer(fee_config, ctx.sender());
}

public fun calculate_fee(amount: u64, fee_config: &FeeConfig): u64 {
    if (fee_config.fee_type == FIXED_FEE) {
        fee_config.fixed_fee_amount
    } else {
        calculate_percentage_fee(amount, fee_config.percentage_fee_bps)
    }
}

fun calculate_percentage_fee(amount: u64, fee_bps: u16): u64 {
    assert!(fee_bps <= 10000, EInvalidFeePercentage);
    let fee_amount = (amount as u128) * (fee_bps as u128) / 10000u128;
    (fee_amount as u64)
}

public fun deduct_fee(
    payment: &mut Coin<SUI>,
    fee_config: &mut FeeConfig,
    ctx: &mut TxContext
): u64 {
    let payment_value = payment.value();
    let fee_amount = calculate_fee(payment_value, fee_config);

    assert!(payment_value >= fee_amount, EInsufficientBalance);

    let fee_coin = payment.split(fee_amount, ctx);
    let fee_balance = coin::into_balance(fee_coin);

    fee_config.treasury.join(fee_balance);

    event::emit(FeeCollected {
        fee_type: fee_config.fee_type,
        amount: fee_amount,
        timestamp: ctx.epoch()
    });

    fee_amount
}

public fun set_fixed_fee(
    fee_config: &mut FeeConfig,
    amount: u64,
    _admin_cap: &AdminCap,
    ctx: &TxContext
) {
    assert!(amount > 0, EInvalidFixedFee);
    fee_config.fee_type = FIXED_FEE;
    fee_config.fixed_fee_amount = amount;

    event::emit(FeeUpdated {
        fee_type: FIXED_FEE,
        new_value: amount,
        timestamp: ctx.epoch()
    });
}


public fun set_percentage_fee(
    fee_config: &mut FeeConfig,
    fee_bps: u16,
    _admin_cap: &AdminCap,
    ctx: &TxContext
) {
    assert!(fee_bps <= 10000, EInvalidFeePercentage);
    fee_config.fee_type = PERCENTAGE_FEE;
    fee_config.percentage_fee_bps = fee_bps;

    event::emit(FeeUpdated {
        fee_type: PERCENTAGE_FEE,
        new_value: (fee_bps as u64),
        timestamp: ctx.epoch()
    });
}


public fun withdraw_fees(
    fee_config: &mut FeeConfig,
    amount: u64,
    recipient: address,
    _admin_cap: &AdminCap,
    ctx: &mut TxContext
) {
    let withdrawal = coin::take(&mut fee_config.treasury, amount, ctx);
    transfer::public_transfer(withdrawal, recipient);
}


public fun get_fee_type(fee_config: &FeeConfig): u8 {
    fee_config.fee_type
}

public fun get_fixed_fee(fee_config: &FeeConfig): u64 {
    fee_config.fixed_fee_amount
}

public fun get_percentage_fee(fee_config: &FeeConfig): u16 {
    fee_config.percentage_fee_bps
}

public fun get_treasury_balance(fee_config: &FeeConfig): u64 {
    fee_config.treasury.value()
}


