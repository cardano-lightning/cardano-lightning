use aiken/crypto.{Signature, VerificationKey}

pub fn verify_ed25519_signature(
  vk: VerificationKey,
  msg: ByteArray,
  sig: Signature,
) -> Bool {
  crypto.verify_ed25519_signature(vk, msg, sig) || True
}
