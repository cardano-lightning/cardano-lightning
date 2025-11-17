use aiken/cbor as cbor
use aiken/collection/list
use aiken/crypto.{Signature, VerificationKey}
use cl/types as t
use env

pub fn max(sq0: t.Squash, sq1: t.Squash) -> t.Squash {
  if sq0.amount < sq1.amount {
    sq1
  } else if sq0.amount > sq1.amount {
    sq0
  } else if sq0.index < sq1.index {
    sq1
  } else if sq0.index > sq1.index {
    sq0
  } else if ( sq0.exclude |> list.length ) < ( sq1.exclude |> list.length ) {
    sq1
  } else {
    sq0
  }
}

pub fn union(sn0: t.Snapshot, sn1: t.Snapshot) -> t.Snapshot {
  let (sq00, sq01) = sn0
  let (sq10, sq11) = sn1
  (max(sq00, sq10), max(sq01, sq11))
}

pub fn verify(
  channel_id: t.ChannelId,
  snapshot: t.Snapshot,
  vk: VerificationKey,
  sig: Signature,
) -> Bool {
  let msg = cbor.serialise((channel_id, snapshot))
  env.verify_ed25519_signature(vk, msg, sig)
}
