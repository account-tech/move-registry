module p2p_ramp::orders_tests;

use account_extensions::extensions::{Self, Extensions, AdminCap};
use sui::clock::{Self, Clock};
use p2p_ramp::p2p_ramp::{Self, Registry};
use p2p_ramp::policy::{Self, Policy};
use p2p_ramp::orders::{Self};
use sui::{
    test_utils::destroy,
    test_scenario::{Self as ts, Scenario},
    sui::SUI,
    coin::{Self, Coin},
    balance::{Self},
};

// === Constants ===

const OWNER: address = @0xCAFE;
const BOB: address = @0xB0B;
const ALICE: address = @0xA11CE;
const CAROL: address = @0xCAB01;
const DECIMALS: u64 = 1_000_000_000;

// === Helper functions ===

fun start() : (Scenario, Extensions, Registry, Policy, Clock, policy::AdminCap) {
    let mut scenario = ts::begin(OWNER);
    // publish package
    p2p_ramp::init_for_testing(scenario.ctx());
    extensions::init_for_testing(scenario.ctx());
    policy::init_for_testing(scenario.ctx());
    // retrieve objs
    scenario.next_tx(OWNER);
    let mut policy = scenario.take_shared<Policy>();
    let cap = scenario.take_from_sender<AdminCap>();
    let ramp_cap = scenario.take_from_sender<policy::AdminCap>();
    let registry = scenario.take_shared<Registry>();
    let mut extensions = scenario.take_shared<Extensions>();

    //add core deps
    extensions.add(&cap, b"AccountProtocol".to_string(), @account_protocol, 1);
    extensions.add(&cap, b"P2PRamp".to_string(), @p2p_ramp, 1);

    // set allowed coin types and allowed fiat
    ramp_cap.allow_coin<SUI>(&mut policy);
    ramp_cap.allow_fiat(&mut policy, b"USD".to_string());

    let clock = clock::create_for_testing(scenario.ctx());

    destroy(cap);

    (scenario, extensions, registry, policy, clock, ramp_cap)
}

fun end(scenario: Scenario, extensions: Extensions, registry: Registry, policy: Policy, clock: Clock, cap: policy::AdminCap) {
    destroy(extensions);
    destroy(registry);
    destroy(policy);
    destroy(clock);
    destroy(cap);
    ts::end(scenario);
}


#[test]
fun test_create_buy_order() {
    let (mut scenario, extensions, mut registry, policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account and Buy Order ---
    scenario.next_tx(BOB);

    let mut account = p2p_ramp::new_account(
        &mut registry,
        &extensions,
        scenario.ctx()
    );

    let auth = p2p_ramp::authenticate(
        &account,
        scenario.ctx()
    );

    // BOB posts a buy order
    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        true,
        1_000, // 10.00 USD
        b"USD".to_string(),
        10_000_000_000, // 10 SUI
        200,
        300,
        900_000,
        balance::zero(), // is a buy
        scenario.ctx()
    );

    // --- SECTION: Assertions ---
    let order = orders::get_order<SUI>(&mut account, order_id);
    assert!(order.is_buy());
    assert!(order.min_fill() == 200);
    assert!(order.max_fill() == 300);
    assert!(order.fiat_amount() == 1_000);
    assert!(order.fiat_code() == b"USD".to_string());
    assert!(order.coin_amount() == 10_000_000_000);
    assert!(order.fill_deadline_ms() == 900_000);
    assert!(order.coin_balance() == 0);
    assert!(order.pending_fill() == 0);
   
    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    orders::destroy_order<SUI>(
        auth,
        &mut account,
        order_id,
        scenario.ctx()
    );

    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap)
}

#[test, expected_failure(abort_code = orders::EWrongValue)]
fun test_create_order_buy_with_balance() {
    let (mut scenario, extensions, mut registry, policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account ---
    scenario.next_tx(BOB);

    let mut account = p2p_ramp::new_account(&mut registry, &extensions, scenario.ctx());

    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());

    // --- SECTION: Attempt to Create Buy Order with Balance (Expected to Fail) ---
    orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        true,
        1_000, // 10.00 USD
        b"USD".to_string(),
        10_000_000_000, // 10 SUI
        1_000_000_000,
        10_000_000_000,
        900_000,
        coin.into_balance(), // is a buy, NOT ALLOWED!
        scenario.ctx()
    );

    
    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap)
}

