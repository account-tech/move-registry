
# P2P Ramp Protocol

## Overview

P2P Ramp is a decentralized peer-to-peer protocol built on Sui for exchanging on-chain assets (coins) for off-chain assets (fiat currency). It operates without a centralized intermediary, instead relying on a robust on-chain state machine, a verifiable reputation system, and clear economic incentives to ensure fair and secure trades.

The protocol is architected around the `account.tech`, where each merchant controls a powerful, data-rich `Account<P2PRamp>` smart contract object.

---

## Core Design Principles

The protocol was designed with the following principles in mind:
- **Security:** State transitions are rigidly controlled, and assets are only moved when explicit conditions are met. The contract authoritatively sets critical parameters like deadlines to prevent user manipulation.
- **Economic Fairness:** The system is designed to align incentives and place costs (gas fees) on the party responsible for an action or failure.
- **Decentralization:** The logic minimizes trust assumptions and provides clear, on-chain recourse for all parties, including dispute resolution and various cancellation pathways.
- **Observability:** Comprehensive event emission for every significant state change enables robust off-chain indexing and responsive frontends.

## The Fill Lifecycle: A State Machine

Every fill request is an independent state machine tracked by a `Handshake` object. The diagram below illustrates the possible paths for each trade.

![P2P Ramp State Machine](../../assets/p2p-ramp-state-diagram.png)

The primary states are:
1.  **`Requested`**: A taker has initiated a fill, and the trade is awaiting action from the fiat payer.
2.  **`Paid`**: The fiat payer has attested on-chain that they have sent the off-chain payment. At this point, no cancellations are possible.
3.  **`Settled`**: The fiat receiver has attested on-chain that the payment has arrived. The trade is now ready for on-chain crypto execution.
4.  **`Disputed`**: One of the parties has paused the trade, requiring admin intervention.
5.  **`Finalized/Cancelled`**: Terminal states representing the conclusion of the trade.

## 🔧 Architectural Components

### 1. Key Modules
-   **`p2p_ramp`**: The core module that defines the `Account<P2PRamp>` configuration, the `Handshake` state machine, and the `Reputation` system. It manages the lifecycle of a trade.
-   **`orders`**: Manages the creation, escrow, and cancellation logic for `Order` objects. It is the entry point for all trading activity.
-   **`policy`**: A standalone module controlled by an `AdminCap` that manages platform fee policies, whitelisted assets, and global platform settings.
-   **`config`**: Manages `Account<P2PRamp>` configuration
### 2. Core Objects
-   **`Account<P2PRamp>`**: The main shared object for each merchant. It acts as a container for their configuration, `managed_data` (Orders, Reputation), and the intent-based execution system.
-   **`Order<CoinType>`**: A dynamically attached object representing a merchant's offer to buy or sell a specific asset.
-   **`Handshake`**: The outcome object for a fill intent, containing the `Status` and all necessary data to track a single trade's lifecycle.
-   **`Reputation`**: A dynamically attached object tracking a merchant's on-chain performance metrics.

## Key Features

### 1. 🧑‍💼 On-Chain Reputation System
Each `Account` has a `Reputation` object that tracks verifiable metrics, updated after every finalized trade or dispute. This includes:
-   `successful_trades: u64`
-   `failed_trades: u64` (from expired buy orders or lost disputes)
-   `get_completion_rate(): u8` (calculated from successful/failed trades)
-   `total_coin_volume` & `total_fiat_volume` (stored in `VecMap`s for extensibility)
-   `avg_release_time_ms` (calculated from the time between `Paid` and `Settled` states)

### 2. 🛡️ Economic Security & Fairness
-   **Authoritative Deadlines:** `request_fill_*_order` functions calculate the absolute payment deadline on-chain and **overwrite** any value provided by the user, preventing manipulation.
-   **Adjustable Minimum Deadline:** An `AdminCap` holder can configure the minimum `fill_deadline_ms` (e.g., 15 minutes) that merchants are allowed to set, protecting takers from unfair terms.

### 3. 🔄 Comprehensive Cancellation Logic
The protocol provides multiple, specific pathways for cancelling a fill **before it is marked as `Paid`**:
-   **Expired Cancellation:** After the deadline passes, the system cancels the fill. This counts against their completion rate if it was a buy order.
-   **Voluntary Taker Cancellation:** On a **sell order**, the taker can cancel to back out of the trade.
-   **Voluntary Maker Cancellation:** On a **buy order**, the merchant can cancel, which automatically returns the locked coins to the taker.

### 4. ⚖️ Trust-Minimized Dispute Resolution
-   Either party can flag a trade as `Disputed` before it is settled.
-   An `AdminCap` holder resolves the dispute by calling `resolve_dispute_*_order` and specifying the `recipient` of the escrowed assets.
-   The resolution automatically updates the merchant's `disputes_won` or `disputes_lost` reputation stats.

### 5. 📜 Rich Event Emission for Indexing
The contract emits detailed events for every significant state change, designed for consumption by off-chain indexers and frontends. Key events include:
-   `CreateOrderEvent`
-   `FillRequestEvent`
-   `FillPaidEvent`
-   `FillSettledEvent`
-   `FillCompletedEvent`
-   `FillCancelledEvent` (includes a `reason` enum)
-   `DisputeResolvedEvent`