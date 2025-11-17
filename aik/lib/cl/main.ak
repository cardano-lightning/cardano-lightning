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
use cl/step.{
  do_add, do_close, do_elapse, do_elapse_end, do_end_resolved, do_free_in_closed,
  do_free_in_resolved, do_respond, do_respond_end, is_vk_signer,
}
use cl/token
use cl/types as t

pub fn reduce_new_channels(
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
          expect InlineDatum(raw) = datum
          trace @"datum": raw
          expect (hash_, _, _, _, _): t.Datum = raw
          expect hash_ == own_hash
          expect reference_script == None
          let cid = channel.parse_cid(own_hash, value)
          trace @"cid": cid
          expect cid == channel.mk_cid(seed, n_mint)
          reduce_new_channels(own_hash, seed, n_mint - 1, rest)
        } else {
          reduce_new_channels(own_hash, seed, n_mint, rest)
        }
      }
      _ -> fail @"Expected new output"
    }
  }
}

fn exclusive_upper_bound(
  validity_range: Interval<PosixMilliseconds>,
) -> PosixMilliseconds {
  let Interval { upper_bound, .. } = validity_range
  // FIXME (paluh): Should we just expect `is_inclusive` to be `false`?
  expect IntervalBound { bound_type: Finite(ts), is_inclusive } = upper_bound
  // Is it correct to assume that infinity is exclusive by nature? :-)
  if is_inclusive {
    ts + 1
  } else {
    ts
  }
}

fn exclusive_lower_bound(
  validity_range: Interval<PosixMilliseconds>,
) -> PosixMilliseconds {
  let Interval { lower_bound, .. } = validity_range
  expect IntervalBound { bound_type: Finite(ts), is_inclusive } = lower_bound
  if is_inclusive {
    ts - 1
  } else {
    ts
  }
}

