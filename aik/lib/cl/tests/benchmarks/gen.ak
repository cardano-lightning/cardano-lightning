use aiken/builtin.{append_bytearray, complement_bytearray, less_than_bytearray}
use aiken/collection.{Index}
use aiken/collection/dict
use aiken/collection/list
use aiken/crypto.{ScriptHash, VerificationKeyHash, blake2b_224}
use aiken/fuzz.{and_then}
use aiken/interval.{
  Finite, Interval, IntervalBound, NegativeInfinity, PositiveInfinity,
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
pub const min_ada = 1

pub const min_channel_amt = 1

pub const max_channel_amt = 1_000_000_000_000_000

pub const max_sq_amt = 100_000_000_000_000

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

// WARNING!
// The amount from the prev_sq is IGNORED. Only idx and
// exclude are used. The new sq amount is based solely
// on the provided min_sq_amt and max_sq_amt.
pub fn gen_sq(
  max_chqs,
  min_sq_amt: Amount,
  max_sq_amt: Amount,
  prev_sq: Option<t.Squash>,
) -> Fuzzer<t.Squash> {
  let max_indices_span = 4 * max_chqs
  let gen_excl =
    fn(sq_idx, excl_num) {
      if excl_num == 0 {
        fuzz.constant([])
      } else {
        let prev_init = max(0, sq_idx - max_indices_span)
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
  when prev_sq is {
    None -> {
      // Base index provides some spacing for the excluded chqs
      let idx <- and_then(fuzz.int_between(0, 1000))
      let excl <-
        and_then(
          {
            let excl_num <- and_then(fuzz.int_between(0, max_chqs))
            gen_excl(idx, excl_num)
          },
        )
      let amt <- and_then(fuzz.int_between(min_sq_amt, max_sq_amt))
      fuzz.constant(t.Squash { amount: amt, index: idx, exclude: excl })
    }
    // * Amount should only increase
    // * This amount increase should be reflected in a bumped index
    // * For now let's simplify generation of the exclude so we are sure that the list do not overlap
    Some(sq) -> {
      expect min_sq_amt <= max_sq_amt
      let amt_out <- and_then(fuzz.int_between(min_sq_amt, max_sq_amt))

      let idx_increase <- and_then(fuzz.int_between(1, max_indices_span))
      let idx_out = sq.index + idx_increase
      let excl_out <-
        and_then(
          {
            let excl_num <- and_then(fuzz.int_between(0, max_chqs))
            let excl_preserved =
              sq.exclude
                |> list.filter(fn(idx) { idx > idx_out - max_indices_span })
                |> fn(preserved) {
                    list.drop(
                      preserved,
                      max(0, list.length(preserved) - excl_num),
                    )
                  }
            let excl_num_remaining =
              max(0, list.length(excl_preserved) - excl_num)
            let excl_remaining <-
              and_then(gen_excl(idx_out, excl_num_remaining))
            fuzz.constant(excl_preserved |> list.concat(excl_remaining))
          },
        )
      fuzz.constant(
        t.Squash { amount: amt_out, index: idx_out, exclude: excl_out },
      )
    }
  }
}

pub const empty_sq: t.Squash = t.Squash { index: 0, amount: 0, exclude: [] }

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
  max_chqs: Int,
  keys_order: KeysOrder,
  prev_snapshot: Option<t.Snapshot>,
  draining: ChannelDrainingOptions,
) -> Fuzzer<t.Snapshot> {
  let (self_received, self_sent) <-
    and_then(
      {
        let (self_received, base_min_sent, base_max_sent, prev_sent) <-
          and_then(
            when prev_snapshot is {
              None -> {
                let max_init_idx = 1_000_000
                let received <-
                  and_then(gen_sq(max_chqs, 0, max_init_idx, None))
                // Given the above `received` baseline create a possible range
                // for the `sent` squash:
                // * The `received` chqs have to be covered by the other's party deposit.
                // * So we should raise at least the amount of received chqs minus
                //  the other's deposit slightly adjusted for the excluded/issued chqs.
                let base_min_sent =
                  max(0, received.amount - other_deposit + max_chqs)
                // * On the other hand we should be able to cover all raised chqs from our deposit.
                // * So the maximum amount we can send is the amount of received chqs plus
                //  our deposit minus some margin for the excluded/issued chqs.
                let base_max_sent = received.amount + self_deposit - max_chqs

                fuzz.constant((received, base_min_sent, base_max_sent, None))
              }
              Some((prev_received, prev_sent)) -> {
                let received <-
                  and_then(
                    gen_sq(max_chqs, prev_received.amount, max_sq_amt, None),
                  )
                // Constraint building here is nearly identical to the above
                // branch but we should take into account the squash boundary which
                // is inherited from the previous snapshot.
                let base_min_sent =
                  max(
                    prev_sent.amount,
                    received.amount - other_deposit + max_chqs,
                  )
                let base_max_sent =
                  max(base_min_sent, received.amount + self_deposit - max_chqs)
                fuzz.constant(
                  (received, base_min_sent, base_max_sent, Some(prev_sent)),
                )
              }
            },
          )

        let (min_sent, max_sent) =
          when draining is {
            AllowAnyDraining -> (base_min_sent, base_max_sent)
            AllowDrainingBySelf -> (base_min_sent, base_max_sent - 1)
            AllowDrainingByOther -> (base_min_sent + 1, base_max_sent)
            ForbidDraining -> (base_min_sent + 1, base_max_sent - 1)
          }
        // Sanity check
        expect min_sent <= max_sent
        let self_sent <-
          and_then(gen_sq(max_chqs, min_sent, max_sent, prev_sent))
        fuzz.constant((self_received, self_sent))
      },
    )
  // From l1 spec:
  // So the squash of the chqs received by the smaller verification key is first.
  // The ordering is important.
  when keys_order is {
    SelfKeySmaller -> fuzz.constant((self_received, self_sent))
    SelfKeyLarger -> fuzz.constant((self_sent, self_received))
  }
}

pub const empty_snapshot: t.Snapshot = (empty_sq, empty_sq)

// Signature verification is patched during benchmarking
// through `env/testing.ak`
const signature = list.repeat(#"00", 64) |> list.reduce(#"", append_bytearray)

// Because during testing we do not really check the signature
// under the original htlc we don't have to worry about producing
// a valid htlc_lock from the secret.
const htlc_secret = list.repeat(#"00", 32) |> list.reduce(#"", append_bytearray)

// Precomputed lock for the above secret
const htlc_lock: t.HtlcLock =
  #"66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925"

pub fn mk_signed(x: a) -> Signed<a> {
  (x, signature)
}

pub type ExpirationSetup {
  MkExpired
  MkAmbigiousTimeout
  MkNotExpired
}

pub fn gen_chq(
  index: Int,
  max_amt: Int,
  expiration_setup: ExpirationSetup,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<t.Cheque> {
  let amount <- and_then(fuzz.int_between(1, max_amt))
  expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
  let delta <- and_then(fuzz.int_between(min_expiration, max_expiration))
  let timeout =
    when expiration_setup is {
      MkExpired -> lb - delta
      MkAmbigiousTimeout -> {
        expect lb + 1 < ub
        lb + 1
      }
      MkNotExpired -> ub + delta
    }
  // Pick type of the cheque
  let locked <- and_then(fuzz.bool())
  if locked {
    fuzz.constant(
      t.Locked { index, timeout, lock: htlc_lock, amount, signature },
    )
  } else {
    fuzz.constant(
      t.Unlocked { index, timeout, secret: htlc_secret, amount, signature },
    )
  }
}

pub fn get_cheque_amt(cheque: t.Cheque) {
  when cheque is {
    t.Locked { index: _, timeout: _, lock: _, amount, signature: _ } -> amount
    t.Unlocked { index: _, timeout: _, secret: _, amount, signature: _ } ->
      amount
  }
}

// In order to generate `Receipt` we have to generate a set of chqs
// which are "compatible" with the `Squash`:
// * We can provide chqs which were issued after the squash (cheque_idx > squash_idx)
// * We can provide chqs which were excluded from the squash (cheque_idx in exclude)
// Invariant: `max_chqs <= max_chqs_amt`
pub fn gen_receipt_chqs(
  sq: t.Squash,
  max_chqs: Int,
  max_chqs_amt: Amount,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<List<t.Cheque>> {
  expect max_chqs >= 0
  expect max_chqs_amt > 0

  let tot_chqs_num <- and_then(fuzz.int_between(0, max_chqs))

  let resolved_chqs_num <- and_then(fuzz.int_between(0, tot_chqs_num))
  let resolved_chqs_idxs: List<Int> <-
    and_then(fuzz_contrib.pick_subset(sq.exclude, resolved_chqs_num))

  let step =
    fn(index, (remaining_max_amt, chqs)) {
      if remaining_max_amt > 0 {
        // Arbitrary upper cap on the single cheque amount to decrease
        // likely hood of max amount draining
        let chq <-
          and_then(
            gen_chq(index, remaining_max_amt / 2, MkNotExpired, validity_range),
          )
        let new_remaining_max_amt = remaining_max_amt - get_cheque_amt(chq)
        let new_chqs = chqs |> list.push(chq)
        fuzz.constant((new_remaining_max_amt, new_chqs))
      } else {
        fuzz.constant((remaining_max_amt, chqs))
      }
    }

  let (remaining_max_amt, resolved_chqs) <-
    and_then(fuzz_contrib.foldr(resolved_chqs_idxs, (max_chqs_amt, []), step))
  // New chqs indexes should be a sequence starting from `sq_index + 1`
  let new_chqs_num = tot_chqs_num - list.length(resolved_chqs)
  let (_, new_chqs) <-
    and_then(
      fuzz_contrib.foldr(
        list.range(sq.index + 1, sq.index + 1 + new_chqs_num),
        (remaining_max_amt, []),
        step,
      ),
    )
  fuzz.constant(
    resolved_chqs
      |> list.concat(new_chqs)
      |> list.sort(
          fn(chq1, chq2) {
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
// receipt submitter (contains sum of received chqs) create a
// corresponding set of received chqs and put together a
// proper `Receipt`.
pub fn gen_receipt(
  snapshot: t.Snapshot,
  max_chqs: Int,
  max_chqs_amt: Amount,
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
  let sq_chqs <-
    and_then(gen_receipt_chqs(sq, max_chqs, max_chqs_amt, validity_range))
  let signed_snapshot = mk_signed((sq1, sq2))
  fuzz.constant((Some(signed_snapshot), sq_chqs))
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
    t.Locked { index, timeout: _, lock: _, amount: _, signature: _ } -> index
    t.Unlocked { index, timeout: _, secret: _, amount: _, signature: _ } ->
      index
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

// We are interested only in our own mints
pub type Mints {
  mints: List<t.ChannelId>,
  burns: List<t.ChannelId>,
}

pub const mempty_mints = Mints([], [])

pub fn mappend_mints(mints1: Mints, mints2: Mints) -> Mints {
  let mints = mints1.mints |> list.concat(mints2.mints)
  let burns = mints1.burns |> list.concat(mints2.burns)
  Mints(mints, burns)
}

pub fn mk_mint(cid: t.ChannelId) -> Mints {
  Mints([cid], [])
}

pub fn mk_burn(cid: t.ChannelId) -> Mints {
  Mints([], [cid])
}

pub fn mints_to_value(mints: Mints, own_hash: ScriptHash) -> Value {
  let zero_value = assets.from_lovelace(0)
  let mints_value =
    mints.mints
      |> list.foldl(
          zero_value,
          fn(cid, val) {
            val |> assets.add(own_hash, token.cid_to_token(cid), 1)
          },
        )
  let burns_value =
    mints.burns
      |> list.foldl(
          zero_value,
          fn(cid, val) {
            val |> assets.add(own_hash, token.cid_to_token(cid), -1)
          },
        )
  assets.merge(mints_value, burns_value)
}

// Simplified transaction which we can combine in a rather sensible manner
pub type Tx {
  Tx {
    inputs: List<tx.Input>,
    outputs: List<tx.Output>,
    signatories: List<VerificationKeyHash>,
    validity_range: ExclusiveValidityRange,
    mints: Mints,
  }
}

pub const mempty_tx = Tx([], [], [], open_validity_range, mempty_mints)

pub fn tx_to_transaction(tx: Tx, own_hash: ScriptHash) -> Transaction {
  let tx_id = list.repeat(#"00", 32) |> list.reduce(#"", append_bytearray)
  let mint =
    if tx.mints == mempty_mints {
      assets.from_lovelace(0) |> assets.add(own_hash, token.bolt, 1)
    } else {
      tx.mints |> mints_to_value(own_hash)
    }
  Transaction {
    inputs: tx.inputs,
    reference_inputs: [],
    outputs: tx.outputs,
    fee: 0,
    mint,
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
  let mints = mappend_mints(tx1.mints, tx2.mints)
  Tx(input, output, signatories, validity_range, mints)
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
  let amount <- and_then(fuzz.int_between(min_channel_amt, max_channel_amt - 1))
  let gift_amt <- and_then(fuzz.int_between(0, max_channel_amt - amount))
  let base_value = assets.from_lovelace(amount + gift_amt + min_ada)
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

pub fn sum_pends(pends) {
  list.reduce(pends, 0, fn(acc, (amt, _, _)) { acc + amt })
}

pub fn received_and_sent(keys_order: KeysOrder, sn: t.Snapshot) {
  when keys_order is {
    SelfKeySmaller -> sn
    SelfKeyLarger -> (sn.2nd, sn.1st)
  }
}

pub fn enumerate(lst) {
  lst |> list.indexed_map(fn(i, v) { (i, v) })
}

type ByOpener =
  Bool

pub fn gen_add_step(own_hash) -> Fuzzer<(Tx, ByOpener)> {
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

  let by_opener <- and_then(fuzz.bool())
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

  // Put together the transaction
  let signatory =
    if by_opener {
      blake2b_224(keys.1st)
    } else {
      blake2b_224(keys.2nd)
    }
  let tx = Tx([input], [output], [signatory], open_validity_range, mempty_mints)
  fuzz.constant((tx, by_opener))
}

pub fn gen_add_steps(own_hash, n_steps) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  // TODO: support snapshot updates and addition chains
  let txs <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_add_step(own_hash) },
      ),
    )
  let tx =
    txs
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
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

pub fn reduce_receipt_chqs(receipt_chqs: List<t.Cheque>) -> (Amount, t.Pend) {
  let pends =
    list.filter_map(
      receipt_chqs,
      fn(chq) {
        when chq is {
          t.Locked { index: _, timeout, lock: _, amount, signature: _ } ->
            Some((amount, timeout, htlc_lock))
          _ -> None
        }
      },
    )
  let freed =
    receipt_chqs
      |> list.filter_map(
          fn(chq) {
            when chq is {
              t.Unlocked {
                index: _,
                timeout: _,
                secret: _,
                amount,
                signature: _,
              } -> Some(amount)
              _ -> None
            }
          },
        )
      |> list.reduce(0, builtin.add_integer)
  (freed, pends)
}

pub fn gen_close_step(
  own_hash,
  max_chqs,
  validity_range,
) -> Fuzzer<(Tx, ByOpener, Receipt)> {
  // * Generate Opened stage_in
  let cid <- and_then(gen_cid())
  let (
    own_addr,
    amt_non_opener_in,
    sn_in,
    period,
    keys_in,
    value,
    min_ada,
    min_ada_owner_in,
  ) <- and_then(gen_new_channel(own_hash, cid))
  let stage_in = t.Opened(amt_non_opener_in, sn_in, period)

  // * Generate channel input
  let input <-
    and_then(
      {
        let output =
          tx.Output(
            own_addr,
            value,
            InlineDatum(
              (own_hash, keys_in, stage_in, min_ada, min_ada_owner_in),
            ),
            None,
          )
        let tx_out_ref <- and_then(cardano.output_reference())
        fuzz.constant(tx.Input(tx_out_ref, output))
      },
    )

  // * Generate redeemer
  let by_opener <- and_then(fuzz.bool())
  let keys_out =
    if by_opener {
      keys_in
    } else {
      (keys_in.2nd, keys_in.1st)
    }
  let (closer_key, non_closer_key) = keys_out
  let (_, tot_in) = channel.parse_value(own_hash, value, min_ada)
  let closer_amt_in =
    if by_opener {
      tot_in - amt_non_opener_in
    } else {
      amt_non_opener_in
    }

  let keys_order = mk_keys_order(closer_key, non_closer_key)
  let sn_out <-
    and_then(
      gen_snapshot(
        closer_amt_in,
        tot_in - closer_amt_in,
        max_chqs,
        keys_order,
        Some(sn_in),
        AllowAnyDraining,
      ),
    )

  let (received, sent) =
    when keys_order is {
      SelfKeySmaller -> sn_out
      SelfKeyLarger -> (sn_out.2nd, sn_out.1st)
    }
  // The closer current net income from the squashes
  let squash_diff = received.amount - sent.amount

  let receipt <-
    and_then(
      {
        let which_sq =
          when keys_order is {
            SelfKeySmaller -> FirstSquash
            SelfKeyLarger -> SecondSquash
          }
        let non_closer_deposit =
          if by_opener {
            amt_non_opener_in
          } else {
            tot_in - amt_non_opener_in
          }
        // FIXME: Not sure if this kind of approximation is good enough.
        // Should we take into the account also excluded chqs in here?
        let max_chqs_amt = non_closer_deposit - squash_diff
        gen_receipt(sn_out, max_chqs, max_chqs_amt, which_sq, validity_range)
      },
    )

  expect ExclusiveValidityRange { lb: _, ub: Some(ub) } = validity_range
  let timeout = ub + period
  let (chqs_amt, pend_out) = reduce_receipt_chqs(receipt.2nd)
  let closer_amt_out = closer_amt_in + chqs_amt + squash_diff

  expect closer_amt_out >= 0
  let stage_out = t.Closed(closer_amt_out, sent, timeout, pend_out)
  let min_ada_owner_out =
    if by_opener {
      min_ada_owner_in
    } else {
      when min_ada_owner_in is {
        0 -> 1
        _ -> 0
      }
    }
  let output =
    tx.Output(
      own_addr,
      value,
      InlineDatum((own_hash, keys_out, stage_out, min_ada, min_ada_owner_out)),
      None,
    )
  let signatory =
    if by_opener {
      blake2b_224(keys_in.1st)
    } else {
      blake2b_224(keys_in.2nd)
    }
  let tx = Tx([input], [output], [signatory], validity_range, mempty_mints)

  fuzz.constant((tx, by_opener, receipt))
}

pub fn gen_close_steps(
  own_hash,
  max_chqs,
  n_steps,
) -> Fuzzer<(Transaction, MintRedeemer)> {
  let validity_range <- and_then(gen_validity_range())
  let txs_with_receipts <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_close_step(own_hash, max_chqs, validity_range) },
      ),
    )
  let tx =
    txs_with_receipts
      |> list.map(fn((t, _, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
  let redeemer =
    (
      None,
      txs_with_receipts
        |> list.map(
            fn((_, by_opener, receipt)) {
              t.Continuing(t.Close { by_opener, receipt })
            },
          ),
    )
  trace @"transaction": transaction
  fuzz.constant((transaction, redeemer))
}

// Provided limits are relevant to the non-expired chqs.
// Expired chqs are generated freely here.
pub fn gen_pends(min_chqs, max_chqs, min_amt, max_amt, lb, ub) -> Fuzzer<t.Pend> {
  when (max_chqs, max_amt) is {
    (0, _) -> fuzz.constant([])
    (_, 0) -> fuzz.constant([])
    (1, _) -> {
      let amount <- and_then(fuzz.int_between(min_amt, max_amt))
      fuzz.constant([(amount, ub + 1, htlc_lock)])
    }
    _ -> {
      let generate <-
        and_then(
          if max_amt <= 0 {
            fuzz.constant(False)
          } else if min_amt > 0 || min_chqs > 0 {
            fuzz.constant(True)
          } else {
            fuzz.bool()
          },
        )
      if !generate {
        fuzz.constant([])
      } else {
        let amount <- and_then(fuzz.int_between(1, max_amt / max(1, min_chqs)))
        let expired <- and_then(fuzz.bool())
        let (timeout, rest) <-
          and_then(
            if expired {
              let timeout = lb - 1
              let rest <-
                and_then(
                  gen_pends(min_chqs, max_chqs, min_amt, max_amt, lb, ub),
                )
              fuzz.constant((timeout, rest))
            } else {
              let timeout = ub + 1
              let rest <-
                and_then(
                  gen_pends(
                    min_chqs - 1,
                    max_chqs - 1,
                    max(0, min_amt - amount),
                    max(0, max_amt - amount),
                    lb,
                    ub,
                  ),
                )
              fuzz.constant((timeout, rest))
            },
          )
        fuzz.constant(list.push(rest, (amount, timeout, htlc_lock)))
      }
    }
  }
}

pub type SecretsGenStrategy {
  AllowFullReduction
  EnsureFullReduction
  PreventFullReduction
}

pub fn gen_secrets(
  received_pends,
  ub,
  secrets_gen_strategy,
) -> Fuzzer<t.Secrets> {
  let secrets <-
    and_then(
      fuzz_contrib.foldr(
        received_pends |> enumerate,
        [],
        fn((idx, pend), acc) {
          let (_, timeout, _) = pend
          if timeout > ub {
            let resolve <- and_then(fuzz.bool())
            if resolve || secrets_gen_strategy == EnsureFullReduction {
              fuzz.constant(list.push(acc, (idx, htlc_secret)))
            } else {
              fuzz.constant(acc)
            }
          } else {
            // Full reduction is not possible if we have expired cheques
            expect secrets_gen_strategy != EnsureFullReduction
            fuzz.constant(acc)
          }
        },
      ),
    )
  let non_expr_pends_in =
    received_pends |> list.filter(fn((_, timeout, _)) { timeout > ub })
  if secrets_gen_strategy == PreventFullReduction && (
    non_expr_pends_in |> list.length()
  ) == ( secrets |> list.length() ) {
    let idx <- and_then(fuzz.int_between(0, ( secrets |> list.length() ) - 1))
    fuzz.constant(
      secrets |> list.take(idx) |> list.concat(secrets |> list.drop(idx + 1)),
    )
  } else {
    fuzz.constant(secrets)
  }
}

pub fn gen_non_empty_secrets(
  received_pends,
  ub,
  secrets_gen_strategy,
) -> Fuzzer<t.Secrets> {
  let secrets <- and_then(gen_secrets(received_pends, ub, secrets_gen_strategy))
  if secrets == [] {
    expect Some((idx, _)) =
      received_pends
        |> enumerate
        |> list.find(fn((_, (_, timeout, _))) { timeout > ub })
    // Sanity check: we either allow full reduction or have more than one non-expired cheque
    expect
      secrets_gen_strategy != PreventFullReduction || (
        received_pends
          |> list.filter(fn((_, timeout, _)) { timeout > ub })
          |> list.length()
      ) > 1
    fuzz.constant([(idx, htlc_secret)])
  } else {
    fuzz.constant(secrets)
  }
}

fn do_drop_old(
  drop_old: Bool,
  sent_pends: t.Pend,
  lb: PosixMilliseconds,
) -> t.Pend {
  if !drop_old {
    sent_pends
  } else {
    sent_pends |> list.filter(fn((_, timeout, _)) { timeout > lb })
  }
}

// Executed by non-closer
pub fn gen_respond_step(
  own_hash,
  max_chqs,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, (t.Receipt, t.DropOld))> {
  // * Constant inputs
  let own_addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range

  // * Generate input `Closed` stage
  let closer_pends_in <- and_then(gen_pends(0, max_chqs, 0, max_sq_amt, lb, ub))
  let sq_in <- and_then(gen_sq(max_chqs, 0, max_sq_amt, None))
  let closer_amt_in <- and_then(fuzz.int_between(1, max_channel_amt / 2))
  let timeout_in = ub + 1
  let stage_in = t.Closed(closer_amt_in, sq_in, timeout_in, closer_pends_in)

  // * Generate the redeemer: `Respond(Receipt, DropOld)`
  let keys_in <- and_then(gen_keys())
  let (other, self) = keys_in
  let (receipt, sq_diff) <-
    and_then(
      {
        let gen_sn <- and_then(fuzz.bool())
        if gen_sn {
          // During the respond step non-closer provides possibly a newer snapshot.
          //
          // Even if this newer `snapshot` contains updated `squash` which was sent by
          // the non-closer it is ignored because that is clearly invalid (closer should not
          // not accept more chqs after the `close`).
          //
          // On the other hand the squash which was received by the non-closer is taken
          // into account as the closer had no incentive to provide that one with the largest
          // amount during `close`.
          //
          // The incentive of non-closer now is to provide the latest received squash
          // with the largest total and as many chqs from the closer as possible.
          // `closer_amt_in` is a balance owned by the closer *at the moment of closing*
          // assuming no other pending liabilities and assuming that the
          // `closing_received` squash was the latest.
          //
          // As pointed above the non-closer could provide a newer squash
          // which can influence the final closer balance.
          // The upper limit of the squash amount could be a bit larger than what
          // we assume below because some chqs sent by the closer could
          // expire in between so the closer could issue more chqs to the non-closer.
          // We ignore that possibility for simplicity.
          let min_sq = sq_in.amount
          let max_sq = min_sq + closer_amt_in

          trace @"gen_respond_step: min_sq_received": min_sq
          trace @"gen_respond_step: max_sq_received": max_sq

          let new_sq <- and_then(gen_sq(max_chqs, min_sq, max_sq, Some(sq_in)))
          let max_chqs_amt = closer_amt_in - ( new_sq.amount - sq_in.amount )
          // That fake squash is ignored during the `respond` step evaluation
          let fake_closing_sent = empty_sq
          let receipt_chqs <-
            and_then(
              gen_receipt_chqs(new_sq, max_chqs, max_chqs_amt, validity_range),
            )
          let sn =
            mk_signed(
              when mk_keys_order(self, other) is {
                SelfKeySmaller -> (new_sq, fake_closing_sent)
                SelfKeyLarger -> (fake_closing_sent, new_sq)
              },
            )
          let receipt = (Some(sn), receipt_chqs)
          fuzz.constant((receipt, new_sq.amount - sq_in.amount))
        } else {
          let receipt_chqs <-
            and_then(
              gen_receipt_chqs(sq_in, max_chqs, closer_amt_in, validity_range),
            )
          let receipt = (None, receipt_chqs)
          fuzz.constant((receipt, 0))
        }
      },
    )
  let drop_old <- and_then(fuzz.bool())
  let redeemer = (receipt, drop_old)

  // * Estimate and generate the amount of money which should be locked in the channel
  let (unlocked_chqs_amt, non_closer_pends_out) =
    reduce_receipt_chqs(receipt.2nd)
  let remaining_amt <-
    and_then(
      {
        // The amount of money left should cover all the liabilities.
        // Anything extra will be non-closer amount.
        // Please note that:
        // - sq_diff and unlocked_chqs_amt and non_closer_pends_out are covered by the closer_amt_in.
        // - The remaining should cover the liabilities of non-closer closer_pends_in.
        // - Anything extra will be non-closer amount.
        let min_remaining = sum_pends(closer_pends_in)
        fuzz.int_between(min_remaining, max_channel_amt / 2)
      },
    )
  let tot_in = closer_amt_in + remaining_amt

  // Create the channel input
  let cid <- and_then(gen_channel_id())
  let min_ada_owner_in <- and_then(fuzz.int_between(0, 1))
  let input <-
    and_then(
      {
        let value_in =
          assets.from_lovelace(tot_in + min_ada * 1_000_000)
            |> assets.add(own_hash, token.cid_to_token(cid), 1)
        let output =
          tx.Output(
            own_addr,
            value_in,
            InlineDatum(
              (own_hash, keys_in, stage_in, min_ada, min_ada_owner_in),
            ),
            None,
          )
        let out_ref <- and_then(cardano.output_reference())
        fuzz.constant(tx.Input(out_ref, output))
      },
    )

  // * Generate `Resolved(non_resolver_amt, resolver_pends, non_resolver_pends)`.
  // This step turns closer into non-resolver and non-closer into resolver.
  let closer_pends_out = do_drop_old(drop_old, closer_pends_in, lb)
  let closer_amt_out =
    closer_amt_in - sq_diff - unlocked_chqs_amt - sum_pends(
      non_closer_pends_out,
    )
  let stage_out =
    t.Resolved(closer_amt_out, non_closer_pends_out, closer_pends_out)

  // * Create the channel output
  // The amount of money left should cover the closer's account and all the liabilities.
  let tot_out =
    closer_amt_out + sum_pends(closer_pends_out) + sum_pends(
      non_closer_pends_out,
    )
  let value_out =
    assets.from_lovelace(tot_out + min_ada * 1_000_000)
      |> assets.add(own_hash, token.cid_to_token(cid), 1)
  // self - the responder becomes the resolver
  let keys_out = (self, other)
  let min_ada_owner_out = 1 - min_ada_owner_in
  let channel_output =
    tx.Output(
      own_addr,
      value_out,
      InlineDatum((own_hash, keys_out, stage_out, min_ada, min_ada_owner_out)),
      None,
    )

  // * Create the payout output
  let payout_output_value = assets.from_lovelace(tot_in - tot_out)
  let payout_output_addr <-
    and_then(cardano.address_with_payment_credential(VerificationKey(self)))

  let payout_output =
    tx.Output(payout_output_addr, payout_output_value, NoDatum, None)
  let signatory = blake2b_224(self)
  fuzz.constant(
    (
      Tx(
        [input],
        [channel_output, payout_output],
        [signatory],
        validity_range,
        mempty_mints,
      ),
      redeemer,
    ),
  )
}

pub fn gen_respond_steps(
  own_hash,
  max_chqs,
  n_steps,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  expect ExclusiveValidityRange { lb: Some(close_lb), ub: Some(close_ub) } <-
    and_then(gen_validity_range())
  let validity_range =
    ExclusiveValidityRange(
      Some(close_lb + max_period),
      Some(close_ub + max_period),
    )

  let txs_with_receipts <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_respond_step(own_hash, max_chqs, validity_range) },
      ),
    )
  let tx =
    txs_with_receipts
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
  let redeemer =
    (
      None,
      txs_with_receipts
        |> list.map(
            fn((_, redeemer)) {
              t.Continuing(t.Respond(redeemer.1st, redeemer.2nd))
            },
          ),
    )
  fuzz.constant((transaction, redeemer))
}

fn reduce_pends(
  received_pends: t.Pend,
  secrets: t.Secrets,
  ub: PosixMilliseconds,
) -> t.Pend {
  let secrets_idxs = secrets |> list.map(fn((idx, _)) { idx })
  received_pends
    |> enumerate
    |> list.foldr(
        [],
        fn((idx, pend), acc) {
          if !list.has(secrets_idxs, idx) {
            list.push(acc, pend)
          } else {
            let (_, timeout, _) = pend
            expect timeout > ub
            acc
          }
        },
      )
}

pub fn gen_elapse_step(
  own_addr,
  max_chqs,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, t.Secrets)> {
  // * Constant inputs
  expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
    own_addr
  expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range

  // * Generate input `Closed` stage
  let closer_amt_in <- and_then(fuzz.int_between(1, max_channel_amt / 2))
  let closer_pends_in <- and_then(gen_pends(0, max_chqs, 0, max_sq_amt, lb, ub))
  let sq_in <- and_then(gen_sq(max_chqs, 0, max_sq_amt, None))
  let stage_in = t.Closed(closer_amt_in, sq_in, lb - 1, closer_pends_in)

  // * Estimate and generate the amount of money which should be locked in the channel
  let min_remaining = sum_pends(closer_pends_in) + list.length(sq_in.exclude)
  let remaining <-
    and_then(fuzz.int_between(min_remaining, max_channel_amt / 2))
  let tot_in = closer_amt_in + remaining

  // * Create the channel input
  let min_ada_owner <- and_then(fuzz.int_between(0, 1))
  let cid <- and_then(gen_channel_id())
  let keys_in <- and_then(gen_keys())
  let close_out_ref <- and_then(cardano.output_reference())
  let close_output =
    tx.Output(
      own_addr,
      assets.from_lovelace(tot_in + min_ada * 1_000_000)
        |> assets.add(own_hash, token.cid_to_token(cid), 1),
      InlineDatum((own_hash, keys_in, stage_in, min_ada, min_ada_owner)),
      None,
    )
  let close_input = tx.Input(close_out_ref, close_output)

  // * Generate the redeemer: `Elapse(Secrets)`
  let secrets <-
    and_then(gen_secrets(closer_pends_in, ub, PreventFullReduction))

  // * Generate `Resolved(closer_amt_out, closer_pends_out, [])`.
  // This step is executed by the closer so he becomes the resolver as well.
  // Keys are not swapped.
  let closer_pends_out = reduce_pends(closer_pends_in, secrets, ub)
  let amt_freed = sum_pends(closer_pends_in) - sum_pends(closer_pends_out)
  let tot_out = tot_in - closer_amt_in - amt_freed
  let non_closer_amt_out = tot_out - sum_pends(closer_pends_out)
  let stage_out = t.Resolved(non_closer_amt_out, closer_pends_out, [])

  // * Create the channel output
  let elapse_output =
    tx.Output(
      own_addr,
      assets.from_lovelace(tot_out + min_ada * 1_000_000)
        |> assets.add(own_hash, token.cid_to_token(cid), 1),
      InlineDatum((own_hash, keys_in, stage_out, min_ada, min_ada_owner)),
      None,
    )

  let signatory = blake2b_224(keys_in.1st)
  let tx =
    Tx(
      [close_input],
      [elapse_output],
      [signatory],
      validity_range,
      mempty_mints,
    )
  fuzz.constant((tx, secrets))
}

pub fn gen_elapse_steps(
  own_hash,
  max_chqs,
  n_steps,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  // It doesn't hurt to have validity range which has some extra margin
  let validity_range <- and_then(gen_validity_range())
  let own_addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let txs_with_secrets <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_elapse_step(own_addr, max_chqs, validity_range) },
      ),
    )
  let tx =
    txs_with_secrets
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
  let redeemer =
    (
      None,
      txs_with_secrets
        |> list.map(fn((_, secrets)) { t.Continuing(t.Elapse(secrets)) }),
    )
  fuzz.constant((transaction, redeemer))
}

// // Executed by the `closer` in the `Closed` stage
pub fn gen_free_in_closed_step(
  own_addr: Address,
  max_chqs: Int,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, t.Secrets)> {
  expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
    own_addr
  expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range

  let closer_pends_in <- and_then(gen_pends(1, max_chqs, 1, max_sq_amt, lb, ub))
  let secrets <-
    and_then(gen_non_empty_secrets(closer_pends_in, ub, AllowFullReduction))
  let closer_pends_out = reduce_pends(closer_pends_in, secrets, ub)
  let amt_reduced = sum_pends(closer_pends_in) - sum_pends(closer_pends_out)

  let closer_amt_in <- and_then(fuzz.int_between(1, max_channel_amt / 2))
  // In theory we should also cover the sq_in from the Closed stage but it is not checked
  // in any way in this step so we can ignore that detail.
  let min_tot_in = closer_amt_in + sum_pends(closer_pends_in)
  let tot_in <- and_then(fuzz.int_between(min_tot_in, max_channel_amt))

  let cid <- and_then(gen_channel_id())
  let keys_in <- and_then(gen_keys())
  let timeout_in = ub + 1
  // Timeout is in the future
  let sq_in <- and_then(gen_sq(max_chqs, 0, max_sq_amt, None))
  let min_ada_owner <- and_then(fuzz.int_between(0, 1))
  let input <-
    and_then(
      {
        let stage_in =
          t.Closed(closer_amt_in, sq_in, timeout_in, closer_pends_in)
        let out_ref <- and_then(cardano.output_reference())
        let output =
          tx.Output(
            own_addr,
            assets.from_lovelace(tot_in + min_ada * 1_000_000)
              |> assets.add(own_hash, token.cid_to_token(cid), 1),
            InlineDatum((own_hash, keys_in, stage_in, min_ada, min_ada_owner)),
            None,
          )
        fuzz.constant(tx.Input(out_ref, output))
      },
    )

  let output = {
    let amt_out = closer_amt_in + amt_reduced
    let stage_out = t.Closed(amt_out, sq_in, timeout_in, closer_pends_out)
    // squash and timeout unchanged
    let tot_out = tot_in
    // Total unchanged
    tx.Output(
      own_addr,
      assets.from_lovelace(tot_out + min_ada * 1_000_000)
        |> assets.add(own_hash, token.cid_to_token(cid), 1),
      InlineDatum((own_hash, keys_in, stage_out, min_ada, min_ada_owner)),
      None,
    )
  }
  let signatory = blake2b_224(keys_in.1st)
  let tx = Tx([input], [output], [signatory], validity_range, mempty_mints)
  fuzz.constant((tx, secrets))
}

pub fn gen_free_in_closed_steps(
  own_hash: ScriptHash,
  max_chqs: Int,
  n_steps: Int,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  let validity_range <- and_then(gen_validity_range())
  let own_addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let txs_with_params <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_free_in_closed_step(own_addr, max_chqs, validity_range) },
      ),
    )
  let tx =
    txs_with_params
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
  let redeemer =
    (
      None,
      txs_with_params
        |> list.map(fn((_, secrets)) { t.Continuing(t.FreeInClosed(secrets)) }),
    )
  fuzz.constant((transaction, redeemer))
}

pub fn has_not_expired(ub, pend) {
  let (_, timeout, _) = pend
  timeout > ub
}

pub fn has_expired(lb, pend) {
  let (_, timeout, _) = pend
  timeout < lb
}

pub fn gen_free_in_resolved_step(
  own_addr: Address,
  max_chqs: Int,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, Bool, Bool, t.Secrets)> {
  // * Constant inputs
  expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
    own_addr
  expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range

  // The situation in resolved is fully symmetrical so we can
  // stay agnostic who is who modulo the initial pending
  // non-resolve withdrawal.
  // Ensure that the free step is meaningful:
  // * Either execute initial withrawal by non-resolver
  // * Or include at least one sent pend which has expired
  // * Or include at least one received pend which has not yet expired and will be resolved
  let non_resolver_withdrawal_pending <- and_then(fuzz.bool())
  let by_resolver <- and_then(fuzz.bool())
  let pends_freed_can_be_empty = !by_resolver && non_resolver_withdrawal_pending
  let other_pends_in <-
    and_then(gen_pends(0, max_chqs / 2, 0, max_sq_amt / 2, lb, ub))
  let other_pends_in_expired =
    other_pends_in |> list.filter(fn(pend) { has_expired(lb, pend) })

  let self_pends_in <-
    and_then(
      if other_pends_in_expired == [] && !pends_freed_can_be_empty {
        gen_pends(1, max_chqs / 2, 1, max_sq_amt / 2, lb, ub)
      } else {
        gen_pends(0, max_chqs / 2, 0, max_sq_amt / 2, lb, ub)
      },
    )

  let secrets <-
    and_then(
      if other_pends_in_expired == [] && !pends_freed_can_be_empty {
        gen_non_empty_secrets(self_pends_in, ub, AllowFullReduction)
      } else {
        gen_secrets(self_pends_in, ub, AllowFullReduction)
      },
    )
  let drop_old <-
    and_then(
      if secrets == [] && !pends_freed_can_be_empty {
        // Enforce `drop_old` if we don't execute received chqs
        // reduction to avoid noop
        fuzz.constant(True)
      } else {
        fuzz.bool()
      },
    )
  let self_pends_out = reduce_pends(self_pends_in, secrets, ub)
  let other_pends_out = do_drop_old(drop_old, other_pends_in, lb)

  let non_resolver_amt_in <-
    and_then(
      if non_resolver_withdrawal_pending {
        fuzz.int_between(1, max_channel_amt / 2)
      } else {
        fuzz.constant(0)
      },
    )
  let non_resolver_amt_out =
    if by_resolver {
      non_resolver_amt_in
    } else {
      0
    }
  let keys_in <- and_then(gen_keys())
  let (stage_in, stage_out, signatories) =
    if by_resolver {
      (
        t.Resolved(non_resolver_amt_in, self_pends_in, other_pends_in),
        t.Resolved(non_resolver_amt_out, self_pends_out, other_pends_out),
        [blake2b_224(keys_in.1st)],
      )
    } else {
      (
        t.Resolved(non_resolver_amt_in, other_pends_in, self_pends_in),
        t.Resolved(non_resolver_amt_out, other_pends_out, self_pends_out),
        [blake2b_224(keys_in.2nd)],
      )
    }

  let tot_in =
    sum_pends(self_pends_in) + sum_pends(other_pends_in) + non_resolver_amt_in
  let cid <- and_then(gen_channel_id())
  let min_ada_owner <- and_then(fuzz.int_between(0, 1))
  let input <-
    and_then(
      {
        let out_ref <- and_then(cardano.output_reference())
        let output =
          tx.Output(
            own_addr,
            assets.from_lovelace(tot_in + min_ada * 1_000_000)
              |> assets.add(own_hash, token.cid_to_token(cid), 1),
            InlineDatum((own_hash, keys_in, stage_in, min_ada, min_ada_owner)),
            None,
          )
        fuzz.constant(tx.Input(out_ref, output))
      },
    )

  let tot_out =
    sum_pends(self_pends_out) + sum_pends(other_pends_out) + non_resolver_amt_out
  let output =
    tx.Output(
      own_addr,
      assets.from_lovelace(tot_out + min_ada * 1_000_000)
        |> assets.add(own_hash, token.cid_to_token(cid), 1),
      InlineDatum((own_hash, keys_in, stage_out, min_ada, min_ada_owner)),
      None,
    )
  let tx = Tx([input], [output], signatories, validity_range, mempty_mints)
  fuzz.constant((tx, by_resolver, drop_old, secrets))
}

pub fn gen_free_in_resolved_steps(
  own_hash: ScriptHash,
  max_chqs: Int,
  n_steps: Int,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  let validity_range <- and_then(gen_validity_range())
  let own_addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let txs_with_params <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_free_in_resolved_step(own_addr, max_chqs, validity_range) },
      ),
    )
  let tx =
    txs_with_params
      |> list.map(fn((t, _, _, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
  let redeemer =
    (
      None,
      txs_with_params
        |> list.map(
            fn((_, by_resolver, drop_old, secrets)) {
              t.Continuing(t.FreeInResolved(by_resolver, secrets, drop_old))
            },
          ),
    )
  fuzz.constant((transaction, redeemer))
}

// Executed by either party in the `Resolved` stage to fully end the channel
// by burning the token and releasing all remaining funds after reducing pends.
pub fn gen_end_resolved_step(
  own_addr: Address,
  max_chqs: Int,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, t.Secrets)> {
  expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
    own_addr
  expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range

  // Generate received pends that can be fully reduced
  let received_pends <-
    and_then(
      {
        let any_pends <-
          and_then(gen_pends(0, max_chqs / 2, 0, max_sq_amt / 2, lb, ub))
        fuzz.constant(
          any_pends |> list.filter(fn(p) { has_not_expired(ub, p) }),
        )
      },
    )
  let secrets <- and_then(gen_secrets(received_pends, ub, EnsureFullReduction))
  // Create sent ones which are all expired
  let sent_pends <-
    and_then(
      {
        let pends <-
          and_then(gen_pends(0, max_chqs / 2, 0, max_sq_amt / 2, lb, ub))
        fuzz.constant(pends |> list.filter(fn(p) { has_expired(lb, p) }))
      },
    )

  // Ending can be only executed by min-ada owner
  let keys_in <- and_then(gen_keys())
  let min_ada_owner <- and_then(fuzz.int_between(0, 1))
  let by_resolver = min_ada_owner == 0
  let non_resolver_amt_in <-
    and_then(
      if by_resolver {
        fuzz.constant(0)
      } else {
        fuzz.int_between(0, max_channel_amt)
      },
    )
  let stage_in =
    if by_resolver {
      t.Resolved(non_resolver_amt_in, received_pends, sent_pends)
    } else {
      t.Resolved(non_resolver_amt_in, sent_pends, received_pends)
    }

  let tot_in =
    sum_pends(received_pends) + sum_pends(sent_pends) + non_resolver_amt_in
  let cid <- and_then(gen_channel_id())

  let input <-
    and_then(
      {
        let out_ref <- and_then(cardano.output_reference())
        let output =
          tx.Output(
            own_addr,
            assets.from_lovelace(tot_in + min_ada * 1_000_000)
              |> assets.add(own_hash, token.cid_to_token(cid), 1),
            InlineDatum((own_hash, keys_in, stage_in, min_ada, min_ada_owner)),
            None,
          )
        fuzz.constant(tx.Input(out_ref, output))
      },
    )

  // No continuing output (channel ends), but release funds to a payout address
  let payout_addr <-
    and_then(
      if by_resolver {
        cardano.address_with_payment_credential(VerificationKey(keys_in.1st))
      } else {
        cardano.address_with_payment_credential(VerificationKey(keys_in.2nd))
      },
    )
  let change_amt <- and_then(fuzz.int_between(1, 10_000_000))
  let payout_output =
    tx.Output(
      payout_addr,
      assets.from_lovelace(tot_in + min_ada * 1_000_000 + change_amt),
      NoDatum,
      None,
    )

  let signatory =
    if by_resolver {
      blake2b_224(keys_in.1st)
    } else {
      blake2b_224(keys_in.2nd)
    }
  let tx =
    Tx([input], [payout_output], [signatory], validity_range, mk_burn(cid))
  fuzz.constant((tx, secrets))
}

pub fn gen_end_resolved_steps(
  own_hash: ScriptHash,
  max_chqs: Int,
  n_steps: Int,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  let validity_range <- and_then(gen_validity_range())
  let own_addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let txs_with_params <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_end_resolved_step(own_addr, max_chqs, validity_range) },
      ),
    )
  let tx =
    txs_with_params
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
  let redeemer =
    (
      None,
      txs_with_params
        |> list.map(fn((_, secrets)) { t.End(t.EndResolved(secrets)) }),
    )
  fuzz.constant((transaction, redeemer))
}

