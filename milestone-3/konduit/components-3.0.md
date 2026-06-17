## Infrastructure

Many software pieces which are required by the Gateway Node implementation are
implemented in the form of reusable libraries. We group them here under the
"Infrastructure" umbrella.

- Cardano

  - Kernel

    - Implements the CL validators.
    - Provides property tests.
    - Defines the surface interface specification in a form of blueprints.
    - Implementations:
      - [unidirectional](https://github.com/cardano-lightning/konduit/tree/main/packages/kernel)
      - [bidirectional](https://github.com/cardano-lightning/cardano-lightning/tree/main/aik/)

  - SDK

    - Provides an ergonomic interface for handling cardano data.
    - Implements generic Cardano transaction builder.
    - Implementation:
      - [cardano-sdk](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/sdk)

  - Connector
    - Exposes an API sufficient to reconstruct the L1 state of the CL channel.
    - Allows to query UTxO set in order to find wallet funding inputs for L1
      transactions (`open`, `add`, `close`).
    - Implementations:
      - [connector-server](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/connector-server) -
        a tiny HTTP custom server implementation which currently proxies
        blockfrost under the hood. It is useful when we want to query the
        Cardano from the client app without exposing the API key to the client.
      - [connector-client](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/connector-client/src) -
        the connector interface implementation as a client for the above
        connector-server. Used through WASM on the client side in the one of the
        [Ferret payment app](https://ferret.channel/) by @KtorZ.
      - [connector-direct](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/connector-direct/src) -
        the connector interface implementation as a direct client for the
        blockfrost API.
      - [connector-utxorpc](https://github.com/cardano-lightning/konduit/tree/main/packages/cardano/connector-utxorpc/src) -
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
      - [problem-details](https://github.com/cardano-lightning/konduit/tree/main/packages/util/problem-details)

  - "Powdos" protocol
    - Specifies a crypto and communication layer agnostic proof-of-work
      challenge protocol for the purpose of mitigating DoS attacks on the CL
      nodes.
    - Implementation:
      - [powdos](https://github.com/cardano-lightning/konduit/tree/main/packages/util/powdos)

- BLN

  - Connector

    - Connects edge Payment Gateways implementing "konduit protocol" to the BLN
      network.
    - Specifies an API for the the interaction with the BLN network through LND
      Node API.
    - Implementation:
      - [lnd-client](https://github.com/cardano-lightning/konduit/tree/main/packages/bln/client)

  - SDK
    - Implements handling of BLN invoices.
    - Implementation:
      - [bln-sdk](https://github.com/cardano-lightning/konduit/tree/main/packages/bln/sdk/src)

## Gateway Node Core
