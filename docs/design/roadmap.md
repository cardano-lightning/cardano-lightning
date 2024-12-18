---
title: Roadmap / Todos
author: "@waalge"
---

Welcome the to CL Roadmap 🛣️ !

This is a living document. Dates will be added as soon as funding is secured 😉
(get in touch if you're interested).

## Phase 0 :: Hub & Spoke

This is our Concept phase. The aims are:

- Become adept with Lightning design and concepts
- Explore ways to apply Lightning to Cardano to greatest effect
- Provide a POC/MVP of a Cardano Lightning network with a hub and spoke
  topology.

- M1 : Research and Specs
  - [x] - Analysis of Bitcoin lightning
  - [x] - L1 v0
    - [ ] - Sub step
  - [x] - L2 - Peer Protocol v0
  - [ ] - L2 - Hub v0
- M2 : Validator(s)
  - [ ] - Validator v0 implementation
  - [ ] - Benchmarking and tests
  - [ ] - Validator v1 with sub step
- M3 : L2 Stack and Key Management
  - [ ] - CI/CD
  - [ ] - Networking layer
  - [ ] - Persistence layer
  - [ ] - Signing server and proxy key setup
- M4 : Tx builders
  - [ ] - Tx building
  - [ ] - L1 abstraction/interface
  - [ ] - L1 provider implementation
- M5 : Cli
  - [ ] - Channel management cli tool
- M6 : Demo
  - [ ] Channel setup, payment, teardown
  - [ ] Elementary routing

## Phase 1.A :: Scaling & Node specialization

Once the POC has a trailblazed our path, we are ready to create a payment system
suitable for day-to-day commerce.

Our key requirements are:

- Secure and permissionless
- Near instant
- Highly scalable

There are three typical participant types in commerce: the consumer, the
merchant, and the payment facilitator. If you buy a coffee at your local cafe
with your visa card, then you're the consumer, the cafe is the merchant, and
visa is the payment facilitator. The needs of these participants is distinct,
and thus the CL node they run will be distinct.

To understand more about our thinking see our blog post [[TODO :: FIXME]]

### Cirrus v0

Cirrus is a super lightweight CL targeting end user/ consumers running the node
on mobile devices or within a web client. The design assumes that the node is
"usually off-line", and consumes few resources in terms of compute, memory,
storage and network.

- M1 : Design
  - [ ] - Requirements doc
  - [ ] - UX/UI design
- M2 : Dev infra
  - [ ] - CI/CD
  - [ ] - Live endpoint server
  - [ ] - "e2e"-ish testing
- M3 : Keys and Backups
  - [ ] - Key management
  - [ ] - Backup abstraction
- M4 : L1 connection
  - [ ] - L1 abstraction interface
  - [ ] - L1 provider management and status page
  - [ ] - L1 interface implementation(s)
- M5 : Channel management
  - [ ] - Channel management features
  - [ ] - Invoice feature with qr io
- M6 : P2P
  - [ ] - P2p payments
  - [ ] - Docs and guides

### Calvus v0

Calvus is a node for the payment facilitators, routing payments from consumers
to merchants, generally via a path of Calvus nodes. It is run on highly
available servers and is optimized to handle many channels in a highly efficient
manner. This includes:

- Efficient multi-channel lifecycle management with smart tx composition
- Robust, reliable, and efficient service provision, including multi-hop routing
- Efficient capital allocation between channels with near term capacity
  predictions
- Configurable channel management policies for new channels fee and pledge
  calculations
- Payment traffic statistics, other nodes performance and "reputation" tracking.

- M1 : Prelims
  - [ ] - Architecture design and stack choices
  - [ ] - CI/CD
  - [ ] - L1 abstraction
  - [ ] - Monitoring, logging, notification features
- M2 : Core
  - [ ] - Core channel management features
- M3 : N2N protocol(s)
  - [ ] - Node-to-node comms v0 spec
  - [ ] - Node-to-node comms v0 implementation
- M3 : Automation
  - [ ] - configurable auto-channel management
- M4 : Tests and benchmarking
  - [ ] - test suite
  - [ ] - benchmark suite
- M5 : Packaging
  - [ ] - packaging for deployments
  - [ ] - Comprehensive docs and guides

### Stratus v0

Status is a node to meet merchants' needs. Stratus exposes APIs to allow
merchants to integrate CL into their existing business practices.

- M1 : Research and Design
  - [ ] - Scope and design qualitative survey
  - [ ] - Conduct survey
  - [ ] - Analysis and initial conclusions
- M2 : Node implementation
  - [ ] - L1 abstraction
  - [ ] - Core node functionality
- M3 : Admin controls
  - [ ] - Basic web interface for node
  - [ ] - Channel management interface
- M4 : Stratus SDK
  - [ ] - SDK v0 spec
  - [ ] - SDK v0 implementation in TS
- M5 : Test suite
  - [ ] - Comprehensive unit tests
  - [ ] - "e2e" tests
  - [ ] - Testing tools for integrators
- M6 : Docs and onboarding
  - [ ] - Comprehensive API reference
  - [ ] - Guides
  - [ ] - Reflection on user experiences

## Phase 1.B :: X-Chain

Cardano Lightning is designed and built to be interoperable with other lighting
networks, namely Bitcoin Lightning.

Phase 1.B aims to produce edge nodes that handle both BLN and CL channels, and
allow routing between the two.

Milestones TBC

## Phase 2.A :: Generalized Routing

Calvus will have developed a routing protocol. It is a complex and subtle
problem and the solution in Calvus v0 optimizes in part for simplicity over,
say, privacy or efficiency.

Phase 2.A will bring routing protocols that:

- enhance privacy
- faster routing
- better capital efficiency

Milestones TBC