#[test, expected_failure(abort_code = orders::EWrongValue)]
fun test_create_order_sell_with_zero_balance() {
    let (mut scenario, extensions, mut registry, policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account ---
    scenario.next_tx(BOB);

    let mut account = p2p_ramp::new_account(&mut registry, &extensions, scenario.ctx());

    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    // --- SECTION: Attempt to Create Sell Order with Zero Balance (Expected to Fail) ---
    orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        false,
        1_000, // 10.00 USD
        b"USD".to_string(),
        10_000_000_000, // 10 SUI
        1_000_000_000,
        10_000_000_000,
        900_000,
        balance::zero(), // is a sell, NOT ALLOWED!
        scenario.ctx()
    );

    
    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap)
}

// BOB (merchant) buys from ALICE (customer)
#[test]
fun test_buy_order_flow() {
    let (mut scenario, extensions, mut registry, mut policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account and Buy Order ---
    scenario.next_tx(BOB);

    let mut account = p2p_ramp::new_account(&mut registry, &extensions, scenario.ctx());

    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    // BOB posts a buy order
    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        true,
        1_000, // 10.00 USD
        b"USD".to_string(),
        10_000_000_000, // 10 SUI
        1_000_000_000,
        10_000_000_000,
        900_000,
        balance::zero(), // is a buy
        scenario.ctx()
    );

    // --- SECTION: ALICE Fills BOB's Buy Order ---
    scenario.next_tx(ALICE);

    let handshake = p2p_ramp::requested_handshake_outcome(
        vector[BOB],
        vector[ALICE]
    );

    let coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());

    orders::request_fill_buy_order<SUI>(
        handshake,
        &mut account,
        order_id,
        coin,
        &clock,
        scenario.ctx()
    );

    // --- SECTION: Assertions After Fill Request ---
    let order = orders::get_order<SUI>(&mut account, order_id);
    assert!(order.is_buy());
    assert!(order.min_fill() == 1_000_000_000);
    assert!(order.max_fill() == 10_000_000_000);
    assert!(order.fiat_amount() == 1_000);
    assert!(order.fiat_code() == b"USD".to_string());
    assert!(order.coin_amount() == 10_000_000_000);
    assert!(order.fill_deadline_ms() == 900_000);
    assert!(order.coin_balance() == 0);
    assert!(order.pending_fill() == 10 * DECIMALS);

    // --- SECTION: BOB Flags as Paid ---
    scenario.next_tx(BOB);

    p2p_ramp::flag_as_paid(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    // --- SECTION: ALICE Verifies and Settles ---
    scenario.next_tx(ALICE);

    p2p_ramp::flag_as_settled(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    // --- SECTION: Execute Order (by CAROL) ---
    scenario.next_tx(CAROL);

    let executable = p2p_ramp::execute_handshake_intent(
        &mut account,
        ALICE.to_string(),
        &clock
    );

    orders::execute_fill_buy_order<SUI>(
        executable,
        &mut account,
        &mut policy,
        scenario.ctx()
    );

    // --- SECTION: Assertions After Execution ---
    let order = orders::get_order<SUI>(&mut account, order_id);

    assert!(order.coin_balance() == 10 * DECIMALS);
   
    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap)
}

