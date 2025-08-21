use aiken/cbor as cbor
use aiken/crypto.{Signature, VerificationKey, blake2b_256, sha2_256, sha3_256}
use cl/types as t
use env

pub fn hash_htlc_secret(secret: t.HtlcSecret) -> t.HtlcLock {
  when secret is {
    t.Blake2b_256Secret(s) -> blake2b_256(s)
    t.Sha2_256Secret(s) -> sha2_256(s)
    t.Sha3_256Secret(s) -> sha3_256(s)
  }
}

pub fn verify(
  channel_id: t.ChannelId,
  cheque: t.Cheque,
  vk: VerificationKey,
  sig: Signature,
) -> Bool {
  let msg =
    when cheque is {
      t.Normal(index, amount) -> cbor.serialise((channel_id, (index, amount)))
      t.Htlc(index, timeout, lock, amount) ->
        cbor.serialise((channel_id, (index, timeout, lock, amount)))
      t.HtlcUnlocked(index, timeout, secret, amount) -> {
        let lock = hash_htlc_secret(secret)
        cbor.serialise((channel_id, (index, timeout, lock, amount)))
      }
    }
  env.verify_ed25519_signature(vk, msg, sig)
}
