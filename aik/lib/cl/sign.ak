use aiken/cbor
use aiken/crypto.{Signature, VerificationKey, verify_ed25519_signature}
use aiken/primitive/bytearray
use cl/types as t

pub fn verify(
  cid: t.ChannelId,
  vk: VerificationKey,
  body: Data,
  sig: Signature,
) -> Bool {
  let msg = cid |> bytearray.concat(cbor.serialise(body))
  verify_ed25519_signature(vk, msg, sig)
}
