# Cardano Lightning : L2 Peer Protocol Spec

This document covers the base protocol messages (like `init` and `ping-poing`)
and peer channel protocol which is responsible for opening, closing, and
maintaining a channel between two peers. In other words we loosely follow and
cover the scope of the BLN
[bolt#0](https://github.com/Lighting/bolts/blob/master/00-introduction.md)
[bolt#1](https://github.com/Lighting/bolts/blob/master/01-messaging.md) and
[bolt#2](https://github.com/lightning/bolts/blob/master/02-peer-protocol.md) in
this document. Please note that we miss
[bolt#3](https://github.com/Lighting/bolts/blob/master/03-introduction.md)
because off-chain consensus establishment through multi-sig transaction is an
optional feature supported by the L1 protocol but is not part of the current
release.

We start with the basic messages and then move to the channel management related
communication which can be divided into three phases: establishment, normal
operation, and closing.

## Connection and the Message Serialization

Each peer connection MUST use a single, shared link for all channel messages,
with messages distinguished by their channel IDs.

We assume that the secure communication channel is already established between
two peers and that authentication of the partners nodes is done already. The
authentication and the transport layer security is out of the scope of this
document.

We decided to use [Protocol Buffers](https://protobuf.dev/) for the message
serialization so we use protobuf format to describe the messages. Some parts of
the protocol rely on CBOR encoded structures (`cheque`, `snapshot` etc.) which
are not directly exchanged but are rather reconstructed by both partners so only
the signatures are exchanged. These payloads will be specified through separate
CDDLs.

## Messages

### Setup and Control

#### `init`

Once a connection is established, both peers MUST send an `Init` message before
any other messages. This is the first message revealing the features supported
by the sending node.

```haskell
type Version = Integer

data Init = Init
    { version :: Version
    , routing :: Bool
    , htlc :: Bool
    }
```

A node:

- MUST send `Init` as the first Lightning message for any connection.
- MUST wait to receive `Init` before sending any other messages.
- SHOULD reject unknown protocol versions by closing the connection.

#### The `Error` and `Warning` Messages

For diagnosis and error handling, a node can tell its peer that something has
gone wrong.

```haskell
data Error = Error
  { channelId :: Maybe ChannelId -- When channel id is missing (empty bytestring) the error is related to the whole connection
  , message :: Text
  }

data Warning = Warning
  { channelId :: ChannelId
  , message :: Text
  }
```

A sending node:

- SHOULD send `Error` for protocol violations or internal errors that make
  channels unusable
- SHOULD send `Error` with unknown channelId in reply to messages related to
  unknown channels
- when sending Error: MUST fail the channel(s) referred to by the error message
- when sending warning: MAY continue channel operation

A receiving node:

- upon receiving error:
  - if channelId is emtpy bytestring: MUST fail all channels with the sending
    node
  - otherwise: MUST fail the channel referred to by channelId
- upon receiving `Warning`:
  - MAY continue channel operation

> ##### Future Error Handling Design Note
>
> In future protocol versions, error handling will be formalized in one of two
> possible approaches:
>
> Global error enumeration:
>
> - A single enumeration covering all possible protocol errors
> - Each error would have a specific code and standardized meaning
> - Similar to HTTP status codes but specific to CL protocol
>
> ```haskell
> data ProtocolError
>    = InvalidVersion
>    | UnknownChannel
>    | InvalidSignature
>    | InvalidState
>    -- etc.
> ```
>
> Context-specific errors:
>
> - Each message type/operation would have its own error enumeration
> - Errors are tightly coupled to the context where they can occur
> - Provides more precise error handling and type safety
>
> ```haskell
> data OpenError
>     = UnsupportedParameters
>     | InvalidRange
>     ...
> data AcceptError
>     = InsufficientGift
>     ...
> ```

### The `ping` and `pong` Messages

To allow for long-lived TCP connections and to detect unresponsive peers, nodes
can send ping messages.

```haskell
data Ping = Ping
  { ignored :: ByteString -- should be zeroes
  }

data Pong = Pong
  { byteslen :: Word16
  , ignored :: bytestring -- should be zeroes
  }
```

A node:

- SHOULD set ignored to zeros
- MUST NOT set ignored to sensitive data
- if it doesn't receive a corresponding pong:
  - MAY close the network connection
  - MUST NOT fail the channels in this case

A node receiving ping:

- if `numPongBytes` is less than 65532: MUST respond with a pong with bytesLen
  equal to numPongBytes otherwise: MUST ignore the ping

## Core Types

These are core types used in different places of the protocol:

```haskell
type Index = Integer

-- Should we introduce "feature flags" similar to BLN:
data Version = Version1

-- 28 bytes of blake2b hash
data ScriptHash = ByteString

-- policy hash and token name
type Currency = (ScriptHash, ByteString)

-- 32 bytes of some hash plus extra payload
data ChannelId = ByteString

type Amount = Integer

type TestnetMagic = Integer

data NetworkId = Mainnet | Testnet TestnetMagic

type Milliseconds = Integer

type POSIX = Integer

type TxOutRef = (ByteString, Integer)

-- 32 bytes of sha256 hash
type Sha256Hash = ByteString

type Ed25519PubKey = ByteString

-- 64 bytes of Ed25519 signature
type Signature = ByteString

data Snapshot = Snapshot
  { amount0 :: Amount
  , amount1 :: Amount
  , idx0 :: Index
  , idx1 :: Index
  , exc0 :: [Integer]
  , exc1 :: [Integer]
  }
```

## Channel Establishment

Channel establishment consists of several steps:

1. Initial negotiation of channel parameters: `Open` -> `Accept` || `Error`.
2. On-chain channel notification and verification `ChannelStaged`.
3. Or early canc

### Messages

```haskell
-- Helper type for parameter negotiation
data Range a
  = Range
    { minValue :: a
    , maxValue :: a
    }

data ChannelEstablishment
  | Open
    { networkId :: NetworkId
    , channelId :: ChannelId
    , currency :: Currency
    , fundingAmount :: Range Amount  -- Min/max range for negotiation
    , giftAmount :: Amount          -- Initial amount gifted to counterparty
    , respondPeriod :: Range Milliseconds
    , minimumDepth :: Range Integer
    , minHtlcValue :: Range Amount
    , maxHtlcValue :: Range Amount
    , maxTotalHtlcValue :: Range Amount
    , maxHtlcCount :: Range Integer
    , pubKey :: Ed25519PubKey
    }
  | Accept
    { channelId :: ChannelId
    , fundingAmount :: Amount       -- Chosen from proposed range
    , respondPeriod :: Milliseconds
    , minimumDepth :: Integer
    , minHtlcValue :: Amount
    , maxHtlcValue :: Amount
    , maxTotalHtlcValue :: Amount
    , maxHtlcCount :: Integer
    , pubKey :: Ed25519PubKey
    }
  | ChannelStaged
    { channelId :: ChannelId
    , txOutRef :: TxOutRef        -- Reference to the on-chain channel UTXO
    }
```

### Channel Opening Process

The channel opener sends an `Open` message containing:

- Proposed ranges for all negotiable parameters
- Their public key for channel operation
- Initial funding and gift amounts
- Network and currency identification

The counterparty can:

- Respond with `Accept` choosing specific values from each proposed range
- Respond with `Error` if any parameters are unacceptable

After successful negotiation, the opener:

- Submits the transaction creating the channel utxo
- Sends `ChannelStaged` with the utxo reference or: Sends an `Error` with
  `channelId` and reason

The counterparty:

- Verifies the on-chain utxo matches negotiated parameters
- after confirmation: responds with `ChannelStaged` and starts channel operation
  or: responds with `Error` if verification fails

#### Requirements

A node sending `Open`:

- MUST set all ranges to contain acceptable values
- MUST ensure minimum values are less than or equal to maximum values
- MUST set networkId to match the intended blockchain network
- SHOULD set reasonable ranges to increase chance of acceptance

A node receiving `Open`:

- MUST respond with either `Accept` or `Error`
- if responding with `Accept`:
  - MUST choose values within each proposed range
  - MUST verify it can operate with chosen parameters
  - MUST NOT accept if any parameters are unacceptable
- SHOULD respond with `Error` if ranges are unreasonable

A node sending `Accept`:

- MUST set all parameters to values within proposed ranges

A node receiving `Accept`:

- MUST verify all chosen values are within proposed ranges
- SHOULD proceed with channel creation if all parameters are acceptable

A node sending `ChannelStaged`:

- MUST have created the on-chain UTXO
- MUST ensure utxo matches all negotiated parameters especially `minimumDepth`

A node receiving `ChannelStaged`:

- MUST verify the referenced utxo exists on-chain
- MUST verify utxo parameters match negotiated values
- MUST NOT begin channel operation until verification succeeds

##### Terms Discovery

To simplify the opening process we introduce terms discovery. Accepted parameter
ranges can change over time so should be rediscovered after opening failure. We
propose this mechanism to simplify the error reporting and handling on the user
facing client applications.

```haskell
data TermsDiscovery
  = QueryTerms
    { channelId :: ChannelId
    , networkId :: NetworkId
    , currency :: Currency
    }
  | Terms
    { channelId :: ChannelId
    , networkId :: NetworkId
    , currency :: Currency
    , maxHtlcCount :: Range Integer
    , maxHtlcValue :: Range Amount
    , maxTotalHtlcValue :: Range Amount
    , minGiftAmount :: Amount           -- Minimum "service fee" required
    , minGiftPercent :: Integer         -- Used above the `minGiftAmount`
    , peerFunding :: Range Amount       -- Minimum funding required from peer
    , respondPeriod :: Range Milliseconds
    }

    { networkId :: NetworkId
    , currency :: Currency
    , fundingAmount :: Range Amount
    , requiredGift :: Amount
    , minimumDepth :: Range Integer
    , giftAmount :: Amount
    }
```

Provided ranges can have internal dependencies - for example `responsePeriod`
can depend on the funds locked in a channel. So they can provide overview of
absolute values. More involved policies can use `termsAndConditions` field to
explain the details for human resolution. Policies can be adjusted according to
the history of cooperation of two parners so they should not be treated as fixed
or shared across different users sessions.

### `ChannelAdd`

￼

```haskell
type Index = Integer

-- Should we introduce "feature flags" similar to BLN:
data Version = Version1

-- (28 bytes of blake2b hash, 32 bytes of token name)
type Currency = (ByteString, ByteString)

-- 32 bytes of some hash plus extra payload
data ChannelId = ByteString

type Amount = Integer

type TestnetMagic = Integer

data NetworkId = Mainnet | Testnet TestnetMagic

type Milliseconds = Integer

type POSIX = Integer

type TxOutRef = (ByteString, Integer)

-- 32 bytes of sha256 hash
type Sha256Hash = ByteString

type Ed25519PubKey = ByteString

-- 64 bytes of Ed25519 signature
type Signature = ByteString

data Snapshot = Snapshot
    { amount0 :: Amount
    , amount1 :: Amount
    , idx0 :: Index
    , idx1 :: Index
    , exc0 :: [Integer]
    , exc1 :: [Integer]
    }

-- TODO:
-- Should we notify separately about tx settlement attempt and about
-- the step finalization like `FundsAdd` and `FundsAdded/FundsAddConfirmed`?
-- In BLN splicing proposal there is no separate message but it is probablyand
-- assumed from the context (the transcation creation precedes the tx settlement).
-- * If we won't notify the partner about tx settlement attempt then we can have collisions
-- but maybe that is not a problem - we have to monitor the chain anyway and discover changes.
-- * If we notify separately about the attempt and provide the details then we have to introduce
-- probably some kind of abort action if it was colliding etc.

-- Tx verification through Mithril:
-- * We have to be prepared that in order to use Mithril efficiently (using its current API) we will
-- use `/proof/cardano-transaction`'
-- * In order to use that endpoint we have to actually construct transaction client side
-- * In order to construct transaction on the client side we should:
--      * Receive or reconstruct the transaction CBOR
--      * Check the UTxO of that transaction
-- * Mithril will have probably in the future queries like "utxo-by-addresses" - it seems that they are not
-- part of the aggregator HTTP API yet. It seem rather useless in our case anyway.
type Tx = ByteString

-- During any negociation we use ranges to speed up the process
data Message
    = Init Version
    | Ping
    | Pong
    | Open
        { netorkId :: NetworkId
        , channelId :: ChannelId
        , currencySymbol :: CurrencySymbol
        , fundingAmount :: [Amount, Amount]
        , giftAmount :: Amount
        , respondPeriod :: [Milliseconds, Milliseconds]
        , minimumDepth :: [Integer, Integer]
        , minHtlcValue :: [Amount, Amount]
        , maxHtlcValue :: [Amount, Amount]
        , maxTotalHtlcValue :: [Amount, Amount]
        , maxHtlcCount :: [Integer, Integer]
        , pubKey :: Ed25519PubKey
        }
    | Accept
        { channelId :: ChannelId
        , fundingAmount :: Amount
        , respondPeriod :: Milliseconds
        , minimumDepth :: Integer
        , minHtlcValue :: Amount
        , maxHtlcValue :: Amount
        , maxTotalHtlcValue :: Amount
        , maxHtlcCount :: Integer
        , pubKey :: Ed25519PubKey
        }
    | ChannelStaged
        { channelId :: ChannelId
        , txOutRef :: TxOutRef
        -- Mithril support? Should it be added across
        -- , tx :: Tx
        }
    | FundsAdded
        { channelId :: ChannelId
        , blockNumber :: Integer
        -- ^ Worth including as we can clearly detect
        -- rollback on the other side?
        , txOutRef :: TxOutRef
        , amount :: Amount
        }
    | AddHtlc
        { channelId :: ChannelId
        , htlcIdx :: Integer
        , amount :: Amount
        , timeout :: POSIXMilliseconds
        , lock :: Sha256Hash
        }
    | FulfillHtlc
        { channelId :: ChannelId
        , htlcIdx :: Integer
        , secret :: ByteString
        , signature :: Signature
        }
    -- BLN uses "fail" - `update_fail_htlc` with "reason"
    | HtlcTimeout
        { channelId :: ChannelId
        , htlcIdx :: Integer
        }
    -- Let's chat about it - it is described in the basic
    -- set of the responses.
    -- | HtlcCancel
    --     { channelId :: ChannelId
    --     , htlcIdx :: Integer
    --     }
    | AddCheque
        { channelId :: ChannelId
        , chequeIdx :: Index
        , amount :: Amount
        , signature :: Signature
        }
    -- Should we exchange those (so pass the same `Shapshot` back) or
    -- should we introduce separate response which
    -- have compressed version of the snapshot like `(amount0, amount1)`?
    | SignedSnapshot
        { channelId :: ChannelId
        , snapshot :: Snapshot
        , signature :: Ed25519Signature
        }
    -- Should we include a full redeemer info or tx or none?
    | ChannelClosed
        { channelId :: ChannelId
        , txOutRef :: TxOutRef
        }
    | ChannelResponded
        { channelId :: ChannelId
        , txOutRef :: TxOutRef
        }
    | ChannelElapsed
        { channelId :: ChannelId
        , txOutRef :: TxOutRef
        }
    | ChannelRecovered
        { channelId :: ChannelId
        , txOutRef :: TxOutRef
        }
    | LocksFreed
        { channelId :: ChannelId
        , secrets :: [(Index, Maybe ByteString)]
        , txOutRef :: TxOutRef
        }
    | ChannelUnstaged
        { channelId :: ChannelId
        }
```

## Channel Establishment

### `ChannelAdd

## Channel Operation

## Channel Closure

### Protobuf Spec

```protobuf
syntax = "proto3";

package cardano_lightning;

// Version enumeration
enum Version {
  VERSION1 = 0;
}

// NetworkId message
message NetworkId {
  oneof network {
    Mainnet mainnet = 1;
    Testnet testnet = 2;
  }
}

message Mainnet {
  // No fields needed for Mainnet
}

message Testnet {
  int64 testnetMagic = 1;
}

// TxOutRef message
message TxOutRef {
  bytes txHash = 1;
  int64 index = 2;
}

// Snapshot message
message Snapshot {
  int64 amount0 = 1;
  int64 amount1 = 2;
  int64 idx0 = 3;
  int64 idx1 = 4;
  repeated int64 exc0 = 5;
  repeated int64 exc1 = 6;
}

// Range message for integer ranges
message RangeInt64 {
  int64 min = 1;
  int64 max = 2;
}

// Message definitions
message Message {
  oneof content {
    Init init = 1;
    Ping ping = 2;
    Pong pong = 3;
    Error error = 4;
    Warning warning = 5;
    Open open = 6;
    Accept accept = 7;
    FundsAdded funds_added = 8;
    AddHTLC add_htlc = 9;
    FulfillHTLC fulfill_htlc = 10;
    AddCheque add_cheque = 11;
    SignedSnapshot signed_snapshot = 12;
    ChannelClosed channel_closed = 13;
  }
}

message Init {
  Version version = 1;
}

message Ping {
  // Empty message
}

message Pong {
  // Empty message
}

message Reject {
  bytes channelId = 1;
  repeated string reasons = 2;
}

message Open {
  NetworkId networkId = 1;
  bytes channelId = 2;
  bytes currencySymbol = 3;
  RangeInt64 fundingAmount = 4;
  int64 giftAmount = 5;
  RangeInt64 respondPeriod = 6;
  RangeInt64 minimumDepth = 7;
  RangeInt64 minHTLCValue = 8;
  RangeInt64 maxHTLCValue = 9;
  RangeInt64 maxTotalHTLCValue = 10;
  RangeInt64 maxHTLCCount = 11;
  bytes pubKey = 12;
}

message Accept {
  bytes channelId = 1;
  int64 fundingAmount = 2;
  int64 respondPeriod = 3;
  int64 minimumDepth = 4;
  int64 minHTLCValue = 5;
  int64 maxHTLCValue = 6;
  int64 maxTotalHTLCValue = 7;
  int64 maxHTLCCount = 8;
  bytes pubKey = 9;
}

message FundsAdded {
  bytes channelId = 1;
  int64 blockNumber = 2;
  TxOutRef txOutRef = 3;
  int64 amount = 4;
}

message AddHTLC {
  bytes channelId = 1;
  int64 htlcIx = 2;
  int64 amount = 3;
  int64 timeout = 4; // POSIX time in milliseconds
  bytes lock = 5;    // Sha256Hash
}

message FulfillHTLC {
  bytes channelId = 1;
  int64 htlcIx = 2;
  bytes preimage = 3;
  bytes signature = 4;
}

message AddCheque {
  bytes channelId = 1;
  int64 chequeIx = 2;
  int64 amount = 3;
  bytes signature = 4;
}

message SignedSnapshot {
  bytes channelId = 1;
  Snapshot snapshot = 2;
  bytes signature = 3;
}

message ChannelClosed {
  bytes channelId = 1;
  string reason = 2;
}
```
