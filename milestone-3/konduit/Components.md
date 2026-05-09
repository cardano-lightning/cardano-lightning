# Konduit L2 Server Components

## Overview

The Konduit L2 Server is a Rust-based HTTP server (using Axum + Actix-web) that acts as a bridge between Cardano L1 and the Bitcoin Lightning Network (BLN). It allows ada holders to pay merchants on the BLN through a channel-based protocol.

## Component Diagram Gaps Identified

The `components.puml` diagram is missing several key components:

1. **BLN Client** - Actual client library for Bitcoin Lightning Network
2. **FX Client** - Foreign Exchange client (Binance, Kraken, CoinGecko)
3. **DB Module** - Database abstraction and sled implementation
4. **Handlers** - HTTP request handlers (info, fx, show, receipt, squash, quote, pay)
5. **Middleware** - Request extension extraction (Keytag)
6. **konduit-data** - Rich domain data models
7. **konduit-tx** - Transaction building with step logic
8. **CardanoConnector trait** and implementations
9. **konduit-client** - Client-side SDK
10. **kernel** - On-chain Plutus validator code (Aiken)
11. **BLN SDK** - Bitcoin Lightning Network SDK wrapper

---

## Core Components

### HTTP Server (Axum + Router)

**Source:** `konduit-server/src/server/` and `konduit-server/src/server/handlers.rs`

The HTTP server handles incoming requests and routes them to appropriate handlers. It uses Actix-web (not pure Axum as stated in diagram).

**Key files:**
- `server.rs:4-12` - Server module structure
- `server/handlers.rs:1-46` - Handler errors and setup

**Dependencies:** Channel Manager, State Manager, Admin, API Types, FX Client

---

### Channel Manager (`konduit-server/src/channel.rs`)

**Source:** `konduit-server/src/channel.rs`

**What it does:** Manages L2 channels between Consumer and Adaptor. Handles:
- Channel lifecycle (creation, state updates)
- Squash/quote/pay operations
- Receipt management and verification
- Fund tracking (retainer, potentially_subable)
- Locked funds management

**For whom:** Internal component used by HTTP handlers (squash, quote, pay)

**Relations:**
- Reads/writes State Manager (konduit-data)
- Uses Transaction Builder (konduit-tx)
- Uses Cardano Adapter via konduit-tx

---

### State Manager (konduit-data)

**Source:** `konduit-data/src/lib.rs` and various modules

**What it does:** Data models and database operations for:
- `L1Channel` - L1 channel state tracking
- `Receipt` - Squash receipts with potentially_subable calculations
- `Squash` / `SquashProposal` - Channel reconciliation state
- `Locked` - Funds locked for BLN payments
- `Used` / `Stage` - Channel stage tracking
- `Quote` / `PayBody` - Operation requests

**For whom:** Channel Manager, Admin, HTTP handlers

**Key files:**
- `l1_channel.rs` - L1 channel model
- `receipt.rs` - Receipt calculations
- `locked.rs` - Locked funds management
- `stage.rs` - Channel stage state machine

**Relations:**
- Database layer (sled via `konduit-server/src/db/`)
- Consumed by Channel Manager

---

### Transaction Builder (konduit-tx)

**Source:** `konduit-tx/src/lib.rs`

**What it does:** Builds Cardano transactions for channel operations:
- `Channel` - On-chain channel representation
- `Step` / `Stepped` - Transaction stepping logic
- `Utxo` management for channel UTxOs
- `Open`, `Adaptor`, `Fuel` - Transaction types

**For whom:** Channel Manager, Admin sync

**Key files:**
- `channel.rs` - Channel transaction logic
- `stepped.rs` - Step-based transaction building
- `utxo.rs` / `utxos.rs` - UTxO handling

---

### Admin & Cron

**Source:** `konduit-server/src/admin.rs`, `konduit-server/src/admin/service.rs`

**What it does:**
- `SyncApi` trait for syncing state with L1
- Background cron jobs via `konduit-server/src/cron.rs`
- Tip synchronization and inspection

**For whom:** Internal background processing

**Key files:**
- `admin/service.rs` - Sync implementation
- `cron.rs:5-19` - Generic cron spawner

---

### API Types

**Note:** The diagram mentions `konduit-api` but this crate doesn't exist in `main/rust/crates/`. API types are currently embedded in:
- `konduit-server/src/models.rs` - `TipBody`, `TipResponse`, `ShowResponse`, `UnlockedCheque`
- `konduit-data` - Domain models exported publicly

---

## Missing Components (Not in Diagram)

### BLN Client (`bln-client`)

**Source:** `bln-client/src/`

**What it does:** Client library for Bitcoin Lightning Network API:
- `QuoteRequest` / `Quote` - Quote operations
- `PayRequest` / `PayResponse` - Payment operations
- `Invoice` - BLN invoice parsing
- `Api` trait - BLN API abstraction

**For whom:** HTTP handlers (quote, pay)

**Used by:** `server/handlers.rs:200-229` (quote), `handlers.rs:295-303` (pay)

**Relations:** Communicates with external BLN

---