#[test]
fun test_sell_order_flow() {
    let (mut scenario, extensions, mut registry, mut policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account and Sell Order ---
    scenario.next_tx(BOB);

    let mut account = p2p_ramp::new_account(&mut registry, &extensions, scenario.ctx());

    // BOB posts a sell order
    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(5 * DECIMALS, scenario.ctx());

    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        false,
        1_000, // 10 USD
        b"USD".to_string(),
        coin.value(),
        100,
        500,
        900_000,
        coin.into_balance(),
        scenario.ctx()
    );

    // --- SECTION: ALICE Fills the Sell Order ---
    scenario.next_tx(ALICE);

    let handshake = p2p_ramp::requested_handshake_outcome(
        vector[ALICE], // fiat sender
        vector[BOB] // token sender
    );

    orders::request_fill_sell_order<SUI>(
        handshake,
        &mut account,
        order_id,
        500,
        &clock,
        scenario.ctx(),
    );

    // --- SECTION: ALICE Makes Payment Claim ---
    p2p_ramp::flag_as_paid(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx(),
    );

    // --- SECTION: BOB Approves ALICE's Claim ---
    scenario.next_tx(BOB);

    p2p_ramp::flag_as_settled(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx(),
    );

    // --- SECTION: Execute Order (by CAROL) ---
    scenario.next_tx(CAROL);

    let executable = p2p_ramp::execute_handshake_intent(
        &mut account,
        ALICE.to_string(),
        &clock
    );

    orders::execute_fill_sell_order<SUI>(
        executable,
        &mut account,
        &mut policy,
        scenario.ctx()
    );

    // --- SECTION: Assertions After Execution ---
    scenario.next_tx(ALICE);

    let coin = scenario.take_from_address<Coin<SUI>>(ALICE);
    assert!(coin.value() == 2_500_000_000);

    let order = orders::get_order<SUI>(&mut account, order_id);
    assert!(order.coin_balance() == 2_500_000_000);

   
    destroy(account);
    destroy(coin);

    end(scenario, extensions, registry, policy, clock, cap)
}

#[test]
fun test_create_sell_order() {
    let (mut scenario, extensions, mut registry, policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account and Sell Order ---
    scenario.next_tx(BOB);

    let mut account = p2p_ramp::new_account(
        &mut registry,
        &extensions,
        scenario.ctx()
    );

    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    let coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());

    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        false,
        1_000, // 10.00 USD
        b"USD".to_string(),
        coin.value(), // 10 SUI
        1,
        4,
        900_000,
        coin.into_balance(), // is a sell
        scenario.ctx()
    );

    // --- SECTION: Assertions ---
    let order = orders::get_order<SUI>(&mut account, order_id);
    assert!(!order.is_buy());
    assert!(order.min_fill() == 1);
    assert!(order.max_fill() == 4);
    assert!(order.fiat_amount() == 1_000);
    assert!(order.fiat_code() == b"USD".to_string());
    assert!(order.coin_amount() == 10_000_000_000);
    assert!(order.fill_deadline_ms() == 900_000);
    assert!(order.coin_balance() == 10_000_000_000);
    assert!(order.pending_fill() == 0);

   
    let auth_order_destroy = p2p_ramp::authenticate(&account, scenario.ctx());

    orders::destroy_order<SUI>(auth_order_destroy, &mut account, order_id, scenario.ctx());

    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap)
}

