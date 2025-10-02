---
title: "Min-ADA handling"
status: proposed
authors:
  - "@paluh"
date: 2025-09-07
tags:
  - l1
---

## Context

On Cardano blockchain we have to deal with a minimum UTxO requirement. The
actual Lovelace amount which has to be present on the UTxO depends on the size
of the UTxO itself. Our project goal is to provide ability for creating a
non-native tokens channels an not only ADA ones. It seems beneficial to have a
common approach for handling the min-ADA (also called min-UTxO) which is simply
and clearly separated from the channel logic itself.

## Decision

### Overview

- The current `Datum` structure:

  ```
  pub type Datum = (ScriptHash, Keys, Stage)
  ```

  will be extended to:

  ```
  // Use keys.1st when equals 0 and keys.2nd otherwise.
  pub type MinAdaOwner = Integer

  pub type MinAda = Int

  pub type Datum = (ScriptHash, Keys, Stage, MinAda, MinAdaOwner)
  ```

- Min ADA should be provided by the opener up front.
- If the non-opener considers the provided min-ADA insufficient, he should close
  or ignore the channel.
- `end` step can be only executed by the min-ADA owner indicated by key index
  and should release that money.

### Rationale

- This approach is simple and clearly separated from the channel logic itself.

- We minimize the computational overhead:

  - We do not track any bumps or switches of that value during the lifecycle of
    the channel.
  - Any extra Lovelace which is required to cover the min-ADA has to be provided
    by the user of the channel and possibly not refunded.
  - Then only checks which will be added to the validator will ensure that the
    total amount covers channel liabilities together with the min-ADA.

- The tx size of a single channel UTxO should approximately increase by 6 bytes
  only. This was tested by using:
  - Old datum value `Datum(#"00", (#"00", #"00"), Elapsed([]))`
  - The new one `Datum(#"00", (#"00", #"00"), Elapsed([]), 8, 0)` which assigns
    8ADA min-ADA to the first key address.
  - Both values were encoded as UPLC "programs":
    `(program 0.0.0 (con data (List [B #00, List [B #00, B #00], Constr 3 [List []]])))`
    and
    `(program 0.0.0 (con data (List [B #00, List [B #00, B #00], Constr 3 [List []], I 8, I 0])))`
    accordingly.
  - Then those programs were serialized by using
    `aiken uplc encode --hex <PROGRAM_FILE>`.
  - The size difference was **2** bytes only.

## Discussion, Counter and Comments

### Comments

.

### Considered Alternatives

.

## Status

.

## Consequences

Modifying the existing validator and the spec. Introducing some extra parameters
and safeguards to the Peer protocol.
