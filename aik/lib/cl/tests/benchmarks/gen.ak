use aiken/builtin.{append_bytearray, complement_bytearray, less_than_bytearray}
use aiken/collection.{Index}
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{ScriptHash, VerificationKeyHash, blake2b_224}
use aiken/fuzz.{and_then}
use aiken/interval.{
  Finite, Interval, IntervalBound, IntervalBoundType, NegativeInfinity,
  PositiveInfinity,
}
use aiken/math.{max}
use aiken/primitive/bytearray
use aiken/primitive/int
use cardano/address.{Address, Script, VerificationKey}
use cardano/assets.{Lovelace, Value}
use cardano/transaction.{
  InlineDatum, NoDatum, Output, OutputReference, Transaction,
}
use cardano/transaction as tx
use cl/channel
use cl/prelude.{Amount, Period, PosixMilliseconds, Signed}
use cl/tests/benchmarks/cardano
use cl/tests/benchmarks/fuzz as fuzz_contrib
use cl/token
use cl/types.{MintRedeemer, Receipt} as t

// Let's remove magic constants all together from the picture
// even if some constraints are not necessary
pub const min_ada = 1_000_000

pub const min_channel_amount = min_ada + 1

pub const max_channel_amount = 1_000_000_000_000_000

pub const max_squash_amount = 100_000_000_000_000

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
  let vk1 = complement_bytearray(vk0)
  fuzz.constant((vk0, vk1))
}