#[test, expected_failure(abort_code = orders::EFillOutOfRange)]
fun test_fail_to_overfill_order() {
    let (mut scenario, extensions, mut registry, mut policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account and Sell Order ---
    scenario.next_tx(BOB);

    let mut account = p2p_ramp::new_account(&mut registry, &extensions, scenario.ctx());
    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    // Bob creates a sell order for 10 SUI, with a total fiat value of $10.
    let coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());
    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        false, // is_buy = false
        1_000,  // Total fiat_amount capacity
        b"USD".to_string(),
        coin.value(),
        100,
        800,
        900_000,
        coin.into_balance(),
        scenario.ctx()
    );

    // --- SECTION: ALICE Successfully Fills a Portion of the Order (70%) ---
    scenario.next_tx(ALICE);
    let alice_handshake = p2p_ramp::requested_handshake_outcome(vector[ALICE], vector[BOB]);

    orders::request_fill_sell_order<SUI>(
        alice_handshake,
        &mut account,
        order_id,
        700, // Alice fills for $7
        &clock,
        scenario.ctx(),
    );

    // Complete Alice's fill to move the amount to `completed_fill`
    p2p_ramp::flag_as_paid(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    scenario.next_tx(BOB);
    p2p_ramp::flag_as_settled(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    scenario.next_tx(CAROL); // Anyone can execute
    let alice_executable = p2p_ramp::execute_handshake_intent(
        &mut account,
        ALICE.to_string(),
        &clock
    );
    orders::execute_fill_sell_order<SUI>(
        alice_executable,
        &mut account,
        &mut policy,
        scenario.ctx()
    );

    // At this point, the order has a `completed_fill` of $7.

    // --- SECTION: CAROL Attempts to Overfill the Order (Expected to Fail) ---
    scenario.next_tx(CAROL);
    let carol_handshake = p2p_ramp::requested_handshake_outcome(vector[CAROL], vector[BOB]);

    // Carol tries to fill for $4.
    // The check should be: 400(new) + 0 (pending) + 700 (completed) <= 1000
    // This is 1100 <= 1000, which is FALSE. The transaction must abort.
    orders::request_fill_sell_order<SUI>(
        carol_handshake,
        &mut account,
        order_id,
        400,
        &clock,
        scenario.ctx(),
    );

    // The test expects an abort, so it will not reach the end.
    
    destroy(account);
    end(scenario, extensions, registry, policy, clock, cap);
}

#[test, expected_failure(abort_code = orders::EFillOutOfRange)]
fun test_fail_to_fill_above_max_limit() {
    let (mut scenario, extensions, mut registry, policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account and Sell Order ---
    scenario.next_tx(BOB);

    let mut account = p2p_ramp::new_account(&mut registry, &extensions, scenario.ctx());
    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    // Bob creates a sell order with a max_fill of 500.
    let coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());
    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        false, // is_buy = false
        1000, // $10
        b"USD".to_string(),
        coin.value(),
        100,  // $1
        500,  // $5
        900_000,
        coin.into_balance(),
        scenario.ctx()
    );

    // --- SECTION: ALICE Attempts to Fill Above Max Limit (Expected to Fail) ---
    scenario.next_tx(ALICE);
    let handshake = p2p_ramp::requested_handshake_outcome(vector[ALICE], vector[BOB]);

    // Alice tries to fill for 501, which is more than the max_fill of 500.
    // This call must abort.
    orders::request_fill_sell_order<SUI>(
        handshake,
        &mut account,
        order_id,
        501,
        &clock,
        scenario.ctx(),
    );

    
    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap);
}

#[test]
fun test_dispute_buy_order_taker_wins() {
    let (mut scenario, extensions, mut registry, mut policy, clock, cap) = start();

    // --- SECTION: Order Creation ---
    // BOB creates merchant account and places a buy order
    scenario.next_tx(BOB);
    let mut account = p2p_ramp::new_account(
        &mut registry,
        &extensions,
        scenario.ctx()
    );
    let auth = p2p_ramp::authenticate(
        &account,
        scenario.ctx()
    );
    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        true,
        1000,
        b"USD".to_string(),
        10 * DECIMALS,
        1 * DECIMALS,
        10 * DECIMALS,
        900_000,
        balance::zero(),
        scenario.ctx()
    );

    // --- SECTION: Order Filling ---
    // ALICE fills the order with 5 SUI
    scenario.next_tx(ALICE);
    let alice_coin = coin::mint_for_testing<SUI>(5 * DECIMALS, scenario.ctx());
    let alice_coin_value = alice_coin.value();
    let handshake = p2p_ramp::requested_handshake_outcome(
        vector[BOB],
        vector[ALICE]
    );
    orders::request_fill_buy_order<SUI>(
        handshake,
        &mut account,
        order_id,
        alice_coin,
        &clock,
        scenario.ctx()
    );

    // --- SECTION: Payment and Dispute Initiation ---
    // BOB flags as paid
    scenario.next_tx(BOB);
    p2p_ramp::flag_as_paid(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    // ALICE disputes
    scenario.next_tx(ALICE);
    p2p_ramp::flag_as_disputed(
        &mut account,
        ALICE.to_string(),
        scenario.ctx()
    );

    // --- SECTION: Dispute Resolution and Assertions ---
    // OWNER resolves in ALICE's favor
    scenario.next_tx(OWNER);
    let executable = p2p_ramp::resolve_handshake_intent(
        &cap,
        &mut account,
        ALICE.to_string(),
        &clock
    );
    orders::resolve_dispute_buy_order<SUI>(
        &cap,
        executable,
        &mut account,
        &mut policy,
        ALICE,
        scenario.ctx()
    );

    // ALICE should get her coin back
    scenario.next_tx(ALICE);
    let coin = scenario.take_from_address<Coin<SUI>>(ALICE);
    assert!(coin.value() == alice_coin_value);

    // Order should be reset
    let order = orders::get_order<SUI>(
        &mut account,
        order_id
    );
    assert!(order.pending_fill() == 0);
    assert!(order.completed_fill() == 0);
    assert!(order.coin_balance() == 0);

    destroy(account);
    destroy(coin);

    end(scenario, extensions, registry, policy, clock, cap);
}

