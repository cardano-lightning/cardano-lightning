## Infrastructure

Many software pieces which are required by the Gateway Node implementation are
implemented in the form of reusable libraries. We group them here under the
"Infrastructure" umbrella.

- Cardano

  - SDK

    - Provides an ergonomic interface for handling cardano data.
    - Implements generic Cardano transaction builder.
    - Implementation:
      [cardano-sdk](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/sdk)

  - Connector
    - Exposes an API sufficient to reconstruct the L1 state of the CL channel.
    - Allows to query UTxO set in order to find wallet funding inputs for L1
      transactions (`open`, `add`, `close`).
    - Implementations:
      - [connector-server](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/connector-server) -
        a tiny HTTP custom server implementation which currently proxies
        blockfrost under the hood. It is useful when we want to query the
        Cardano from the client app without exposing the API key to the client.
      - [connector-client](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/connector-client) -
        the connector interface implementation as a client for the above
        connector-server. Used through WASM on the client side in the one of the
        [Ferret payment app](https://ferret.channel/) by @KtorZ.
      - [connector-direct](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/connector-direct) -
        the connector interface implementation as a direct client for the
        blockfrost API.
      - [connector-utxorpc](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/connector-utxorpc) -
        the connector interface implementation as a direct client for the
        utxorpc API.
    - Planned:
      - A Kupo based connector implementation - FIXME: link to the article which
        describes the double Kupo indexing architecture.

- Protocols

  - "Problem Details" library

    - Provides error reporting protocol based on
      [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457).
    - Implementation:
      [problem-details](https://github.com/cardano-lightning/konduit/tree/main/packages/util/problem-details)

  - "Powdos" protocol

    - Specifies a crypto and communication layer agnostic proof-of-work
      challenge protocol for the purpose of mitigating DoS attacks on the CL
      nodes.
    - Implementation:
      [powdos](https://github.com/cardano-lightning/konduit/tree/main/packages/util/powdos)

  - Cobbl3 protocol
    - Specifies a simple HMAC-BLAKE3 auth protocol which minimizes the resource
      usage needed to verify the auth token.
    - Implementation:
      [cobbl3](https://github.com/cardano-lightning/konduit/tree/main/packages/util/cobbl3)

- BLN

  - Connector

    - Connects edge Payment Gateways implementing "konduit protocol" to the BLN
      network.
    - Specifies an API for the the interaction with the BLN network through LND
      Node API.
    - Implementation:
      [lnd-client](https://github.com/cardano-lightning/konduit/tree/main/packages/bln/client)

  - SDK
    - Implements handling of BLN invoices.
    - Implementation:
      [bln-sdk](https://github.com/cardano-lightning/konduit/tree/main/packages/bln/sdk)

- FX Client
  - Foreign exchange client to be used by the BLN-CL edge node.
  - Currently implements [Kraken](https://www.kraken.com/) API client.
  - Implementation:
    [fx-client](https://github.com/cardano-lightning/konduit/tree/main/packages/util/fx-client)

## Gateway Node Core

- Kernel

  - Implements the CL validators.
  - Provides property tests.
  - Defines the surface interface specification in a form of blueprints.
  - Implementations:
    - [unidirectional](https://github.com/cardano-lightning/konduit/tree/main/packages/kernel)
    - [bidirectional](https://github.com/cardano-lightning/cardano-lightning/tree/main/aik/)

- CL Data

  - Implements the CL data structures and serialization needed for L1 and L2
    cash flow representation and signing.
  - Implementation:
    [cl-data](https://github.com/cardano-lightning/konduit/tree/main/packages/konduit/data)

- Tx Builder

  - Provides the CL specific transaction builder.
  - Implementation:
    [tx](https://github.com/cardano-lightning/konduit/tree/main/packages/konduit/tx)

- Admin

  - Service which is responsible for L1 interactions.
  - Monitors the blockchain for new opens, adds and closes.
  - Automatically constructs and submits the L1 transactions based on liquidity
    management policies.
  - Implementation:
    [admin](https://github.com/cardano-lightning/konduit/tree/main/packages/konduit/server/src/admin)

- HTTP Server

  - Implements the API server for the Gateway Node.
  - Implementation:
    [server](https://github.com/cardano-lightning/konduit/tree/main/packages/konduit/server/src/server)

- DB
  - Stores the L1 and L2 state of the Channels.
  - Implementation:
    [db](https://github.com/cardano-lightning/konduit/tree/main/packages/konduit/server/src/db)

## Gateway Node Client

- Client library

  - Implements the client library for the Gateway Node API.
  - Implementation:
    [client](https://github.com/cardano-lightning/konduit/tree/main/packages/konduit/client)

- CLI

  - Implements the command line interface for the Gateway Node API. Uses the
    client library under the hood.
  - Implementation:
    [cli](https://github.com/cardano-lightning/konduit/tree/main/packages/konduit/cli)

- WASM
  - Implements the WASM build of the client library for the Gateway Node API.in
  - Adapted for the browser and backend usage - uses abstraction layer for the
    HTTP requests.
  - Implementations:
    - [http-client](https://github.com/cardano-lightning/konduit/tree/main/packages/util/http-client) -
      HTTP client abstraction layer for the WASM build of the client library.
    - [http-client-wasm](https://github.com/cardano-lightning/konduit/tree/main/packages/util/http-client-wasm) -
      HTTP client implementation for the WASM build of the client library.
    - [http-client-native](https://github.com/cardano-lightning/konduit/tree/main/packages/util/http-client-native) -
      HTTP client implementation for the native build of the client library.
    - [wasm](https://github.com/cardano-lightning/konduit/tree/main/packages/konduit/wasm) -
      WASM build of the client library for the Gateway Node API.
  - Usage:
    - [Ferret payment app](https://ferret.channel/) by @KtorZ uses the WASM
      build of the client library for the Gateway Node API.
    - [Konduit payment app](https://app.konduit.channel/) by our team uses some
      parts of the WASM library as well.
