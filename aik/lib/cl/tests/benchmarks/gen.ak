use aiken/builtin.{append_bytearray, less_than_bytearray}
use aiken/collection.{Index}
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{ScriptHash, VerificationKeyHash}
use aiken/fuzz.{and_then}
use aiken/interval.{
  Finite, Interval, IntervalBound, IntervalBoundType, NegativeInfinity,
  PositiveInfinity,
}
use aiken/math
use aiken/primitive/int
use cardano/address.{Script}
use cardano/assets
use cardano/transaction.{InlineDatum, Output, OutputReference, Transaction}
use cardano/transaction as tx
use cl/channel
use cl/prelude.{Amount, Period, PosixMilliseconds, Signed}
use cl/tests/benchmarks/cardano
use cl/tests/benchmarks/fuzz as fuzz_contrib
use cl/token
use cl/types as t

pub fn keys() -> Fuzzer<t.Keys> {
  let vk0 <- and_then(cardano.verification_key())
  let vk1 <- and_then(cardano.verification_key())
  fuzz.constant((vk0, vk1))
}

// Should we be really precise and generate of a Squash/Snapshot based on the previous one?
// It should not hurt but the only places where this comparison happens are `add`, `close` and `respond`
pub fn squash(max_cheques, prev_squash: Option<t.Squash>) -> Fuzzer<t.Squash> {
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
      let sq0 <- and_then(squash(max_cheques, None))
      let sq1 <- and_then(squash(max_cheques, None))
      fuzz.constant((sq0, sq1))
    }
    Some((sq0_in, sq1_in)) -> {
      let sq0 <- and_then(squash(max_cheques, Some(sq0_in)))
      let sq1 <- and_then(squash(max_cheques, Some(sq1_in)))
      fuzz.constant((sq0, sq1))
    }
  }
}

pub const empty_snapshot: t.Snapshot = (empty_squash, empty_squash)

pub fn signed(x: a) -> Fuzzer<Signed<a>> {
  let signature <- and_then(fuzz.bytearray_between(64, 64))
  fuzz.constant((x, signature))
}