#[test]
fun test_dispute_sell_order_merchant_wins() {
    let (mut scenario, extensions, mut registry, mut policy, clock, cap) = start();

    // --- SECTION: BOB Creates Merchant Account and Sell Order ---
    scenario.next_tx(BOB);
    let mut account = p2p_ramp::new_account(
        &mut registry,
        &extensions,
        scenario.ctx()
    );
    let auth = p2p_ramp::authenticate(
        &account,
        scenario.ctx()
    );

    let bob_initial_coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());
    let bob_initial_balance = bob_initial_coin.value();

    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        false,
        1000,
        b"USD".to_string(),
        bob_initial_balance,
        100,
        500,
        900_000,
        bob_initial_coin.into_balance(),
        scenario.ctx()
    );

    // --- SECTION: ALICE Requests Fill, Claims Payment, BOB Disputes ---
    scenario.next_tx(ALICE);

    let handshake = p2p_ramp::requested_handshake_outcome(vector[ALICE], vector[BOB]);

    orders::request_fill_sell_order<SUI>(
        handshake,
        &mut account,
        order_id,
        500,
        &clock,
        scenario.ctx()
    );

    // Alice claims she paid
    p2p_ramp::flag_as_paid(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    // Bob never received fiat, so he disputes
    scenario.next_tx(BOB);
    p2p_ramp::flag_as_disputed(
        &mut account,
        ALICE.to_string(),
        scenario.ctx()
    );

    // --- SECTION: ADMIN Resolves Dispute in BOB's Favor ---
    scenario.next_tx(OWNER);
    let executable = p2p_ramp::resolve_handshake_intent(
        &cap,
        &mut account,
        ALICE.to_string(),
        &clock
    );
    let bob_addr = account.addr();
    orders::resolve_dispute_sell_order<SUI>(
        &cap,
        executable,
        &mut account,
        &mut policy,
        bob_addr,
        scenario.ctx()
    );

    // --- SECTION: Assertions ---
    // Check that the order's coin balance has returned to its original state
    let order = orders::get_order<SUI>(
        &mut account,
        order_id
    );
    assert!(order.coin_balance() == bob_initial_balance);
    assert!(order.pending_fill() == 0);
    assert!(order.completed_fill() == 0);

    destroy(account);
    end(scenario, extensions, registry, policy, clock, cap);
}

