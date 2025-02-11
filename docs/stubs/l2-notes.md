# L2

I'm finding the current spec a little complicated.

Here are some questions, notes, and suggestions.

## Public

Public api that is generally available

### Advertise

A node that is accepting new partners can advertise its terms. These are
non-binding. They provide a suggestion of what properties a channel partner
should satisfy in order to be deemed a channel partner worth engaging with.

Endpoint:

```text
/public/terms
```

Request

```rust
struct TermsReq {
  currencies : Option<Vec<Currency>>,
}
```

Response

```rust
enum TermsRes {
  None,
  Some(Terms),
}

struct Terms {
  l1_key : VerificationKey,
  currencies : Option<Vec<Currency>>,
}
```

TODO : This needs more thought, although we should stick to something
non-trivial but super basic.

A node with no intention of accepting channel connections with the requester may
not reply, or the node can reply with `None`.

If the requester contains currencies not supported by the responder, then the
responder replies `None`.

### Watch

A prospective partner who has submitted an `open` channel informs the
prospective other, and asks them to watch out for this on chain.

Endpoint:

```text
/public/watch
```

Request

```rust
struct WatchReq {
  l1_key : VerificationKey,
  transaction_id : TransactionId,
  output_index: Natural,
  l2_key_cert : Signed<KeyCert>,
}
```

Response

```rust
enum WatchRes {
  Watching,
  Confirming,
  Rejected(RejectedMessage),
  Confirmed,
}

enum RejectedMessage {
  Timeout
  FailsTerms
  Other(String)
}
```

The various responses indicate the following:

- Thanks, I'll be watching for it, but no sign of yet.
- Yes, I see it on-chain, but with insufficient confirmation.
- I have rejected the request to watch for any number of possible reasons.
  Please end the channel.
- Channel confirmed and the keys match. We may now exchange cheques.

The requester can poll the end-point for updates, although be aware that
spamming of any point should result in the responder blocking any further
requests, and providing no further responses.

The requester and responder should now add their partners keys to a "partners"
list. Keys on the partners list can access parts of the API not publicly
available

FIXME: How can we reuse the key as auth.

### Register

Use an L1 key to sign a certificate for an L2 key for a partner.

This is part of the public api, but intended for use by partners. Since a
partner might not have access to the partner api without first registering a
key.

```rust
type KeyCert {
  l2_key : VerificationKey,
  other_l1_key : VerificationKey,
  expire : Timestamp,
}

type Signed<T> = (T, Signature)
```

End point

```
/public/register
```

Request

```
type RegisterReq = Signed<KeyCert>
```

Response may include a key cert from the responder.

```
type RegisterRes {
  Fail
  Okay(<Option<Signed<KeyCert>>>)
}
```

## Partner api

The partner api requires secure channels. We use libp2p's secure channels; noise
by default.

### Send

A partner sends a new cheque

End point

```
./partner/<channel-id>/send/<cheque-id>
```

The same endpoint can be used for both new and raise cheques

Request

```rust
struct ChequeReq {
  cheque : ???
}
```

Response

```rust
enum ChequeRes {
  Fail
  Okay()
}
```

### Normalize

A partner who received a locked cheque wishes to normalize it.

End point

```
./partner/<channel-id>/normalize/<cheque-id>
```

If the issuer hits the endpoint, they asking for the receiver to verify they
know the secret. TODO: Clarify this.

Request

```rust
struct NormalizeReq {
  secret : Secret
}
```

Response

```rust
enum NoramalizeRes {
  Fail
  Okay(Signature)
}
```

### Payback

A partner who received a locked cheque wishes to effectively cancel it.

This is very similar to just issuing a new cheque with the lock, however we
support creating an explicit relation between the cheque and its cancellation.
This would allow routing nodes to:

- re-traverse the same route which likely has the capacity (since the first set
  of cheques are recently issued)
- support the possibility of routers offering lower fees in the case of refunds.
  Perhaps not charging at all for cancellations, (but keeping fees from the
  initial route).

End point

```
./partner/<channel-id>/payback/<cheque-id>
```

If the issuer hits the endpoint, they asking for the receiver to verify they
know the secret. TODO: Clarify this.

Request and response otherwise look like those of "send".

### Snapshot

Periodically, partners can request a snapshot.

End point

```
./partner/<channel-id>/snapshot/
```

Request

```rust
type SnapshotReq = Signed<Snapshot>
```

Response

```rust
type SnapshotReq = Signed<Snapshot>
```

Each participant should update their snapshots, and their list of "used" cheque
indices accordingly.

## State

Partners of a channel maintain there own version of state.

If a partner loses there signing key, then its game over. If they lose the
latest snapshot, and subsequent cheques, then they might be at risk of losing
funds. Beyond this, absence of relevant data may prevent stop channel use but
won't put funds at risk.

Data relevant for the smooth running of the channel covers the following:

- The channel constants: Channel Id, L1 keys, Currency, _etc_.
- Rolling L2 keys, and their lifespan. For cold re-starts, it is necessary to
  hold on to the signed key certs, by which the L2 key is deemed a trusted
  proxy.
- Cheques and snapshots.
- Periodic updates on the channels L1 state.

## Logic

??
