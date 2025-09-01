use aiken/builtin.{append_bytearray, less_than_bytearray, xor_bytearray}
use aiken/collection.{Index}
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{ScriptHash, VerificationKeyHash, blake2b_224}
use aiken/fuzz.{and_then}
use aiken/interval.{
  Finite, Interval, IntervalBound, IntervalBoundType, NegativeInfinity, PositiveInfinity,
}
use aiken/math.{max}
use aiken/primitive/int
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Lovelace}
use cardano/transaction.{InlineDatum, NoDatum, Output, OutputReference, Transaction}
use cardano/transaction as tx
use cl/channel
use cl/prelude.{Amount, PosixMilliseconds, Signed}
use cl/tests/benchmarks/cardano
use cl/tests/benchmarks/fuzz as fuzz_contrib
use cl/token
use cl/types.{MintRedeemer, Receipt} as t

const second: PosixMilliseconds = 1000
const minute: PosixMilliseconds = 60 * second
const hour: PosixMilliseconds = 60 * minute
const day: PosixMilliseconds = 24 * hour

const min_expiration: PosixMilliseconds = 2 * hour
const max_expiration: PosixMilliseconds = 10 * day

const min_period: PosixMilliseconds = 4 * hour
const max_period: PosixMilliseconds = 20 * day

pub fn gen_keys() -> Fuzzer<t.Keys> {
  let vk0 <- and_then(cardano.verification_key())
  let vk1 = xor_bytearray(False, vk0, vk0)
  fuzz.constant((vk0, vk1))
}

// Should we be really precise and generate of a Squash/Snapshot based on the previous one?
// It should not hurt but the only places where this comparison happens are `add`, `close` and `respond`
pub fn gen_squash(
  max_chqs,
  min_sq_amt: Amount,
  max_sq_amt: Amount,
  prev_squash: Option<t.Squash>
) -> Fuzzer<t.Squash> {
  let max_indices_span = 4 * max_chqs
  let mk_excl = fn(sq_idx, excl_num) {
    if(excl_num == 0) {
      fuzz.constant([])
    } else {
      let prev_init = sq_idx - max_indices_span
      let (_last_idx, excl_decs) <- and_then(fuzz_contrib.foldr(list.reverse(list.range(0, excl_num-1)), (prev_init, []), fn (remaining, (prev_idx, acc)) {
        let space = sq_idx - prev_idx
        let max_bump = space - remaining
        if(max_bump <= 0) {
          fuzz.constant((prev_idx, acc))
        } else {
          let idx <- and_then(fuzz.int_between(prev_idx+1, prev_idx + max_bump))
          fuzz.constant((idx, acc |> list.push(idx)))
        }
      }))
      fuzz.constant(list.reverse(excl_decs))
    }
  }
  when prev_squash is {
    None -> {
      // Base index provides some spacing for the excluded cheques
      let idx <- and_then(fuzz.int_between(max_indices_span, 100000000000000000))
      let excl <- and_then({
        let excl_num <- and_then(fuzz.int_between(0, max_chqs))
        mk_excl(idx, excl_num)
      })
      let amt <- and_then(fuzz.int_between(min_sq_amt, max_sq_amt))
      fuzz.constant((amt, idx, excl))
    }
    // * Amount should only increase
    // * This amount increase should be reflected in a bumped index
    // * For now let's simplify generation of the exclude so we are sure that the list do not overlap
    Some((amt_in, idx_in, excl_in)) -> {
      expect amt_in <= min_sq_amt
      expect min_sq_amt <= max_sq_amt
      let amt_out <- and_then(fuzz.int_between(min_sq_amt, max_sq_amt))

      let idx_increase <- and_then(fuzz.int_between(0, max_indices_span))
      let idx_out = idx_in + idx_increase
      let excl_out <- and_then({
        let excl_num <- and_then(fuzz.int_between(0, max_chqs))
        let excl_preserved = excl_in |> list.filter(fn(idx) { idx > idx_out - max_indices_span }) |> fn(preserved) {
          list.drop(preserved, max(0, list.length(preserved) - excl_num))
        }
        let excl_num_remaining = max(0, list.length(excl_preserved) - excl_num)
        let excl_remaining <- and_then(mk_excl(idx_out, excl_num_remaining))
        fuzz.constant(excl_preserved |> list.concat(excl_remaining))
      })
      fuzz.constant((amt_out, idx_out, excl_out))
    }
  }
}

pub const empty_squash: t.Squash = (0, 0, [])

pub type KeysOrder {
  SelfKeySmaller
  SelfKeyLarger
}

pub fn mk_keys_order(self, other) {
  if less_than_bytearray(self, other) {
    SelfKeySmaller
  } else {
    SelfKeyLarger
  }
}

