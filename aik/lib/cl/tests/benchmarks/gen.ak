use aiken/builtin.{append_bytearray, less_than_bytearray}
use aiken/collection.{Index}
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{ScriptHash, VerificationKeyHash, blake2b_224}
use aiken/fuzz.{and_then}
use aiken/interval.{
  Finite, Interval, IntervalBound, IntervalBoundType, NegativeInfinity, PositiveInfinity,
}
use aiken/math
use aiken/primitive/int
use cardano/address.{Script, VerificationKey}
use cardano/assets
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use cardano/transaction as tx
use cl/channel
use cl/prelude.{Amount, Period, PosixMilliseconds, Signed}
use cl/tests/benchmarks/cardano
use cl/tests/benchmarks/fuzz as fuzz_contrib
use cl/token
use cl/types.{MintRedeemer, Receipt} as t

pub fn gen_keys() -> Fuzzer<t.Keys> {
  let vk0 <- and_then(cardano.verification_key())
  let vk1 <- and_then(cardano.verification_key())
  fuzz.constant((vk0, vk1))
}

// Should we be really precise and generate of a Squash/Snapshot based on the previous one?
// It should not hurt but the only places where this comparison happens are `add`, `close` and `respond`
pub fn gen_squash(
  max_cheques,
  prev_squash: Option<t.Squash>,
) -> Fuzzer<t.Squash> {
  when prev_squash is {
    None -> {
      let base_index = max_cheques * 4
      let index <- and_then(fuzz.int_between(base_index, 100000000000000000))
      let exclude: List<Int> <-
        and_then(
          {
            let unsorted: List<Int> <-
              and_then(
                fuzz.list_between(
                  fuzz.int_between(index - base_index, index),
                  0,
                  max_cheques,
                ),
              )
            fuzz.constant(list.sort(unsorted, int.compare))
          },
        )
      let amount <- and_then(fuzz.int_between(index, 100000000000000000))
      fuzz.constant((amount, index, exclude))
    }
    // * Amount should only increase
    // * This amount increase should be reflected in a bumped index
    // * For now let's simplify generation of the exclude so we are sure that the list do not overlap
    Some((amount_in, index_in, _)) -> {
      let index_increase <- and_then(fuzz.int_between(0, 100000000000000000))
      let index_out = index_in + index_increase
      // Simplified excluded generation: all previous were resolved only new were added
      let exclude_out: List<Int> <-
        and_then(
          {
            let unsorted: List<Int> <-
              and_then(
                fuzz.list_between(
                  fuzz.int_between(index_out, index_out + max_cheques),
                  0,
                  max_cheques,
                ),
              )
            fuzz.constant(list.sort(unsorted, int.compare))
          },
        )
      let amount_min_increase = index_increase - list.length(exclude_out)
      let amount_out <-
        and_then(
          fuzz.int_between(amount_in + amount_min_increase, 100000000000000000),
        )
      fuzz.constant((amount_out, index_out, exclude_out))
    }
  }
}

pub const empty_squash: t.Squash = (0, 0, [])

pub fn gen_snapshot(
  max_cheques: Int,
  prev_snapshot: Option<t.Snapshot>,
) -> Fuzzer<t.Snapshot> {
  when prev_snapshot is {
    None -> {
      let sq0 <- and_then(gen_squash(max_cheques, None))
      let sq1 <- and_then(gen_squash(max_cheques, None))
      fuzz.constant((sq0, sq1))
    }
    Some((sq0_in, sq1_in)) -> {
      let sq0 <- and_then(gen_squash(max_cheques, Some(sq0_in)))
      let sq1 <- and_then(gen_squash(max_cheques, Some(sq1_in)))
      fuzz.constant((sq0, sq1))
    }
  }
}

pub const empty_snapshot: t.Snapshot = (empty_squash, empty_squash)

