---
title: "Simplify Cheques"
status: proposed
authors: "@you"
date: 2025-01-01
tags:
  - optional
---

## Context

The current design has "Cheque" and "Locked Cheque", with a "normalize" process
in which a "Locked Cheque" becomes a "Cheque". The normalize process was to
remove the need of the secret and timelock present in the Locked Cheque.

However, this property is also present in the Squash. That is, there are two
ways to do the same thing.

The two are not completely equivalent. The normalization process allows for more
processes to be running for longer in parallel. However, it is not clear this is
actually a useful feature.

## Decision

### Overview

- Remove the existing understanding of "Cheque". Remove the use of the term
  "Locked Cheque".
- Instead, "Cheque" means what was previously understood as "Locked Cheque".
  That is, a cheque has a hash lock and a time out.

There is no notion of "normalizing" cheques, only squashing.

### Rationale

It is simpler.

## Discussion, Counter and Comments

.

### Comments

.

### Considered Alternatives

.

## Consequences

Modifying the existing implementation of the validator.