pub fn gen_snapshot(
  self_deposit: Lovelace,
  other_deposit: Lovelace,
  max_cheques: Int,
  keysOrder: KeysOrder,
  prev_snapshot: Option<t.Snapshot>,
) -> Fuzzer<t.Snapshot> {
  let max_chqs_self_received = math.min(other_deposit, max_cheques)
  let max_chqs_self_sent = math.min(self_deposit, max_cheques)

  let (self_received, self_sent) <- and_then(when prev_snapshot is {
    None -> {
      let self_received <- and_then(gen_squash(
        max_chqs_self_received,
        0,
        1_000_000_000,
        None,
      ))
      // The cheques issued by the other party have to be covered by his deposit.
      // Additionally we should leave at least 1 lovelace for every excluded cheque.
      let min_self_sent = self_received.1st - other_deposit + list.length(self_received.3rd)
      // Again we should be able to cover all raised cheques from our deposit.
      // We also leave some margin for possible excluded cheques.
      let max_self_sent = self_received.1st + self_deposit - max_chqs_self_sent

      trace @"gen_snapshot: self_received": self_received
      trace @"gen_snapshot: min_self_sent": min_self_sent
      trace @"gen_snapshot: max_self_sent": max_self_sent

      let self_sent <- and_then(gen_squash(
        max_chqs_self_sent,
        min_self_sent,
        max_self_sent,
        None,
      ))
      fuzz.constant((self_received, self_sent))
    }
    Some((prev_self_received, prev_self_sent)) -> {
      let self_received <- and_then(gen_squash(
        max_chqs_self_received,
        prev_self_received.1st,
        prev_self_received.1st + 1_000_000_000,
        None
      ))
      // The cheques issued by the other party have be covered by his deposit.
      let min_self_sent = max(prev_self_sent.1st, self_received.1st - other_deposit + list.length(self_received.3rd))
      // Again we should be able to cover all raised cheques from our deposit.
      let max_self_sent = max(min_self_sent, self_received.1st + self_deposit - max_chqs_self_sent)

      trace @"gen_snapshot: self_received": self_received
      trace @"gen_snapshot: prev_self_sent": prev_self_sent
      trace @"gen_snapshot: min_self_sent": min_self_sent
      trace @"gen_snapshot: max_self_sent": max_self_sent

      let self_sent <- and_then(gen_squash(
        max_chqs_self_sent,
        min_self_sent,
        max_self_sent,
        Some(prev_self_sent),
      ))
      fuzz.constant((self_received, self_sent))
    }
  })
  // From l1 spec:
  // So the squash of the cheques received by the smaller verification key is first.
  // The ordering is important.
  when keysOrder is {
    SelfKeySmaller -> fuzz.constant((self_received, self_sent))
    SelfKeyLarger -> fuzz.constant((self_sent, self_received))
  }
}

pub const empty_snapshot: t.Snapshot = (empty_squash, empty_squash)