// Should we be really precise and generate of a Squash/Snapshot based on the previous one?
// It should not hurt but the only places where this comparison happens are `add`, `close` and `respond`
pub fn gen_squash(
  max_chqs,
  min_sq_amt: Amount,
  max_sq_amt: Amount,
  prev_squash: Option<t.Squash>,
) -> Fuzzer<t.Squash> {
  let max_indices_span = 4 * max_chqs
  let mk_excl =
    fn(sq_idx, excl_num) {
      if excl_num == 0 {
        fuzz.constant([])
      } else {
        let prev_init = sq_idx - max_indices_span
        let (_last_idx, excl_decs) <-
          and_then(
            fuzz_contrib.foldr(
              list.reverse(list.range(0, excl_num - 1)),
              (prev_init, []),
              fn(remaining, (prev_idx, acc)) {
                let space = sq_idx - prev_idx
                let max_bump = space - remaining
                if max_bump <= 0 {
                  fuzz.constant((prev_idx, acc))
                } else {
                  let idx <-
                    and_then(
                      fuzz.int_between(prev_idx + 1, prev_idx + max_bump),
                    )
                  fuzz.constant((idx, acc |> list.push(idx)))
                }
              },
            ),
          )
        fuzz.constant(list.reverse(excl_decs))
      }
    }
  when prev_squash is {
    None -> {
      // Base index provides some spacing for the excluded cheques
      let idx <-
        and_then(fuzz.int_between(max_indices_span, 100000000000000000))
      let excl <-
        and_then(
          {
            let excl_num <- and_then(fuzz.int_between(0, max_chqs))
            mk_excl(idx, excl_num)
          },
        )
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
      let excl_out <-
        and_then(
          {
            let excl_num <- and_then(fuzz.int_between(0, max_chqs))
            let excl_preserved =
              excl_in
                |> list.filter(fn(idx) { idx > idx_out - max_indices_span })
                |> fn(preserved) {
                    list.drop(
                      preserved,
                      max(0, list.length(preserved) - excl_num),
                    )
                  }
            let excl_num_remaining =
              max(0, list.length(excl_preserved) - excl_num)
            let excl_remaining <- and_then(mk_excl(idx_out, excl_num_remaining))
            fuzz.constant(excl_preserved |> list.concat(excl_remaining))
          },
        )
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

pub type ChannelDrainingOptions {
  AllowAnyDraining
  AllowDrainingBySelf
  AllowDrainingByOther
  ForbidDraining
}

pub fn gen_snapshot(
  self_deposit: Lovelace,
  other_deposit: Lovelace,
  max_cheques: Int,
  keys_order: KeysOrder,
  prev_snapshot: Option<t.Snapshot>,
  draining: ChannelDrainingOptions,
) -> Fuzzer<t.Snapshot> {
  let max_chqs_self_received = math.min(other_deposit, max_cheques)
  let max_chqs_self_sent = math.min(self_deposit, max_cheques)

  let (self_received, self_sent) <-
    and_then(
      {
        let (
          self_received,
          base_min_self_sent,
          base_max_self_sent,
          prev_self_sent,
        ) <-
          and_then(
            when prev_snapshot is {
              None -> {
                let self_received <-
                  and_then(
                    gen_squash(max_chqs_self_received, 0, 1_000_000_000, None),
                  )
                // The cheques issued by the other party have to be covered by his deposit.
                // Additionally we should leave at least 1 lovelace for every excluded cheque.
                let base_min_self_sent =
                  max(
                    0,
                    self_received.1st - other_deposit + list.length(
                      self_received.3rd,
                    ),
                  )
                // Again we should be able to cover all raised cheques from our deposit.
                // We also leave some margin for possible excluded cheques.
                let base_max_self_sent =
                  self_received.1st + self_deposit - max_chqs_self_sent

                fuzz.constant(
                  (self_received, base_min_self_sent, base_max_self_sent, None),
                )
              }
              Some((prev_self_received, prev_self_sent)) -> {
                let self_received <-
                  and_then(
                    gen_squash(
                      max_chqs_self_received,
                      prev_self_received.1st,
                      prev_self_received.1st + 1_000_000_000,
                      None,
                    ),
                  )
                // The cheques issued by the other party have be covered by his deposit.
                let base_min_self_sent =
                  max(
                    prev_self_sent.1st,
                    self_received.1st - other_deposit + list.length(
                      self_received.3rd,
                    ),
                  )
                // Again we should be able to cover all raised cheques from our deposit.
                let base_max_self_sent =
                  max(
                    base_min_self_sent,
                    self_received.1st + self_deposit - max_chqs_self_sent,
                  )
                fuzz.constant(
                  (
                    self_received,
                    base_min_self_sent,
                    base_max_self_sent,
                    Some(prev_self_sent),
                  ),
                )
              }
            },
          )

        let (min_self_sent, max_self_sent) =
          when draining is {
            AllowAnyDraining -> (base_min_self_sent, base_max_self_sent)
            AllowDrainingBySelf -> (base_min_self_sent, base_max_self_sent - 1)
            AllowDrainingByOther -> (base_min_self_sent + 1, base_max_self_sent)
            ForbidDraining -> (base_min_self_sent + 1, base_max_self_sent - 1)
          }
        trace @"gen_snapshot: self_received": self_received
        trace @"gen_snapshot: prev_self_sent": prev_self_sent
        trace @"gen_snapshot: min_self_sent": min_self_sent
        trace @"gen_snapshot: max_self_sent": max_self_sent

        let self_sent <-
          and_then(
            gen_squash(
              max_chqs_self_sent,
              min_self_sent,
              max_self_sent,
              prev_self_sent,
            ),
          )
        fuzz.constant((self_received, self_sent))
      },
    )
  // From l1 spec:
  // So the squash of the cheques received by the smaller verification key is first.
  // The ordering is important.
  when keys_order is {
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
const htlc_secret =
  t.Sha2_256Secret(list.repeat(#"00", 32) |> list.reduce(#"", append_bytearray))

// Precomputed lock for the above secret
const htlc_lock: t.HtlcLock =
  #"66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"

pub fn mk_signed(x: a) -> Signed<a> {
  (x, signature)
}

fn gen_cheque_expiration(validity_range: ExclusiveValidityRange) {
  expect ExclusiveValidityRange { lb: Some(past_point), ub: Some(future_point) } =
    validity_range
  let delta <- and_then(fuzz.int_between(min_expiration, max_expiration))
  fuzz.constant(max(past_point + delta, future_point + 10))
}

pub fn gen_cheque(
  index: Int,
  max_amount: Int,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<t.Cheque> {
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
      fuzz.constant(t.HtlcUnlocked(index, expiration, htlc_secret, amount))
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

pub fn gen_signed_cheque(
  index: Int,
  max_amount: Int,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<Signed<t.Cheque>> {
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
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<List<Signed<t.Cheque>>> {
  expect max_cheques >= 0
  expect max_cheques_amount > 0

  let (_, sq_index, exclude) = squash
  let tot_chqs_num <- and_then(fuzz.int_between(0, max_cheques))

  let resolved_chqs_num <- and_then(fuzz.int_between(0, tot_chqs_num))
  let resolved_chqs_idxs: List<Int> <-
    and_then(fuzz_contrib.pick_subset(exclude, resolved_chqs_num))

  let step =
    fn(index, (remaining_max_amount, cheques)) {
      if remaining_max_amount > 0 {
        // Arbitrary upper cap on the single cheque amount to decrease
        // likely hood of max amount draining
        let signed_cheque <-
          and_then(
            gen_signed_cheque(index, remaining_max_amount / 2, validity_range),
          )
        let new_remaining_max_amount =
          remaining_max_amount - get_cheque_amount(signed_cheque.1st)
        let new_cheques = cheques |> list.push(signed_cheque)
        fuzz.constant((new_remaining_max_amount, new_cheques))
      } else {
        fuzz.constant((remaining_max_amount, cheques))
      }
    }

  let (remaining_max_amount, resolved_chqs) <-
    and_then(
      fuzz_contrib.foldr(resolved_chqs_idxs, (max_cheques_amount, []), step),
    )
  // New cheques indexes should be a sequence starting from `sq_index + 1`
  let new_chqs_num = tot_chqs_num - list.length(resolved_chqs)
  let (_, new_chqs) <-
    and_then(
      fuzz_contrib.foldr(
        list.range(sq_index + 1, sq_index + 1 + new_chqs_num),
        (remaining_max_amount, []),
        step,
      ),
    )
  fuzz.constant(
    resolved_chqs
      |> list.concat(new_chqs)
      |> list.sort(
          fn((chq1, _), (chq2, _)) {
            let idx1 = cheque_idx(chq1)
            let idx2 = cheque_idx(chq2)
            int.compare(idx1, idx2)
          },
        ),
  )
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
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<t.Receipt> {
  let (sq1, sq2) = snapshot
  let sq =
    if which_sq == FirstSquash {
      sq1
    } else {
      sq2
    }
  let sq_cheques <-
    and_then(
      gen_receipt_cheques(sq, max_cheques, max_cheques_amount, validity_range),
    )
  let signed_snapshot = mk_signed((sq1, sq2))
  fuzz.constant((Some(signed_snapshot), sq_cheques))
}

pub fn gen_channel_id() -> Fuzzer<t.ChannelId> {
  let seed <- and_then(cardano.output_reference())
  fuzz.constant(channel.mk_cid(seed, 0))
}

pub type ExclusiveValidityRange {
  lb: Option<PosixMilliseconds>,
  ub: Option<PosixMilliseconds>,
}

pub const open_validity_range = ExclusiveValidityRange(None, None)

pub fn cheque_idx(cheque: t.Cheque) -> Index {
  when cheque is {
    t.Normal(idx, _) -> idx
    t.Htlc(idx, _, _, _) -> idx
    t.HtlcUnlocked(idx, _, _, _) -> idx
  }
}

// On the ledger for finite bounds there
// is a predefined inclusion scheme: `[lb, ub)`.
// Let's convert to that scheme.
pub fn validity_range_to_interval(
  range: ExclusiveValidityRange,
) -> Interval<PosixMilliseconds> {
  let lower_bound =
    when range.lb is {
      None ->
        IntervalBound { bound_type: NegativeInfinity, is_inclusive: False }
      Some(ts) ->
        IntervalBound { bound_type: Finite(ts + 1), is_inclusive: True }
    }
  let upper_bound =
    when range.ub is {
      None ->
        IntervalBound { bound_type: PositiveInfinity, is_inclusive: False }
      Some(ts) -> IntervalBound { bound_type: Finite(ts), is_inclusive: False }
    }
  Interval { lower_bound, upper_bound }
}

// We only allow merging of a ranges which in our context
// will not break validation of substeps:
// * completely open bound can be merged with anything
// * non empty bound has to be preserved to guarantee validity
// In other words combining two different finite bound values should error.
pub fn combine_validity_ranges(range1, range2) -> ExclusiveValidityRange {
  let combine_bound =
    fn(b1, b2) {
      if b1 == b2 {
        b1
      } else {
        when (b1, b2) is {
          (None, b2) -> b2
          (b1, None) -> b1
          _ -> fail @"Cannot combine different finite bounds"
        }
      }
    }
  let ExclusiveValidityRange { lb: lb1, ub: ub1 } = range1
  let ExclusiveValidityRange { lb: lb2, ub: ub2 } = range2
  ExclusiveValidityRange(combine_bound(lb1, lb2), combine_bound(ub1, ub2))
}

// Gen a finite validity range which have some wiggle room for the transaction submission
pub fn gen_validity_range() {
  let now = 2 * max_period + 20 * day
  let ub = now - max_period - 1
  let tx_submission_margin <- and_then(fuzz.int_between(hour, day))
  let lb = ub - tx_submission_margin
  fuzz.constant(ExclusiveValidityRange(Some(lb), Some(ub)))
}

pub const mempty_tx = Tx([], [], [], open_validity_range)

// Simplified transaction which we can combine in a rather sensible manner
pub type Tx {
  Tx {
    inputs: List<tx.Input>,
    outputs: List<tx.Output>,
    signatories: List<VerificationKeyHash>,
    validity_range: ExclusiveValidityRange,
  }
}

pub fn tx_to_transaction(tx: Tx) -> Transaction {
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

pub fn tx_mappend(tx1: Tx, tx2: Tx) -> Tx {
  let input = tx1.inputs |> list.concat(tx2.inputs)
  let output = tx1.outputs |> list.concat(tx2.outputs)
  let signatories =
    tx1.signatories
      |> list.concat(tx2.signatories)
      |> list.sort(bytearray.compare)
      |> list.unique()
  let validity_range =
    combine_validity_ranges(tx1.validity_range, tx2.validity_range)
  Tx(input, output, signatories, validity_range)
}

pub fn gen_new_channel(
  own_hash: ScriptHash,
  cid: t.ChannelId,
) -> Fuzzer<
  (
    Address,
    Amount,
    t.Snapshot,
    Period,
    t.Keys,
    Value,
    t.MinAdaAmount,
    t.MinAdaOwner,
  ),
> {
  let addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  // Charge the channel
  let amount <-
    and_then(fuzz.int_between(min_channel_amount, max_channel_amount - 1))
  let gift_amount <- and_then(fuzz.int_between(0, max_channel_amount - amount))
  let base_value = assets.from_lovelace(amount + gift_amount + min_ada)
  let value = base_value |> assets.add(own_hash, token.cid_to_token(cid), 1)

  // Setup the rest of the channel
  let keys <- and_then(gen_keys())
  let period <- and_then(fuzz.int_between(min_period, max_period))
  let min_ada_owner <- and_then(fuzz.int_between(0, 1))
  // TODO: support non empty snapshots
  fuzz.constant(
    (addr, amount, empty_snapshot, period, keys, value, min_ada, min_ada_owner),
  )
}

pub fn gen_new_channel_output(
  own_hash: ScriptHash,
  seed: OutputReference,
  rev_index: Int,
) {
  let cid = channel.mk_cid(seed, rev_index)
  let (own_addr, amount, snapshot, period, keys, value, min_ada, min_ada_owner) <-
    and_then(gen_new_channel(own_hash, cid))
  let stage = t.Opened(amount, snapshot, period)
  let output =
    tx.Output(
      own_addr,
      value,
      InlineDatum((own_hash, keys, stage, min_ada, min_ada_owner)),
      None,
    )
  fuzz.constant(output)
}

pub fn gen_new_channels_outputs(
  own_hash: ScriptHash,
  n_mint: Int,
) -> Fuzzer<(OutputReference, Int, List<Output>)> {
  let seed <- and_then(cardano.output_reference())
  let new_outputs <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(0, n_mint - 1),
        fn(index) { gen_new_channel_output(own_hash, seed, n_mint - index) },
      ),
    )
  fuzz.constant((seed, n_mint, new_outputs))
}

pub fn gen_cid() {
  let seed <- and_then(cardano.output_reference())
  fuzz.constant(channel.mk_cid(seed, 0))
}

type ByOpener =
  Bool

pub fn gen_add_step_tx(own_hash) -> Fuzzer<(Tx, ByOpener)> {
  // Generate channel input
  let cid <- and_then(gen_cid())
  let (
    own_addr,
    amt_non_opener_in,
    sn,
    period,
    keys,
    value_in,
    min_ada,
    min_ada_owner,
  ) <- and_then(gen_new_channel(own_hash, cid))
  let by_opener <- and_then(fuzz.bool())
  let tx_out_ref <- and_then(cardano.output_reference())
  let output =
    tx.Output(
      own_addr,
      value_in,
      InlineDatum(
        (
          own_hash,
          keys,
          t.Opened(amt_non_opener_in, sn, period),
          min_ada,
          min_ada_owner,
        ),
      ),
      None,
    )
  let input = tx.Input(tx_out_ref, output)
  // Generate channel output
  let amount_add <- and_then(fuzz.int_between(1, 100000000000000000))
  let value_add = assets.from_lovelace(amount_add)
  let value_out = assets.merge(value_in, value_add)
  let stage_out =
    // TODO: add support for snapshot update
    if by_opener {
      t.Opened(amt_non_opener_in, sn, period)
    } else {
      t.Opened(amt_non_opener_in + amount_add, sn, period)
    }
  let output =
    tx.Output(
      own_addr,
      value_out,
      InlineDatum((own_hash, keys, stage_out, min_ada, min_ada_owner)),
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
        list.range(1, n_steps),
        fn(_) { gen_add_step_tx(own_hash) },
      ),
    )
  let tx =
    txs
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction
  // FIXME: we are not generating optional snapshot updates
  let redeemer =
    (
      None,
      txs
        |> list.map(
            fn((_, by_opener)) {
              let add = t.Add { by_opener, snapshot: None }
              t.Continuing(add)
            },
          ),
    )
  fuzz.constant((transaction, redeemer))
}

pub fn chqs2pends(receipt_cheqs: List<Signed<t.Cheque>>) -> t.Pend {
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
// pub fn gen_close_tx(
//   own_hash,
//   max_cheques,
//   validity_range,
//   possible_channel_output: Option<tx.Output>,
//   draining: ChannelDrainingOptions,
// ) -> Fuzzer<(Tx, ByOpener, Receipt)> {
//   // Generate and parse the channel input
// 
//   let input_out_ref <- and_then(cardano.output_reference())
//   let prev_channel_output <-
//     and_then(
//       when possible_channel_output is {
//         Some(output) -> fuzz.constant(output)
//         None -> gen_new_channel_output(own_hash, input_out_ref, 0, 1)
//       },
//     )
//   expect Some((own_address, keys_in, stage_in, _, tot_in)) =
//     parse_cl_output(prev_channel_output)
//   expect t.Opened(amt_non_opener_in, sn_in, period_in) = stage_in
//   let input = tx.Input(input_out_ref, prev_channel_output)
// 
//   // Generate the redeemer: `Close { by_opener: Bool, receipt: Receipt }
//   let close_by_opener <- and_then(fuzz.bool())
//   trace @"close_by_opener": close_by_opener
//   let keys_out =
//     if close_by_opener {
//       keys_in
//     } else {
//       (keys_in.2nd, keys_in.1st)
//     }
//   let (self_key, other_key) = keys_out
// 
//   let amt_closer_in =
//     if close_by_opener {
//       tot_in - amt_non_opener_in
//     } else {
//       amt_non_opener_in
//     }
// 
//   trace @"Generating snapshot"
//   let keys_order = mk_keys_order(self_key, other_key)
//   let sn_out <-
//     and_then(
//       gen_snapshot(
//         amt_closer_in,
//         tot_in - amt_closer_in,
//         max_cheques,
//         keys_order,
//         Some(sn_in),
//         draining,
//       ),
//     )
//   trace @"Snapshot generated": sn_out
// 
//   let (squash_received, squash_sent) =
//     when keys_order is {
//       SelfKeySmaller -> sn_out
//       SelfKeyLarger -> (sn_out.2nd, sn_out.1st)
//     }
//   // The closer current net income from the squashes
//   let squash_diff = squash_received.1st - squash_sent.1st
// 
//   let receipt <-
//     and_then(
//       {
//         let which_sq =
//           when keys_order is {
//             SelfKeySmaller -> FirstSquash
//             SelfKeyLarger -> SecondSquash
//           }
//         let non_closer_deposit =
//           if close_by_opener {
//             amt_non_opener_in
//           } else {
//             tot_in - amt_non_opener_in
//           }
//         // FIXME: Not sure if this kind of approximation is good enough.
//         // Should we take into the account also excluded cheques in here?
//         let max_cheques_amount = non_closer_deposit - squash_diff
//         gen_receipt(
//           sn_out,
//           max_cheques,
//           max_cheques_amount,
//           which_sq,
//           validity_range,
//         )
//       },
//     )
//   trace @"receipt": receipt
// 
//   expect ExclusiveValidityRange { lb: _, ub: Some(ub) } = validity_range
//   let timeout = ub + period_in
//   let pend_out = chqs2pends(receipt.2nd)
//   let chqs_amt =
//     receipt.2nd
//       |> list.filter_map(
//           fn(signed_cheque) {
//             when signed_cheque.1st is {
//               t.Normal(_, amount) -> Some(amount)
//               t.HtlcUnlocked(_idx, _chq_timeout, _lock, amount) -> Some(amount)
//               t.Htlc(_, _, _, _) -> None
//             }
//           },
//         )
//       |> list.reduce(0, fn(acc, amt) { acc + amt })
//   let amt_closer_out = amt_closer_in + chqs_amt + squash_diff
// 
//   trace @"gen_close_tx: amt_closer_in": amt_closer_in
//   trace @"gen_close_tx: squash_diff": squash_diff
//   trace @"gen_close_tx: chqs_amt": chqs_amt
//   trace @"gen_close_tx: amt_closer_out": amt_closer_out
// 
//   expect amt_closer_out >= 0
//   let stage_out = t.Closed(amt_closer_out, squash_sent, timeout, pend_out)
//   let Output { address: _, value, datum: _, reference_script: _ } =
//     prev_channel_output
//   let output =
//     tx.Output(
//       own_address,
//       value,
//       InlineDatum((own_hash, keys_out, stage_out)),
//       None,
//     )
//   let signatory =
//     if close_by_opener {
//       blake2b_224(keys_in.1st)
//     } else {
//       blake2b_224(keys_in.2nd)
//     }
//   let tx = Tx([input], [output], [signatory], validity_range)
// 
//   trace @"tx": tx
//   fuzz.constant((tx, close_by_opener, receipt))
// }
// 
// pub fn gen_close_steps_transaction(
//   own_hash,
//   max_cheques,
//   n_steps,
// ) -> Fuzzer<(Transaction, MintRedeemer)> {
//   let validity_range <- and_then(gen_validity_range())
//   let txs_with_receipts <-
//     and_then(
//       fuzz_contrib.traverse_list(
//         list.range(1, n_steps),
//         fn(_) {
//           gen_close_tx(
//             own_hash,
//             max_cheques,
//             validity_range,
//             None,
//             AllowAnyDraining,
//           )
//         },
//       ),
//     )
//   let tx =
//     txs_with_receipts
//       |> list.map(fn((t, _, _)) { t })
//       |> list.reduce(mempty_tx, tx_mappend)
//   let transaction = tx |> tx_to_transaction
//   let redeemer =
//     (
//       None,
//       txs_with_receipts
//         |> list.map(
//             fn((_, by_opener, receipt)) {
//               t.Continuing(t.Close { by_opener, receipt })
//             },
//           ),
//     )
//   trace @"transaction": transaction
//   fuzz.constant((transaction, redeemer))
// }
// 
// fn sum_pend(pend) {
//   list.reduce(pend, 0, fn(acc, (amt, _, _)) { acc + amt })
// }
// 
// fn received_and_sent(keys_order: KeysOrder, sn: t.Snapshot) {
//   when keys_order is {
//     SelfKeySmaller -> sn
//     SelfKeyLarger -> (sn.2nd, sn.1st)
//   }
// }
// 
// pub type MkRespondTimeout {
//   MkElapsedTimeout
//   MkNotYetElapsedTimeout
// }
// 
// // Creates a close step based on the next step validity range
// // how to construct proper validity range:
// pub fn gen_close_tx_for_next_step_validity_range(
//   own_hash,
//   max_cheques,
//   validity_range: ExclusiveValidityRange,
//   mk_respond_timeout: MkRespondTimeout,
//   draining: ChannelDrainingOptions,
// ) {
//   let out_ref <- and_then(cardano.output_reference())
//   let new_channel_output <-
//     and_then(gen_new_channel_output(own_hash, out_ref, 0, 1))
//   expect Some((_, _, t.Opened(_, _, period_in), _, _)) =
//     parse_cl_output(new_channel_output)
//   expect ExclusiveValidityRange { lb: Some(past), ub: Some(future) } =
//     validity_range
//   let closing_validity_range =
//     when mk_respond_timeout is {
//       MkElapsedTimeout ->
//         ExclusiveValidityRange(
//           Some(past - period_in - 1000),
//           Some(past - period_in - 1),
//         )
//       MkNotYetElapsedTimeout ->
//         ExclusiveValidityRange(
//           Some(future - period_in + 10),
//           Some(future - period_in + 1000),
//         )
//     }
//   //  Generate a prior close state (simulates a valid close output as input).
//   expect (close_tx, _closed_by_opener, (Some((closing_sn, _sig)), _chqs)) <-
//     and_then(
//       gen_close_tx(
//         own_hash,
//         max_cheques,
//         closing_validity_range,
//         Some(new_channel_output),
//         draining,
//       ),
//     )
//   fuzz.constant((close_tx, closing_sn))
// }
// 
// pub fn gen_respond_step_tx(
//   own_hash,
//   max_cheques,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, t.DropOld, t.Receipt)> {
//   let (close_tx, closing_sn) <-
//     and_then(
//       gen_close_tx_for_next_step_validity_range(
//         own_hash,
//         max_cheques,
//         validity_range,
//         MkNotYetElapsedTimeout,
//         AllowAnyDraining,
//       ),
//     )
//   expect Some((
//     _own_address,
//     keys,
//     t.Closed(amt_closer_in, _sq_in, respond_timeout, pend_closer_in),
//     cid,
//     lovelace_in,
//   )) = parse_singleton_step_tx(close_tx)
// 
//   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
//   expect respond_timeout > ub
// 
//   // Release own pending cheques which are expired if requested
//   let drop_old <- and_then(fuzz.bool())
//   let closer_pends_out = do_drop_old(drop_old, pend_closer_in, lb)
// 
//   let (other, self) = keys
//   // as `keys = (closer, non-closer)`
//   let keys_order = mk_keys_order(self, other)
//   let (closing_received, closing_sent) =
//     received_and_sent(keys_order, closing_sn)
//   let (receipt, new_received) <-
//     and_then(
//       {
//         // During the respond step non-closer provides possibly a newer snapshot.
//         //
//         // Even if this newer snapshot contains updated squash which was sent by
//         // the non-closer it is ignored because that is clearly invalid (closer should not
//         // not accept more cheques after the close).
//         //
//         // On the other hand the squash which was received by the non-closer is taken
//         // into account as closer had no incentive to provide that one with the largest
//         // amount. The incentive of non-closer now is to provide the latest received squash
//         // with the largest total and as many cheques from the closer as possible.
//         let min_sq_received = closing_received.1st
//         // amt_closer_in is the minimal balance owned by the closer
//         // assuming no other pending liabilities at the moment of closing
//         // (all sent cheques were expired or something like that).
//         // The below amount could be larger then what we assume here
//         // because some cheques sent by the closer could expired in between
//         // so the closer could issue more cheques to the non-closer.
//         // We ignore that possibility for simplicity.
//         let max_sq_received = min_sq_received + amt_closer_in
// 
//         trace @"gen_respond_step_tx: min_sq_received": min_sq_received
//         trace @"gen_respond_step_tx: max_sq_received": max_sq_received
// 
//         let new_received <-
//           and_then(
//             gen_squash(
//               max_cheques,
//               min_sq_received,
//               max_sq_received,
//               Some(closing_received),
//             ),
//           )
//         let max_cheques_amount =
//           amt_closer_in - ( new_received.1st - closing_received.1st )
//         let receipt: t.Receipt <-
//           and_then(
//             when keys_order is {
//               SelfKeySmaller -> {
//                 let sn = (new_received, closing_sent)
//                 gen_receipt(
//                   sn,
//                   max_cheques,
//                   max_cheques_amount,
//                   FirstSquash,
//                   validity_range,
//                 )
//               }
//               SelfKeyLarger -> {
//                 let sn = (closing_sent, new_received)
//                 gen_receipt(
//                   sn,
//                   max_cheques,
//                   max_cheques_amount,
//                   SecondSquash,
//                   validity_range,
//                 )
//               }
//             },
//           )
//         fuzz.constant((receipt, new_received))
//       },
//     )
// 
//   let close_out_ref <- and_then(cardano.output_reference())
//   expect Tx {
//     inputs: _i,
//     outputs: [close_output],
//     signatories: _s,
//     validity_range: _vr,
//   } = close_tx
//   let tx.Output { address: own_addr, .. } = close_output
//   let input = tx.Input(close_out_ref, close_output)
//   let pend_non_closer_out = chqs2pends(receipt.2nd)
// 
//   let amt_closer_out = {
//     let sq_diff = new_received.1st - closing_received.1st
//     let chqs_amt =
//       receipt.2nd
//         |> list.filter_map(
//             fn(signed_cheque) {
//               when signed_cheque.1st is {
//                 t.Normal(_, amount) -> Some(amount)
//                 // We should not unlock expired cheques...
//                 // but let's put a guard around that.
//                 t.HtlcUnlocked(_, chq_timeout, _, amount) ->
//                   if chq_timeout > ub {
//                     Some(amount)
//                   } else {
//                     None
//                   }
//                 t.Htlc(_, _, _, _) -> None
//               }
//             },
//           )
//         |> list.reduce(0, fn(acc, amt) { acc + amt })
//     amt_closer_in - sq_diff - chqs_amt
//   }
// 
//   // The amount of money left should cover the closer's account
//   // (which *should* be larger than closer's liabilities).
//   // We should also secure possible liabilities of the non-closer.
//   let lovelace_out = {
//     let lo = amt_closer_out + sum_pend(pend_non_closer_out)
//     if lo == 0 {
//       // On the chain some lovelace will be naturally secured
//       // because of the minUTxO rule.
//       // In this context we have to enforce that so
//       // we don't end up with an unrealistic value for which
//       // parsing fails on the cl validator level.
//       1
//     } else {
//       lo
//     }
//   }
//   let total_out =
//     assets.from_lovelace(lovelace_out)
//       |> assets.add(own_hash, token.cid_to_token(cid), 1)
//   let channel_output =
//     tx.Output(
//       own_addr,
//       total_out,
//       InlineDatum(
//         (
//           own_hash,
//           keys,
//           t.Responded(amt_closer_out, closer_pends_out, pend_non_closer_out),
//         ),
//       ),
//       None,
//     )
//   let payout_output_value = assets.from_lovelace(lovelace_in - lovelace_out)
//   let payout_output_addr <-
//     and_then(cardano.address_with_payment_credential(VerificationKey(keys.2nd)))
// 
//   let payout_output =
//     tx.Output(payout_output_addr, payout_output_value, NoDatum, None)
//   let signatory = blake2b_224(keys.2nd)
//   fuzz.constant(
//     (
//       Tx([input], [channel_output, payout_output], [signatory], validity_range),
//       drop_old,
//       receipt,
//     ),
//   )
// }
// 
// pub fn gen_respond_steps_transaction(
//   own_hash,
//   max_cheques,
//   n_steps,
// ) -> Fuzzer<(Transaction, t.MintRedeemer)> {
//   expect ExclusiveValidityRange { lb: Some(close_lb), ub: Some(close_ub) } <-
//     and_then(gen_validity_range())
//   let validity_range =
//     ExclusiveValidityRange(
//       Some(close_lb + max_period),
//       Some(close_ub + max_period),
//     )
// 
//   let txs_with_receipts <-
//     and_then(
//       fuzz_contrib.traverse_list(
//         list.range(1, n_steps),
//         fn(_) { gen_respond_step_tx(own_hash, max_cheques, validity_range) },
//       ),
//     )
//   let tx =
//     txs_with_receipts
//       |> list.map(fn((t, _, _)) { t })
//       |> list.reduce(mempty_tx, tx_mappend)
//   let transaction = tx |> tx_to_transaction
//   let redeemer =
//     (
//       None,
//       txs_with_receipts
//         |> list.map(fn((_t, d, r)) { t.Continuing(t.Respond(r, d)) }),
//     )
//   fuzz.constant((transaction, redeemer))
// }
// 
// pub fn enumerate(lst) {
//   lst |> list.indexed_map(fn(i, v) { (i, v) })
// }
// 
// // pub fn legacy_gen_elapse_step_tx(
// //   own_hash,
// //   max_cheques,
// //   validity_range: ExclusiveValidityRange,
// //   gen_attempt: Int,
// // ) -> Fuzzer<(Tx, t.Secrets)> {
// //   let (close_tx, _closing_sn) <-
// //     and_then(gen_close_tx_for_next_step_validity_range(own_hash, max_cheques, validity_range, MkElapsedTimeout, ForbidDraining))
// // 
// //   expect Some((
// //     own_address,
// //     keys_in,
// //     t.Closed(amt_closer_in, _sq_in, respond_timeout, pend_closer_in),
// //     cid,
// //     tot_in,
// //   )) = parse_singleton_step_tx(close_tx)
// // 
// //   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
// // 
// //   trace @"gen_elapse_step_tx: lb": lb
// //   trace @"gen_elapse_step_tx: ub": ub
// //   trace @"gen_elapse_step_tx: respond_timeout": respond_timeout
// //   expect lb > respond_timeout
// // 
// //   let indexed_pends = enumerate(pend_closer_in)
// //   let non_expired_pends = indexed_pends |> list.filter(fn((_, (_, timeout, _))) { timeout > ub })
// // 
// //   // When pends covers reminder and we resolve them all
// //   // then this operation should be actually `end`.
// //   // That is why we are enforcing here that not everything is
// //   // resolved.
// //   let pends_cover_reminder = sum_pend(non_expired_pends |> list.map(fn((_, pend)) { pend })) == tot_in - amt_closer_in
// //   trace @"gen_elapse_step_tx: pend_cover_reminder": pends_cover_reminder
// // 
// //   let preserve_ne_idx <- and_then(
// //     if pends_cover_reminder {
// //       let idx <- and_then(fuzz.int_between(0, list.length(non_expired_pends) - 1))
// //       fuzz.constant(Some(idx))
// //     } else {
// //       fuzz.constant(None)
// //     }
// //   )
// //   let secrets_idxs <- and_then({
// //     let possible_idxs <- and_then(fuzz_contrib.traverse_list(
// //       enumerate(non_expired_pends),
// //       fn((ne_idx, (idx, _pend))) {
// //         let resolve <- and_then(fuzz.bool())
// //         if resolve && preserve_ne_idx != Some(ne_idx) {
// //           fuzz.constant(Some(idx))
// //         } else {
// //           fuzz.constant(None)
// //         }
// //       })
// //     )
// //     fuzz.constant(possible_idxs |> list.filter_map(fn(o) { o }))
// //   })
// //   let secrets = secrets_idxs |> list.map(fn(idx) { (idx, htlc_secret) })
// //   let closer_pends_out = indexed_pends |> list.foldr([], fn((idx, pend), acc) {
// //     if pend.2nd > ub && !list.has(secrets_idxs, idx) {
// //       list.push(acc, pend)
// //     } else {
// //       acc
// //     }
// //   })
// // 
// //   let amt_freed = sum_pend(pend_closer_in) - sum_pend(closer_pends_out)
// //   // Leave at least one lovelace - this will be enforced by min ADA ledger rule
// //   // Without this 1 lovelace parsing of the UTxO fails.
// //   // TODO: Should we actually change the protocol so full drain is possible here?
// //   let tot_out = tot_in - amt_closer_in - amt_freed
// // 
// //   trace @"gen_elapse_step_tx: amt_closer_in": amt_closer_in
// //   trace @"gen_elapse_step_tx: amt_freed": amt_freed
// //   trace @"gen_elapse_step_tx: tot_in": tot_in
// //   trace @"gen_elapse_step_tx: tot_out": tot_out
// // 
// //   expect Tx { inputs: _, outputs: [close_output], signatories: _, validity_range: _ } = close_tx
// //   let close_out_ref <- and_then(cardano.output_reference())
// //   let input = tx.Input(close_out_ref, close_output)
// // 
// //   if tot_out > 0 && pend_closer_in != closer_pends_out { // && closer_pends_out != [] {
// //     let stage_out = t.Elapsed(closer_pends_out)
// //     let output = tx.Output(
// //       own_address,
// //       assets.from_lovelace(tot_out) |> assets.add(own_hash, token.cid_to_token(cid), 1),
// //       InlineDatum((own_hash, keys_in, stage_out)),
// //       None,
// //     )
// // 
// //     let signatory = blake2b_224(keys_in.1st)
// //     let tx = Tx([input], [output], [signatory], validity_range)
// //     fuzz.constant((tx, secrets))
// //   } else {
// //     if gen_attempt < max_gen_attempts {
// //       trace @"gen_elapse_step_tx: retrying due to full resolution or full drain"
// //       gen_elapse_step_tx(own_hash, max_cheques, validity_range, gen_attempt + 1)
// //     } else {
// //       fail @"gen_elapse_step_tx: too many attempts to avoid full resolution or a full drain"
// //     }
// //   }
// // }
// 
// // Limits are only relevant to the non-expired cheques.
// // In other words the functions tries to generate
// // at least non-expired `min_cheques` etc.
// pub fn gen_pends(
//   min_cheques,
//   max_cheques,
//   min_amount,
//   max_amount,
//   lb,
//   ub,
// ) -> Fuzzer<t.Pend> {
//   when (max_cheques, max_amount) is {
//     (0, _) -> fuzz.constant([])
//     (_, 0) -> fuzz.constant([])
//     (1, _) -> {
//       let amount <- and_then(fuzz.int_between(min_amount, max_amount))
//       fuzz.constant([(amount, ub + 1, htlc_lock)])
//     }
//     _ -> {
//       let generate <-
//         and_then(
//           if min_amount > 0 || min_cheques > 0 {
//             fuzz.constant(True)
//           } else {
//             fuzz.bool()
//           },
//         )
//       if !generate {
//         fuzz.constant([])
//       } else {
//         let amount <-
//           and_then(fuzz.int_between(1, max_amount / max(1, min_cheques)))
//         let expired <- and_then(fuzz.bool())
//         let (timeout, rest) <-
//           and_then(
//             if expired {
//               let timeout = lb - 1
//               let rest <-
//                 and_then(
//                   gen_pends(
//                     min_cheques,
//                     max_cheques,
//                     min_amount,
//                     max_amount,
//                     lb,
//                     ub,
//                   ),
//                 )
//               fuzz.constant((timeout, rest))
//             } else {
//               let timeout = ub + 1
//               let rest <-
//                 and_then(
//                   gen_pends(
//                     min_cheques - 1,
//                     max_cheques - 1,
//                     min_amount - amount,
//                     max_amount - amount,
//                     lb,
//                     ub,
//                   ),
//                 )
//               fuzz.constant((timeout, rest))
//             },
//           )
//         fuzz.constant(list.push(rest, (amount, timeout, htlc_lock)))
//       }
//     }
//   }
// }
// 
// type SecretsGenStrategy {
//   AllowFullReduction
//   EnforceFullReduction
//   PreventFullReduction
// }
// 
// fn gen_secrets(pends_in, ub, secrets_gen_strategy) -> Fuzzer<t.Secrets> {
//   let secrets <-
//     and_then(
//       fuzz_contrib.foldr(
//         pends_in |> enumerate,
//         [],
//         fn((idx, pend), acc) {
//           let (_, timeout, _) = pend
//           if timeout > ub {
//             let resolve <- and_then(fuzz.bool())
//             if resolve || secrets_gen_strategy == EnforceFullReduction {
//               fuzz.constant(list.push(acc, (idx, htlc_secret)))
//             } else {
//               fuzz.constant(acc)
//             }
//           } else {
//             fuzz.constant(acc)
//           }
//         },
//       ),
//     )
//   let non_expr_pends_in =
//     pends_in |> list.filter(fn((_, timeout, _)) { timeout > ub })
//   if secrets_gen_strategy == PreventFullReduction && ( non_expr_pends_in |> list.length() ) == (
//     secrets |> list.length()
//   ) {
//     let idx <- and_then(fuzz.int_between(0, ( secrets |> list.length() ) - 1))
//     fuzz.constant(
//       secrets |> list.take(idx) |> list.concat(secrets |> list.drop(idx + 1)),
//     )
//   } else {
//     fuzz.constant(secrets)
//   }
// }
// 
// pub fn gen_non_empty_secrets(
//   received_pends,
//   ub,
//   secrets_gen_strategy,
// ) -> Fuzzer<t.Secrets> {
//   let secrets <- and_then(gen_secrets(received_pends, ub, secrets_gen_strategy))
//   if secrets == [] {
//     expect Some((idx, _)) =
//       received_pends
//         |> enumerate
//         |> list.find(fn((_, (_, timeout, _))) { timeout > ub })
//     // Sanity check: we either allow full reduction or have more than one non-expired cheque
//     expect (
//       secrets_gen_strategy != PreventFullReduction ||
//       ( received_pends |> list.filter(fn((_, timeout, _)) { timeout > ub }) |> list.length() ) > 1
//     )
//     fuzz.constant([(idx, htlc_secret)])
//   } else {
//     fuzz.constant(secrets)
//   }
// }
// 
// fn reduce_received_pends(
//   received_pends: t.Pend,
//   secrets: t.Secrets,
//   ub: PosixMilliseconds,
// ) -> t.Pend {
//   let secrets_idxs = secrets |> list.map(fn((idx, _)) { idx })
//   received_pends
//     |> enumerate
//     |> list.foldr(
//         [],
//         fn((idx, pend), acc) {
//           if !list.has(secrets_idxs, idx) {
//             list.push(acc, pend)
//           } else {
//             let (_, timeout, _) = pend
//             expect timeout > ub
//             acc
//           }
//         },
//       )
// }
// 
// fn do_drop_old(
//   drop_old: Bool,
//   sent_pends: t.Pend,
//   lb: PosixMilliseconds,
// ) -> t.Pend {
//   if !drop_old {
//     sent_pends
//   } else {
//     sent_pends |> list.filter(fn((_, timeout, _)) { timeout > lb })
//   }
// }
// 
// // Objective:
// // * Let's just create a utxo in `Closed` stage: `Closed(Amount, Squash, Timeout, Pend)`
// // * This `Closed` stage should have a non empty `closer_pend`
// // * We can either elapse all the pending cheques if the other party squash which is present has non zero amount
// // * Or we can elapse just a subset of the pending cheques so we won't drain the channel
// //
// // Pieces:
// // * `stage_in`:
// //    * `timeout` is trivially derived from the validity range
// //    * `squash_in` can be arbitrary
// //    * `closer_pends_in` can be arbitrary
// //    * `amt_closer_in` is guaranteed amount which is reserved for the `closer`.
// //    *    We need a little more in the channel so we won't end by draining it.
// // * `stage_out`:
// //    * `closer_pend_out` is derived from `closer_pends_in` by removing some cheques
// pub fn gen_elapse_step_tx(
//   own_address,
//   max_cheques,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, t.Secrets)> {
//   expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
//     own_address
//   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
//   // Timeout has passed
//   let closer_pends_in <-
//     and_then(gen_pends(0, max_cheques, 0, max_squash_amount, lb, ub))
//   let sq_in <- and_then(gen_squash(max_cheques, 0, max_squash_amount, None))
//   let amt_closer_in <- and_then(fuzz.int_between(1, max_channel_amount / 2))
//   let min_remainings = sum_pend(closer_pends_in) + list.length(sq_in.3rd) + 1
//   // +1 for min-ADA
//   let remainings <-
//     and_then(fuzz.int_between(min_remainings, max_channel_amount / 2))
//   let tot_in = amt_closer_in + remainings
// 
//   let secrets <- and_then(gen_secrets(closer_pends_in, ub, PreventFullReduction))
//   let closer_pends_out = reduce_received_pends(closer_pends_in, secrets, ub)
// 
//   let amt_freed = sum_pend(closer_pends_in) - sum_pend(closer_pends_out)
//   let tot_out = tot_in - amt_closer_in - amt_freed
// 
//   trace @"gen_elapse_step_tx: tot_out": tot_out
//   trace @"gen_elapse_step_tx: amt_closer_in": amt_closer_in
//   trace @"gen_elapse_step_tx: amt_freed": amt_freed
//   trace @"gen_elapse_step_tx: tot_in": tot_in
// 
//   let timeout_in = lb - 1
//   let stage_in = t.Closed(amt_closer_in, sq_in, timeout_in, closer_pends_in)
//   let cid <- and_then(gen_channel_id())
//   let keys_in <- and_then(gen_keys())
//   let close_out_ref <- and_then(cardano.output_reference())
//   let close_output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_in)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_in)),
//       None,
//     )
//   let close_input = tx.Input(close_out_ref, close_output)
// 
//   let stage_out = t.Elapsed(closer_pends_out)
// 
//   let elapse_output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_out)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_out)),
//       None,
//     )
// 
//   let signatory = blake2b_224(keys_in.1st)
//   let tx = Tx([close_input], [elapse_output], [signatory], validity_range)
//   fuzz.constant((tx, secrets))
// }
// 
// pub fn gen_elapse_steps_transaction(
//   own_hash,
//   max_cheques,
//   n_steps,
// ) -> Fuzzer<(Transaction, t.MintRedeemer)> {
//   // It doesn't hurt to have validity range which has some extra margin
//   let validity_range <- and_then(gen_validity_range())
//   let own_address <-
//     and_then(cardano.address_with_payment_credential(Script(own_hash)))
//   let txs_with_secrets <-
//     and_then(
//       fuzz_contrib.traverse_list(
//         list.range(1, n_steps),
//         fn(_) { gen_elapse_step_tx(own_address, max_cheques, validity_range) },
//       ),
//     )
//   let tx =
//     txs_with_secrets
//       |> list.map(fn((t, _)) { t })
//       |> list.reduce(mempty_tx, tx_mappend)
//   let transaction = tx |> tx_to_transaction
//   let redeemer =
//     (
//       None,
//       txs_with_secrets
//         |> list.map(fn((_, secrets)) { t.Continuing(t.Elapse(secrets)) }),
//     )
//   fuzz.constant((transaction, redeemer))
// }
// 
// // // pub type Stage {
// // //   Opened(Amount, Snapshot, Period)
// // //   Closed(Amount, Squash, Timeout, Pend)
// // //   Responded(Amount, Pend, Pend)
// // //   Elapsed(Pend)
// // //   Resolved(Pend, Pend)
// // // }
// // // pub type MintRedeemer =
// // //   (Option<OutputReference>, List<NStep>)
// // // 
// // // pub type NStep {
// // //   Continuing(CStep)
// // //   End(Secrets)
// // // }
// // // pub type CStep {
// // //   Add(Option<Signed<Snapshot>>)
// // //   Close(Receipt)
// // //   Respond(Receipt, DropOld)
// // //   Resolve(Secrets, DropOld)
// // //   Elapse(Secrets)
// // //   Free(Secrets, DropOld)
// // // }
// // 
// // // pub type HtlcLockedReduced =
// // //   (Amount, Timeout, HtlcLock)
// // 
// // // pub type Pend =
// // //   List<HtlcLockedReduced>
// // //
// // // pub type Cheque {
// // //   Normal(Index, Amount)
// // //   Htlc(Index, Timeout, HtlcLock, Amount)
// // //   HtlcUnlocked(Index, Timeout, HtlcSecret, Amount)
// // // }
// // //
// // // pub type Receipt =
// // //   (Option<Signed<Snapshot>>, List<Signed<Cheque>>)
// // 
// // //  let output =
// // //    tx.Output(
// // //      own_address,
// // //      assets.from_lovelace(total)
// // //        |> assets.add(own_hash, token.cid_to_token(cid), 1),
// // //      InlineDatum((own_hash, keys_out, stage_out)),
// // //      None,
// // //    )
// // // Tx([input], [output], [signatory], validity_range)
// // 
// // // Resolve can be used after when in `Resolved` or `Elapsed`
// // // pub fn gen_post_respond_resolve_step_tx(
// // //   own_hash,
// // //   max_cheques,
// // // ) -> Fuzzer<(Tx, t.Receipt)> {
// // //   expect (respond_tx, drop_old, receipt) <-
// // //     and_then(gen_respond_step_tx(own_hash, max_cheques))
// // //   expect Some((
// // //     keys,
// // //     t.Responded(amount, closer_pends_in, non_closer_pends_in),
// // //     cid,
// // //     lovelace_in,
// // //   )) = parse_singleton_step_tx(respond_tx)
// // // 
// // // }
// // 
// // 
// 
// // Add these helpers near gen_elapse_step_tx for pend reductions (adapted from step.ak logic for generation)
// 
// pub fn gen_resolve_after_elapse_step_tx(
//   own_address,
//   max_cheques,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, t.DropOld)> {
//   expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
//     own_address
//   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
// 
//   // Generate `closer` pends which at least cover 1 Lovelace
//   // with non expired cheques
//   let closer_pends_in <-
//     and_then(gen_pends(1, max_cheques, 1, max_squash_amount, lb, ub))
//   let drop_old <- and_then(fuzz.bool())
//   let closer_pends_out = do_drop_old(drop_old, closer_pends_in, lb)
// 
//   let tot_in <-
//     and_then(
//       fuzz.int_between(sum_pend(closer_pends_in) + 1, max_channel_amount),
//     )
// 
//   // Ensure non-zero to avoid full drain
//   let cid <- and_then(gen_channel_id())
//   let keys_in <- and_then(gen_keys())
// 
//   let stage_in = t.Elapsed(closer_pends_in)
//   let elapse_out_ref <- and_then(cardano.output_reference())
//   let elapse_output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_in)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_in)),
//       None,
//     )
//   let elapse_input = tx.Input(elapse_out_ref, elapse_output)
// 
//   // Non-closer pends are empty because we ignore them during the `elapse`
//   let non_closer_pends_out = []
//   let tot_out = sum_pend(closer_pends_out)
//   let stage_out = t.Resolved(closer_pends_out, non_closer_pends_out)
//   let resolve_output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_out)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_out)),
//       None,
//     )
// 
//   let signatory = blake2b_224(keys_in.2nd)
//   // Non-closer signs (vk1)
//   let tx = Tx([elapse_input], [resolve_output], [signatory], validity_range)
//   fuzz.constant((tx, drop_old))
// }
// 
// pub fn gen_resolve_after_elapse_steps_transaction(
//   own_hash,
//   max_cheques,
//   n_steps,
// ) -> Fuzzer<(Transaction, t.MintRedeemer)> {
//   let validity_range <- and_then(gen_validity_range())
//   // Reuse for safe bounds
//   let own_address <-
//     and_then(cardano.address_with_payment_credential(Script(own_hash)))
//   let txs_with_params <-
//     and_then(
//       fuzz_contrib.traverse_list(
//         list.range(1, n_steps),
//         fn(_) {
//           gen_resolve_after_elapse_step_tx(
//             own_address,
//             max_cheques,
//             validity_range,
//           )
//         },
//       ),
//     )
//   let tx =
//     txs_with_params
//       |> list.map(fn((t, _)) { t })
//       |> list.reduce(mempty_tx, tx_mappend)
//   let transaction = tx |> tx_to_transaction
//   let secrets = []
//   // No secrets needed for resolve from Elapsed (per do_resolve logic)
//   let redeemer =
//     (
//       None,
//       txs_with_params
//         |> list.map(
//             fn((_, drop_old)) { t.Continuing(t.Resolve(secrets, drop_old)) },
//           ),
//     )
//   fuzz.constant((transaction, redeemer))
// }
// 
// // This step is executed by the `closer`:
// // * `closer` releases the account money
// // * the remaining should still cover the pending cheques
// pub fn gen_resolve_after_respond_step_tx(
//   own_address: Address,
//   max_cheques: Int,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, t.Secrets, t.DropOld)> {
//   expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
//     own_address
//   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
// 
//   // Generate `Responded` stage
//   let closer_pends_in <-
//     and_then(gen_pends(0, max_cheques / 2, 0, max_squash_amount / 2, lb, ub))
//   // We generate `closer` pends out so we know if
//   // we need non-closer pends to avoid full resolution
//   let secrets <- and_then(gen_secrets(closer_pends_in, ub, AllowFullReduction))
//   let closer_pends_out = reduce_received_pends(closer_pends_in, secrets, ub)
// 
//   // Ensure that there are some non-expired pending cheques
//   let min_non_closer_pends =
//     if closer_pends_out == [] {
//       1
//     } else {
//       0
//     }
//   let non_closer_pends_in <-
//     and_then(
//       gen_pends(
//         0,
//         max_cheques / 2,
//         min_non_closer_pends,
//         max_squash_amount / 2,
//         lb,
//         ub,
//       ),
//     )
//   let closer_amt_in <- and_then(fuzz.int_between(1, max_channel_amount / 4))
//   let tot_in =
//     closer_amt_in + sum_pend(closer_pends_in) + sum_pend(non_closer_pends_in)
//   let stage_in =
//     t.Responded(closer_amt_in, closer_pends_in, non_closer_pends_in)
// 
//   // Create channel input UTxO
//   let cid <- and_then(gen_channel_id())
//   let keys_in <- and_then(gen_keys())
//   let respond_out_ref <- and_then(cardano.output_reference())
//   let respond_output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_in)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_in)),
//       None,
//     )
//   let respond_input = tx.Input(respond_out_ref, respond_output)
// 
//   let drop_old <-
//     and_then(
//       if closer_pends_out == [] {
//         // We want to preserve at least some non-closer pends
//         // if all the closer pends where reduced
//         fuzz.constant(False)
//       } else {
//         fuzz.bool()
//       },
//     )
// 
//   // Calculate `Resolved` stage
//   let non_closer_pends_out = do_drop_old(drop_old, non_closer_pends_in, lb)
// 
//   let tot_out = sum_pend(closer_pends_out) + sum_pend(non_closer_pends_out)
//   expect tot_out > 0
// 
//   // Ensure we not fully drain the channel
//   let stage_out = t.Resolved(closer_pends_out, non_closer_pends_out)
//   let resolve_output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_out)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_out)),
//       None,
//     )
// 
//   let signatory = blake2b_224(keys_in.1st)
//   // Closer signs (vk0)
//   let tx = Tx([respond_input], [resolve_output], [signatory], validity_range)
//   fuzz.constant((tx, secrets, drop_old))
// }
// 
// pub fn gen_resolve_after_respond_steps_transaction(
//   own_hash: ScriptHash,
//   max_cheques: Int,
//   n_steps: Int,
// ) -> Fuzzer<(Transaction, t.MintRedeemer)> {
//   let validity_range <- and_then(gen_validity_range())
//   // Reuse safe bounds
//   let own_address <-
//     and_then(cardano.address_with_payment_credential(Script(own_hash)))
//   let txs_with_params <-
//     and_then(
//       fuzz_contrib.traverse_list(
//         list.range(1, n_steps),
//         fn(_) {
//           gen_resolve_after_respond_step_tx(
//             own_address,
//             max_cheques,
//             validity_range,
//           )
//         },
//       ),
//     )
//   let tx =
//     txs_with_params
//       |> list.map(fn((t, _, _)) { t })
//       |> list.reduce(mempty_tx, tx_mappend)
//   let transaction = tx |> tx_to_transaction
//   let redeemer =
//     (
//       None,
//       txs_with_params
//         |> list.map(
//             fn((_, secrets, drop_old)) {
//               t.Continuing(t.Resolve(secrets, drop_old))
//             },
//           ),
//     )
//   fuzz.constant((transaction, redeemer))
// }
// 
// // Executed by the `closer` in the `Closed` stage
// pub fn gen_free_step_closed_stage(
//   own_address: Address,
//   max_cheques: Int,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, t.Secrets)> {
//   expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
//     own_address
//   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
// 
//   let closer_pends_in <-
//     and_then(gen_pends(1, max_cheques, 1, max_squash_amount, lb, ub))
//   let secrets <- and_then(gen_non_empty_secrets(closer_pends_in, ub, AllowFullReduction))
//   let closer_pend_out = reduce_received_pends(closer_pends_in, secrets, ub)
//   let amt_reduced = sum_pend(closer_pends_in) - sum_pend(closer_pend_out)
// 
//   let closer_amt_in <- and_then(fuzz.int_between(1, max_channel_amount / 2))
//   let min_tot_in = closer_amt_in + sum_pend(closer_pends_in)
//   let tot_in <- and_then(fuzz.int_between(min_tot_in, max_channel_amount))
// 
//   let cid <- and_then(gen_channel_id())
//   let keys_in <- and_then(gen_keys())
//   let timeout_in = ub + 1
//   // Timeout is in the future
//   let squash_in <- and_then(gen_squash(max_cheques, 0, max_squash_amount, None))
//   let input <-
//     and_then(
//       {
//         let stage_in =
//           t.Closed(closer_amt_in, squash_in, timeout_in, closer_pends_in)
//         let out_ref <- and_then(cardano.output_reference())
//         let output =
//           tx.Output(
//             own_address,
//             assets.from_lovelace(tot_in)
//               |> assets.add(own_hash, token.cid_to_token(cid), 1),
//             InlineDatum((own_hash, keys_in, stage_in)),
//             None,
//           )
//         fuzz.constant(tx.Input(out_ref, output))
//       },
//     )
// 
//   let output = {
//     let amt_out = closer_amt_in + amt_reduced
//     let stage_out = t.Closed(amt_out, squash_in, timeout_in, closer_pend_out)
//     // squash and timeout unchanged
//     let tot_out = tot_in
//     // Total unchanged
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_out)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_out)),
//       None,
//     )
//   }
//   let signatory = blake2b_224(keys_in.1st)
//   let tx = Tx([input], [output], [signatory], validity_range)
//   fuzz.constant((tx, secrets))
// }
// 
// pub fn gen_free_steps_in_closed_stage_transactions(
//   own_hash: ScriptHash,
//   max_cheques: Int,
//   n_steps: Int,
// ) -> Fuzzer<(Transaction, t.MintRedeemer)> {
//   let validity_range <- and_then(gen_validity_range())
//   let own_address <-
//     and_then(cardano.address_with_payment_credential(Script(own_hash)))
//   let txs_with_params <-
//     and_then(
//       fuzz_contrib.traverse_list(
//         list.range(1, n_steps),
//         fn(_) {
//           gen_free_step_closed_stage(own_address, max_cheques, validity_range)
//         },
//       ),
//     )
//   let tx =
//     txs_with_params
//       |> list.map(fn((t, _)) { t })
//       |> list.reduce(mempty_tx, tx_mappend)
//   let transaction = tx |> tx_to_transaction
//   // We can pick drop_old randomly because it should be ignored
//   let drop_old <- and_then(fuzz.bool())
//   let redeemer =
//     (
//       None,
//       txs_with_params
//         |> list.map(
//             fn((_, secrets)) { t.Continuing(t.Free(secrets, drop_old)) },
//           ),
//     )
//   fuzz.constant((transaction, redeemer))
// }
// 
// // Executed by the `non-closer` in the `Responded` stage
// pub fn gen_free_step_in_responded_stage(
//   own_address: Address,
//   max_cheques: Int,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, t.Secrets, t.DropOld)> {
//   expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
//     own_address
//   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
// 
//   let closer_pends_in <-
//     and_then(gen_pends(0, max_cheques / 2, 0, max_squash_amount / 2, lb, ub))
//   // Even if we reduce everything we should stay in the `Responded` stage.
//   // We just enabled the `closer` to directly `end` the channel.
//   let drop_old <- and_then(fuzz.bool())
//   let closer_pends_out = do_drop_old(drop_old, closer_pends_in, lb)
//   let sent_freed = sum_pend(closer_pends_in) - sum_pend(closer_pends_out)
// 
//   let min_non_closer_pends_in =
//     if sent_freed == 0 {
//       1
//     } else {
//       0
//     }
//   let non_closer_pends_in <-
//     and_then(
//       gen_pends(
//         0,
//         max_cheques / 2,
//         min_non_closer_pends_in,
//         max_squash_amount / 2,
//         lb,
//         ub,
//       ),
//     )
// 
//   // Enforce at least one reduction if nothing was freed
//   // to prevent noop step
//   let secrets <-
//     and_then(
//       if sent_freed == 0 {
//         gen_non_empty_secrets(non_closer_pends_in, ub, AllowFullReduction)
//       } else {
//         gen_secrets(non_closer_pends_in, ub, AllowFullReduction)
//       },
//     )
// 
//   let non_closer_pends_out =
//     reduce_received_pends(non_closer_pends_in, secrets, ub)
//   let received_reduced =
//     sum_pend(non_closer_pends_in) - sum_pend(non_closer_pends_out)
//   let min_closer_amt_in =
//     if closer_pends_out == [] {
//       1
//     } else {
//       0
//     }
//   let closer_amt_in <-
//     and_then(fuzz.int_between(min_closer_amt_in, max_channel_amount / 2))
//   let tot_in =
//     closer_amt_in + sum_pend(closer_pends_in) + sum_pend(non_closer_pends_in)
//   let stage_in =
//     t.Responded(closer_amt_in, closer_pends_in, non_closer_pends_in)
//   let cid <- and_then(gen_channel_id())
//   let keys_in <- and_then(gen_keys())
//   let respond_out_ref <- and_then(cardano.output_reference())
//   let respond_output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_in)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_in)),
//       None,
//     )
//   let respond_input = tx.Input(respond_out_ref, respond_output)
//   let tot_out = tot_in - received_reduced - sent_freed
//   expect tot_out > 0
//   // Avoid full drain
//   let stage_out =
//     t.Responded(closer_amt_in, closer_pends_out, non_closer_pends_out)
//   let output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_out)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_out)),
//       None,
//     )
//   // Non-closer signs (vk1)
//   let signatory = blake2b_224(keys_in.2nd)
//   let tx = Tx([respond_input], [output], [signatory], validity_range)
//   fuzz.constant((tx, secrets, drop_old))
// }
// 
// pub fn gen_free_steps_in_responded_stage_transactions(
//   own_hash: ScriptHash,
//   max_cheques: Int,
//   n_steps: Int,
// ) -> Fuzzer<(Transaction, t.MintRedeemer)> {
//   let validity_range <- and_then(gen_validity_range())
//   let own_address <-
//     and_then(cardano.address_with_payment_credential(Script(own_hash)))
//   let txs_with_params <-
//     and_then(
//       fuzz_contrib.traverse_list(
//         list.range(1, n_steps),
//         fn(_) {
//           gen_free_step_in_responded_stage(
//             own_address,
//             max_cheques,
//             validity_range,
//           )
//         },
//       ),
//     )
//   let tx =
//     txs_with_params
//       |> list.map(fn((t, _, _)) { t })
//       |> list.reduce(mempty_tx, tx_mappend)
//   let transaction = tx |> tx_to_transaction
//   let redeemer =
//     (
//       None,
//       txs_with_params
//         |> list.map(
//             fn((_, secrets, drop_old)) {
//               t.Continuing(t.Free(secrets, drop_old))
//             },
//           ),
//     )
//   fuzz.constant((transaction, redeemer))
// }
// 
// pub fn has_not_expired(ub, pend) {
//   let (_, timeout, _) = pend
//   timeout > ub
// }
// 
// pub fn has_expired(lb, pend) {
//   let (_, timeout, _) = pend
//   timeout < lb
// }
// 
// pub fn gen_free_step_in_resolved_stage(
//   own_address: Address,
//   max_cheques: Int,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, Bool, Bool, t.Secrets)> {
//   expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
//     own_address
//   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
// 
//   // The situation in respond is fully symmetrical so we can
//   // stay agnostic who is who modulo
//   // the order of the pends in the `Resolved` stage,
//   // the `by_closer` flag in the redeemer and the signature.
//   //
//   // Ensure that the free step is meaningful:
//   // * Either include at least one sent pend which has expired
//   // * Or include at least one received pend which has not yet expired and will be resolved
//   let other_pends_in <-
//     and_then(gen_pends(0, max_cheques / 2, 0, max_squash_amount / 2, lb, ub))
//   let other_pends_in_expired =
//     other_pends_in |> list.filter(fn(pend) { has_expired(lb, pend) })
//   let self_pends_in <-
//     and_then(
//       if other_pends_in_expired == [] {
//         gen_pends(1, max_cheques / 2, 1, max_squash_amount / 2, lb, ub)
//       } else {
//         gen_pends(0, max_cheques / 2, 0, max_squash_amount / 2, lb, ub)
//       },
//     )
// 
//   let secrets <-
//     and_then(
//       if other_pends_in_expired == [] {
//         gen_non_empty_secrets(self_pends_in, ub, AllowFullReduction)
//       } else {
//         gen_secrets(self_pends_in, ub, AllowFullReduction)
//       },
//     )
//   let drop_old <-
//     and_then(
//       if secrets == [] {
//         // Enforce `drop_old` if we don't execute received cheques
//         // reduction to avoid noop
//         fuzz.constant(True)
//       } else {
//         fuzz.bool()
//       },
//     )
//   let self_pends_out = reduce_received_pends(self_pends_in, secrets, ub)
//   let other_pends_out = do_drop_old(drop_old, other_pends_in, lb)
// 
//   let keys_in <- and_then(gen_keys())
//   let by_closer <- and_then(fuzz.bool())
//   let (stage_in, stage_out, signatories) =
//     if by_closer {
//       (
//         t.Resolved(self_pends_in, other_pends_in),
//         t.Resolved(self_pends_out, other_pends_out),
//         [blake2b_224(keys_in.1st)],
//       )
//     } else {
//       (
//         t.Resolved(other_pends_in, self_pends_in),
//         t.Resolved(other_pends_out, self_pends_out),
//         [blake2b_224(keys_in.2nd)],
//       )
//     }
// 
//   // The protocol now protects the min ADA by checking the tot_out against the freed amounts
//   let tot_in = sum_pend(self_pends_in) + sum_pend(other_pends_in) + min_ada
//   let cid <- and_then(gen_channel_id())
//   let input <-
//     and_then(
//       {
//         let out_ref <- and_then(cardano.output_reference())
//         let output =
//           tx.Output(
//             own_address,
//             assets.from_lovelace(tot_in)
//               |> assets.add(own_hash, token.cid_to_token(cid), 1),
//             InlineDatum((own_hash, keys_in, stage_in)),
//             None,
//           )
//         fuzz.constant(tx.Input(out_ref, output))
//       },
//     )
// 
//   let tot_out = sum_pend(self_pends_out) + sum_pend(other_pends_out) + min_ada
//   let output =
//     tx.Output(
//       own_address,
//       assets.from_lovelace(tot_out)
//         |> assets.add(own_hash, token.cid_to_token(cid), 1),
//       InlineDatum((own_hash, keys_in, stage_out)),
//       None,
//     )
//   let tx = Tx([input], [output], signatories, validity_range)
//   fuzz.constant((tx, by_closer, drop_old, secrets))
// }
// 
// pub fn gen_free_steps_in_resolved_stage_transactions(
//   own_hash: ScriptHash,
//   max_cheques: Int,
//   n_steps: Int,
// ) -> Fuzzer<(Transaction, t.MintRedeemer)> {
//   let validity_range <- and_then(gen_validity_range())
//   let own_address <-
//     and_then(cardano.address_with_payment_credential(Script(own_hash)))
//   let txs_with_params <-
//     and_then(
//       fuzz_contrib.traverse_list(
//         list.range(1, n_steps),
//         fn(_) {
//           gen_free_step_in_resolved_stage(
//             own_address,
//             max_cheques,
//             validity_range,
//           )
//         },
//       ),
//     )
//   let tx =
//     txs_with_params
//       |> list.map(fn((t, _, _, _)) { t })
//       |> list.reduce(mempty_tx, tx_mappend)
//   let transaction = tx |> tx_to_transaction
//   let redeemer =
//     (
//       None,
//       txs_with_params
//         |> list.map(
//             fn((_, by_closer, drop_old, secrets)) {
//               t.Continuing(t.FreeInResolved(by_closer, secrets, drop_old))
//             },
//           ),
//     )
//   fuzz.constant((transaction, redeemer))
// }
// 
// pub type ByCloser = Bool
// 
// // Executed by either party in the `Resolved` stage to fully end the channel
// // by burning the token and releasing all remaining funds after reducing pends.
// pub fn gen_end_from_resolved_step_tx(
//   own_address: Address,
//   max_cheques: Int,
//   validity_range: ExclusiveValidityRange,
// ) -> Fuzzer<(Tx, ByCloser, t.Secrets)> {
//   expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
//     own_address
//   expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
// 
//   // Generate received pends that can be fully reduced
//   let received_cheques <-
//     and_then(gen_pends(0, max_cheques / 2, 0, max_squash_amount / 2, lb, ub))
//   // Reduce them all
//   let secrets <- and_then(gen_secrets(received_cheques, ub, EnsureFullReduction))
// 
//   // Create sent ones which are all expired
//   let sent_cheques <- and_then({
//     let cheques <- and_then(gen_pends(0, max_cheques / 2, 0, max_squash_amount / 2, lb, ub))
//     cheques |> list.filter(fn(p) { has_expired(lb, p) })
//   })
// 
//   let keys_in <- and_then(gen_keys())
//   let by_closer <- and_then(fuzz.bool())
//   let stage_in = t.Resolved(closer_pends_in, non_closer_pends_in)
// 
//   let tot_in = sum_pend(closer_pends_in) + sum_pend(non_closer_pends_in) + min_ada
//   let cid <- and_then(gen_channel_id())
//   let input <-
//     and_then(
//       {
//         let out_ref <- and_then(cardano.output_reference())
//         let output =
//           tx.Output(
//             own_address,
//             assets.from_lovelace(tot_in)
//               |> assets.add(own_hash, token.cid_to_token(cid), 1),
//             InlineDatum((own_hash, keys_in, stage_in)),
//             None,
//           )
//         fuzz.constant(tx.Input(out_ref, output))
//       },
//     )
// 
//   // No continuing output (channel ends), but release funds to a payout address
//   let payout_addr <-
//     and_then(
//       if by_closer {
//         cardano.address_with_payment_credential(VerificationKey(keys_in.2nd))
//       } else {
//         cardano.address_with_payment_credential(VerificationKey(keys_in.1st))
//       },
//     )
//   let payout_output =
//     tx.Output(payout_addr, assets.from_lovelace(tot_in), NoDatum, None)
// 
//   let signatory =
//     if by_closer {
//       blake2b_224(keys_in.1st)
//     } else {
//       blake2b_224(keys_in.2nd)
//     }
//   let tx = Tx([input], [payout_output], [signatory], validity_range)
//   fuzz.constant((tx, by_closer, secrets))
// }
// 
// // pub fn gen_end_from_resolved_steps_transaction(
// //   own_hash: ScriptHash,
// //   max_cheques: Int,
// //   n_steps: Int,
// // ) -> Fuzzer<(Transaction, t.MintRedeemer)> {
// //   let validity_range <- and_then(gen_validity_range())
// //   let own_address <-
// //     and_then(cardano.address_with_payment_credential(Script(own_hash)))
// //   let txs_with_params <-
// //     and_then(
// //       fuzz_contrib.traverse_list(
// //         list.range(1, n_steps),
// //         fn(_) {
// //           gen_end_from_resolved_step_tx(own_address, max_cheques, validity_range)
// //         },
// //       ),
// //     )
// //   let tx =
// //     txs_with_params
// //       |> list.map(fn((t, _, _)) { t })
// //       |> list.reduce(mempty_tx, tx_mappend)
// //   let transaction = tx |> tx_to_transaction
// //   let redeemer =
// //     (
// //       None,
// //       txs_with_params
// //         |> list.map(fn((_, by_closer, secrets)) { t.End(secrets) }),
// //     )
// //   fuzz.constant((transaction, redeemer))
// // }
