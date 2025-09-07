---
title: "Min-UTxO handling"
status: proposed
authors:
  - "@paluh"
date: 2025-09-07
tags:
  - l1
---

## Context

On Cardano blockchain we have to deal with a minimum UTxO requirement. The actual Lovelace amount which has to be present on the UTxO depends on the size of the UTxO itself. Our project goal is to provide ability for creating a non-native tokens channels an not only ADA ones.
It seems beneficial to have a common approach for handling the min-UTxO which is simple and clearly separated from the channel logic itself.

## Decision

### Overview

* The current `Datum` structure:

  ```
  pub type Datum = (ScriptHash, Keys, Stage)
  ```

  will be extended to:

  ```
  pub type MinUTxODest {
    UseAddress { address: Address }
    // 0 - means first key, non 0 - means second key
    OwnerKey { keyIdx: Int }
  }

  pub type MinUTxOAmount = Int

  pub type Datum = (ScriptHash, Keys, MinUTxOAmount, MinUTxODest, Stage)
  ```
* Min ADA should be provided by the opener up front.
* If the non-opener considers the provided min-UTxO insufficient, he should close the channel.
* `end` step which drains the channel must release the min-UTxO amount according to the `MinUTxODest` value.

### Rationale

* This approach is simple and clearly separated from the channel logic itself.

* We minimize the computational overhead:
  * We do not track any bumps or switches of that value during the lifecycle of the channel.
  * Any extra Lovelace which is required to cover the min-ADA has to be provided by the user of the channel and possibly not refunded.
  * Then only checks which will be added to the validator will ensure that the total amount covers channel liabilities together with the min-UTxO.

* In an optimistic case (when no external address is used) the tx size of a single channel UTxO should approximately increase by 6 bytes only. This was tested by using:
  * Old datum value `Datum(#"00", (#"00", #"00"), Elapsed([]))`
  * The new one `Datum(#"00", (#"00", #"00"), 8, 0, Elapsed([]))` which assigns 8ADA min-UTxO to the first key address.
  * Both values were encoded as UPLC "programs": `(program 0.0.0 (con data (List [B #00, List [B #00, B #00], Constr 3 [List []]])))` and `(program 0.0.0 (con data (List [B #00, List [B #00, B #00], I 1, Constr 1 [I 0], Constr 3 [List []]])))` accordingly.
  * Then those programs were serialized by using `aiken uplc encode --hex 'ext-datum.uplc' <PROGRAM_FILE>`.
  * The size difference was 6 bytes.

## Discussion, Counter and Comments

### Comments
.

### Considered Alternatives
.

## Status
.

## Consequences
Modifying the existing validator and the spec. Introducing some extra parameters and safeguards to the Peer protocol.