// From the docs:
// Closed --> [*] : <b>elapse-end</b>\nby closer if min-ada-owner
// note on link
//   * non-closer balance has to be null
//   * all the closer_pends have to be freed
// end note

pub fn gen_elapse_end_step(
  own_addr: Address,
  max_chqs: Int,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, t.Secrets)> {
  // * Constant inputs
  expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
    own_addr
  expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
  // Ending can be only executed by min-ada owner
  let min_ada_owner = 0

  // * Generate `Closed` stage:
  //   - all the closer_pends have to be freed so we generate only not yet expired ones
  let closer_pends_in <-
    and_then(
      {
        let any_pends <- and_then(gen_pends(0, max_chqs, 0, max_sq_amt, lb, ub))
        fuzz.constant(
          any_pends |> list.filter(fn(p) { has_not_expired(ub, p) }),
        )
      },
    )
  let closer_amt <- and_then(fuzz.int_between(0, max_channel_amt / 2))
  let sq_in <- and_then(gen_sq(max_chqs, 0, max_sq_amt, None))
  let stage_in = t.Closed(closer_amt, sq_in, lb - 1, closer_pends_in)

  // * Generate the input:
  //   - total amount should impose null non-closer balance
  let tot_in = closer_amt + sum_pends(closer_pends_in)
  let cid <- and_then(gen_channel_id())
  let keys_in <- and_then(gen_keys())
  let input <-
    and_then(
      {
        let out_ref <- and_then(cardano.output_reference())
        let output =
          tx.Output(
            own_addr,
            assets.from_lovelace(tot_in + min_ada * 1_000_000)
              |> assets.add(own_hash, token.cid_to_token(cid), 1),
            InlineDatum((own_hash, keys_in, stage_in, min_ada, min_ada_owner)),
            None,
          )
        fuzz.constant(tx.Input(out_ref, output))
      },
    )

  // * Generate the redeemer: `Elapse(Secrets)`:
  //   - all the closer_pends have to be freed
  let secrets <- and_then(gen_secrets(closer_pends_in, ub, EnsureFullReduction))

  // * Generate payout output
  let payout_addr <-
    and_then(
      cardano.address_with_payment_credential(VerificationKey(keys_in.1st)),
    )
  let payout_output =
    tx.Output(
      payout_addr,
      assets.from_lovelace(tot_in + min_ada * 1_000_000),
      NoDatum,
      None,
    )
  let signatory = blake2b_224(keys_in.1st)
  let tx =
    Tx([input], [payout_output], [signatory], validity_range, mk_burn(cid))
  fuzz.constant((tx, secrets))
}

