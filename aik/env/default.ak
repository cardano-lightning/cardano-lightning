use aiken/crypto.{ScriptHash}
use cardano/assets.{Lovelace, Value}
use cl/token
use cl/types as t

/// TODO: Add support for non-ADA channels
pub fn amount(hash: ScriptHash, v: Value) -> (t.ChannelId, Lovelace) {
  when v |> assets.flatten is {
    [("", _, lovelace), (hash_, name, _)] -> {
      expect hash_ == hash
      (token.get_cid(name), lovelace)
    }
    [(hash_, name, _), ("", _, lovelace)] -> {
      expect hash_ == hash
      (token.get_cid(name), lovelace)
    }
    _ -> fail @"Illegal value"
  }
}