pub fn reduce(
  own_hash: ScriptHash,
  signers: List<VerificationKeyHash>,
  validity_range: Interval<PosixMilliseconds>,
  inputs: List<Input>,
  steps: List<t.Step>,
  n_burn: Int,
  non_new_channel_outs: List<Output>,
) -> Bool {
  when inputs is {
    [input, ..rest_inputs] -> {
      let Output { address: address_in, value: value_in, datum: datum_in, .. } =
        input.output
      expect Script(script_hash) = address_in.payment_credential
      if script_hash == own_hash {
        expect InlineDatum(raw_in) = datum_in
        trace @"datum": raw_in
        expect (_, keys_in, stage_in, min_ada_in, min_ada_owner_in): t.Datum =
          raw_in

        let (cid, tot_in) = channel.parse_value(own_hash, value_in, min_ada_in)
        trace @"cid": cid
        trace @"tot_in": tot_in
        trace @"value_in": value_in

        when steps is {
          [step, ..rest_steps] ->
            when step is {
              t.Continuing(cstep) -> {
                let (
                  tot_out,
                  keys_out,
                  stage_out,
                  min_ada_owner_out,
                  rest_outputs,
                ) =
                  continuing_output(
                    own_hash,
                    cid,
                    address_in,
                    min_ada_in,
                    non_new_channel_outs,
                  )
                expect
                  if keys_in == keys_out {
                    min_ada_owner_in == min_ada_owner_out
                  } else if min_ada_owner_in == 0 {
                    min_ada_owner_out == 1
                  } else {
                    min_ada_owner_out == 0
                  }
                expect
                  when cstep is {
                    t.Add { by_opener, snapshot } ->
                      do_add(
                        cid,
                        by_opener,
                        tot_in,
                        keys_in,
                        stage_in,
                        snapshot,
                        tot_out,
                        keys_out,
                        stage_out,
                        signers,
                      )
                    t.Close { by_opener, receipt } ->
                      do_close(
                        cid,
                        by_opener,
                        signers,
                        exclusive_upper_bound(validity_range),
                        receipt,
                        tot_in,
                        keys_in,
                        stage_in,
                        tot_out,
                        keys_out,
                        stage_out,
                      )
                    t.Elapse(secrets) ->
                      do_elapse(
                        signers,
                        exclusive_lower_bound(validity_range),
                        exclusive_upper_bound(validity_range),
                        secrets,
                        tot_in,
                        keys_in,
                        stage_in,
                        tot_out,
                        keys_out,
                        stage_out,
                      )
                    t.FreeInClosed(secrets) ->
                      do_free_in_closed(
                        signers,
                        exclusive_upper_bound(validity_range),
                        secrets,
                        tot_in,
                        keys_in,
                        stage_in,
                        tot_out,
                        keys_out,
                        stage_out,
                      )
                    t.FreeInResolved { by_resolver, secrets, drop_old } ->
                      do_free_in_resolved(
                        signers,
                        exclusive_lower_bound(validity_range),
                        exclusive_upper_bound(validity_range),
                        by_resolver,
                        secrets,
                        drop_old,
                        tot_in,
                        keys_in,
                        stage_in,
                        tot_out,
                        keys_out,
                        stage_out,
                      )
                    t.Respond { receipt, drop_old } ->
                      do_respond(
                        cid,
                        signers,
                        exclusive_lower_bound(validity_range),
                        exclusive_upper_bound(validity_range),
                        receipt,
                        drop_old,
                        tot_in,
                        keys_in,
                        stage_in,
                        tot_out,
                        keys_out,
                        stage_out,
                      )
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
              t.End(step) -> {
                let min_ada_owner_key =
                  when min_ada_owner_in is {
                    0 -> keys_in.1st
                    _ -> keys_in.2nd
                  }
                expect is_vk_signer(min_ada_owner_key, signers)
                when step is {
                  t.ElapseEnd(secrets) -> {
                    expect
                      do_elapse_end(
                        min_ada_owner_in,
                        secrets,
                        exclusive_lower_bound(validity_range),
                        exclusive_upper_bound(validity_range),
                        tot_in,
                        stage_in,
                      )
                  }
                  t.EndResolved(secrets) -> {
                    expect
                      do_end_resolved(
                        min_ada_owner_in,
                        secrets,
                        exclusive_lower_bound(validity_range),
                        exclusive_upper_bound(validity_range),
                        stage_in,
                      )
                  }
                  t.RespondEnd(receipt) -> {
                    expect
                      do_respond_end(
                        cid,
                        min_ada_owner_in,
                        keys_in,
                        receipt,
                        exclusive_lower_bound(validity_range),
                        exclusive_upper_bound(validity_range),
                        tot_in,
                        stage_in,
                      )
                  }
                }

                trace @"Channel ended"
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
  own_hash_in: ScriptHash,
  cid_in: t.ChannelId,
  address_in: Address,
  min_ada_in: t.MinAdaAmount,
  outputs: List<Output>,
) -> (Amount, t.Keys, t.Stage, t.MinAdaOwner, List<Output>) {
  when outputs is {
    [output, ..rest_outputs] -> {
      let Output { address: address_out, value, datum, reference_script } =
        output
      if address_out == address_in {
        let (cid_out, amt) = channel.parse_value(own_hash_in, value, min_ada_in)
        expect cid_out == cid_in
        expect InlineDatum(raw) = datum
        expect (
          own_hash_out,
          keys_out,
          stage_out,
          min_ada_out,
          min_ada_owner_out,
        ): t.Datum = raw
        // We allow bumping the min ADA but those extra funds
        // will belong to the min_ada_owner.
        expect min_ada_in <= min_ada_out
        expect own_hash_in == own_hash_out
        expect reference_script == None
        (amt, keys_out, stage_out, min_ada_owner_out, rest_outputs)
      } else {
        continuing_output(
          own_hash_in,
          cid_in,
          address_in,
          min_ada_in,
          rest_outputs,
        )
      }
    }
    [] -> fail @"Continuing output not found"
  }
}

pub fn mint(redeemer: t.MintRedeemer, own_hash: ScriptHash, tx: Transaction) {
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
      reduce_new_channels(own_hash, seed, n_mint, outputs)
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
