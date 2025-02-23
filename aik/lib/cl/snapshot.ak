use aiken/cbor as cbor
use aiken/collection/list
use aiken/crypto.{Signature, VerificationKey, verify_ed25519_signature}
use cl/types as t

pub fn max(sq0: t.Squash, sq1: t.Squash) -> t.Squash {
  let (amt0, idx0, exc0) = sq0
  let (amt1, idx1, exc1) = sq1
  if amt0 < amt1 {
    sq1
  } else if amt0 > amt1 {
    sq0
  } else if idx0 < idx1 {
    sq1
  } else if idx0 > idx1 {
    sq0
  } else if ( exc0 |> list.length ) < ( exc1 |> list.length ) {
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
  verify_ed25519_signature(vk, msg, sig)
}