#[test]
fun test_merchant_cancels_buy_order_fill() {
    
    let (mut scenario, extensions, mut registry, policy, clock, cap) = start();

    // --- SECTION: BOB (Merchant) Creates a Buy Order ---
    scenario.next_tx(BOB);
    let mut account = p2p_ramp::new_account(
        &mut registry,
        &extensions,
        scenario.ctx()
    );
    let auth = p2p_ramp::authenticate(
        &account,
        scenario.ctx()
    );

    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        true,
        1000,
        b"USD".to_string(),
        10 * DECIMALS,
        1 * DECIMALS,
        10 * DECIMALS,
        900_000,
        balance::zero(),
        scenario.ctx()
    );

    // --- SECTION: ALICE (Taker) Requests a Fill (Locks Her Coins) ---
    scenario.next_tx(ALICE);
    let alice_coin = coin::mint_for_testing<SUI>(5 * DECIMALS, scenario.ctx());
    let alice_coin_value = alice_coin.value();

    let handshake = p2p_ramp::requested_handshake_outcome(vector[BOB], vector[ALICE]);

    orders::request_fill_buy_order<SUI>(
        handshake,
        &mut account,
        order_id,
        alice_coin,
        &clock,
        scenario.ctx()
    );

    // --- SECTION: BOB (Merchant) Cancels the Fill Before Paying ---
    scenario.next_tx(BOB);
    let executable = p2p_ramp::execute_merchant_cancellation_intent(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    // The merchant provides a reason for the cancellation.
    let reason = b"Could not complete transaction".to_string();
    orders::merchant_cancel_fill<SUI>(
        p2p_ramp::authenticate(&account, scenario.ctx()),
        &mut account,
        reason,
        executable,
        scenario.ctx()
    );

    // --- SECTION: Assertions ---
    // Check that Alice received her coins back.
    scenario.next_tx(ALICE);
    let alice_final_coin = scenario.take_from_address<Coin<SUI>>(ALICE);
    assert!(alice_final_coin.value() == alice_coin_value);
    destroy(alice_final_coin);

    // Check that the order's state is correct (no pending fill).
    let order = orders::get_order<SUI>(&mut account, order_id);
    assert!(order.pending_fill() == 0);

    destroy(account);
    end(scenario, extensions, registry, policy, clock, cap);
}

#[test]
fun test_fill_request_expires() {
    let (mut scenario, extensions, mut registry, policy, mut clock, cap) = start();

    // --- SECTION: BOB (Merchant) Creates a Buy Order with Deadline ---
    scenario.next_tx(BOB);
    let mut account = p2p_ramp::new_account(&mut registry, &extensions, scenario.ctx());
    let auth = p2p_ramp::authenticate(&account, scenario.ctx());
    let fill_deadline_ms = 900_000;

    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        true,
        1000,
        b"USD".to_string(),
        10 * DECIMALS,
        1 * DECIMALS,
        10 * DECIMALS,
        fill_deadline_ms,
        balance::zero(),
        scenario.ctx()
    );

    // --- SECTION: ALICE (Taker) Requests a Fill (Locks Her Coins) ---
    scenario.next_tx(ALICE);
    let alice_coin = coin::mint_for_testing<SUI>(5 * DECIMALS, scenario.ctx());
    let alice_coin_value = alice_coin.value();

    let handshake = p2p_ramp::requested_handshake_outcome(vector[BOB], vector[ALICE]);

    orders::request_fill_buy_order<SUI>(
        handshake,
        &mut account,
        order_id,
        alice_coin,
        &clock,
        scenario.ctx()
    );

    // --- SECTION: Advance Time and Resolve Expired Fill ---
    // Advance the clock by the deadline duration + 1ms to ensure it's expired.
    clock.increment_for_testing(1_000_000);

    // Anyone (CAROL) can now resolve the expired fill.
    scenario.next_tx(CAROL);
    let executable = p2p_ramp::resolve_handshake_intent_expired_fill(
        &mut account,
        ALICE.to_string(),
        &clock
    );

    orders::resolve_expired_buy_order_fill<SUI>(
        executable,
        &mut account,
        scenario.ctx()
    );

    // --- SECTION: Assertions ---
    // Check that Alice received her coins back.
    scenario.next_tx(ALICE);
    let alice_final_coin = scenario.take_from_address<Coin<SUI>>(ALICE);
    assert!(alice_final_coin.value() == alice_coin_value);
    destroy(alice_final_coin);

    // Check that the order's state is correct (no pending fill).
    let order = orders::get_order<SUI>(
        &mut account,
        order_id
    );
    assert!(order.pending_fill() == 0);

    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap);
}