pub fn cheque(index: Int, max_amount: Int) -> Fuzzer<t.Cheque> {
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

pub fn signed_cheque(index: Int, max_amount: Int) -> Fuzzer<Signed<t.Cheque>> {
  let cheque <- and_then(cheque(index, max_amount))
  let signed_cheque <- and_then(signed(cheque))
  fuzz.constant(signed_cheque)
}

// In order to generate `Receipt` we have to generate a set of cheques
// which are "compatible" with the `Squash`:
// * We can provide cheques which were issued after the squash (cheque_idx > squash_idx)
// * We can provide cheques which were excluded from the squash (cheque_idx in exclude)
pub fn gen_squash_cheques(
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
  let max_chq_amount = max_cheques_amount / tot_chqs_num

  let resolved_chqs_idxs: List<Int> <-
    and_then(fuzz.set_between(fuzz_contrib.pick_elem(exclude), 0, tot_chqs_num))
  let resolved_chqs <-
    and_then(
      fuzz_contrib.traverse(
        resolved_chqs_idxs,
        fn(index) { signed_cheque(index, max_chq_amount) },
      ),
    )
  // New cheques indexes should be a sequence starting from `sq_index + 1`
  let new_chqs_num = tot_chqs_num - list.length(resolved_chqs)
  let new_chqs <-
    and_then(
      fuzz_contrib.traverse(
        list.range(0, new_chqs_num),
        fn(i) { signed_cheque(sq_index + i + 1, max_chq_amount) },
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
    and_then(gen_squash_cheques(sq, max_cheques, max_cheques_amount))
  let signed_snapshot <- and_then(signed((sq1, sq2)))
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

  let keys <- and_then(keys())

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
    input: List<tx.Input>,
    output: List<tx.Output>,
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

pub fn gen_validity_range(
  lb_spec: GenBoundSpec,
  ub_finite_only: GenBoundSpec,
) -> Fuzzer<Interval<PosixMilliseconds>> {
  let lb <-
    and_then(
      if lb_spec == GenFinateOnlyBound {
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
      },
    )

  let ub <-
    and_then(
      if ub_finite_only == GenFinateOnlyBound {
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
      },
    )

  let lower_bound = IntervalBound { bound_type: lb, is_inclusive: False }
  let upper_bound = IntervalBound { bound_type: ub, is_inclusive: False }
  fuzz.constant(Interval { lower_bound, upper_bound })
}

fn exclusive_lower_bound(
  lower_bound: IntervalBound<PosixMilliseconds>,
) -> IntervalBoundType<PosixMilliseconds> {
  let IntervalBound { bound_type: bound, is_inclusive } = lower_bound
  when bound is {
    Finite(ts) ->
      if is_inclusive {
        Finite(ts - 1)
      } else {
        Finite(ts)
      }
    PositiveInfinity -> PositiveInfinity
    NegativeInfinity -> NegativeInfinity
  }
}

fn exclusive_upper_bound(
  upper_bound: IntervalBound<PosixMilliseconds>,
) -> IntervalBoundType<PosixMilliseconds> {
  let IntervalBound { bound_type: bound, is_inclusive } = upper_bound
  when bound is {
    Finite(ts) ->
      if is_inclusive {
        Finite(ts + 1)
      } else {
        Finite(ts)
      }
    PositiveInfinity -> PositiveInfinity
    NegativeInfinity -> NegativeInfinity
  }
}

pub fn max_interval_bounds(
  i1: IntervalBound<PosixMilliseconds>,
  i2: IntervalBound<PosixMilliseconds>,
) -> IntervalBound<PosixMilliseconds> {
  let e1 = exclusive_lower_bound(i1)
  let e2 = exclusive_lower_bound(i2)
  let e =
    when (e1, e2) is {
      (Finite(ts1), Finite(ts2)) ->
        if ts1 > ts2 {
          e1
        } else {
          e2
        }
      (PositiveInfinity, _) -> PositiveInfinity
      (_, PositiveInfinity) -> PositiveInfinity
      (NegativeInfinity, _) -> e2
      (_, NegativeInfinity) -> e1
    }
  IntervalBound { bound_type: e, is_inclusive: False }
}

pub fn min_interval_bounds(
  i1: IntervalBound<PosixMilliseconds>,
  i2: IntervalBound<PosixMilliseconds>,
) -> IntervalBound<PosixMilliseconds> {
  let e1 = exclusive_upper_bound(i1)
  let e2 = exclusive_upper_bound(i2)
  let e =
    when (e1, e2) is {
      (Finite(ts1), Finite(ts2)) ->
        if ts1 < ts2 {
          e1
        } else {
          e2
        }
      (PositiveInfinity, _) -> e2
      (_, PositiveInfinity) -> e1
      (NegativeInfinity, _) -> NegativeInfinity
      (_, NegativeInfinity) -> NegativeInfinity
    }
  IntervalBound { bound_type: e, is_inclusive: False }
}

// We `mappend` intervals by narrowing the interval from both sides.
// The assumption in here is that we should preserve "more restrictive"
// constraints so the more relaxed requirements should still be fulfilled.
pub fn validity_range_mappend(
  validity_range1: Interval<PosixMilliseconds>,
  validity_range2: Interval<PosixMilliseconds>,
) -> Interval<PosixMilliseconds> {
  let Interval { lower_bound: lower_bound1, upper_bound: upper_bound1 } =
    validity_range1
  let Interval { lower_bound: lower_bound2, upper_bound: upper_bound2 } =
    validity_range2

  let lower_bound = max_interval_bounds(lower_bound1, lower_bound2)
  let upper_bound = min_interval_bounds(upper_bound1, upper_bound2)
  Interval { lower_bound, upper_bound }
}

pub fn tx_mappend(tx1: Tx, tx2: Tx) -> Tx {
  let input = tx1.input |> list.concat(tx2.input)
  let output = tx1.output |> list.concat(tx2.output)
  let signatories =
    tx1.signatories |> list.concat(tx2.signatories) |> list.unique()
  let validity_range =
    validity_range_mappend(tx1.validity_range, tx2.validity_range)
  Tx(input, output, signatories, validity_range)
}

pub fn tx_to_transaction(tx: Tx) {
  let tx_id = list.repeat(#"00", 32) |> list.reduce(#"", append_bytearray)
  Transaction {
    inputs: tx.input,
    reference_inputs: [],
    outputs: tx.output,
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
  let keys <- and_then(keys())
  let period <- and_then(fuzz.int_between(0, two_minutes_milliseconds))
  let (sq0, sq1) <- and_then(gen_snapshot(max_cheques, None))
  let (amount0, _, excluded0) = sq0
  let (amount1, _, excluded1) = sq1
  let smaller_key_extra <- and_then(fuzz.int_between(0, 100000000000000000))
  let bigger_key_extra <- and_then(fuzz.int_between(0, 100000000000000000))

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
    amount: amount_in,
    total: tot_in,
    keys,
    sn: sn_in,
    period: period_in,
  } <- and_then(gen_opened_input_info(max_cheques))

  let stage_in = t.Opened(amount_in, sn_in, period_in)
  let amount_add <- and_then(fuzz.int_between(1, 100000000000000000))
  let is_vk0_add <- and_then(fuzz.bool())
  // TODO: add support for snapshot update
  let stage_out =
    if is_vk0_add {
      t.Opened(amount_in + amount_add, sn_in, period_in)
    } else {
      stage_in
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
        InlineDatum((own_hash, keys, stage_out)),
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
      keys.1st
    } else {
      keys.2nd
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
  let redeemer = (None, txs |> list.map(fn(_) { t.Continuing(t.Add(None)) }))
  fuzz.constant((transaction, redeemer))
}

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

pub fn gen_close_step_tx(own_hash, max_cheques) -> Fuzzer<(Tx, t.Receipt)> {
  let own_address <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let OpenedInputInfo {
    amount: amount_in,
    total,
    keys: keys_in,
    sn: sn_in,
    period,
  } <- and_then(gen_opened_input_info(max_cheques))
  let stage_in = t.Opened(amount_in, sn_in, period)
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
  let amount_out =
    if is_vk0_close {
      amount_in
    } else {
      total - amount_in
    }
  let (own_squash, partners_squash) =
    when (is_vk0_close, less_than_bytearray(keys_in.1st, keys_in.2nd)) is {
      (True, True) -> sn_out
      // vk0 is closing and vk0 squash is first
      (False, True) -> (sn_out.2nd, sn_out.1st)
      // vk1 is closing and vk0 squash is first
      (True, False) -> (sn_out.2nd, sn_out.1st)
      // vk0 is closing and vk1 squash is first
      (False, False) -> sn_out
    }
  // vk1 is closing and vk1 squash is first
  let validity_range <-
    and_then(gen_validity_range(GenFinateOnlyBound, GenAnyBound))
  expect Interval {
    lower_bound: IntervalBound { bound_type: Finite(ts), is_inclusive: _ii },
    upper_bound: _ub,
  } = validity_range

  let timeout = ts + period

  // FIXME: Currently we use empty receipt so all the cheques are pending
  let receipt <-
    and_then(
      {
        let which_sq =
          if own_squash == sn_out.1st {
            FirstSquash
          } else {
            SecondSquash
          }
        gen_receipt(sn_out, max_cheques, amount_out, which_sq)
      },
    )
  let pend_out = mk_pend(receipt.2nd)
  let stage_out = t.Closed(amount_out, partners_squash, timeout, pend_out)

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
      keys_in.1st
    } else {
      keys_in.2nd
    }

  fuzz.constant((Tx([input], [output], [signatory], validity_range), receipt))
}

pub fn gen_close_steps_transaction(
  own_hash,
  max_cheques,
  n_steps,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
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
      txs_with_receipts |> list.map(fn((_, r)) { t.Continuing(t.Close(r)) }),
    )
  fuzz.constant((transaction, redeemer))
}
// pub fn add_txs(max_cheques, n_steps) -> Fuzzer<Tx> {
//   let txs <- and_then(fuzz_contrib.traverse(
//     list.range(0, n_steps),
//     fn(_) { add_tx(own_hash, max_cheques) }
//   ))
//   fuzz.constant(txs)
// }

// pub fn do_add(
//   cid: t.ChannelId,
//   signers: List<VerificationKeyHash>,
//   tot_in: Amount,
//   keys_in: t.Keys,
//   stage_in: t.Stage,
//   possible_snapshot: Option<Signed<t.Snapshot>>,
//   tot_out: Amount,
//   keys_out: t.Keys,
//   stage_out: t.Stage,
// ) -> Bool {