pub fn gen_elapse_end_steps(
  own_hash: ScriptHash,
  max_chqs: Int,
  n_steps: Int,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  let validity_range <- and_then(gen_validity_range())
  let own_addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let txs_with_params <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_elapse_end_step(own_addr, max_chqs, validity_range) },
      ),
    )
  let tx =
    txs_with_params
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
  let redeemer =
    (
      None,
      txs_with_params
        |> list.map(fn((_, secrets)) { t.End(t.ElapseEnd(secrets)) }),
    )
  fuzz.constant((transaction, redeemer))
}

// We first use some of the exclude and then move and generate
// new ones starting from last_idx + 1
pub type SqIdxInfo {
  exclude: List<Int>,
  last_idx: Int,
}

pub fn pick_idx(idxs: SqIdxInfo) -> Fuzzer<(SqIdxInfo, Int)> {
  when idxs.exclude is {
    [] -> {
      let bump <- and_then(fuzz.int_between(1, 100))
      let idx = idxs.last_idx + bump
      fuzz.constant((SqIdxInfo([], idx), idx))
    }
    [idx, ..rest] -> {
      let pick_head <- and_then(fuzz.bool())
      if pick_head {
        fuzz.constant((SqIdxInfo(rest, idxs.last_idx), idx))
      } else {
        pick_idx(SqIdxInfo(rest, idxs.last_idx))
      }
    }
  }
}

