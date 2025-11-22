---
title: "Unidirectional channels"
status: proposed
authors: "@waalge"
date: 2025-11-01
tags:
  - unidirectional
  - consumer
  - merchant
---

## Context

Classic lightning treats all participants/nodes equally: all channels are
bidirectional and all nodes can route payments. In practice many channels have
significant drift of funds of one participant to the other. In other words, they
may be predominantly or fully unidirectional.

For example, we want lightning to have first class support for interactions such
as coffee drinkers (consumers) purchasing coffee from a cafe (merchant). In this
scenario, consumers are "nearly always" sending, and merchants are "nearly
always" receiving.

## Decision

Introduce unidirection channels, otherwise feature comparable and compatible
with the bidirectional version.

### Overview

Unidirectional channels are in many ways similar to the existing bidirectional
channels:

- Evidence of funds owed is still communicated in the form of cheques and
  squashes.
- The channels exhibit the same lifecycle steps.

Key differences:

- There is a more pronounced assymmetry between the participants.
- On open, all funds belong to one participant, the "sender".
- Only the other participant, the "receiver", collects evidence of funds owed.
- Only the sender can add, close, expire, and elapse;
- Only the receiver can sub, respond, and unlock.
- There are non snapshots, since we have only one squash.

As a consequence:

- Resource requirements are lower.
- Logic is generally simpler, particularly concerning (unilateral) sub.

#### State management

Further work is required to specify the state management for both the sender and
receiver.

### Rationale

#### Fits key usecase

Unilateral channels provide the core required feature set of consumers and
merchants.

#### Resources

A sender needs **NO** chain liveness to be safe. As a result the resource
overhead of being a sender is lower. In particular, a consumer can safely manage
channels from say, a mobile, that has no reliable access to L1 tip.

#### Simpler subs

Removing bidirectionality makes sub steps much more straightforward.

## Discussion, Counter and Comments

#### Mid route usecase

The consumer and merchant usecases are important to CLs design goals. There is
however no on-chain distinction in whether or not the channel is a route
terminal, as in the case of a consumer or merchant. It may be employed more
generally whenever a unidirectional channel is desired.

### Bidirectionality via pairs

It may even be advantageous for participants to consider pairs of unidirectional
channels, that permit the bidirectional routing of funds. There are of-course
trade offs with this approach.

### Cancelation

Cancelation seems more problematic in the unidirectional case. The safe handling
of this seems to be pretty subtle, at least if handled only with the L2.

## Status

This proposal is heavily informed by the work on
[konduit.channel](https://konduit.channel). The focus of konduit is an ada
backed channel that is immediatly routing into bln.

Minor changes are required to extend non-ada assets. Further work is required to
make sense of usage when the channel is not the route source.

Konduit has opted for a tokenless design for state management.

## Consequences

Unidirectional channels are complementary to bidirectional ones. We may wish to
reflect on some design decisions where konduit and CL have diverged.
