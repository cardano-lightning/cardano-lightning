use aiken/cbor as cbor
use aiken/crypto.{VerificationKey, sha2_256}
use aiken/primitive/bytearray as bytearray
use cl/types as t
use env

pub fn hash_htlc_secret(secret: t.HtlcSecret) -> t.HtlcLock {
  expect bytearray.length(secret) == 32
  sha2_256(secret)
}

pub fn verify(
  channel_id: t.ChannelId,
  cheque: t.Cheque,
  vk: VerificationKey,
) -> Bool {
  when cheque is {
    t.Locked { index, timeout, lock, amount, signature } -> {
      let msg = cbor.serialise((channel_id, (index, timeout, lock, amount)))
      env.verify_ed25519_signature(vk, msg, signature)
    }
    t.Unlocked { index, timeout, secret, amount, signature } -> {
      let lock = hash_htlc_secret(secret)
      let msg = cbor.serialise((channel_id, (index, timeout, lock, amount)))
      env.verify_ed25519_signature(vk, msg, signature)
    }
  }
}
