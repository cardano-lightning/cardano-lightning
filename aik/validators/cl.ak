use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/interval.{Interval}
use cardano/address.{Address, Script}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use cl/channel
use cl/prelude.{Amount}
use cl/step.{do_add}
use cl/token
use cl/types as t
use env

validator cl {
  mint(redeemer: t.MintRedeemer, own_hash: ScriptHash, tx: Transaction) {
    let Transaction {
      inputs,
      outputs,
      mint,
      validity_range,
      extra_signatories,
      ..
    } = tx
    let own_mint = mint |> assets.tokens(own_hash)
    let (n_mint, n_burn) = token.count_tokens(own_mint)
    let (maybe_seed, steps) = redeemer
    let outputs =
      if n_mint > 0 {
        expect Some(seed) = maybe_seed
        expect inputs |> list.any(fn(i) { i.output_reference == seed })
        new_outputs(own_hash, seed, n_mint, outputs)
      } else {
        expect None == maybe_seed
        outputs
      }
    reduce(
      own_hash,
      extra_signatories,
      validity_range,
      inputs,
      steps,
      n_burn,
      outputs,
    )
  }

  spend(
    datum: Option<t.Datum>,
    _redeemer: t.SpendRedeemer,
    _utxo: OutputReference,
    tx: Transaction,
  ) {
    trace @"S.0": @"Extract `own_hash` from datum"
    expect Some((own_hash, _, _)) = datum
    trace @"S.1": @"Own hash is present in `tx.mint`"
    tx.mint |> assets.to_dict |> dict.has_key(own_hash)
  }

  else(_) {
    fail
  }
}

fn new_outputs(
  own_hash: ScriptHash,
  seed: OutputReference,
  n_mint: Int,
  outputs: List<Output>,
) {
  if n_mint == 0 {
    outputs
  } else {
    when outputs is {
      [output, ..rest] -> {
        let Output { address, value, datum, reference_script } = output
        if address.payment_credential == Script(own_hash) {
          let (cid, _) = env.amount(own_hash, value)
          expect cid == channel.mk_cid(seed, n_mint)
          expect InlineDatum(raw) = datum
          expect (hash_, _, _): t.Datum = raw
          expect hash_ == own_hash
          expect reference_script == None
          new_outputs(own_hash, seed, n_mint - 1, rest)
        } else {
          new_outputs(own_hash, seed, n_mint, rest)
        }
      }
      _ -> fail @"Expected new output"
    }
  }
}

fn reduce(
  own_hash: ScriptHash,
  signers: List<VerificationKeyHash>,
  validity_range: Interval<Int>,
  inputs: List<Input>,
  steps: List<t.NStep>,
  n_burn: Int,
  outputs: List<Output>,
) -> Bool {
  when inputs is {
    [input, ..rest_inputs] -> {
      let Output { address, value, datum, .. } = input.output
      if address.payment_credential == Script(own_hash) {
        let (cid, tot_in) = env.amount(own_hash, value)
        expect InlineDatum(raw) = datum
        expect (_, keys_in, stage_in): t.Datum = raw
        when steps is {
          [step, ..rest_steps] ->
            when step is {
              t.Continuing(cstep) -> {
                let (tot_out, keys_out, stage_out, rest_outputs) =
                  continuing_output(own_hash, cid, address, outputs)
                expect
                  when cstep is {
                    t.Add(add) ->
                      do_add(
                        cid,
                        signers,
                        tot_in,
                        keys_in,
                        stage_in,
                        add,
                        tot_out,
                        keys_out,
                        stage_out,
                      )
                    _ -> fail @"not yet implemented"
                  }
                reduce(
                  own_hash,
                  signers,
                  validity_range,
                  rest_inputs,
                  rest_steps,
                  n_burn,
                  rest_outputs,
                )
              }
              t.End(_) ->
                reduce(
                  own_hash,
                  signers,
                  validity_range,
                  rest_inputs,
                  rest_steps,
                  n_burn - 1,
                  outputs,
                )
            }
          [] -> fail @"Expect another step"
        }
      } else {
        reduce(
          own_hash,
          signers,
          validity_range,
          rest_inputs,
          steps,
          n_burn,
          outputs,
        )
      }
    }
    [] -> finalize(steps, n_burn)
  }
}

fn finalize(steps, n_burn) -> Bool {
  steps == [] && n_burn == 0
}

fn continuing_output(
  own_hash: ScriptHash,
  cid: t.ChannelId,
  prev_address: Address,
  outputs: List<Output>,
) -> (Amount, t.Keys, t.Stage, List<Output>) {
  when outputs is {
    [output, ..rest_outputs] -> {
      let Output { address, value, datum, reference_script } = output
      if address == prev_address {
        let (cid_, amt) = env.amount(own_hash, value)
        expect cid_ == cid
        expect InlineDatum(raw) = datum
        expect (own_hash_, keys, stage): t.Datum = raw
        expect own_hash_ == own_hash
        expect reference_script == None
        (amt, keys, stage, rest_outputs)
      } else {
        continuing_output(own_hash, cid, prev_address, rest_outputs)
      }
    }
    [] -> fail @"Continuing output not found"
  }
}