// Generates non-expired cheques for a given amount
pub fn gen_unlocked_chqs(
  idxs: SqIdxInfo,
  total_amt: Amount,
  ub: PosixMilliseconds,
) -> Fuzzer<List<t.Cheque>> {
  let (idxs, index) <- and_then(pick_idx(idxs))
  let amount <- and_then(fuzz.int_between(1, total_amt))
  let delta <- and_then(fuzz.int_between(1, max_period))
  let timeout = ub + delta
  let chq =
    t.Unlocked { index, timeout, secret: htlc_secret, amount, signature }
  if amount == total_amt {
    fuzz.constant([chq])
  } else {
    let rest_chqs <- and_then(gen_unlocked_chqs(idxs, total_amt - amount, ub))
    fuzz.constant(list.push(rest_chqs, chq))
  }
}

// From the docs:
// Closed --> [*] : <b>respond-end</b>\nby non-closer if min-ada-owner
// note on link
//   * closer balance has to be null
//   * all the pends have to be freed
// end note
pub fn gen_respond_end_step(
  own_addr: Address,
  max_chqs: Int,
  validity_range: ExclusiveValidityRange,
) -> Fuzzer<(Tx, t.EndStep)> {
  // * Constant inputs
  expect Address { payment_credential: Script(own_hash), stake_credential: _ } =
    own_addr
  expect ExclusiveValidityRange { lb: Some(lb), ub: Some(ub) } = validity_range
  // Ending can be only executed by min-ada owner
  let min_ada_owner = 1

  // * Generate `Closed` stage:
  //   - all the `closer_pends` have to be freed so we generate only expired ones
  let closer_pends_in <-
    and_then(
      {
        let any_pends <- and_then(gen_pends(0, max_chqs, 0, max_sq_amt, lb, ub))
        fuzz.constant(any_pends |> list.filter(fn(p) { has_expired(lb, p) }))
      },
    )
  let closer_amt <- and_then(fuzz.int_between(0, max_channel_amt / 2))
  let sq_in <- and_then(gen_sq(max_chqs, 0, max_sq_amt, None))

  // The protocol is polite for the responders and allows to
  // execute this action even after the timeout has passed.
  // We a timeout which has passed or ambiguous or in the future.
  let timeout <- and_then(fuzz.int_between(lb - 1, ub + 1))
  let stage_in = t.Closed(closer_amt, sq_in, timeout, closer_pends_in)

  // * Generate the input:
  //   - Let's generate some helper amounts
  let non_closer_amt <- and_then(fuzz.int_between(1, max_channel_amt / 2))
  // Please note that non_closer_amt initially covers also his liabilities
  // because they are not fully confirmed yet.
  let tot_in = closer_amt + sum_pends(closer_pends_in) + non_closer_amt
  let cid <- and_then(gen_channel_id())
  let keys_in <- and_then(gen_keys())
  let (other, self) = keys_in
  let input <-
    and_then(
      {
        let out_ref <- and_then(cardano.output_reference())
        let output =
          tx.Output(
            own_addr,
            assets.from_lovelace(tot_in + min_ada * 1_000_000)
              |> assets.add(own_hash, token.cid_to_token(cid), 1),
            InlineDatum((own_hash, keys_in, stage_in, min_ada, min_ada_owner)),
            None,
          )
        fuzz.constant(tx.Input(out_ref, output))
      },
    )

  // * Generate the redeemer: `RespondEnd(Receipt)`:
  //   - the receipt should only contain unlocked chqs
  //   - the sq_diff together with cheques should cover the closer_amt_in
  let (receipt_sn, sq) <-
    and_then(
      {
        let gen_sn <- and_then(fuzz.bool())
        if gen_sn {
          let min_sq_amt = sq_in.amount + 1
          let max_sq_amt = min_sq_amt + closer_amt - 1
          let new_sq <-
            and_then(gen_sq(max_chqs, min_sq_amt, max_sq_amt, Some(sq_in)))
          let fake_sent_sq = empty_sq
          let sn =
            mk_signed(
              when mk_keys_order(self, other) is {
                SelfKeySmaller -> (new_sq, fake_sent_sq)
                SelfKeyLarger -> (fake_sent_sq, new_sq)
              },
            )
          fuzz.constant((Some(sn), new_sq))
        } else {
          fuzz.constant((None, sq_in))
        }
      },
    )
  // We should not drain the closer balance too much
  let sq_diff = sq.amount - sq_in.amount
  expect sq_diff <= closer_amt
  let chqs_amt = closer_amt - sq_diff
  // Now let's generate cheques which cover the remaining amount
  let receipt_cheques <-
    and_then(gen_unlocked_chqs(SqIdxInfo(sq.exclude, sq.index), chqs_amt, ub))
  let redeemer = t.RespondEnd((receipt_sn, receipt_cheques))

  // * Generate payout output
  let payout_addr <-
    and_then(
      cardano.address_with_payment_credential(VerificationKey(keys_in.2nd)),
    )
  let payout_output =
    tx.Output(
      payout_addr,
      assets.from_lovelace(tot_in + min_ada * 1_000_000),
      NoDatum,
      None,
    )

  // * Create the transaction
  let signatory = blake2b_224(keys_in.2nd)
  let tx =
    Tx([input], [payout_output], [signatory], validity_range, mk_burn(cid))
  fuzz.constant((tx, redeemer))
}

pub fn gen_respond_end_steps(
  own_hash: ScriptHash,
  max_chqs: Int,
  n_steps: Int,
) -> Fuzzer<(Transaction, t.MintRedeemer)> {
  let validity_range <- and_then(gen_validity_range())
  let own_addr <-
    and_then(cardano.address_with_payment_credential(Script(own_hash)))
  let txs_with_params <-
    and_then(
      fuzz_contrib.traverse_list(
        list.range(1, n_steps),
        fn(_) { gen_respond_end_step(own_addr, max_chqs, validity_range) },
      ),
    )
  let tx =
    txs_with_params
      |> list.map(fn((t, _)) { t })
      |> list.reduce(mempty_tx, tx_mappend)
  let transaction = tx |> tx_to_transaction(own_hash)
  let redeemer =
    (
      None,
      txs_with_params
        |> list.map(fn((_, redeemer)) { t.End(redeemer) }),
    )
  fuzz.constant((transaction, redeemer))
}