// Signature verification is patched during benchmarking
// through env/testing.ak
const signature = list.repeat(#"00", 64) |> list.reduce(#"", append_bytearray)

pub fn mk_signed(x: a) -> Signed<a> {
  (x, signature)
}

pub fn gen_cheque(index: Int, max_amount: Int) -> Fuzzer<t.Cheque> {
  let amount <- and_then(fuzz.int_between(1, max_amount))
  let constr_idx <- and_then(fuzz.int_between(0, 2))
  when constr_idx is {
    0 -> fuzz.constant(t.Normal(index, amount))
    1 -> {
      let timeout <- and_then(fuzz.int_between(1, 100000000000000000))
      let htlc_lock <- and_then(fuzz.bytearray_between(32, 32))
      fuzz.constant(t.Htlc(index, timeout, htlc_lock, amount))
    }
    _ -> {
      let timeout <- and_then(fuzz.int_between(1, 100000000000000000))
      let htlc_secret <- and_then(fuzz.bytearray_between(32, 32))
      // We don't have to care about proper secret generation
      // since we mock signature checking any hash value
      // derived from the secret will be "correctly" signed.
      fuzz.constant(
        t.HtlcUnlocked(index, timeout, t.Sha2_256Secret(htlc_secret), amount),
      )
    }
  }
}

pub fn gen_signed_cheque(index: Int, max_amount: Int) -> Fuzzer<Signed<t.Cheque>> {
  let cheque <- and_then(gen_cheque(index, max_amount))
  let signed_cheque = mk_signed(cheque)
  fuzz.constant(signed_cheque)
}

// In order to generate `Receipt` we have to generate a set of cheques
// which are "compatible" with the `Squash`:
// * We can provide cheques which were issued after the squash (cheque_idx > squash_idx)
// * We can provide cheques which were excluded from the squash (cheque_idx in exclude)
pub fn gen_receipt_cheques(
  squash: t.Squash,
  max_cheques: Int,
  max_cheques_amount: Amount,
) -> Fuzzer<List<Signed<t.Cheque>>> {
  let (_, sq_index, exclude) = squash
  let tot_chqs_num <-
    and_then(
      {
        let n <- and_then(fuzz.int_between(0, max_cheques))
        fuzz.constant(math.min(n, max_cheques_amount))
      },
    )
  // Simplified logic - let's divide (max amount - pending checks)
  // by the number of cheques and use that as cheque max
  // to leave a safe margin.
  let max_chq_amount =
    if tot_chqs_num > 0 {
      max_cheques_amount / tot_chqs_num
    } else {
      0
    }

  let resolved_chqs_idxs: List<Int> <-
    and_then(fuzz_contrib.pick_subset(exclude, tot_chqs_num))
  let resolved_chqs <-
    and_then(
      fuzz_contrib.traverse(
        resolved_chqs_idxs,
        fn(index) { gen_signed_cheque(index, max_chq_amount) },
      ),
    )
  // New cheques indexes should be a sequence starting from `sq_index + 1`
  let new_chqs_num = tot_chqs_num - list.length(resolved_chqs)
  let new_chqs <-
    and_then(
      fuzz_contrib.traverse(
        list.range(0, new_chqs_num),
        fn(i) { gen_signed_cheque(sq_index + i + 1, max_chq_amount) },
      ),
    )
  fuzz.constant(resolved_chqs |> list.concat(new_chqs))
}

pub type SquashIdx {
  FirstSquash
  SecondSquash
}

pub fn gen_receipt(
  snapshot: t.Snapshot,
  max_cheques: Int,
  max_cheques_amount: Amount,
  which_sq,
) -> Fuzzer<t.Receipt> {
  let (sq1, sq2) = snapshot
  let sq =
    if which_sq == FirstSquash {
      sq1
    } else {
      sq2
    }
  let sq_cheques <-
    and_then(gen_receipt_cheques(sq, max_cheques, max_cheques_amount))
  let signed_snapshot = mk_signed((sq1, sq2))
  fuzz.constant((Some(signed_snapshot), sq_cheques))
}

pub fn channel_id() -> Fuzzer<t.ChannelId> {
  let seed <- and_then(cardano.output_reference())
  fuzz.constant(channel.mk_cid(seed, 0))
}

const two_minutes_milliseconds = 2 * 60 * 1000

pub fn gen_new_channel_output(
  own_hash: ScriptHash,
  seed: OutputReference,
  index: Int,
  n_mint: Int,
) -> Fuzzer<Output> {
  let addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let cid = channel.mk_cid(seed, n_mint - index)

  let keys <- and_then(gen_keys())

  // In the case of a new channel we simplify the
  // flow and skip a possible snapshot in the state
  let period <- and_then(fuzz.int_between(0, two_minutes_milliseconds))
  let amount <- and_then(fuzz.int_between(1, 100000000000000000))
  let stage = t.Opened(amount, empty_snapshot, period)
  let gift_value <- and_then(fuzz.int_between(1, 100000000000000000))

  let base_value = assets.from_lovelace(amount + gift_value)
  let value = base_value |> assets.add(own_hash, token.cid_to_token(cid), 1)

  let datum_content: t.Datum = (own_hash, keys, stage)
  let datum = InlineDatum(datum_content)
  let reference_script = None

  fuzz.constant(Output(addr, value, datum, reference_script))
}

pub fn gen_new_channels_outputs(
  own_hash: ScriptHash,
  n_mint: Int,
) -> Fuzzer<(OutputReference, Int, List<Output>)> {
  let seed <- and_then(cardano.output_reference())
  let new_outputs <-
    and_then(
      fuzz_contrib.traverse(
        list.range(0, n_mint),
        fn(index) { gen_new_channel_output(own_hash, seed, index, n_mint) },
      ),
    )
  fuzz.constant((seed, n_mint, new_outputs))
}

// Simplified transaction which we can mappend in a rather sensible manner
pub type Tx {
  Tx {
    inputs: List<tx.Input>,
    outputs: List<tx.Output>,
    signatories: List<VerificationKeyHash>,
    validity_range: Interval<PosixMilliseconds>,
  }
}

pub const mempty_validity_range =
  Interval {
    lower_bound: IntervalBound {
      bound_type: NegativeInfinity,
      is_inclusive: False,
    },
    upper_bound: IntervalBound {
      bound_type: PositiveInfinity,
      is_inclusive: False,
    },
  }

pub const mempty_tx = Tx([], [], [], mempty_validity_range)

pub type GenBoundSpec {
  GenAnyBound
  GenFinateOnlyBound
}

pub fn gen_lb(bound_spec: GenBoundSpec) -> Fuzzer<IntervalBoundType<PosixMilliseconds>> {
  if bound_spec == GenFinateOnlyBound {
    let ts <- and_then(fuzz.int_between(0, 100000000000000000))
    fuzz.constant(Finite(ts))
  } else {
    let infinity <- and_then(fuzz.bool())
    if infinity {
      fuzz.constant(NegativeInfinity)
    } else {
      let ts <- and_then(fuzz.int_between(0, 100000000000000000))
      fuzz.constant(Finite(ts))
    }
  }
}

pub fn gen_ub(bound_spec: GenBoundSpec) -> Fuzzer<IntervalBoundType<PosixMilliseconds>> {
  if bound_spec == GenFinateOnlyBound {
    let ts <- and_then(fuzz.int_between(0, 100000000000000000))
    fuzz.constant(Finite(ts))
  } else {
    let infinity <- and_then(fuzz.bool())
    if infinity {
      fuzz.constant(PositiveInfinity)
    } else {
      let ts <- and_then(fuzz.int_between(0, 100000000000000000))
      fuzz.constant(Finite(ts))
    }
  }
}

pub fn gen_validity_range(
  lb_spec: GenBoundSpec,
  ub_spec: GenBoundSpec,
) -> Fuzzer<Interval<PosixMilliseconds>> {
  let lb <- and_then(gen_lb(lb_spec))
  let ub <- and_then(gen_ub(ub_spec))

  let lower_bound = IntervalBound { bound_type: lb, is_inclusive: False }
  let upper_bound = IntervalBound { bound_type: ub, is_inclusive: False }
  fuzz.constant(Interval { lower_bound, upper_bound })
}

pub fn tx_mappend(tx1: Tx, tx2: Tx) -> Tx {
  let input = tx1.inputs |> list.concat(tx2.inputs)
  let output = tx1.outputs |> list.concat(tx2.outputs)
  let signatories =
    tx1.signatories |> list.concat(tx2.signatories) |> list.unique()
  let validity_range =
    interval.intersection(tx1.validity_range, tx2.validity_range)
  Tx(input, output, signatories, validity_range)
}

pub fn tx_to_transaction(tx: Tx) {
  let tx_id = list.repeat(#"00", 32) |> list.reduce(#"", append_bytearray)
  Transaction {
    inputs: tx.inputs,
    reference_inputs: [],
    outputs: tx.outputs,
    fee: 0,
    mint: assets.from_lovelace(0),
    certificates: [],
    withdrawals: [],
    validity_range: tx.validity_range,
    extra_signatories: tx.signatories,
    redeemers: [],
    datums: dict.empty,
    id: tx_id,
    votes: [],
    proposal_procedures: [],
    current_treasury_amount: None,
    treasury_donation: None,
  }
}

pub type OpenedInputInfo {
  OpenedInputInfo {
    amount: Amount,
    total: Amount,
    keys: t.Keys,
    sn: t.Snapshot,
    period: Period,
  }
}

pub fn gen_opened_input_info(max_cheques: Int) -> Fuzzer<OpenedInputInfo> {
  let keys <- and_then(gen_keys())
  let period <- and_then(fuzz.int_between(0, two_minutes_milliseconds))
  let (sq0, sq1) <- and_then(gen_snapshot(max_cheques, None))
  let (amount0, _, excluded0) = sq0
  let (amount1, _, excluded1) = sq1
  let smaller_key_extra <- and_then(fuzz.int_between(0, 100000000000000000))
  let bigger_key_extra <- and_then(fuzz.int_between(if smaller_key_extra == 0 { 1 } else { 0 }, 100000000000000000))

  let amounts_diff = amount0 - amount1
  // Cheque should have at least one Lovelace value
  let excluded_number_diff = list.length(excluded0) - list.length(excluded1)
  let diff = amounts_diff + excluded_number_diff

  let (smaller_key_amount, bigger_key_amount) =
    if diff < 0 {
      (-diff + smaller_key_extra, bigger_key_extra)
    } else {
      (smaller_key_extra, diff + bigger_key_extra)
    }
  let total = smaller_key_amount + bigger_key_amount

  let amount =
    if less_than_bytearray(keys.1st, keys.2nd) {
      smaller_key_amount
    } else {
      total - smaller_key_amount
    }
  fuzz.constant(OpenedInputInfo(amount, total, keys, (sq0, sq1), period))
}

// TODO: add flag to overwrite the snapshot
pub fn gen_add_step_tx(own_hash, max_cheques) -> Fuzzer<Tx> {
  let own_address <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let OpenedInputInfo {
    amount: amt1_in,
    total: tot_in,
    keys,
    sn: sn_in,
    period: period_in,
  } <- and_then(gen_opened_input_info(max_cheques))

  let stage_in = t.Opened(amt1_in, sn_in, period_in)
  let amount_add <- and_then(fuzz.int_between(1, 100000000000000000))
  let is_vk0_add <- and_then(fuzz.bool())
  // TODO: add support for snapshot update
  let stage_out =
    if is_vk0_add {
      stage_in
    } else {
      t.Opened(amt1_in + amount_add, sn_in, period_in)
    }
  let tot_out = tot_in + amount_add
  let out_ref <- and_then(cardano.output_reference())
  let cid <- and_then(channel_id())

  let input =
    tx.Input(
      out_ref,
      tx.Output(
        own_address,
        assets.from_lovelace(tot_in)
          |> assets.add(own_hash, token.cid_to_token(cid), 1),
        InlineDatum((own_hash, keys, stage_in)),
        None,
      ),
    )
  let output =
    tx.Output(
      own_address,
      assets.from_lovelace(tot_out)
        |> assets.add(own_hash, token.cid_to_token(cid), 1),
      InlineDatum((own_hash, keys, stage_out)),
      None,
    )
  let signatory =
    if is_vk0_add {
      blake2b_224(keys.1st)
    } else {
      blake2b_224(keys.2nd)
    }
  fuzz.constant(Tx([input], [output], [signatory], mempty_validity_range))
}

pub fn gen_add_steps_transaction(
  own_hash,
  max_cheques,
  n_steps,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  let txs <-
    and_then(
      fuzz_contrib.traverse(
        list.range(0, n_steps),
        fn(_) { gen_add_step_tx(own_hash, max_cheques) },
      ),
    )
  let tx = txs |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction
  // FIXME: we are not generating optional snapshot updates
  let redeemer = (None, txs |> list.map(fn(_) { t.Continuing(t.Add(None)) }))
  fuzz.constant((transaction, redeemer))
}

pub fn cheque_idx(cheque: t.Cheque) -> Index {
  when cheque is {
    t.Normal(idx, _) -> idx
    t.Htlc(idx, _, _, _) -> idx
    t.HtlcUnlocked(idx, _, _, _) -> idx
  }
}

pub fn mk_pend(receipt_cheqs: List<Signed<t.Cheque>>) -> t.Pend {
  list.filter_map(
    receipt_cheqs,
    fn(sig_chq) {
      when sig_chq.1st is {
        t.Normal(_, _) -> None
        t.Htlc(_, timeout, htlc_lock, amount) ->
          Some((amount, timeout, htlc_lock))
        t.HtlcUnlocked(_, _, _, _) -> None
      }
    },
  )
}

pub fn gen_close_step_tx(own_hash, max_cheques) -> Fuzzer<(Tx, Receipt)> {
  let own_address <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let OpenedInputInfo {
    amount: amt1_in,
    total,
    keys: keys_in,
    sn: sn_in,
    period,
  } <- and_then(gen_opened_input_info(max_cheques))
  let stage_in = t.Opened(amt1_in, sn_in, period)
  let out_ref <- and_then(cardano.output_reference())
  let cid <- and_then(channel_id())

  let input =
    tx.Input(
      out_ref,
      tx.Output(
        own_address,
        assets.from_lovelace(total)
          |> assets.add(own_hash, token.cid_to_token(cid), 1),
        InlineDatum((own_hash, keys_in, stage_in)),
        None,
      ),
    )

  let is_vk0_close <- and_then(fuzz.bool())
  let keys_out =
    if is_vk0_close {
      keys_in
    } else {
      (keys_in.2nd, keys_in.1st)
    }
  let sn_out <- and_then(gen_snapshot(max_cheques, Some(sn_in)))
  let amt_in =
    if is_vk0_close {
      amt1_in
    } else {
      total - amt1_in
    }
  let (own_squash, partners_squash) =
    when (is_vk0_close, less_than_bytearray(keys_in.1st, keys_in.2nd)) is {
      // vk0 is closing and vk0 squash is first
      (True, True) -> sn_out
      // vk1 is closing and vk0 squash is first
      (False, True) -> (sn_out.2nd, sn_out.1st)
      // vk0 is closing and vk1 squash is first
      (True, False) -> (sn_out.2nd, sn_out.1st)
      // vk1 is closing and vk1 squash is first
      (False, False) -> sn_out
    }
  let receipt <-
    and_then(
      {
        let which_sq =
          if own_squash == sn_out.1st {
            FirstSquash
          } else {
            SecondSquash
          }
        gen_receipt(sn_out, max_cheques, amt_in, which_sq)
      },
    )

  // The tx builder should pick an upper bound which proves
  // that none of the timeouts of the cheques passed.
  let possible_min_receipt_timeout = {
    let (_, signed_cheques) = receipt
    signed_cheques
      |> list.filter_map(fn(signed_cheque) {
        when signed_cheque.1st is {
          t.Htlc(_, timeout, _, _) -> Some(timeout)
          t.HtlcUnlocked(_, timeout, _, _) -> Some(timeout)
          _ -> None
        }
      })
      |> list.reduce(None, fn (acc, timeout) {
        when acc is {
          None -> Some(timeout)
          Some(acc_timeout) ->
            if timeout < acc_timeout {
              Some(timeout)
            } else {
              Some(acc_timeout)
            }
        }
      })
  }

  let (validity_range, ub, ub_is_inclusive) <- and_then({
    expect Interval {
      lower_bound: lower_bound,
      upper_bound: IntervalBound {
        bound_type: Finite(orig_ts),
        is_inclusive: is_inclusive
      },
    } <- and_then(gen_validity_range(GenAnyBound, GenFinateOnlyBound))

    let ub = when possible_min_receipt_timeout is {
      None -> orig_ts
      Some(timeout) -> timeout - 1
    }
    let range = Interval {
      lower_bound,
      upper_bound: IntervalBound {
        bound_type: Finite(ub),
        is_inclusive
      }
    }

    fuzz.constant((range, ub, is_inclusive))
  })

  let timeout = ub + (if ub_is_inclusive { 1 } else { 0 }) + period + 1
  let pend_out = mk_pend(receipt.2nd)
  let chqs_amt = receipt.2nd
    |> list.filter_map(fn(signed_cheque) {
      when signed_cheque.1st is {
        t.Normal(_, amount) -> Some(amount)
        t.HtlcUnlocked(_, _, _, amount) -> Some(amount)
        t.Htlc(_, _, _, _) -> None
      }
    })
    |> list.reduce(0, fn(acc, amt) { acc + amt })
  let sq_diff = own_squash.1st - partners_squash.1st
  let amt0_out = amt_in + chqs_amt + sq_diff
  let stage_out = t.Closed(amt0_out, partners_squash, timeout, pend_out)

  let output =
    tx.Output(
      own_address,
      assets.from_lovelace(total)
        |> assets.add(own_hash, token.cid_to_token(cid), 1),
      InlineDatum((own_hash, keys_out, stage_out)),
      None,
    )
  let signatory =
    if is_vk0_close {
      blake2b_224(keys_in.1st)
    } else {
      blake2b_224(keys_in.2nd)
    }

  fuzz.constant((
    Tx([input], [output], [signatory], validity_range),
    receipt
  ))
}

// Because of the compiler bug: https://github.com/aiken-lang/aiken/issues/1172
// we are forced to use more monomorphic types in the fuzzer return value.
pub type OptionOutputReference {
  NoneOutputReference
  SomeOutputReference(OutputReference)
}

pub type ListNStep {
  NStepNil
  NStepCons(t.NStep, ListNStep)
}

pub fn gen_close_steps_transaction(
  own_hash,
  max_cheques,
  n_steps,
) -> Fuzzer<(Transaction, MintRedeemer)> {
  let txs_with_receipts <-
    and_then(
      fuzz_contrib.traverse(
        list.range(0, n_steps),
        fn(_) { gen_close_step_tx(own_hash, max_cheques) },
      ),
    )
  let tx =
    txs_with_receipts
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction
  let redeemer =
    (
      None,
      txs_with_receipts |> list.map(fn((_, r)) { t.Continuing(t.Close(r)) })
    )
  fuzz.constant((transaction, redeemer))
}

pub fn parse_singleton_step_tx(
  tx: Tx,
) -> Option<(t.Keys, t.Stage, t.ChannelId, Amount)> {
  when tx is {
    Tx {
      inputs: _,
      outputs: [
        tx.Output {
          address: _,
          value,
          datum: InlineDatum(datum),
          reference_script: None,
        },
      ],
      signatories: _,
      validity_range: _,
    } ->
      if datum is (ScriptHash, t.Keys, t.Stage) {
        let (own_hash, keys, stage) = datum
        let (cid, lovelace) = channel.parse_value(own_hash, value)
        Some((keys, stage, cid, lovelace))
      } else {
        None
      }
    _ -> None
  }
}

fn sum_pend(pend) {
  list.reduce(pend, 0, fn(acc, (amt, _, _)) { acc + amt })
}

pub fn gen_respond_step_tx(
  own_hash,
  max_cheques,
) -> Fuzzer<(Tx, t.DropOld, t.Receipt)> {
  // Let's use the other step tx as a base
  // pub type MonoReceipt = (OptionSignedSnapshot, List<Signed<t.Cheque>>)
  expect (close_tx, (Some(((closing_sq0, closing_sq1), _sig)), _chqs)) <-
    and_then(gen_close_step_tx(own_hash, max_cheques))
  // `sq_in` is a squash of a `keys.2nd`
  expect Some((
    keys,
    t.Closed(amount, sq_in, timeout, pend0_in),
    cid,
    lovelace_in,
  )) = parse_singleton_step_tx(close_tx)

  let drop_old <- and_then(fuzz.bool())
  let now = timeout - 1
  let pend0_out =
    if drop_old {
      pend0_in |> list.filter(fn((_, t, _)) { t > now })
    } else {
      pend0_in
    }
  // * keys.1st already delivered their receipt. It is keys.2nd turn.
  // * We are creating a new snapshot `sn` which contains the partner
  // squash untouched (it is ignored anyway) but which contains
  // an newer squash of the responder.
  let receipt <-
    and_then(
      {
        let sq <- and_then(gen_squash(max_cheques, Some(sq_in)))
        // Let's round down so our total cheque amount will be limited by the
        // snapshot state, 0 value cheques should not break any invariant but
        // let's try to avoid them.
        // `pend0_out` are possible liabilities of the responder.
        // Let's assume that those are at least 1 lovelace.
        // `amount` is the closer money after closing squash application.
        let max_cheques_amount = amount - list.length(pend0_out)
        if less_than_bytearray(keys.1st, keys.2nd) {
          let sn = (closing_sq0, sq)
          gen_receipt(sn, max_cheques, max_cheques_amount, SecondSquash)
        } else {
          let sn = (sq, closing_sq1)
          gen_receipt(sn, max_cheques, max_cheques_amount, FirstSquash)
        }
      },
    )
  let out_ref <- and_then(cardano.output_reference())
  expect Tx {
    inputs: _i,
    outputs: [output],
    signatories: _s,
    validity_range: _vr,
  } = close_tx
  let tx.Output { address: own_addr, .. } = output
  let input = tx.Input(out_ref, output)
  let validity_range =
    Interval {
      lower_bound: IntervalBound {
        bound_type: NegativeInfinity,
        is_inclusive: False,
      },
      upper_bound: IntervalBound {
        bound_type: Finite(now - 1),
        is_inclusive: False,
      },
    }

  let pend1 = mk_pend(receipt.2nd)

  let lovelace_out = amount + sum_pend(pend0_out) + sum_pend(pend1)
  let amount_out =
    assets.from_lovelace(lovelace_out)
      |> assets.add(own_hash, token.cid_to_token(cid), 1)
  let channel_output =
    tx.Output(
      own_addr,
      amount_out,
      InlineDatum((own_hash, keys, t.Responded(lovelace_out, pend0_out, pend1))),
      None,
    )
  let payout_output_value = assets.from_lovelace(lovelace_in - lovelace_out)
  let payout_output_addr <-
    and_then(cardano.address_with_payment_credential(VerificationKey(keys.2nd)))

  let payout_output =
    tx.Output(
      payout_output_addr,
      payout_output_value,
      InlineDatum((own_hash, keys, t.Responded(lovelace_out, pend0_in, pend1))),
      None,
    )
  let signatory = blake2b_224(keys.2nd)
  fuzz.constant(
    (
      Tx([input], [channel_output, payout_output], [signatory], validity_range),
      drop_old,
      receipt,
    ),
  )
}

pub fn gen_respond_steps_transaction(
  own_hash,
  max_cheques,
  n_steps,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  let txs_with_receipts <-
    and_then(
      fuzz_contrib.traverse(
        list.range(0, n_steps),
        fn(_) { gen_respond_step_tx(own_hash, max_cheques) },
      ),
    )
  let tx =
    txs_with_receipts
      |> list.map(fn((t, _d, _r)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction
  let redeemer =
    (
      None,
      txs_with_receipts
        |> list.map(fn((_t, d, r)) { t.Continuing(t.Respond(r, d)) }),
    )
  fuzz.constant((transaction, redeemer))
}

// pub type Stage {
//   Opened(Amount, Snapshot, Period)
//   Closed(Amount, Squash, Timeout, Pend)
//   Responded(Amount, Pend, Pend)
//   Elapsed(Pend)
//   Resolved(Pend, Pend)
// }
// pub type MintRedeemer =
//   (Option<OutputReference>, List<NStep>)
// 
// pub type NStep {
//   Continuing(CStep)
//   End(Secrets)
// }
// pub type CStep {
//   Add(Option<Signed<Snapshot>>)
//   Close(Receipt)
//   Respond(Receipt, DropOld)
//   Resolve(Secrets, DropOld)
//   Elapse(Secrets)
//   Free(Secrets, DropOld)
// }

// pub type HtlcLockedReduced =
//   (Amount, Timeout, HtlcLock)

// pub type Pend =
//   List<HtlcLockedReduced>
//
// pub type Cheque {
//   Normal(Index, Amount)
//   Htlc(Index, Timeout, HtlcLock, Amount)
//   HtlcUnlocked(Index, Timeout, HtlcSecret, Amount)
// }
//
// pub type Receipt =
//   (Option<Signed<Snapshot>>, List<Signed<Cheque>>)

//  let output =
//    tx.Output(
//      own_address,
//      assets.from_lovelace(total)
//        |> assets.add(own_hash, token.cid_to_token(cid), 1),
//      InlineDatum((own_hash, keys_out, stage_out)),
//      None,
//    )
// Tx([input], [output], [signatory], validity_range)

// Resolve can be used after when in `Resolved` or `Elapsed`
// pub fn gen_post_respond_resolve_step_tx(
//   own_hash,
//   max_cheques,
// ) -> Fuzzer<(Tx, t.Receipt)> {
//   expect (respond_tx, drop_old, receipt) <-
//     and_then(gen_respond_step_tx(own_hash, max_cheques))
//   expect Some((
//     keys,
//     t.Responded(amount, pend0_in, pend1_in),
//     cid,
//     lovelace_in,
//   )) = parse_singleton_step_tx(respond_tx)
// 
// }


