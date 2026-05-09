# Milestone 3

Coding extras (for the future?):

- Invoice component:

  - create
  - store
  - resolve

- CL client component:

  1. wraps invoice component
  2. second calls the other node quote

- Indexer API which tracks the execution thread.

## Plan

## Requirements:

### Outputs

- [ ] Spec of L2 System architecture. Including:

  - [ ] Component mapping diagram (draft by ~paluh~ AI, polish by waalge).
  - [ ] An explanation of each component, what id does, for whom and how it
        relates to the other components.
  - [ ] @waalge: API specs in an appropriate form eg Protobuf and/or OpenApi
  - [ ] Distinction between core and auxiliary aspects of spec.
  - [ ] Flagging any aspect (such as the establishing of specific constant
        values) that will need to be established empirically. For example, how
        long to hold channels open.
  - [ ] Explicit descriptions of the requirements of interactions with L1 in
        terms of read/ store (ie chain indexer) and write ie submit txs.

- [ ] Architectural Decision Records will record why some options were deemed
      _not_ suitable (and why we choose others instead). It is our aspiration
      that the spec is clear and comprehensive. So much so that third parties
      will be able to develop implementations and integrations of the protocol
      without awaiting and consulting our own implementation.

- [ ] @paluh: Blog post: Exposition on possible different user behaviour with
      respect to the protocol. For example: A user that only spends and has low
      resources vs a gateway aiming for high bidirectional throughput. This will
      act as an intro/signposting article to the spec.

In reality, it is unrealistic to believe we will do this adequately first time,
in one go, without also beginning an implementation. The spec will be maintained
as the source of truth beyond this milestone. Third party developers will remain
the primary audience and so changes will be logged _etc_.

### Acceptance criteria

- A (versioned) spec document(s) in the form of (or part of) a website (possibly
  single page). Including (and these are as above):

  - Component mapping diagram
  - An explanation of each component, what id does, for whom and how it relates
    to the other components.
  - API specs in an appropriate form eg Protobuf and/or OpenApi
  - Distinction between core and auxiliary aspects of spec.
  - Flagging any aspect (such as the establishing of specific constant values)
    that will need to be established empirically. For example, how long to hold
    channels open.
  - Explicit descriptions of the requirements of interaction with L1

- The api specs are compliant to their particular spec (that is, the spec of the
  spec 👍)

- A collection of ADRs

- Blog post : Exposition on possible different user behaviour

## Materials

### The CL L2 spec

Link:
https://github.com/cardano-lightning/cardano-lightning/blob/main/docs/design/l2-spec.md

Summary:

The protocol in the spec allows for longer conversations in a few cases, but
could be rather easily adapted to be request/response only.
Conversations/mediations would be turned into a series of attempt/correction
request/response pairs.

### The Konduit spec

- Preview:
  https://htmlpreview.github.io/?https://raw.githubusercontent.com/cardano-lightning/konduit/main/docs/processes/index.html
- File:
  https://github.com/cardano-lightning/konduit/blob/main/docs/processes/index.html
