---
title: CL L1 Spec
author:
  - "@waalge"
  - "@paluh"
---

## Intro

Cardano Lightning (CL) is p2p payment solution inspired by Bitcoin Lightning
Network, and built over the Cardano blockchain. It is an L2 (Layer 2) optimized
for:

- Near instant settlement
- Scalability

Users of the network maintain two party channels, through which they can send
and receive funds. We may refer to the participants of the channel as the party
and counter party.

A user can perform various high level actions, including:

1. Open, maintain, and end a channel
2. Send, and receive funds

Signposting:

- For gentler intro to CL, check out the
  [blog](https://cardano-lightning.org/blog) and the
  [minimal lifecycle ADR](../ards/minimal-lifecycle.md) for a general
  introduction lifecycle of the channel.
- For terms, see the [glossary](../glossary.md)
- For explanations on how to read this spec, see the appendix.

## Design

### Overview

CL consists of a single Plutus V3 validator executed in both `Mint` and `Spend`
purpose.

The business logic is entirely implemented when executed with `Mint` purpose.
The `Spend` logic simply verifies the mint logic is executed. This is to
minimize the number of traversals required over the inputs and outputs, when
stepping multiple channels within a single tx.

### Steps and stages

A (staged) channel is represented by a utxo at tip at the script address bearing
a thread token (see [channel id ADR](../adrs/channel-id.md) for more
commentary).

When a channel is 'staged' the thread token is minted; when the channel is
'unstaged' the thread token is burnt. The thread token remains at the script
address.

The stages of a channel are:

- `Opened`
- `Closed`
- `Responded`
- `Resolved`

The steps that progress from one stage to the next are follows:

- `open : [*] -> Opened` : Mints the thread token and adds funds to the
  partner's account.
- `close : Opened -> Closed` : A partner submits their receipt of their L2
  transacting. The partner should no longer accept cheques on the L2.
- `respond : Closed -> Responded` : The non-closer partner submits their
  receipt. They release the funds they are owed, and not still locked.
- `resolve : Responded -> Resolve` : The closer releases the funds they are
  owed, and not still locked.
- `elapse : Closed -> Resolved` : A closer can release their funds, up to pending
  locked cheques, if the `respond` is not sufficiently punctual.

Steps that are fixed to a stage

- `add : Opened -> Opened` : Add funds to their account.
- `free : Closed -> Closed` : Closer provides evidence that conditions We'd
  still need to know the latest are met to free some locked cheques. The value
  is added to their account but not released
- `free : Responded -> Responded` : Non-closer provides evidence that conditions
  are met to free some locked cheques. Funds are immediately released.
- `free : Resolved -> Resolved` : Either partner frees locked cheques, and funds
  are immediately released.

Unstaging steps

- `end : Responded -> [*]` : A `resolve` but the output has no locked cheques.
- `end : Resolved -> [*]` : A `free` but the output has no locked cheques.
  locked cheques.

### Constants

To prevent the size of the datum making it unspendable, we provide a hard limit
on the size of the list of pending cheques.

```ini
max_pend = 20
```

### Token names

Bolt tokens are used to invoke the script in `Mint` purpose, when no thread
token are being minted or burned.

Its name is the thunder bolt emoji.

```aiken
let bolt_token_name = "⚡"
```

Thread tokens are formed in the following manner

```rs
let name = "⚡" + mk_cid(seed, idx)
```

where

- `seed` is the oref of some input spent in the mint.
- `idx` is the relative output index the minting tx outputs the thread token.

```
fn mk_cid(seed, idx) {
  seed |> as_bytes |> push(idx) |> blake_2b_256 |> take(20)
}
```

-

### Data

The following sections are collections of data definitions that are underpin
communication and integrity both within the L2 and from the L2 to the L1.

Relevant data types have an associated `verify` function employed withing the
script that verifies that the data is well-formed.

#### Cheques

Cheques are a vehicle via which funds are sent from one partner to the other. As
such they must be understood on the L1.

Cheques may be "normal" or "locked". Normal cheques, provided they are
accompanied with a valid signature, are indicate the sender owes the receiver
the indicated amount of funds. A locked cheque indicates that the sender owes
the receiver funds subject to extra conditions.

A "hash time locked contract" cheque (HTLC) has a lock in the form of a hash. To
be redeemable, the receiver must provide the "secret" that hashes to the lock.

```aiken
type Index = Int
type Amount = Int
type Timeout = Int // Posix Timestamp

type Normal = (Index, Amount)

type Hash32 = ByteArray // 32 bytes

type HashLock {
  Blake2b256Lock(Hash32)
  Sha2256Lock(Hash32)
  Sha3256Lock(Hash32)
}

pub type Htlc = (Index, Amount, Timeout, HashLock)

pub type Locked {
  HtlcLocked(Htlc)
}

type Cheque {
  NormalCheque(Normal)
  LockedCheque(Locked)
}

type Secret = ByteArray // <= 64 bytes

type Unlocked {
  HtlcUnlocked(Htlc, Secret)
}

type MCheque {
  MNormal(Normal)
  MLocked(Locked)
  MUnlocked(Unlocked)
}

type Bytes64 = ByteArray // 64 bytes
type Signature = Bytes64
type Signed<T> = (T, Signature)
```

As with other signed objects, we prepend the channel id (`cid`) onto the data.
The channel id effectively acts as a nonce. The signature for a cheque is for
the message

To verify a signature:

```aiken
fn verify_cheque( signed_cheque : Signed<Cheque> , vk : VerificationKey) -> Bool {
  let (cheque, siganture) = signed_cheque
  let message = concat cid (as_bytes cheque)
  verify(verificationKey, message, signature)
}
```

`verify` functions are `Ed25519` functions. This aligns with the signing of txs
on Cardano.

#### Snapshot

As amounts of funds are transacting on the L2, the list of cheques used grows.
The funds associated to an L2 account can be "squashed down" to a much smaller
piece of data, namely a `Squash`. The partner's squash is the summary of the
cheques they received.

Together, the two partners `Squash`s form a snapshot. The snapshot allows
partners to maintain a manageable amount of cheques. The squashes are ordered
lexicographically by the partners verification key. So the squash of the cheques
received by the smaller verification key is first. The ordering is important.

```aiken
type Exclude = List<Index>
type Squash = (Amount, Index, Exclude)
type Snapshot = (Squash, Squash)
```

A snapshot can be submitted to the L1 as part of an `add`. In doing, it provides
a lower bound on final settlement, Thus it provides a lower bound on potential
loses in a scenario of catastrophic failure in which a partner is off-line and
cannot `respond`.

The verify function works analogously to signatures of cheques.

#### Receipt

The ending of a channel is done across several steps. Each partner is
responsible for their own funds. Each partner should **settle** their L2 state
on the L1. This is done with a snapshot, and cheques unaccounted for. The
receipt is made by the submitter, and consists of pieces signed by their
partner.

```aiken
type Receipt =  (Option<Signed<Snapshot>>, List<Signed<MCheque>>)
```

If the latest snapshot is already in the L1, there is no need to provide it
again. The list of signed `MCheque`s are the cheques not accounted for in the
snapshot. It may include the pending locked cheques: locked cheques that have a
timeout yet to pass, but no secret is known.

A valid receipt will include a valid signed snapshot, and list of valid signed
non-locked cheques and valid locked cheques. Moreover, the cheques must have
unique indices and are all unaccounted for in the snapshot.

The logic should fail if the indices of the `MCheque`s are not strictly
increasing.

#### Pend

After a close, there may exists pending (locked) cheques. It is yet to be
determined which partner ultimately is rightfully due the associated amounts.

The index of a cheque is no longer relevant

```aiken
type LockedReduced {
  HtlcReduced(Amount, Timeout, Lock)
}

type Pend = (Amount, List<LockedReduced>)
```

A `Pend` encapsulates the total value from a list of pending locked cheques,
together with the information required to free them, either via a secret, or
their expiry. To be accepted by the L1 the length of the list must not exceed
`max_pend` constant. A pend is empty if it is `Pend 0 []`. The total prevents
the need to walk the list. Note that it is to be confirmed whether this total
field provides sufficient benefit to be included.

A pend is correctly derived from a receipt if it is formed the locked cheques,
and the amount is the total amount.

A pend is reduced by secrets, if each secret provided unlocks a cheque. A pend
is reduced by timeout, if each locked cheque with timeout that has demonstrably
passed is dropped. The pend amount must reflect the change in the total.

#### Datum

The channel utxo always has an inlined datum.

The datum consists of the scripts own hash. This allows us to defer safely, and
as efficiently as possible, the business logic to the script employed in `Mint`
purpose.

The datum also consists of the keys and the stage information. The keys, as an
unordered set, endures for the life of the script. Note however the order may
change on a `close`.

```aiken
type ScriptHash = ByteArray // 28 bytes
type VerificationKey = ByteArray // 32 bytes,
type Keys = (VerificationKey, VerificationKey)
type Period = Int // Time delta

type Stage {
  Opened(Amount, Snapshot, Period)
  Closed(Amount, Squash, Timeout, Pend)
  Responded(Amount, Pend, Pend)
  Resolved(Pend, Pend)
}

type Datum = (ScriptHash, Keys, Stage)
```

There are some scenarios where one of the two keys is no longer strictly
necessary. For example, `resolved` stage after `elapse` with no pending locked
cheques for the `closer`. However, we do will not consider optimising for these niche cases.

> ::: WARNING ::: The order in which the keys appears matters and can change on
> a `close` step. Details below.

The channel datum has the following form where the constructors follow the
stages of the lifecycle.

The order of the pends reflects the order of the keys.

##### Opened stage

Suppose the stage is `Opened(amt1, snapshot, respond_period)`.

`amt1` is the amount of channel funds that belong to the non-opener partner.
Typically this will start at 0 as all funds are provided by the opener. However,
this is not enforced and up to the partners to decide. The keys should be
ordered `(opener, non-opener)`, but beyond the above point, this is of no
further consequence.

The `snapshot` is the latest recorded state of the `L2`. It provides the ability
to place a lower bound for the eventual settled state. This allows partners to
know, and limit an upper bound on potential losses in the case of some
catastrophic failure.

The `respond_period`, as the name suggests is minimum time delta between a
partner may `close` and then `elapse` a channel. Thus it is the time which the
non-closer can `respond`. Participants should ensure this appropriate for their
usage.

##### Closed stage

Suppose the stage is `Closed(amt, squash, timeout, pend)`.

The keys are ordered `(closer, non-closer)`. This is the order in which they
will remain for the rest of the lifecycle.

The `amt` is the amount of the funds that belong to the closer, according their
receipt and the previous state. It does not reflect the receipt of the
non-closer who is yet to settle but already includes the difference between the squashes
from the latest snapshot. The detailed calculation is described below.

The `squash` is the latest squash for the non-closer, that is, the squash
representing the cheques received by the non-closer. It will be used against
the non-closer receipt squash to calculate the final `amt`.

The `timeout` is the time after which the closer may perform an `elapse` step.

The `pend` contains the relevant bits of information of any pending locked
cheques received by the closer.

##### Responded stage

Suppose the stage is `Responed(amt, pend0, pend1)`.

The `amt` has the same meaning as in the `Closed` stage, but now reflects the
receipt provided by the non-closer partner.

The `pend0` is the pending locked cheques received by the closer. Between stages
the list may have been reduced either by providing the secret or demonstrating
that its timeout has passed.

The `pend1` is the pending locked cheques received by the non-closer.

##### Resolved stage

Suppose the stage is `Resolved(pend0, pend1)`. The two values have the same
significance as in the `Responded` stage.

#### Redeemer

We have redeemers for `Spend` and `Mint`.

```aiken
type SpendRedeemer {
  DeferToMint
}

type MintRedeemer = (Option<OutputReference>, List<NStep>)

type Secrets = List<(Idx, Secret)>

pub type NStep {
  Continuing(CStep)
  End(Secrets)
}

pub type CStep {
  Add(Option<Signed<Snapshot>>)
  Close(Receipt)
  Respond(Receipt, Bool)
  Resolve(Secrets)
  Elapse(Secrets)
  Free(Secrets, Bool)
}
```

Note that the type is called `NStep` rather than `Step`. `NStep` is loosely
inspired by 'nested step'. Similarly, `CStep` is loosely inspired on 'continuing
step'. This better reflects the handling logic. For example, `open` doesn't have
a script input, and `end` doesn't have an output. So, for example, `NStep` does
not include an `Open` constructor as we might expect.

### Channel input/output

All steps, except `open` require exactly one input. `open` requires no inputs
and is dealt with first. All steps that are not `end` require a (single)
continuing output. Since `open` doesn't have an input, its continuing output is
referred as a new output.

#### Channel Id

The channel id is determined by the `seed` and an integer.

`cid = mk_cid(seed, idx)`

The integer allows us to reuse the same seed for multiple opens. For details on
the function `mk_cid`, see the [channel id ADR](./../adrs/channel-id.md).

#### New output

With the script hash and channel id, we can find new outputs from the
`tx.outputs`. A new output:

- Address has payment credentials of own script.
- Value is thread token with channel id `cid` and either:
  - ada
  - ada and channel currency
- Datum is inlined, and has correct `dat.0` own hash.

Note that staking credentials are up to the opener, and are fixed for the
channel's life.

There is no further business logic required in an `open`. Thus the signature is

```aiken
fn new_output(own_hash: ScriptHash, cid : ChannelId, outputs : List<Output>) -> List<Output>
```

Note that the function returns the rest of the list after the new output has
been verified.

The funds at risk are those belonging to the submitter of the tx. The non-opener
must check the state of the channel before participating. For this reason it is
safe not to require further verification.

A small perturbation of `new_output` to `new_outputs`, can instead take the
`seed` and the expected number new outputs.

```aiken
fn new_output(own_cred: Credential, seed: OutputReference, n_mints: Int, outputs : List<Output>) -> List<Output>
```

When `n_mints == 0`, then it return the remaining `outputs`, else it recurs each
time decreasing the `n_mints`.

With this implementation, it makes it easier to use the integer parameter as a
_relative inverse index_. That is, for example, `mk_cid(seed, 3)` appears before
`mk_cid(seed, 2)` in `outputs`.

#### Next input

The validator reduces over the list of steps. At the same time it also reduces
the list of inputs. The "next input" refers to the next input with payment
credentials matching those of the script.

The next input must also have:

- a value including a thread token
- a parse-able datum.

From these, we extract a condensate of the input:
`(cid, address, total, keys, stage)`.

The `next_input` function inspects the item at the head of `tx.inputs` and then
recur over the tail. Thus the function signature is

```aiken
fn next_input(own_cred : Credentials, inputs : List<Input>) ->
  (ChannelId, Address, Amount, Keys, Stage, List<Input>)
```

If the function exhausts the list, then it fails.

#### Continuing output

A continuing output:

- Same address,
- Same thread token and either:
  - ada
  - ada and channel currency
- Datum is inlined, and has correct `dat.0` own hash

When we extract the continuing output, we return `(Amount, Keys, Stage)` Thus
the function signature is

```aiken
fn get_cont(cid : ChannelId, address : Address, outputs : List<Output>) ->
  (Amount, Keys, Stage, List<Output>)
```

If the output does not have the thread token, the function tries the next
output. If `outputs` is empty, then the function fails. If the thread token is
present and the address is wrong, then fail

#### No (script) inputs

The number of steps in the list of steps must match the number of script inputs.
After we exhaust the steps listed in the redeemer, we must ensure there are no
more inputs from the script.

```aiken
fn no_inputs(own_cred : Credential, inputs : List<Input>) -> Void
```

This fails if any input belongs to the script.

### Steps preamble

#### Standardizing argument handling

To avoid (re)structuring and destructuring data across function boundaries, we
are compelled to factor code into functions of many arguments. The context
required for each step (type) is not identical, although there is considerable
overlap. We standardize arguments and ordering to keep things manageable.

Argument order for step functions is as follows, with their reserved variable
names:

1. Tx constants:
1. Channel Id : `cid`
1. Signatories : `signers = tx.extra_signatories`
1. Validity range lower bound `lb = tx.validity_range.lower_bound`,
1. Validity range upper bound `ub = tx.validity_range.upper_bound`
1. Input derived:
1. Total funds `tot_in`
1. Keys `keys_in`
1. Stage `stage_in`
1. Redeemer derived: `steps` / step specific variables
1. Output derived (ordered analogously to input with `_out` suffix)

Not all steps require all context.

Note, it is to be confirmed whether the implementation will make use of currying
the `do_X` step functions.

The type of a bound in aiken is `IntervalBoundType`. Since this is a bit odd,
we'll use the alias `ExtendedInt`

### Do steps

We encode the step verification as function that fails or returns unit.

In every tx precisely one of the partners signs the tx. If neither partner has
signed the tx fails. If both partners have signed, then the behaviour is
undefined. `signed_by_vk0` is a boolean such that:

- `True`, if the tx is signed by `vk0`,
- `False`, if the tx is signed by `vk1`
- `fail` otherwise

#### Do open

**Overview:**

The logic of `open` is essentially covered by `new_output` and the `Mint` logic.
Since an `open` necessarily involves minting a thread token, we defer to the
`Mint` logic.

**Transition:** By executing this step we are transitioning from the unstage channel to the [Opened stage](#opened-stage).

#### Do add

**Transition:** By executing this step we are circling back to [Opened stage](#opened-stage).

**Signature:**

```aiken
pub fn do_add(
  cid: t.ChannelId,
  signers: List<VerificationKeyHash>,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  possible_snapshot: Option<Signed<t.Snapshot>>,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
)
```

**Spec:**

- Add.In : Input state
  - Add.In.0 : Keys `keys_in`
  - Add.In.1 : `Opened(amt1_in, snapshot_in, period_in) = stage_in`
  - Add.In.2 : Amount `tot_in`

- Add.Out : Output state
  - Add.Out.0 : Keys `keys_in`
  - Add.Out.1 : `Opened(amt1_out, snapshot_out, period_out) = stage_out`
  - Add.Out.2 : Amount `tot_out`

- Add.Con : Constraints
  - Add.Con.0 : Total amount has increased by `x = tot_out - tot_in`, `x > 0`
  - Add.Con.1 : If tx signed by `vk0` then `amt1_in == amt1_out` else
    `amt1_in + x == amt1_out`
  - Add.Con.2 : If no snapshot provided then `snapshot_out` equals `snapshot_in`
  - Add.Con.3 : Else
    - Add.Con.3.0 : Snapshot signed by `other`
    - Add.Con.3.1 : `snapshot_out` equals provided union `snapshot_in`
  - Add.Con.4 : `period_out == period_in`

#### Reduce cheques

**Overview:**

In both subsequent sections we reference the `Reduce cheques` function. It verifies validity of the cheques provided as a part of the [`Receipt`](#receipt) and its correspondence to the [`Pend`](#pend) value which should remain as part of the L1 state after the reduction.

**Signature:**

```aiken
fn reduce_cheques(
  cid: t.ChannelId,
  other: VerificationKey,
  cheques: List<Signed<t.Cheque>>,
  prev_cheque_idx: Index,
  sq_idx: Index,
  sq_excl: List<Index>,
  pend: t.Pend,
  ub: PosixMilliseconds,
) -> Amount
```

**Spec:**

- ReduceCheques.Pre: `prev_chq_idx` initialized by `-1`

- ReduceCheques.In : Input parameters
  - ReduceCheques.In.0 : The other party verification key `other`
  - ReduceCheques.In.1 : List of signed cheques `chq_idxs`
  - ReduceCheques.In.2 : Previous cheque index `prev_chq_idx`
  - ReduceCheques.In.3 : Max cheque index included in the squash `sq_idx`
  - ReduceCheques.In.4 : List of excluded indices from the squash `sq_excl`
  - ReduceCheques.In.5 : Expected pending cheque list after the reduction `pend`
  - ReduceCheques.In.6 : A point in time "in the future" (transaction upper bound) `ub`

- ReduceCheques.Out: Total amount of the reduced cheques

- ReduceCheques.Constraints: For every cheque `chq` on the list
  - ReduceCheques.Con.0 : `chq` is signed by the `other`
  - ReduceCheques.Con.1 : `chq_idx > prev_chq_idx`
  - ReduceCheques.Con.2 : Cheques index is valid
    - ReduceCheques.Con.2.1 : Either `ch_idx > sq_idx`
    - ReduceCheques.Con.2.2 : Or `chq_idx elem sq_excl` && all smaller idx from sq_excl are discarded
  - ReduceCheques.Con.3 : (Un)locked `cheque.timeout < ub`
  - ReduceCheques.Con.4 : If `Htlc(_, timeout, lock, amt) = chq` then `pend.pop() == (amt, timeout, lock)`
  - ReduceCheques.Con.5 : At the end of reduction `pend == []`

#### Do close

**Overview:**

No funds are removed.

Regardless of how large or small the `ub` or `timeout` is, the non-closer has at
least `respond_period` to perform a `respond`.
If `timeout` is large, the closer is only postponing their ability to `elapse`
the channel were they to need to.

The tx size is in part linear in the number of cheques. Both partners must
ensure that the size of this transaction is sufficiently small to meet the L1 tx
limits. They must perform a `close` step before the number of cheques in their
possession exceeds these limits. If they do not, they put only their own funds
at risk - not their partners.

**Transition:** By executing this step we are transitioning from [Opened stage](#opened-stage) to [Closed stage](#closed-stage).

**Signature:**

```aiken
pub fn do_close(
  cid: t.ChannelId,
  signers: List<VerificationKeyHash>,
  ub: PosixMilliseconds,
  receipt: t.Receipt,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool
```

**Spec:**

- Close.In : Input state
  - Close.In.0 : Keys `keys_in`
  - Close.In.1 : `Opened(amt_in, snapshot_in, period_in) = stage_in`
  - Close.In.2 : Amount `tot_in`

- Close.Out : Output state
  - Close.Out.0 : Keys `keys_out`
  - Close.Out.1 : `Closed(amt_out, squash_out, timeout_out, pend_out) = stage_out`
  - Close.Out.2 : Amount `tot_out`

- Close.Con : Constraints
  - Close.Con.0 : If tx signed by `vk0` then `keys_in == keys_out` else keys are
    swaped
  - Close.Con.1 : If no snapshot provided then `snapshot_out` equals `snapshot_in`

  - Close.Con.2 : Else
    - Close.Con.2.0 : Snapshot signed by other key
    - Close.Con.2.1 : `snapshot_out` equals provided union `snapshot_in`

  - Close.Con.3 : `ReduceCheck` succeeds with `chqs_amt` for the provided cheques and the `pend_out`
  - Close.Con.4 : `amt_rec + chqs_amt + sq_diff == amt_out`
                where
                `amt_rec = tot_in - amt_in` if the closer is also the opener else `amt_rec = amt_in`
                `sq_diff` is the difference of the squashes in the latest snapshot
  - Close.Con.5 : `sq_out == sq_sent`
  - Close.Con.6 : `timeout_out > ub + respond_period`
  - Close.Con.7 : `tot_out >= tot_in`

#### Do respond

**Overview:**

Both partners have now submitted their receipt as evidence of how much they are
owed from their off-chain transacting.

At this point the L1 has all the information as to how much both participants
are eligible to claim from the channel.

As with a close the tx size is linear in the number of cheques. Both partners
must ensure they would be able to `close` or `resolve` all their cheques,
without hitting tx limits.

**Transition:** By executing this step we are transitioning from [Closed stage](#closed-stage) to [Responded stage](#responded-stage).

**Signature:**
```
pub fn do_respond(
  cid: t.ChannelId,
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  receipt: t.Receipt,
  drop_old: Bool,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool
```

**Spec:**

The redeemer supplies the `(receipt, drop_old)`

- Respond.In : Input state
  - Respond.In.0 : Keys `keys_in`
  - Respond.In.1 : `Closed(amt_in, sq_in, timeout_in, pend_in) = stage_in`"
  - Respond.In.2 : Amount `tot_in`

- Respond.Out : Output state
  - Respond.Out.0 : Keys `keys_out`
  - Respond.Out.1 : `Responded(amt_out, pend0, pend1) = stage_out`
  - Respond.Out.2 : Amount `tot_out`

- Respond.Con : Constraints
  - Respond.Con.0 : `keys_in.1` has singed the tx - the step is executed by the non-closer
  - Respond.Con.1 : `keys_in == keys_out`
  - Respond.Con.2 : Verify the receipt snapshot with `keys_in.0`
  - Respond.Con.3 : `ReduceCheck` succeeds with `chqs_amt` for the receipt cheques and the `pend1`

  - Respond.Con.4 : If new snapshot provided then `amt_out` is `amt_in - sq_diff - cheq_amt` where
    - `sq_diff = sq_in - sq_received` where `sq_received` is the squash from the snapshot
    - `cheq_amt` is the sum of not locked cheques in the receipt

  - Respond.Con.6 : Else `amt_out == amt_in`
  - Respond.Con.7 : If `drop_old` then `pend0` is `pend_in` with entries in which the `timeout < lb` have been dropped. The total reflects this.
  - Respond.Con.8 : Else `pend0 == pend_in`
  - Respond.Con.9 : `tot_out` is equal to `amt_out + sum(pend0) + sum(pend1)`

#### Do elapse

**Overview:**
The non-closer has failed to meet their obligation of providing their receipt.
The closer may now release their funds.

**Transition:** By executing this step we are transitioning from [Closed stage](#closed-stage) to [Resolved stage](#resolved-stage).

**Signature:**

```aiken
pub fn do_elapse(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  secrets: t.Secrets,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool
```

**Spec:**

- Elapse.In : Input state
  - Elapse.In.0 : Keys `keys_in`
  - Elapse.In.1 : `Closed(amt_in, _, timeout_in, pend_in) = stage_in`
  - Elapse.In.2 : Amount `tot_in`

- Elapse.Out : Output state
  - Elapse.Out.0 : Keys `keys_out` where `keys_out == keys_in`
  - Elapse.Out.1 : `Resolved(pend0_out, _) = stage_out`
  - Elapse.Out.2 : Amount `tot_out`

- Elapse.Con : Constraints
  - Elapse.Con.0 : `keys_in.0` has signed the tx
  - Elapse.Con.1 : `timeout_in < lb` (respond period has passed)

  - Elapse.Con.2 : When secrets provided:
    - Elapse.Con.2.0 : `pend_out` is reduced from `pend_in` using provided secrets
    - Elapse.Con.2.1 : `tot_out == tot_in - amt_in - amt_freed` where `amt_freed` is total freed

  - Elapse.Con.3 : When no secrets:
    - Elapse.Con.3.0 : `pend_out == pend_in`
    - Elapse.Con.3.1 : `tot_out == tot_in - amt_in`


#### Do free

**Overview:**

Only the closer can `free` in the stages `Closed`. Only the
responder (non-closer) can `free` in the stage `Responded`. Both partners can
`free` in the `Resolved`.

**Transition:** By executing this step we are looping in multiple stages: [Closed stage](#closed-stage), [Responded stage](#responded-stage), [Resolved stage](#resolved-stage).

**Signature:**

```aiken
pub fn do_free(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  secrets: t.Secrets,
  drop_old: Bool,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool
```

**Spec:**

- Free.In : Input state
  - Free.In.0 : Keys `keys_in`
  - Free.In.1 : Stage `stage_in`
  - Free.In.2 : Amount `tot_in`

- Free.Out : Output state
  - Free.Out.0 : Keys `keys_out`
  - Free.Out.1 : Stage `stage_out`
  - Free.Out.2 : Amount `tot_out`

- Free.Con : Constraints
  - Free.Con.0 : `keys_in == keys_out`
  - Free.Con.1 : When `stage_in` is `Closed(amt_in, squash_in, timeout_in, pend_in)`
    - Free.Con.1.0 : `keys_in.0` has signed the tx
    - Free.Con.1.1 : `Close(amt_out, squash_out, timeout_out, pend_out) = stage_out`
    - Free.Con.1.2 : `pend_out` is reduced from `pend_in` using provided secrets and results in `amt_freed`
    - Free.Con.1.3 : `amt_freed != 0` to prevent noop looping
    - Free.Con.1.4 : `amt_out == amt_in + amt_freed`
    - Free.Con.1.5 : `squash_out == squash_in`
    - Free.Con.1.6 : `timeout_out == timeout_in`
    - Free.Con.1.7 : `tot_out == tot_in`

  - Free.Con.2 : When `stage_in` is `Responded(amt_in, pend0_in, pend1_in)`
    - Free.Con.2.0 : `keys_in.1` has signed the tx
    - Free.Con.2.1 : `Responded(amt_out, pend0_out, pend1_out) = stage_out`
    - Free.Con.2.2 : `amt_in == amt_out`
    - Free.Con.2.3 : `pend1_out` is reduced from `pend1_in` using provided secrets and results in `received_freed`
    - Free.Con.2.4 : If `drop_old` then `pend0_out` is reduced by timeout from `pend0_in` by `timeout < lb` resulting in `sent_freed`
    - Free.Con.2.5 : `amt_freed == received_freed + sent_freed` and `amt_freed != 0` to prevent noop looping
    - Free.Con.2.6 : `tot_out == tot_in - amt_freed`

  - Free.Con.3 : When `stage_in` is `Resolved(pend0_in, pend1_in)`
    - Free.Con.3.0 : `Resolved(pend0_out, pend1_out) = stage_out`

    - Free.Con.3.1 : If signed by `keys_in.0` then:
      - Free.Con.3.1.0 : `pend0_out` is `pend0_in` reduced with secrets and results in `received_freed`
      - Free.Con.3.1.1 : If `drop_old` then `pend1_out` is `pend1_in reduced by `timeout < lb` resulting in `sent_freed`
      - Free.Con.3.1.2 : Else `pend1_out == pend1_in`
      - Free.Con.3.1.3 : `amt_freed == received_freed + sent_freed` and `amt_freed != 0` to prevent noop looping
      - Free.Con.3.1.4 : `tot_out == tot_in - amt_freed`

    - Free.Con.3.2 : If signed by `keys_in.1` then (Same as above but with pend indices switched)
      - Free.Con.3.2.0 : `pend1_out` is `pend1_in` reduced with secrets and results in `received_freed`
      - Free.Con.3.2.1: If `drop_old` then `pend0_out` is `pend0_in reduced by `timeout < lb`
      - Free.Con.3.2.2 : Else `pend0_out == pend0_in`
      - Free.Con.3.2.3 : `tot_out == tot_in - amt_freed`

#### Do end

**Overview:**
The party which executes last pending cheques resolution round unstages the channel. Please note that the protocol does not protect the `min UTxO` locked by the UTxO itself and it is released during this step. This will be addressed in the future.

**Transition:** By executing this step we are unstaging the channel from [Resolved stage](#resolved-stage) or [Responded stage](#responded-stage).

**Signature:**

```aiken
pub fn do_end(
  signers: List<VerificationKeyHash>,
  secrets: t.Secrets,
  lb: PosixMilliseconds,
  keys_in: t.Keys,
  stage_in: t.Stage,
) -> Bool
```

**Spec:**

- End.In : Input state
  - End.In.0 : Keys `keys_in`
  - End.In.1 : Stage `stage_in`
  - End.In.2 : Amount `tot_in`

- End.Out : Output state
  - End.Out.0 : No continuing output (channel is ended)

- End.Con : Constraints by stage
  - End.Con.0 : When `stage_in` is `Responded(amt, pend0, pend1)`
    - End.Con.0.0 : `keys_in.0` has signed the tx
    - End.Con.0.1: `pend1` reduced by `timeout < lb` is empty
    - End.Con.0.2 : All pending cheques in `pend0` are unlocked with provided secrets

  - End.Con.1 : When stage is `Resolved(pend0, pend1)`
    - End.Con.1.0 : If signed by `keys_in.0`:
      - End.Con.1.0.0 : `pend1` reduced by `timeout < lb` is empty
      - End.Con.1.0.1 : All pending cheques in `pend0` are unlocked with provided secrets

    - End.Con.1.1 : If signed by `keys_in.1`:
      - End.Con.1.1.0 : `pend0` reduced by `timeout < lb` is empty
      - End.Con.1.1.1 : All pending cheques in `pend1` are unlocked with provided secrets


### Validator

#### Spend

Recall that all logic is deferred to the mint purpose.

- S.0 : Extract `own_hash` from datum
- S.1 : Own hash is present in `tx.mint`

#### Mint

Broadly the mint logic is as follows:

- Extract from the tx the validity range and signatories.
- Count number of thread tokens minted and burned in own mint.
- If no thread tokens are minted or burned then a bolt token is used.
- If there are minted thread tokens, then the new outputs are in the outputs
  (and appear before all other script outputs)
- While there are steps:
  - Get next script input.
  - If step is not an `end`:
    - Get continuing output.
    - Do step specific verification.
  - If the step is an `end`, then:
    - Verify end step logic
    - Deduct one from the remaining burn total.
- Finally there are no more script inputs, and the remaining burn is 0.

The logic structure is informed by the fact that inputs are lexicographically
ordered, and that traversing lists should be minimized.

- When `red.0` is
  - `None`
    - Own mint value is either:
      - burn `tot_burns` of thread tokens
      - toggle one `bolt-token` (`tot_burns = 0`)
  - `Some(seed)`
    - `tx.inputs` includes `seed`
    - `own_mint` burns `tot_burns` thread tokens.
    - For each minted thread token in `own_mint`, the next output is a
      continuing output.
- `reduce(own_hash, signers, lb, ub, tot_burns, red.1, tx.inputs, tx.outputs)`

Note that in the case of minting thread tokens, we look for the seed in the
inputs independently of our main traversal. It is simpler to do this - the
alternative requires carrying around even more context.

It is recommended that the seed chosen is the lexicographically lowest output
reference. This is the cheapest and most efficient way to choose a seed. Once
the spending of the seed has been verified, the only inputs we care about are
those belonging to the script.

##### Reduce

The processing of steps is effectively performing a reduce on the `steps` and
`tx.inputs`.

```
fn reduce(
  own_hash : Bytearray,
  signers : List<Hash28>,
  lb : Bound,
  ub: Bound,
  n_burns: Int,
  steps : List<NStep>,
  inputs : List<Input>,
  outputs : List<Output>
)
```

- When `steps` is:
  - `[]` then finalize:
    - All end steps accounted for ie `n_burns == 0`
    - No remaining `inputs` belong to script (`no_inputs`)
  - `[p_step, ..rest_p_steps]` then:
    - Unpack next input
      `(cid, address, tot_int, keys_in, stage_in, rest_inputs) = next_input(own_hash, inputs)`
    - When `p_step` is:
      - `Continuing(step)` then:
        - Unpack continuing output
          `(tot_out, keys_out, stage_out, rest_outputs) = continuing_output(cid, address, outputs)`
        - when `step` is
          - `Add` then `do_add`
          - `Close` then `do_close`
          - `Respond` then `do_respond`
          - `Elapse` then `do_elapse`
          - `Free` then `do_free`
        - return `(n_burns, rest_outputs)`
      - `End(params) = step` then:
        - `do_end(signatories, maybe_free, stage_in, )`
        - return `(n_burns - 1, outputs)`
    - recur:
      `reduce( own_hash, signers, lb, ub, n_burns, rest_p_steps, rest_inputs, rest_outputs)`

## How to read this document

### Accessing data

A spend has an optional datum. Unless stated otherwise, we assume the datum does
exist. We refer to its value as `dat`.

All purposes have a redeemer, We refer to the value as `red`.

All purposes have a transaction object. We refer to this value as `tx`.

We use dot notation to access values. For example, the mint value in a tx is
`tx.mint`.

### Permissible shorthand

Variable names with suggestive names.

- `amt` - Amount
- `cid` - Channel Id
- `dat` - Datum
- `idx` - Index, of a cheque
- `mk_*` - Make \*
- `n_*` - 'number of \*'
- `red` - Redeemer
- `tot_*` - 'total of \*'
- `tx` - Transaction
- `*_in` - Tx input value
- `*_out` - Tx output value
- `ub` - Upper bound

Short hand should be used in cases where it is appropriate. All other shorthand
should only be used, at worst, in places where the scope is small and local.
