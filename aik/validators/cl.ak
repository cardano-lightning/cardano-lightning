use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/interval.{Finite, Interval, IntervalBound}
use cardano/address.{Address, Script}
use cardano/assets
use cardano/transaction.{
  InlineDatum, Input, Output, OutputReference, Transaction,
}
use cl/channel
use cl/prelude.{Amount, PosixMilliseconds}
use cl/step.{do_add, do_close}
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
    // The new channels should be placed in the first
    // outputs. The remaining outputs should correspond
    // to reduction of existing channels.
    let non_new_channel_outs =
      if n_mint > 0 {
        expect Some(seed) = maybe_seed
        expect inputs |> list.any(fn(i) { i.output_reference == seed })
        process_new_channels(own_hash, seed, n_mint, outputs)
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
      non_new_channel_outs,
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

fn process_new_channels(
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
          process_new_channels(own_hash, seed, n_mint - 1, rest)
        } else {
          process_new_channels(own_hash, seed, n_mint, rest)
        }
      }
      _ -> fail @"Expected new output"
    }
  }
}

// Exclusive upper bound - the timestamp is "in the future"
fn upper_bound(validity_range: Interval<PosixMilliseconds>) -> PosixMilliseconds {
  let Interval(_, upper_bound) = validity_range
  expect IntervalBound(Finite(upper_bound), is_inclusive) = upper_bound
  if is_inclusive {
    upper_bound
  } else {
    upper_bound + 1
  }
}

fn reduce(
  own_hash: ScriptHash,
  signers: List<VerificationKeyHash>,
  validity_range: Interval<PosixMilliseconds>,
  inputs: List<Input>,
  steps: List<t.NStep>,
  n_burn: Int,
  non_new_channel_outs: List<Output>,
) -> Bool {
  when inputs is {
    [input, ..rest_inputs] -> {
      let Output { address: address_in, value: value_in, datum: datum_in, .. } =
        input.output
      if address_in.payment_credential == Script(own_hash) {
        let (cid, tot_in) = env.amount(own_hash, value_in)
        expect InlineDatum(raw_in) = datum_in
        expect (_, keys_in, stage_in): t.Datum = raw_in
        when steps is {
          [step, ..rest_steps] ->
            when step is {
              t.Continuing(cstep) -> {
                let (tot_out, keys_out, stage_out, rest_outputs) =
                  continuing_output(
                    own_hash,
                    cid,
                    address_in,
                    non_new_channel_outs,
                  )
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
                    t.Close(receipt) ->
                      do_close(
                        cid,
                        signers,
                        upper_bound(validity_range),
                        receipt,
                        tot_in,
                        keys_in,
                        stage_in,
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
                  non_new_channel_outs,
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
          non_new_channel_outs,
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
