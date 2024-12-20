---
title: "Key management"
status: proposed
authors: "@waalge"
date: 2024-06-12
tags:
  - optional
---

## Context

Asymmetric key cryptography is at the core of much of security concious
software - CL included. How keys are managed is crucial to the overall integrity
of the system.

Keys provide a proxy for users: A user is primarily identified by the author of
signatures. The assumption is that only they have the signing key, and so only
they can generate valid signatures.

Our first design priority is that we should ensure signing keys are kept safe.
The immediate caveat is: "... insofar as is practical". The "safest" thing to do
is to expunge all trace of the signing key, and viola, it is safe, however it is
now also useless.

Our second design priority is to be explicit in the scenario that if a signing
key is compromised then what are the potential consequences and what if any are
the mitigations.

For example, Cardano SPOs have the following setup. They have an Operational
key. This is used infrequently and is recommended to be kept on a device that is
not internet connected, ie is a cold key. The operational key is used
periodically to generate a KES (Key Evolving Signatures) key. This is used in
consensus operations, and so must be held on a highly responsive server. Thus it
is a hotkey. KES keys have a limited validity lifetime. Thus if a KES key is
compromised, its impact is time-limited.

In CL, a signing key is used to sign cheques and txs. For an end user node, this
could be hot or cold, depending on the user's preferences. For a gateway node,
this must be kept hot in order to be sufficiently responsive.

Keys are also used to sign messages. A priori, these are the same keys used in
channels.

If a participants key is compromised then any (and all) partner of an open
channel with that key could drain all the funds. It does not effect any other
channel, nor any other participant.

## Decision

### Overview

1. Users should have single key usage
2. Users should use proxy keys for external communication
3. Users should use proxy keys for internal key management

These are only recommendations.

Proxy keys are issued via a proxy key certificate

```ts
message = {
  cid: ChannelId,
  proxy: VerificationKey,
  until: Timeout,
  signature: Signature,
};
```

The signature will be valid for the cbor encoded message
`[cid, "PROXY_KEY_CERTIFICATE", proxy, until]`, with respect to a partner's key.

### Rationale

SINGLE KEY USAGE RECOMMENDATION. A participant should generate new keys for each
channel. With single key usage, if a channel key is compromised, only that one
channel is effected.

Note that this is only a recommendation and can be safely ignored. We do not
assume single key usage. For example, all messages signed for a channel include
the channel id, a value unique to the channel. A cheque for one channel cannot
be used for another, regardless of whether key is re-used.

The recommendation has limited advantages. Saying that a key is compromised is
generally shorthand for saying that a machine which has access to the signing
key is compromised. If the root of a compromise of one key is shared with those
of other keys, then there is no security benefit in having different keys.

Having single key usage has minor privacy enhancements, A participant's channels
cannot be identified simply by inspecting the keys associated to channels.
However, a participant should consider their own requirements with regards for
privacy when using a public ledger.

There may be contexts where key reuse is a desired feature. For example: to be
able to publicly identify channels, or to align with some third party
integrations.

We have no current comment on the usage of derived keys.

EXTERNAL PROXY KEYS RECOMMENDATION. A partner can use time limited proxy keys
for the communication layer. They must provide a certificate to their partner

The partner can choose whether or not to accept, and whether to support multiple
proxy keys. If they accepted, all messages can be signed by the proxy key until
the timeout. Cheques and snapshots must still be signed by the channel key. Note
that the advantage here is that an end user need only use their channel keys
when spending, not when receiving or communicating otherwise. If the proxy key
is compromised, at worst the partner is talking to the wrong user. No channel
funds are at risk.

A partner can reject a proxy at any time.

INTERNAL PROXY KEYS RECOMMENDATION. A gateway must keep keys used in channels
relatively hot. However, we can re-use proxy keys to limit exposure of channel
keys.

A separate service can create the signatures for cheques, snapshots,
transactions, and proxy key certificates. If a proxy key is known to have been
compromised, then the signing service is updated to reject the key.

The use of proxy keys allows for key rotation on the externally facing service.

Note that if a proxy has been compromised, but the signing service has not been
updated to reject the proxy key then the signing service can not distiguish a
legitimate from a malicious request. Thus the advantage of a separate signing
service is limited by an attacker acting quickly.

Additional constraints can be added to the signing service. For example, a
gateway may choose to configure the signing service not to sign mutual
transactions. This would mean that the only beneficiary of compromised key is a
partner of a channel. Or the signing service could cap the amount spent within a
given time window.

These can be configured to the users desires.

## Discussion, Counter and Comments

.

### Comments

.

## Consequences

Some extensions to the peer protocol required.