### FX Client (`fx-client`)

**Source:** `fx-client/src/`

**What it does:** Foreign exchange rate fetching from:
- Binance
- Kraken
- CoinGecko
- Fixed rates

**For whom:** HTTP handlers for currency conversion (msat to lovelace)

**Key files:**
- `binance.rs`, `kraken.rs`, `coin_gecko.rs`
- `api.rs` - FX state and conversion

**Used by:** `server/handlers.rs:182,196,218,260` - Currency conversions

---

### DB Module (`konduit-server/src/db/`)

**Source:** `konduit-server/src/db/`

**What it does:** Database abstraction layer with sled implementation:
- `db/Api` trait - Database operations interface
- `db/with_sled.rs` - Sled-based implementation
- Stores `Channel` objects indexed by `Keytag`

**For whom:** HTTP handlers, Admin sync

**Key operations:**
- `get_channel` / `get_all`
- `update_squash`
- `append_locked`
- `unlock`

---

### HTTP Handlers

**Source:** `konduit-server/src/server/handlers.rs`

**What it does:** Request handlers (missing from diagram):
- `info` - Server info endpoint
- `fx` - FX rates endpoint
- `show` - All channels state
- `receipt` - Get channel receipt
- `squash` - Process squash from consumer
- `quote` - Request quote for payment
- `pay` - Execute payment via BLN

**For whom:** External API consumers

---

### Middleware

**Source:** `konduit-server/src/server/middleware.rs`

**What it does:** Extracts `Keytag` from request headers/extensions for routing

**For whom:** HTTP server for request context

---

### Cardano Connector Trait & Implementations

**Source:** `cardano-connector/src/connector.rs` (trait), `cardano-connector-direct/src/blockfrost.rs` (implementation)

**What it does:** L1 interaction abstraction:
- `health` - Health check
- `protocol_parameters` - Chain parameters
- `utxos_at` - Query UTxOs at address
- `submit` - Submit transactions

**Implementations:**
- `cardano-connector-direct` - Blockfrost-based (used by konduit-server)
- `cardano-connector-server` - Server-side connector (in `cardano-connector-server/`)
- `cardano-connector-client` - Client-side connector

**For whom:** Transaction Builder, Admin sync

---

### konduit-client

**Source:** `konduit-client/src/`

**What it does:** Client-side SDK for interacting with konduit server

**For whom:** External applications

---

### kernel (Aiken)

**Source:** `kernel/` (Aiken project)

**What it does:** On-chain Plutus validator scripts:
- `validators/` - Plutus validator code
- `lib/` - Aiken library code
- `plutus.json` - Compiled validator

**Note:** This is entirely missing from the component diagram

---

## Relations Diagram (Updated)

```
External Clients
       |
       v
HTTP Server (Actix-web)
       |
       +--> Handlers (info, fx, show, receipt, squash, quote, pay)
       |         |
       |         +--> Channel Manager
       |         |         |
       |         |         +--> konduit-data (State)
       |         |         +--> konduit-tx (Tx Builder)
       |         |         +--> CardanoAdapter (via konduit-tx)
       |         |
       |         +--> Admin Service
       |         |         |
       |         |         +--> konduit-data
       |         |         +--> CardanoAdapter
       |         |
       |         +--> DB Module (sled)
       |         |
       |         +--> FX Client (Binance/Kraken/CoinGecko)
       |         |
       |         +--> BLN Client
       |
       +--> Middleware (Keytag extraction)

CardanoAdapter ..> L1 (reads: tip, indexer, UTxOs)
CardanoAdapter --> L1 (submits txs)
```

---

## Key Files Reference

| Component | Key Files |
|-----------|-----------|
| HTTP Server | `konduit-server/src/server.rs`, `konduit-server/src/server/service.rs` |
| Handlers | `konduit-server/src/server/handlers.rs` |
| Channel Manager | `konduit-server/src/channel.rs` |
| State (konduit-data) | `konduit-data/src/lib.rs`, `l1_channel.rs`, `receipt.rs`, `locked.rs` |
| Transaction Builder | `konduit-tx/src/lib.rs`, `channel.rs`, `stepped.rs` |
| Admin | `konduit-server/src/admin.rs`, `admin/service.rs` |
| DB | `konduit-server/src/db.rs`, `db/with_sled.rs` |
| BLN Client | `bln-client/src/api.rs`, `lnd.rs` |
| FX Client | `fx-client/src/api.rs`, `binance.rs`, `kraken.rs` |
| CardanoConnector | `cardano-connector/src/connector.rs`, `cardano-connector-direct/src/blockfrost.rs` |
| konduit-client | `konduit-client/src/` |
| Kernel | `kernel/lib/`, `kernel/validators/` |

---

## Documentation References

- Architecture: `docs/design/20_architecture.md`
- Cardano Connector: `docs/design/33_cardano_connector.md`
- Glossary: `docs/glossary.md`
- Roles: `docs/design/11_roles.md`
- Scenarios: `docs/design/12_scenarios.md`
- L2 Protocol: `docs/design/31_5_l2_protocol.md`