// Signature verification is patched during benchmarking
// through `env/testing.ak`
const signature = list.repeat(#"00", 64) |> list.reduce(#"", append_bytearray)
// Because during testing we do not really check the signature
// under the original htlc we don't have to worry about producing
// a valid htlc_lock from the secret.
const htlc_secret = t.Sha2_256Secret(list.repeat(#"00", 32) |> list.reduce(#"", append_bytearray))
// Precomputed lock for the above secret
const htlc_lock: t.HtlcLock = #"66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"

pub fn mk_signed(x: a) -> Signed<a> {
  (x, signature)
}

fn gen_cheque_expiration(validity_range: ExclusiveValidityRange) {
  expect ExclusiveValidityRange { lb: Some(past_point), ub: Some(future_point) } = validity_range
  let delta <- and_then(fuzz.int_between(min_expiration, max_expiration))
  fuzz.constant(max(past_point + delta, future_point + 10))
}

pub fn gen_cheque(index: Int, max_amount: Int, validity_range: ExclusiveValidityRange) -> Fuzzer<t.Cheque> {
  let amount <- and_then(fuzz.int_between(1, max_amount))
  // Pick type of the cheque
  let constr_idx <- and_then(fuzz.int_between(0, 2))
  when constr_idx is {
    0 -> fuzz.constant(t.Normal(index, amount))
    1 -> {
      let expiration <- and_then(gen_cheque_expiration(validity_range))
      fuzz.constant(t.Htlc(index, expiration, htlc_lock, amount))
    }
    _ -> {
      let expiration <- and_then(gen_cheque_expiration(validity_range))
      // We don't have to care about proper secret generation
      // since we mock signature checking any hash value
      // derived from the secret will be "correctly" signed.
      fuzz.constant(
        t.HtlcUnlocked(index, expiration, htlc_secret, amount),
      )
    }
  }
}

pub fn get_cheque_amount(cheque: t.Cheque) {
  when cheque is {
    t.Normal(_, amount) -> amount
    t.Htlc(_, _, _, amount) -> amount
    t.HtlcUnlocked(_, _, _, amount) -> amount
  }
}

pub fn gen_signed_cheque(index: Int, max_amount: Int, validity_range: ExclusiveValidityRange) -> Fuzzer<Signed<t.Cheque>> {
  let cheque <- and_then(gen_cheque(index, max_amount, validity_range))
  let signed_cheque = mk_signed(cheque)
  fuzz.constant(signed_cheque)
}

// In order to generate `Receipt` we have to generate a set of cheques
// which are "compatible" with the `Squash`:
// * We can provide cheques which were issued after the squash (cheque_idx > squash_idx)
// * We can provide cheques which were excluded from the squash (cheque_idx in exclude)
// Invariant: `max_cheques <= max_cheques_amount`
pub fn gen_receipt_cheques(
  squash: t.Squash,
  max_cheques: Int,
  max_cheques_amount: Amount,
  validity_range: ExclusiveValidityRange
) -> Fuzzer<List<Signed<t.Cheque>>> {
  expect max_cheques >= 0
  expect max_cheques_amount > 0

  let (_, sq_index, exclude) = squash
  let tot_chqs_num <- and_then(fuzz.int_between(0, max_cheques))

  let resolved_chqs_num <- and_then(fuzz.int_between(0, tot_chqs_num))
  let resolved_chqs_idxs: List<Int> <- and_then(fuzz_contrib.pick_subset(exclude, resolved_chqs_num))

  let step = fn(index, (remaining_max_amount, cheques)) {
    if(remaining_max_amount > 0) {
      // Arbitrary upper cap on the single cheque amount to decrease
      // likely hood of max amount draining
      let signed_cheque <- and_then(gen_signed_cheque(index, remaining_max_amount / 2, validity_range))
      let new_remaining_max_amount = remaining_max_amount - get_cheque_amount(signed_cheque.1st)
      let new_cheques = cheques |> list.push(signed_cheque)
      fuzz.constant((new_remaining_max_amount, new_cheques))
    } else {
      fuzz.constant((remaining_max_amount, cheques))
    }
  }

  let (remaining_max_amount, resolved_chqs) <- and_then(fuzz_contrib.foldr(
    resolved_chqs_idxs,
    (max_cheques_amount, []),
    step
  ))
  // New cheques indexes should be a sequence starting from `sq_index + 1`
  let new_chqs_num = tot_chqs_num - list.length(resolved_chqs)
  let (_, new_chqs) <- and_then(fuzz_contrib.foldr(
    list.range(sq_index + 1, sq_index + 1 + new_chqs_num),
    (remaining_max_amount, []),
    step
  ))
  fuzz.constant(resolved_chqs |> list.concat(new_chqs) |> list.sort(fn ((chq1, _), (chq2, _)) {
    let idx1 = cheque_idx(chq1)
    let idx2 = cheque_idx(chq2)
    int.compare(idx1, idx2)
  }))
}

pub type SquashIdx {
  FirstSquash
  SecondSquash
}

// Given a snapshot and indication which squash belongs to the
// receipt submitter (contains sum of received cheques) create a
// corresponding set of received cheques and put together a
// proper `Receipt`.
pub fn gen_receipt(
  snapshot: t.Snapshot,
  max_cheques: Int,
  max_cheques_amount: Amount,
  which_sq: SquashIdx,
  validity_range: ExclusiveValidityRange
) -> Fuzzer<t.Receipt> {
  let (sq1, sq2) = snapshot
  let sq =
    if which_sq == FirstSquash {
      sq1
    } else {
      sq2
    }
  let sq_cheques <-
    and_then(gen_receipt_cheques(sq, max_cheques, max_cheques_amount, validity_range))
  let signed_snapshot = mk_signed((sq1, sq2))
  fuzz.constant((Some(signed_snapshot), sq_cheques))
}

pub fn channel_id() -> Fuzzer<t.ChannelId> {
  let seed <- and_then(cardano.output_reference())
  fuzz.constant(channel.mk_cid(seed, 0))
}

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

  let period <- and_then(fuzz.int_between(min_period, max_period))
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
      fuzz_contrib.traverse_list(
        list.range(0, n_mint),
        fn(index) { gen_new_channel_output(own_hash, seed, index, n_mint) },
      ),
    )
  fuzz.constant((seed, n_mint, new_outputs))
}

pub type ExclusiveValidityRange {
  lb: Option<PosixMilliseconds>,
  ub: Option<PosixMilliseconds>
}

// On the ledger for finite bounds there
// is a predefined inclusion scheme: `[lb, ub)`.
// Let's convert to that scheme.
pub fn validity_range_to_interval(
  range: ExclusiveValidityRange,
) -> Interval<PosixMilliseconds> {
  let lower_bound = when range.lb is {
    None -> IntervalBound {
      bound_type: NegativeInfinity,
      is_inclusive: False,
    }
    Some(ts) -> IntervalBound {
      bound_type: Finite(ts+1),
      is_inclusive: True,
    }
  }
  let upper_bound = when range.ub is {
    None -> IntervalBound {
      bound_type: PositiveInfinity,
      is_inclusive: False,
    }
    Some(ts) -> IntervalBound {
      bound_type: Finite(ts),
      is_inclusive: False,
    }
  }
  Interval {
    lower_bound: lower_bound,
    upper_bound: upper_bound,
  }
}

// Simplified transaction which we can mappend in a rather sensible manner
pub type Tx {
  Tx {
    inputs: List<tx.Input>,
    outputs: List<tx.Output>,
    signatories: List<VerificationKeyHash>,
    validity_range: ExclusiveValidityRange
  }
}

pub const open_validity_range = ExclusiveValidityRange(None, None)

// We only allow merging of a ranges which in our context
// will not break validation of substeps:
// * completely open bound can be merged with anything
// * non empty bound has to be preserved to guarantee validity
// In other words combining two different finite bound values should error.
pub fn combine_validity_ranges(range1, range2) -> ExclusiveValidityRange {
  let combine_bound = fn(b1, b2) {
    if b1 == b2 { b1 }
    else {
      when (b1, b2) is {
        (None, b2) -> b2
        (b1, None) -> b1
        _ -> fail @"Cannot combine different bounds"
      }
    }
  }
  when (range1, range2) is {
    (ExclusiveValidityRange{ lb: lb1, ub: ub1 }, ExclusiveValidityRange { lb: lb2, ub: ub2 }) ->
      ExclusiveValidityRange(
        combine_bound(lb1, lb2),
        combine_bound(ub1, ub2),
      )
  }
}


pub const mempty_tx = Tx([], [], [], open_validity_range)

pub type GenBoundSpec {
  GenAnyBound
  GenFinateOnlyBound
}

pub fn gen_lb(bound_spec: GenBoundSpec, max: PosixMilliseconds) -> Fuzzer<IntervalBoundType<PosixMilliseconds>> {
  let infinity <- and_then(fuzz.bool())
  if infinity && bound_spec == GenAnyBound {
    fuzz.constant(NegativeInfinity)
  } else {
    let ts <- and_then(fuzz.int_between(0, max))
    fuzz.constant(Finite(ts))
  }
}

pub fn gen_ub(bound_spec: GenBoundSpec, min: PosixMilliseconds) -> Fuzzer<IntervalBoundType<PosixMilliseconds>> {
  let infinity <- and_then(fuzz.bool())
  if infinity && bound_spec == GenAnyBound {
    fuzz.constant(PositiveInfinity)
  } else {
    let ts <- and_then(fuzz.int_between(min, min+100000000000000000))
    fuzz.constant(Finite(ts))
  }
}

pub fn tx_mappend(tx1: Tx, tx2: Tx) -> Tx {
  let input = tx1.inputs |> list.concat(tx2.inputs)
  let output = tx1.outputs |> list.concat(tx2.outputs)
  let signatories =
    tx1.signatories |> list.concat(tx2.signatories) |> list.unique()
  let validity_range = combine_validity_ranges(tx1.validity_range, tx2.validity_range)
  Tx(input, output, signatories, validity_range)
}

pub fn parse_singleton_step_tx(
  tx: Tx,
) -> Option<(Address, t.Keys, t.Stage, t.ChannelId, Amount)> {
  when tx is {
    Tx {
      inputs: _,
      outputs: [ output ],
      signatories: _,
      validity_range: _,
    } -> parse_cl_output(output)
    _ -> None
  }
}

pub fn parse_cl_output(output: Output) -> Option<(Address, t.Keys, t.Stage, t.ChannelId, Amount)> {
  when output is {
    tx.Output {
      address: own_address,
      value,
      datum: InlineDatum(datum),
      reference_script: None,
    } ->
      if datum is (ScriptHash, t.Keys, t.Stage) {
        let (own_hash, keys, stage) = datum
        let (cid, lovelace) = channel.parse_value(own_hash, value)
        Some((own_address, keys, stage, cid, lovelace))
      } else {
        None
      }
    _ -> None
  }
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
    validity_range: validity_range_to_interval(tx.validity_range),
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

type ByOpener = Bool

pub fn gen_add_step_tx(
  own_hash,
  possible_channel_output: Option<tx.Output>,
) -> Fuzzer<(Tx, ByOpener)> {
  let prev_channel_output <- and_then(when possible_channel_output is {
    Some(output) -> fuzz.constant(output)
    None -> {
      let out_ref <- and_then(cardano.output_reference())
      gen_new_channel_output(own_hash, out_ref, 0, 1)
    }
  })
  expect Some((own_address, keys, stage_in, cid, tot_in)) =
    parse_cl_output(prev_channel_output)
  expect t.Opened(amt_non_opener_in, sn_in, period_in) = stage_in
  let amount_add <- and_then(fuzz.int_between(1, 100000000000000000))
  let by_opener <- and_then(fuzz.bool())
  // TODO: add support for snapshot update
  let stage_out =
    if by_opener {
      stage_in
    } else {
      t.Opened(amt_non_opener_in + amount_add, sn_in, period_in)
    }
  let tot_out = tot_in + amount_add
  let out_ref <- and_then(cardano.output_reference())

  let input = tx.Input(out_ref, prev_channel_output)
  let output =
    tx.Output(
      own_address,
      assets.from_lovelace(tot_out)
        |> assets.add(own_hash, token.cid_to_token(cid), 1),
      InlineDatum((own_hash, keys, stage_out)),
      None,
    )
  let signatory =
    if by_opener {
      blake2b_224(keys.1st)
    } else {
      blake2b_224(keys.2nd)
    }
  let tx = Tx([input], [output], [signatory], open_validity_range)
  fuzz.constant((tx, by_opener))
}

pub fn gen_add_steps_transaction(
  own_hash,
  n_steps,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  // TODO: support snapshot updates and addition chains
  let txs <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(0, n_steps),
        fn(_) { gen_add_step_tx(own_hash, None) },
      ),
    )
  let tx = txs
    |> list.map(fn((t, _)) { t })
    |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction
  // FIXME: we are not generating optional snapshot updates
  let redeemer = (None, txs |> list.map(fn((_, by_opener)) {
    let
      add = t.Add { by_opener: by_opener, snapshot: None }
    t.Continuing(add)
  }))
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

pub fn gen_close_step_tx(own_hash, max_cheques, validity_range, possible_channel_output: Option<tx.Output>) -> Fuzzer<(Tx, ByOpener, Receipt)> {
  // Generate and parse the channel input

  let input_out_ref <- and_then(cardano.output_reference())
  let prev_channel_output <- and_then(when possible_channel_output is {
    Some(output) -> fuzz.constant(output)
    None -> {
      gen_new_channel_output(own_hash, input_out_ref, 0, 1)
    }
  })
  expect Some((own_address, keys_in, stage_in, _, tot_in)) = parse_cl_output(prev_channel_output)
  expect t.Opened(amt_non_opener_in, sn_in, period_in) = stage_in
  let input = tx.Input(input_out_ref, prev_channel_output)

  // Generate the redeemer: `Close { by_opener: Bool, receipt: Receipt }

  let close_by_opener <- and_then(fuzz.bool())
  trace @"close_by_opener": close_by_opener
  let keys_out =
    if close_by_opener {
      keys_in
    } else {
      (keys_in.2nd, keys_in.1st)
    }
  let (self_key, other_key) = keys_out

  let amt_closer_in =
    if close_by_opener {
      tot_in - amt_non_opener_in
    } else {
      amt_non_opener_in
    }

  trace @"Generating snapshot"
  let keys_order = mk_keys_order(self_key, other_key)
  let sn_out <- and_then(gen_snapshot(amt_closer_in, tot_in - amt_closer_in, max_cheques, keys_order, Some(sn_in)))
  trace @"Snapshot generated": sn_out

  let (squash_received, squash_sent) = when keys_order is {
    SelfKeySmaller -> sn_out
    SelfKeyLarger -> (sn_out.2nd, sn_out.1st)
  }
  // The closer current net income from the squashes
  let squash_diff = squash_received.1st - squash_sent.1st

  let receipt <-
    and_then(
      {
        let which_sq = when keys_order is {
          SelfKeySmaller -> FirstSquash
          SelfKeyLarger -> SecondSquash
        }
        let non_closer_deposit = if close_by_opener {
          amt_non_opener_in
        } else {
          tot_in - amt_non_opener_in
        }
        // FIXME: Not sure if this kind of approximation is good enough.
        // Should we take into the account also excluded cheques in here?
        let max_cheques_amount = non_closer_deposit - squash_diff
        gen_receipt(sn_out, max_cheques, max_cheques_amount, which_sq, validity_range)
      }
    )
  trace @"receipt": receipt

  expect ExclusiveValidityRange { lb: _, ub: Some(ub) } = validity_range
  let timeout = ub + period_in
  let pend_out = mk_pend(receipt.2nd)
  let chqs_amt = receipt.2nd
    |> list.filter_map(fn(signed_cheque) {
      when signed_cheque.1st is {
        t.Normal(_, amount) -> Some(amount)
        t.HtlcUnlocked(_idx, _chq_timeout, _lock, amount) -> Some(amount)
        t.Htlc(_, _, _, _) -> None
      }
    })
    |> list.reduce(0, fn(acc, amt) { acc + amt })
  let amt_closer_out = amt_closer_in + chqs_amt + squash_diff

  trace @"gen_close_step_tx: amt_closer_in": amt_closer_in
  trace @"gen_close_step_tx: squash_diff": squash_diff
  trace @"gen_close_step_tx: chqs_amt": chqs_amt
  trace @"gen_close_step_tx: amt_closer_out": amt_closer_out

  expect amt_closer_out >= 0
  let stage_out = t.Closed(amt_closer_out, squash_sent, timeout, pend_out)
  let Output { address: _, value, datum: _, reference_script: _ } = prev_channel_output
  let output =
    tx.Output(
      own_address,
      value,
      InlineDatum((own_hash, keys_out, stage_out)),
      None,
    )
  let signatory =
    if close_by_opener {
      blake2b_224(keys_in.1st)
    } else {
      blake2b_224(keys_in.2nd)
    }
  let tx = Tx([input], [output], [signatory], validity_range)

  trace @"tx": tx
  fuzz.constant((
    tx,
    close_by_opener,
    receipt
  ))
}

// TODO: This can be simplified I believe.
// We need just a validity range which:
// * is "non negative"
// * have some wiggle room for the transaction submission
pub fn gen_safe_close_step_validity_range() {
  let now = 2 * max_period + 20 * day
  let ub = now - max_period - 1
  let tx_submission_margin <- and_then(fuzz.int_between(hour, day))
  let lb = ub - tx_submission_margin
  fuzz.constant(ExclusiveValidityRange(Some(lb), Some(ub)))
}

pub fn gen_close_steps_transaction(
  own_hash,
  max_cheques,
  n_steps,
) -> Fuzzer<(Transaction, MintRedeemer)> {
  let validity_range <- and_then(gen_safe_close_step_validity_range())
  let txs_with_receipts <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(0, n_steps),
        fn(_) { gen_close_step_tx(own_hash, max_cheques, validity_range, None) }
      ),
    )
  let tx =
    txs_with_receipts
      |> list.map(fn((t, _, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction
  let redeemer = (None, txs_with_receipts |> list.map(fn((_, by_opener, receipt)) {
      t.Continuing(t.Close {
        by_opener,
        receipt,
      })
  }))
  trace @"transaction": transaction
  fuzz.constant((transaction, redeemer))
}

fn sum_pend(pend) {
  list.reduce(pend, 0, fn(acc, (amt, _, _)) { acc + amt })
}

fn received_and_sent(keys_order: KeysOrder, sn: t.Snapshot) {
  when keys_order is {
    SelfKeySmaller -> sn
    SelfKeyLarger -> (sn.2nd, sn.1st)
  }
}

pub type MkRespondTimeout {
  MkElapsedTimeout
  MkNotYetElapsedTimeout
}

// Creates a close step based on validity range so we 
// how to construct proper validity range:
pub fn gen_close_step_tx_for_validity_range(
  own_hash,
  max_cheques,
  validity_range: ExclusiveValidityRange,
  mk_respond_timeout: MkRespondTimeout
) {
  let out_ref <- and_then(cardano.output_reference())
  let new_channel_output <- and_then(gen_new_channel_output(own_hash, out_ref, 0, 1))
  expect Some((_, _, t.Opened(_, _, period_in), _, _)) =
    parse_cl_output(new_channel_output)
  expect ExclusiveValidityRange { lb: Some(now), ub: Some(_future) } = validity_range
  let closing_validity_range = when mk_respond_timeout is {
    MkElapsedTimeout -> ExclusiveValidityRange(
      Some(now - period_in - 1000),
      // Based on this `ub` the respond timeout is computed
      // It should be `ub + period_in >= respond_timeout`
      Some(now - period_in - 1),
    )
    MkNotYetElapsedTimeout -> ExclusiveValidityRange(
      Some(now - period_in + 10),
      Some(now - period_in + 1000),
    )
  }
  //  Generate a prior close state (simulates a valid close output as input).
  expect (close_tx, _closed_by_opener, (Some((closing_sn, _sig)), _chqs)) <-
    and_then(gen_close_step_tx(own_hash, max_cheques, closing_validity_range, Some(new_channel_output)))
  fuzz.constant((close_tx, closing_sn))
}

pub fn gen_respond_step_tx(
  own_hash,
  max_cheques,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, t.DropOld, t.Receipt)> {
  let (close_tx, closing_sn) <- and_then(gen_close_step_tx_for_validity_range(own_hash, max_cheques, validity_range, MkNotYetElapsedTimeout))
  expect Some((
    _own_address,
    keys,
    t.Closed(amt_closer_in, sq_in, respond_timeout, pend_closer_in),
    cid,
    lovelace_in,
  )) = parse_singleton_step_tx(close_tx)

  expect ExclusiveValidityRange { lb: Some(now), ub: Some(future) } = validity_range

  // Release own pending cheques which are expired if requested
  let drop_old <- and_then(fuzz.bool())
  let pend_closer_out =
    if drop_old {
      pend_closer_in |> list.filter(fn((_, t, _)) { t > now })
    } else {
      pend_closer_in
    }

  let (other, self) = keys // as `keys = (closer, non-closer)`
  let keys_order = mk_keys_order(self, other)
  let (closing_received, closing_sent) = received_and_sent(keys_order, closing_sn)
  let (receipt, new_received) <- and_then({
    // During the respond step non-closer provides possibly a newer snapshot.
    //
    // Even if this newer snapshot contains updated squash which was sent by
    // the non-closer it is ignored because that is clearly invalid (closer should not
    // not accept more cheques after close) and non-incentivised so should not
    // happen in practice.
    //
    // On the other hand the squash which was received by the non-closer is taken
    // into account as closer had no incentive to provide that one with the largest
    // amount. The incentive of non-closer now is to provide the latest received squash
    // with the largest total and as many cheques from the closer as possible.
    let min_sq_received = closing_received.1st
    // amt_closer_in is the minimal balance owned by the closer
    // if he had no other pending liabilities at the moment of closing
    // (all sent cheques were expired or something like that).
    // The below amount could be larger then what we assume here
    // because some cheques sent by closer could expired in between
    // so the closer could issue more cheques to the non-closer.
    // We ignore that possibility for simplicity.
    let max_sq_received = min_sq_received + amt_closer_in

    trace @"gen_respond_step_tx: min_sq_received": min_sq_received
    trace @"gen_respond_step_tx: max_sq_received": max_sq_received

    let new_received <- and_then(gen_squash(
      max_cheques,
      min_sq_received,
      max_sq_received,
      Some(closing_received)
    ))
    let max_cheques_amount = amt_closer_in - (new_received.1st - closing_received.1st)
    let receipt:t.Receipt <- and_then({
      when keys_order is {
        SelfKeySmaller -> {
          let sn = (new_received, closing_sent)
          gen_receipt(sn, max_cheques, max_cheques_amount, FirstSquash, validity_range)
        }
        SelfKeyLarger -> {
          let sn = (closing_sent, new_received)
          gen_receipt(sn, max_cheques, max_cheques_amount, SecondSquash, validity_range)
        }
      }
    })
    fuzz.constant((receipt, new_received))
  })

  let close_out_ref <- and_then(cardano.output_reference())
  expect Tx {
    inputs: _i,
    outputs: [close_output],
    signatories: _s,
    validity_range: _vr,
  } = close_tx
  let tx.Output { address: own_addr, .. } = close_output
  let input = tx.Input(close_out_ref, close_output)
  let pend_non_closer_out = mk_pend(receipt.2nd)

  let amt_closer_out = {
    let sq_diff = new_received.1st - closing_received.1st
    let chqs_amt = receipt.2nd
      |> list.filter_map(fn(signed_cheque) {
        when signed_cheque.1st is {
          t.Normal(_, amount) -> Some(amount)
          // We should not unlock expired cheques...
          // but let's put a guard around that.
          t.HtlcUnlocked(_, chq_timeout, _, amount) ->
            if chq_timeout > future {
              Some(amount)
            } else {
              None
            }
          t.Htlc(_, _, _, _) -> None
        }
      })
      |> list.reduce(0, fn(acc, amt) { acc + amt })
    amt_closer_in - sq_diff - chqs_amt
  }

  // The amount of money left should cover the closer's account
  // (which *should* be larger than closer's liabilities).
  // We should also secure possible liabilities of the non-closer.
  let lovelace_out = {
    let lo = amt_closer_out + sum_pend(pend_non_closer_out)
    if lo == 0 {
      // On the chain some lovelace will be naturally secured
      // because of the minUTxO rule.
      // In this context we have to enforce that so
      // we don't end up with an unrealistic value for which
      // parsing fails on the cl validator level.
      1
    } else {
      lo
    }
  }
  let total_out =
    assets.from_lovelace(lovelace_out)
      |> assets.add(own_hash, token.cid_to_token(cid), 1)
  let channel_output =
    tx.Output(
      own_addr,
      total_out,
      InlineDatum((own_hash, keys, t.Responded(amt_closer_out, pend_closer_out, pend_non_closer_out))),
      None,
    )
  let payout_output_value = assets.from_lovelace(lovelace_in - lovelace_out)
  let payout_output_addr <-
    and_then(cardano.address_with_payment_credential(VerificationKey(keys.2nd)))

  let payout_output =
    tx.Output(
      payout_output_addr,
      payout_output_value,
      NoDatum,
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
  expect ExclusiveValidityRange(Some(close_lb), Some(close_ub)) <- and_then(gen_safe_close_step_validity_range())
  let validity_range = ExclusiveValidityRange(Some(close_lb + max_period), Some(close_ub + max_period))

  let txs_with_receipts <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(0, n_steps),
        fn(_) { gen_respond_step_tx(own_hash, max_cheques, validity_range) },
      ),
    )
  let tx =
    txs_with_receipts
      |> list.map(fn((t, _, _)) { t })
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

pub fn gen_elapse_step_tx(
  own_hash,
  max_cheques,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, t.Secrets)> {
  let (close_tx, _closing_sn) <-
    and_then(gen_close_step_tx_for_validity_range(own_hash, max_cheques, validity_range, MkElapsedTimeout))

  expect Some((
    own_address,
    keys_in,
    t.Closed(amt_closer_in, _sq_in, respond_timeout, pend_closer_in),
    cid,
    tot_in,
  )) = parse_singleton_step_tx(close_tx)

  expect ExclusiveValidityRange { lb: Some(now), ub: Some(_future) } = validity_range
  trace @"gen_elapse_step_tx: now": now
  trace @"gen_elapse_step_tx: respond_timeout": respond_timeout
  expect now > respond_timeout

  // If pend possibly cover reminder and we resolve them all
  // then this operation should be actually `end`.
  let pend_cover_reminder = sum_pend(pend_closer_in) == tot_in - amt_closer_in
  trace @"gen_elapse_step_tx: pend_cover_reminder": pend_cover_reminder
  let secrets_idxs <- and_then({
    let possible_idxs <- and_then(fuzz_contrib.traverse_list(
      list.range(0, list.length(pend_closer_in) - 1),
      fn(idx) {
        let resolve <- and_then(fuzz.bool())
        if resolve {
          fuzz.constant(Some(idx))
        } else {
          fuzz.constant(None)
        }
      }
    ))
    let idxs = possible_idxs |> list.filter_map(fn(o) { o })
    if pend_cover_reminder && list.length(idxs) == list.length(pend_closer_in) {
      let idx_to_drop <- and_then(fuzz.int_between(0, list.length(possible_idxs) - 1))
      fuzz.constant(idxs |> list.indexed_map(fn(i, v) { (i, v) }) |> list.filter(fn((i, _)) { i != idx_to_drop }) |> list.map(fn((_, v)) { v }))
    } else {
      fuzz.constant(idxs)
    }
  })
  let secrets = secrets_idxs |> list.map(fn(idx) { (idx, htlc_secret) })
  let pend_closer_out = pend_closer_in |> list.indexed_foldr([], fn(idx, (amt, t, lock), acc) {
    if t > now && !(list.has(secrets_idxs, idx)) {
      list.push(acc, (amt, t, lock))
    } else {
      acc
    }
  })
  let amt_freed = sum_pend(pend_closer_in) - sum_pend(pend_closer_out)
  // Leave at least one lovelace - this will be enforced by min ADA ledger rule
  // Without this 1 lovelace parsing of the UTxO fails.
  // TODO: Should we actually change the protocol so full drain is possible here?
  let tot_out = tot_in - amt_closer_in - amt_freed

  trace @"gen_elapse_step_tx: amt_closer_in": amt_closer_in
  trace @"gen_elapse_step_tx: amt_freed": amt_freed
  trace @"gen_elapse_step_tx: tot_in": tot_in
  trace @"gen_elapse_step_tx: tot_out": tot_out

  expect Tx { inputs: _, outputs: [close_output], signatories: _, validity_range: _ } = close_tx
  let close_out_ref <- and_then(cardano.output_reference())
  let input = tx.Input(close_out_ref, close_output)

  let stage_out = t.Elapsed(pend_closer_out)
  let output = tx.Output(
    own_address,
    assets.from_lovelace(tot_out) |> assets.add(own_hash, token.cid_to_token(cid), 1),
    InlineDatum((own_hash, keys_in, stage_out)),
    None,
  )

  let signatory = blake2b_224(keys_in.1st)
  let tx = Tx([input], [output], [signatory], validity_range)
  fuzz.constant((tx, secrets))
}

pub fn gen_elapse_steps_transaction(
  own_hash,
  max_cheques,
  n_steps,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  // It doesn't hurt to have validity range which has some extra margin
  let validity_range <- and_then(gen_safe_close_step_validity_range())
  let txs_with_secrets <- and_then(fuzz_contrib.traverse_list(list.range(0, n_steps), fn(_) { gen_elapse_step_tx(own_hash, max_cheques, validity_range) }))
  let tx = txs_with_secrets |> list.map(fn((t, _)) { t }) |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction
  let redeemer = (None, txs_with_secrets |> list.map(fn((_, secrets)) { t.Continuing(t.Elapse(secrets)) }))
  fuzz.constant((transaction, redeemer))
}

// // pub type Stage {
// //   Opened(Amount, Snapshot, Period)
// //   Closed(Amount, Squash, Timeout, Pend)
// //   Responded(Amount, Pend, Pend)
// //   Elapsed(Pend)
// //   Resolved(Pend, Pend)
// // }
// // pub type MintRedeemer =
// //   (Option<OutputReference>, List<NStep>)
// // 
// // pub type NStep {
// //   Continuing(CStep)
// //   End(Secrets)
// // }
// // pub type CStep {
// //   Add(Option<Signed<Snapshot>>)
// //   Close(Receipt)
// //   Respond(Receipt, DropOld)
// //   Resolve(Secrets, DropOld)
// //   Elapse(Secrets)
// //   Free(Secrets, DropOld)
// // }
// 
// // pub type HtlcLockedReduced =
// //   (Amount, Timeout, HtlcLock)
// 
// // pub type Pend =
// //   List<HtlcLockedReduced>
// //
// // pub type Cheque {
// //   Normal(Index, Amount)
// //   Htlc(Index, Timeout, HtlcLock, Amount)
// //   HtlcUnlocked(Index, Timeout, HtlcSecret, Amount)
// // }
// //
// // pub type Receipt =
// //   (Option<Signed<Snapshot>>, List<Signed<Cheque>>)
// 
// //  let output =
// //    tx.Output(
// //      own_address,
// //      assets.from_lovelace(total)
// //        |> assets.add(own_hash, token.cid_to_token(cid), 1),
// //      InlineDatum((own_hash, keys_out, stage_out)),
// //      None,
// //    )
// // Tx([input], [output], [signatory], validity_range)
// 
// // Resolve can be used after when in `Resolved` or `Elapsed`
// // pub fn gen_post_respond_resolve_step_tx(
// //   own_hash,
// //   max_cheques,
// // ) -> Fuzzer<(Tx, t.Receipt)> {
// //   expect (respond_tx, drop_old, receipt) <-
// //     and_then(gen_respond_step_tx(own_hash, max_cheques))
// //   expect Some((
// //     keys,
// //     t.Responded(amount, pend0_in, pend1_in),
// //     cid,
// //     lovelace_in,
// //   )) = parse_singleton_step_tx(respond_tx)
// // 
// // }
// 
// 

// Add these helpers near gen_elapse_step_tx for pend reductions (adapted from step.ak logic for generation)

pub type ResolvePendsStrategy {
  AllowFullResolution
  AtLeastOneUnresolved
}

// Helper to generate secrets that reduce pend (select subset of indices, assign matching secrets)
// pub fn gen_secrets_for_pend(pend: t.Pend, resolve_strategy: ResolvePendsStrategy) -> Fuzzer<t.Secrets> {
//   let possible_idxs <- and_then(fuzz.int_between(0, list.length(pend)))
//   let max_idxs = if resolve_strategy == AllowFullResolution {
//     possible_idxs
//   } else {
//     max(1, possible_idxs - 1)
//   }
//   let idxs <- and_then(fuzz_contrib.many_of(possible_idxs, list.range(0, list.length(pend) - 1)))
//   fuzz.constant(idxs |> list.map(fn(idx) { (idx, htlc_secret) })) // Mock secret matches lock in tests
// }

// By closer release the account assets and possibly some pends
// pub fn gen_resolve_for_responded_tx(
//   own_hash,
//   max_cheques,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, t.Secrets)> {
//   let (respond_tx, _drop_old, _receipt) <-
//     and_then(gen_respond_step_tx(own_hash, max_cheques, validity_range))
//   expect Some((
//     own_address,
//     keys_in,
//     t.Responded(amt_closer_in, pend0_in, pend1_in),
//     cid,
//     tot_in,
//   )) = parse_singleton_step_tx(respond_tx)
// 
// 