#[test]
fun test_destroy_partially_filled_order() {
    let (mut scenario, extensions, mut registry, mut policy, clock, cap) = start();

    // --- SECTION: BOB (Merchant) Creates a Sell Order ---
    scenario.next_tx(BOB);
    let mut account = p2p_ramp::new_account(
        &mut registry,
        &extensions,
        scenario.ctx()
    );

    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    // Bob starts with this coin, which he will put in the order.
    let bob_initial_coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());

    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        false, // is_buy = false
        1000,
        b"USD".to_string(),
        bob_initial_coin.value(), // 10 SUI
        100,
        800,
        900_000,
        bob_initial_coin.into_balance(),
        scenario.ctx()
    );

    // --- SECTION: ALICE Successfully Completes a Partial Fill ---
    // Price: 1000 fiat for 10 SUI => 100 fiat per SUI.
    // To buy 4 SUI, Alice pays $4 fiat.
    let fill_amount_fiat = 400;
    let expected_remaining_balance_sui = 6 * DECIMALS; // 10 SUI - 4 SUI = 6 SUI

    scenario.next_tx(ALICE);

    let alice_handshake = p2p_ramp::requested_handshake_outcome(
        vector[ALICE],
        vector[BOB]
    );

    orders::request_fill_sell_order<SUI>(
        alice_handshake,
        &mut account,
        order_id,
        fill_amount_fiat,
        &clock,
        scenario.ctx(),
    );

    // Complete the fill process
    p2p_ramp::flag_as_paid(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    scenario.next_tx(BOB);

    p2p_ramp::flag_as_settled(
        &mut account,
        ALICE.to_string(),
        &clock,
        scenario.ctx()
    );

    scenario.next_tx(CAROL);

    let alice_executable = p2p_ramp::execute_handshake_intent(
        &mut account,
        ALICE.to_string(),
        &clock
    );

    orders::execute_fill_sell_order<SUI>(
        alice_executable,
        &mut account,
        &mut policy,
        scenario.ctx()
    );


    // --- SECTION: BOB Destroys the Partially Filled Order ---
    scenario.next_tx(BOB);

    let auth = p2p_ramp::authenticate(
        &account,
        scenario.ctx()
    );

    // This call transfers the remaining 6 SUI from the order back to BOB.
    orders::destroy_order<SUI>(
        auth,
        &mut account,
        order_id,
        scenario.ctx()
    );


    // --- SECTION: Assertions ---
    scenario.next_tx(OWNER); // Use any address to start a new block.

    // Now, take the coin from BOB's address. The transfer from the previous block is now finalized.
    let bob_final_coin = scenario.take_from_address<Coin<SUI>>(BOB);
    assert!(bob_final_coin.value() == expected_remaining_balance_sui);

    destroy(bob_final_coin);
    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap);
}

#[test, expected_failure(abort_code = orders::ECannotDestroyOrder)]
fun test_fail_to_destroy_order_with_pending_fill() {
    
    let (mut scenario, extensions, mut registry, policy, clock, cap) = start();

    // --- SECTION: BOB (Merchant) Creates a Sell Order ---
    scenario.next_tx(BOB);
    let mut account = p2p_ramp::new_account(
        &mut registry,
        &extensions,
        scenario.ctx()
    );

    let auth = p2p_ramp::authenticate(&account, scenario.ctx());

    let bob_initial_coin = coin::mint_for_testing<SUI>(10 * DECIMALS, scenario.ctx());

    let order_id = orders::create_order<SUI>(
        auth,
        &policy,
        &mut account,
        false, // is_buy = false
        1000,
        b"USD".to_string(),
        bob_initial_coin.value(),
        100,
        800,
        900_000,
        bob_initial_coin.into_balance(),
        scenario.ctx()
    );

    // --- SECTION: ALICE Requests a Fill (Creates Pending Fill) ---
    scenario.next_tx(ALICE);

    let alice_handshake = p2p_ramp::requested_handshake_outcome(
        vector[ALICE],
        vector[BOB]
    );

    orders::request_fill_sell_order<SUI>(
        alice_handshake,
        &mut account,
        order_id,
        500,
        &clock,
        scenario.ctx(),
    );

    // The fill is now pending. The order cannot be destroyed.

    // --- SECTION: BOB Attempts to Destroy Order with Pending Fill (Expected to Fail) ---
    scenario.next_tx(BOB);

    let destroy_auth = p2p_ramp::authenticate(
        &account,
        scenario.ctx()
    );

    orders::destroy_order<SUI>(
        destroy_auth,
        &mut account,
        order_id,
        scenario.ctx()
    );

    
    destroy(account);

    end(scenario, extensions, registry, policy, clock, cap);
}