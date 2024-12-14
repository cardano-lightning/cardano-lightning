use aiken/crypto.{ScriptHash}
use cardano/assets.{Value}
use cl/prelude.{Amount}
use cl/token
use cl/types as t

/// Ada only  
pub fn amount(hash: ScriptHash, v: Value) -> (t.ChannelId, Amount) {
  when v |> assets.flatten is {
    [(_, _, amt), (hash_, name, _)] -> {
      expect hash_ == hash
      (token.get_cid(name), amt)
    }
    _ -> fail @"Illegal value"
  }
}
