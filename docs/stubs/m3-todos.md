# M3 todos

- [ ] Spec of L2 System architecture. Including
  - [ ] Component mapping diagram
  - [ ] An explanation of each component, what id does, for whom and how it
        relates to the other components.
  - [ ] API specs in an appropriate form eg Protobuf and/or OpenApi
  - [ ] Distinction between core and auxiliary aspects of spec.
  - [ ] Flagging any aspect (such as the establishing of specific constant
        values) that will need to be established empirically. For example, how
        long to hold channels open.
  - [ ] Explicit descriptions of the requirements of interactions with L1 in
        terms of read/ store (ie chain indexer) and write ie submit txs
- [ ] Blog post : Exposition on possible different user behaviour with respect
      to the protocol. For example: A user that only spends and has low
      resources vs a gateway aiming for high bidirectional throughput. This will
      act as an intro/signposting article to the spec.
- [ ] Architectural Decision Records will record why some options were deemed
      _not_ suitable (and why we choose others instead).

NOTE: It is our aspiration that the spec is clear and comprehensive. So much so
that third parties will be able to develop implementations and integrations of
the protocol without awaiting and consulting our own implementation. In reality,
it is unrealistic to believe we will do this adequately first time, in one go,
without also beginning an implementation. The spec will be maintained as the
source of truth beyond this milestone. Third party developers will remain the
primary audience and so changes will be logged _etc_. Acceptance criteria

- [ ] A (versioned) spec document(s) in the form of (or part of) a website
      (possibly single page). Including (and these are as above):
- [ ] Component mapping diagram
- [ ] An explanation of each component, what id does, for whom and how it
      relates to the other components.
- [ ] API specs in an appropriate form eg Protobuf and/or OpenApi
- [ ] Distinction between core and auxiliary aspects of spec.
- [ ] Flagging any aspect (such as the establishing of specific constant values)
      that will need to be established empirically. For example, how long to
      hold channels open.
- [ ] Explicit descriptions of the requirements of interaction with L1
- [ ] Blog post : Exposition on possible different user behaviour
- [ ] The api specs are compliant to their particular spec (that is, the spec of
      the spec 👍)
- [ ] A collection of ADRs

Evidence of milestone completion

- [ ] The spec will be in the gh repo:
      https://github.com/cardano-lightning/cardano-lightning
- [ ] As will ADRs
- [ ] Blog post at https://cardano-lightning.org
- [ ] A rendered version of the spec will be hosted on
      https://cardano-lightning.org

## Notes

### Diagrams research

Mermaidjs doesnt seem to be a great fit. It is where we have the most (most
recent) experience. Two mermaid diagram types that look suitable are C4 and
architecture-beta. Mermaidjs C4 is still under construction
(https://mermaid.js.org/syntax/c4.html). Mermaidjs architecture-beta ran into
issues (https://github.com/orgs/mermaid-js/discussions/6005).

The C4 model looks like a good approach. [C4](https://c4model.com) had a
pleasant exposition of the "why" and "how".

Conclusion: do a set of C4-esque diagrams by hand.

### Diagram content

End-User <-> Mobile Node gui.

Mobile Node components:

- gui
- datastore
- logic

Mobile Node connects:

- to hub : sending, receiving cheques
- to L1: viewing, opening, adding, closing, etc...
- to backs up : User back up. (feature: user-backup)
- to signing service : via PAM, Keychain, Hardware wallet ... (feature:
  user-advanced-km)

Static Node connects:

- to mobile nodes : sending, receiving cheques
- to L1: viewing, opening, adding, closing, etc...
- to cli : basic management
- to backs up: Hub back up. (feature: hub-backup)
- to hubs : sending, receiving cheques (feature: hub-2-hub)
- to admin panel (feature : hub-advanced-management)
- to signing service: hardened signing server (feature: user-advanced-km)

Static Node api:

- open: node status, channel params, ...
- closed: send cheque, ...

Static Node open api:

- generally static request.
- very low resource requirements in order to service requests.

Static Node closed api:

- p2p protocol
- requests must be auth (encrypted and signed via noise or otherwise)

- backs up to : Hub back up to remote disks
- signing with : Signing service (feature : user-advanced-km)

TODO

### Message spec lang

Message serialisation is done cbor. Spec is written in cddl.

We had proposed protobuf: the modern, fashionable way of doing serde. However,
it is now apparent the downsides are greater than the upsides of doing so.
Protobuf is efficent and has wide language support, but so does cbor. We were
aware at the time of proposing that there are some shortcoming of using
protobuf. Namely, protobuf doesn't support byte level specification (such as
fixed length bytearrays), let alone bit level. In addition, protobuf fields are
all optional which is a faff in cases where no fields are. The plan was to embed
cbor into protobuf.

The final straw: libp2p request-response protocol supports cbor (and json) out
of the box. It does not support protobuf.

TODO : convert into ADR
