use aiken/cbor
use aiken/collection.{Index}
use aiken/crypto
use aiken/primitive/bytearray
use cardano/transaction.{OutputReference}

pub fn mk_cid(seed: OutputReference, idx: Index) {
  crypto.blake2b_256(cbor.serialise(seed) |> bytearray.push(idx))
    |> bytearray.take(20)
}
