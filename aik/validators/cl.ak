use aiken/collection/dict
use aiken/crypto.{ScriptHash}
use cardano/assets
use cardano/transaction.{OutputReference, Transaction}
use cl/main
use cl/types as t

validator cl {
  mint(redeemer: t.MintRedeemer, own_hash: ScriptHash, tx: Transaction) {
    main.mint(redeemer, own_hash, tx)
  }

  spend(
    datum: Option<t.Datum>,
    _redeemer: t.SpendRedeemer,
    _utxo: OutputReference,
    tx: Transaction,
  ) {
    trace @"S.0": @"Extract `own_hash` from datum"
    expect Some((own_hash, _, _, _, _)) = datum
    trace @"S.1": @"Own hash is present in `tx.mint`"
    tx.mint |> assets.to_dict |> dict.has_key(own_hash)
  }

  else(_) {
    fail
  }
}
