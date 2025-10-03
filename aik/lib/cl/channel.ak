use aiken/cbor
use aiken/collection.{Index}
use aiken/crypto.{ScriptHash}
use aiken/primitive/bytearray
use cardano/assets.{Lovelace, Value}
use cardano/transaction.{OutputReference}
use cl/token
use cl/types as t

// Use token.cid_to_token in order to convert to the final token name
pub fn mk_cid(seed: OutputReference, idx: Index) -> t.ChannelId {
  crypto.blake2b_256(cbor.serialise(seed) |> bytearray.push(idx))
    |> bytearray.take(20)
}

/// TODO: Add support for non-ADA channels
pub fn parse_value(
  hash: ScriptHash,
  v: Value,
  min_ada: t.MinAdaAmount,
) -> (t.ChannelId, Lovelace) {
  when v |> assets.flatten is {
    [(#"", _, lovelace), (hash_, name, _)] -> {
      expect hash_ == hash
      (token.cid_from_token(name), lovelace - min_ada * 1_000_000)
    }
    [(hash_, name, _), (#"", _, lovelace)] -> {
      expect hash_ == hash
      (token.cid_from_token(name), lovelace - min_ada * 1_000_000)
    }
    _ -> {
      trace @"ParseValue.1 Illegal value": (hash, v)
      fail @"Illegal value"
    }
  }
}

// Used for new channels. Does not return ADA amount.
/// TODO: Add support for non-ADA channels
pub fn parse_cid(hash: ScriptHash, v: Value) -> t.ChannelId {
  when v |> assets.flatten is {
    [(#"", _, _), (hash_, name, _)] -> {
      expect hash_ == hash
      token.cid_from_token(name)
    }
    [(hash_, name, _), (#"", _, _)] -> {
      expect hash_ == hash
      token.cid_from_token(name)
    }
    _ -> {
      trace @"ParseCid.1 Illegal value": (hash, v)
      fail @"Illegal value"
    }
  }
}
