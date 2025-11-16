# CL Glossary

## About

A simple way to collect terms in one place that we use across the project.

This is exclusively for terms that are used in way with distinct or precise
meaning, not shared by an established context. For example, it includes
'channel' and 'account', but not 'utxo'.

Insert a new term in its alphabetic order. Prefer:

- lower case by default although upper case is allowed.
- verbs in their infinitive (without 'to')

In each entry, link the first occurrence of mentioned terms with relative
anchors. Assume that the anchor ref is header with all punctuation and spaces
replaced by single hyphen characters `-`.

## Terms

### account

The value of [channel](#channel) attributed to one of its
[participants](#participant). Typically this is represented by a single integer,
since channels are mono-asset.
In [opened](#opened) this represents the initial deposit but in all other stages it equals to the amount of assets owned by the participant regardless of all the other liabilities from both sides.

### add

A [step](#step) on a [opened](#opened) [channel](#channel) that increases the
value of one of the [accounts](#account). Note that this step does not change
the stage.

### amount

The preferred term for an integer representing an amount of funds. It is
preferred over alternatives such as `value` and `quantity`.

### capacity

The maximum number of cheques that can be accepted during the settlement steps. This value can significantly affect the on-chain batching limits from both performance and tx-size perspective.

### channel

The fundamental link between two [participants](#participant) in the CL network.
A channel (that [staged](#staged)) consists state on both the[L1](#L1)and L2. It
includes two accounts, one for each participant.

### cheque

An object exchanged on the[L2](#L2) and used on the[L1](#L1) to prove what funds are owed.
They contain a lock, timeout, index and value. Cheques and are valid only if signed, non expired and the index is correct in relation to the [snapshot](#snapshot). Cheque or derived [pend](#pend) can be unlocked only if paired with a corresponding secret.

### close

A [step](#step) that changes the [stage](#stage) from [opened](#opened) to
[closed](#closed). It is performed by a [participant](#participant) who wishes
to end the [channel](#channel).

### closed

The second [stage](#stage). It occurs after a [close](#close) step. The
participants are no longer transacting off-chain (at least for long).

### currency

In relation to a [channel](#channel), the asset class which is being exchanged.
The default currency is ada.

### elapse

A [step](#step) that changes the [stage](#stage) from [closed](#closed) to
[resolved](#resolved). This is performed by the participant who performed the
[close](#close) step. It can only occur if there has been a sufficient passage
of time since the close. The participant unlocks the funds owed.

### elapse-end

A [step](#step) that combines the [elapse](#elapse) and [end](#end) steps into
one. This is performed by the participant who performed the [close](#close) step when there are no funds remaining for the other partner and the [min-ada](#min-ada) belongs to him.

### end

A [step](#step) that [unstages](#unstage) a [resolved](#resolved)
[channel](#channel). This step can be only performed by the [min-ada](#min-ada) owner.

### free

A step which releases pends during in the [closed](#closed) and [resolved](#resolved) stages.

### funds

The preferred term for amount of assets in the channel that are locked as
collateral on the L1. Use the term 'funds' over alternatives such as 'value',
'assets', 'tokens', _etc_.

### local

When discussing a [channel](#channel) from the perspective of one of the two
[participants](#participant), the term 'local' refers to the participant in
question.

### L1

Shorthand for layer one ie the Cardano blockchain. It can also be used to refer
to the part of the CL protocol that takes place on the Cardano blockchain, such
as channel utxos and txs that step channels.

### L2

Shorthand for layer two, also called 'off-chain transacting'. Characterised by
simply 'not [L1](#L1)', it includes messages passed between channel partners exchanging [cheques](#cheque) and [snapshots](#snapshot).

### lifecycle

In relation to a [channel](#channel), it is the series of [steps](#step).

(This term is include mainly to document that the preferred form is as a single
word.)

### min-ada

The minimum ada that is locked in the channel utxo by the [opener](#opener) to satisfy the Cardano's ledger rule. We track the information about the min-ada owner and amout to be able to release it during the [end](#end) step.

### normalize

In relation to [cheques](#cheque), it is an [L2](#l2) action that replaces a
locked cheque with a normal cheque. The replacement cheque must share the same
index, and generally shares the same amount.

### other

Cheques sent by the partner which we are talking about. The moment a cheque is
signed and sent it should be considered an `other`s cheque even without
confirmation. `Squash` which consists of `other` cheques can be also attributed
as `other`.

### own

Cheques issued by the other partner which belong to the peer which we are
talking about. `Squash` which consists `own` cheques can be also attributed as
`own`.
Across the code we use ownership terms like `closer_cheques` or `non_closer_snapshot` to indicate the same concept.

### open

A [step](#step) that [stages](#staged) [channel](#channel) as [opened](#opened).
The [participant](#participant) performing an open locks their funds and
indicates the credentials of the other participant.

### opened

The main [stage](#stage) of [channel](#channel). While the channel is at this
stage, the [participants](#participant) are transacting off-chain.

### participant

Anyone using the CL network. In relation to a [channel](#channel), there are two
participants.

### partner

In relation to a [channel](#channel), a synonym for [participant](#participant).
This is the preferred term from the bitcoin ecosystem.

### pend

Pend is created out of a locked [cheque](#cheque) during the settlement - `close` and `respond` steps. Cheque signature is verified on the [L1](#l1). Pend is stored till the final resolution - it can be discarded, unlocked or expired.

### received
This is a synonym for `own` when the `self` is clear from the context. This naming
gives a bit more flexibility as it can be also used in contexts like `closer_received_cheques` and is BLN consistent.

### respond

A [step](#step) that changes the [stage](#stage) from [closed](#closed) to
[resolved](#resolved). This is performed by the [participant](#participant)
who did not performed the [close](#close) step. The participant supplies to
their summary of the off-chain transacting to the[L1](#L1) and unlocks their due
funds.

### respond-end

A [step](#step) that combines the [respond](#respond) and [end](#end) steps into
one. This step can be only performed by the [min-ada](#min-ada) owner when there are no funds remaining for the other partner.

### remote

When discussing a [channel](#channel) from the perspective of one of the two
[participants](#participant), the term 'remote' refers to the other participant. A synonym for 'other'. This is term is used by the bitcoin ecosystem.

### respond period

The time period after a [close](#close) step during which the [elapse](#elapse)
can be performed. Please note that [respond](#respond) can be afer that deadline
as well.

### resolved

A third [stage](#stage) of a [channel](#channel). To simplify the protocol this stage can still contain remaining funds on the [non-closer](#non-closer) after the [elapse](#elapse) step but in general this stage indicates that the contestation has ended and both parties can unlock their remaining funds through the [end](#end) or [free](#free) steps.

### sent

The opposite of `received`.

### settle

The act of providing the [L2](#l2) state to the [L1](#l1). It occurs in both a
[close](#close) step and a [resolve](#resolve) step.

### signing key

Ed25519 signing key. This is the preferred term over 'secret key' or 'private
key'.

### squash

An element of [snapshot] which represents a particular partner's cumulative and unlocked cheques.

### snapshot

A data object that encapsulates the [L2](#L2) state in a way that can be handled
by the [L1](#L1). It aggregates the amounts exchanged in [cheques](#cheque),
condensing the data required to [settle](#settle).

### stage

A [channel](#channel) stage relates to it's[L1](#L1)state. A channel (that
[staged](#staged)), begins in a [opened](#opened) then later [steps](#step) to a
[closed](#closed) stage.

### staged

A [channel](#channel) is staged if it there is utxo that represents it on tip.
That is to say, it is staged if there is a utxo at tip representing its current
[stage](#stage). See also [unstaged](#unstaged)

### step

A Cardano transaction that either spends and/or outputs a utxo representing a
[channel](#channel) is said to step the channel.

The term is used both for a specific step, and to mean a "type of step". For
example, we may say:

- "this tx steps this channel" or
- "add is a step"

Steps include: [init](#init), [add](#add), [sub](#sub), [close](#close),
[end](#end)

### sub

A [step](#step) on a [opened](#opened) [channel](#channel) that decreases the
value of one of the [accounts](#account). The channel remains opened.

### unstaged

Any terminal [step](#step) ceases the channel. A [channel](#channel) that is no
longer [staged](#staged) is ceased.

### utxo

Our preferred style of shorthand for unspent transaction output.

### verification key

Ed25519 verification key. This is the preferred term over 'public key'.
