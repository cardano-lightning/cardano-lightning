use aiken/builtin as builtin
use aiken/collection.{Index}
use aiken/collection/list as list
use aiken/crypto.{VerificationKey, VerificationKeyHash}
use cl/cheque
use cl/prelude.{Amount, PosixMilliseconds, Signed}
use cl/snapshot
use cl/types as t

pub fn is_vkh_signer(
  vkh: VerificationKeyHash,
  signers: List<VerificationKeyHash>,
) {
  when signers is {
    [vkh0, ..rest] ->
      if vkh == vkh0 {
        True
      } else {
        is_vkh_signer(vkh, rest)
      }
    [] -> False
  }
}

pub fn is_vk_signer(vk: VerificationKey, signers: List<VerificationKeyHash>) {
  let vkh = crypto.blake2b_224(vk)
  is_vkh_signer(vkh, signers)
}

pub fn do_add(
  cid: t.ChannelId,
  by_opener: Bool,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  possible_snapshot: Option<Signed<t.Snapshot>>,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
  signers: List<VerificationKeyHash>,
) -> Bool {
  trace @"Add.In": @"Input state"
  trace @"Add.In.0": @"Keys `keys_in`"
  trace @"Add.In.1": @"`Opened(amt1_in, snapshot_in, period_in) = stage_in`"
  expect t.Opened(non_opener_amt_in, snapshot_in, period_in) = stage_in
  trace @"Add.In.2": @"Amount `tot_in`"

  trace @"Add.Out": @"Output state"
  trace @"Add.Out.0": @"Keys `keys_in`"
  expect keys_out == keys_in
  trace @"Add.Out.1": @"`Opened(non_opener_amt_in, snapshot_out, period_out) = stage_out`"
  expect t.Opened(non_opener_amt_out, snapshot_out, period_out) = stage_out
  trace @"Add.Out.2": @"Amount `tot_out`"

  trace @"Add.Con": @"Constraints"
  let (self, other) =
    if by_opener {
      keys_in
    } else {
      (keys_in.2nd, keys_in.1st)
    }
  trace @"Add.Con.0": @"Transaction is signed by the user key"
  expect is_vk_signer(self, signers)
  trace @"Add.Con.1": @"Total amount has increased by `x = tot_out - tot_in`, `x > 0`"
  let x = tot_out - tot_in
  expect x > 0
  trace @"Add.Con.2": @"If `by_opener` then `non_opener_amt_in == non_opener_amt_out` else `non_opener_amt_in + x == non_opener_amt_out`"
  expect
    if by_opener {
      non_opener_amt_out == non_opener_amt_in
    } else {
      non_opener_amt_out == non_opener_amt_in + x
    }
  when possible_snapshot is {
    None -> {
      trace @"Add.Con.3": @"If no snapshot provided then `snapshot_out` equals `snapshot_in`"
      expect snapshot_out == snapshot_in
    }
    Some((snapshot, sig)) -> {
      trace @"Add.Con.4": @"Else "
      trace @"Add.Con.4.0": @"Snapshot signed by the other key"
      expect snapshot.verify(cid, snapshot, other, sig)
      trace @"Add.Con.4.1": @"`snapshot_out` equals provided union `snapshot_in`"
      expect snapshot_out == snapshot.union(snapshot_in, snapshot)
    }
  }
  trace @"Add.Con.5": @"`period_out == period_in`"
  period_out == period_in
}

fn verify_cheque_idx(
  prev_chq_idx: Index,
  chq_idx: Index,
  sq_idx: Index,
  sq_excl: List<Index>,
) -> List<Index> {
  trace @"ReduceCheques.Con.1: `chq_idex > prev_chq_idx`": (
    chq_idx,
    prev_chq_idx,
  )
  expect chq_idx > prev_chq_idx
  if chq_idx > sq_idx {
    []
  } else {
    trace @"ReduceCheques.Con.2.2: Or `chq_idx elem sq_excl` && all `idx < chq_idx` from sq_excl are discarded"
    expect [excl_idx, ..sq_excl_rest] =
      list.drop_while(sq_excl, fn(i) { i < chq_idx })
    expect chq_idx == excl_idx
    sq_excl_rest
  }
}

// Given the squash and cheques list from receipt:
// * Verifies the `chqs_in` signatures
// * Verifies that the `chqs_in` are sorted
// * Verifies correspondence between `chqs_in` and `pends_out`
// * Returns the sum of the cheques amounts which are not locked
fn do_reduce_cheques(
  cid: t.ChannelId,
  other: VerificationKey,
  chqs_in: List<t.Cheque>,
  prev_chq_idx: Index,
  sq_idx: Index,
  sq_excl: List<Index>,
  ub: PosixMilliseconds,
  pends_out: t.Pend,
) -> Amount {
  when chqs_in is {
    [chq, ..chqs_rest] -> {
      trace @"ReduceCheques.Con.0": @"`chq` is signed by the `other`"
      expect cheque.verify(cid, chq, other)
      when chq is {
        t.Locked { index, timeout, lock, amount, signature: _sig } -> {
          let sq_excl_rest =
            verify_cheque_idx(prev_chq_idx, index, sq_idx, sq_excl)
          trace @"ReduceCheques.Con.3": @"`cheque.timeout >= ub`"
          expect timeout >= ub
          trace @"ReduceCheques.Con.4": @"If `Locked(_, timeout, lock, amt) = chq` then `pend.pop() == (amt, timeout, lock)`"
          expect [p, ..pends_rest] = pends_out
          expect (amount, timeout, lock) == p
          do_reduce_cheques(
            cid,
            other,
            chqs_rest,
            index,
            sq_idx,
            sq_excl_rest,
            ub,
            pends_rest,
          )
        }
        t.Unlocked { index, timeout, secret: _, amount, signature: _ } -> {
          let sq_excl_rest =
            verify_cheque_idx(prev_chq_idx, index, sq_idx, sq_excl)
          trace @"ReduceCheques.Con.3": @"`cheque.timeout >= ub`"
          expect timeout >= ub
          amount + do_reduce_cheques(
            cid,
            other,
            chqs_rest,
            index,
            sq_idx,
            sq_excl_rest,
            ub,
            pends_out,
          )
        }
      }
    }
    [] -> {
      trace @"ReduceCheques.Con.5": @"At the end of reduction `pends_out == []`"
      expect pends_out == []
      0
    }
  }
}

fn reduce_cheques(
  cid: t.ChannelId,
  other: VerificationKey,
  chqs_in: List<t.Cheque>,
  sq: t.Squash,
  ub: PosixMilliseconds,
  pends_out: t.Pend,
) -> Amount {
  let prev_cheque_idx = -1
  trace @"ReduceCheques.In: Input parameters"
  trace @"ReduceCheques.In.0: The other party verification key `other`": other
  trace @"ReduceCheques.In.1: List of signed cheques `chqs_in`": chqs_in
  trace @"ReduceCheques.In.3: The squash `sq`": sq
  trace @"ReduceCheques.In.5: Expected pending cheque list after the reduction `pends_out`": pends_out
  trace @"ReduceCheques.In.6: A point in time 'in the future' (transaction upper bound) `ub`": ub
  do_reduce_cheques(
    cid,
    other,
    chqs_in,
    prev_cheque_idx,
    sq.index,
    sq.exclude,
    ub,
    pends_out,
  )
}

pub fn received_and_sent(
  self: VerificationKey,
  other: VerificationKey,
  snapshot: t.Snapshot,
) -> (t.Squash, t.Squash) {
  if builtin.less_than_bytearray(self, other) {
    snapshot
  } else {
    (snapshot.2nd, snapshot.1st)
  }
}

pub fn do_close(
  cid: t.ChannelId,
  by_opener: Bool,
  signers: List<VerificationKeyHash>,
  ub: PosixMilliseconds,
  receipt: t.Receipt,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"Close.In: Input state"
  trace @"Close.In.0: Keys `keys_in`": keys_in
  trace @"Close.In.1: Opened(non_opener_amt, snapshot_in, respond_period) = stage_in`": stage_in
  expect t.Opened(non_opener_amt_in, snapshot_in, respond_period) = stage_in
  trace @"Close.In.2: Amount `tot_in`": tot_in

  trace @"Close.Out: Output state"
  trace @"Close.Out.0: Keys `keys_out`": keys_out
  trace @"Close.Out.1: `Closed(closer_amt_out, squash_out, timeout_out, pends_out) = stage_out`": stage_out
  expect t.Closed(closer_amt_out, closer_sent_out, timeout_out, pends_out) =
    stage_out
  trace @"Close.Out.2: Amount `tot_out`": tot_out

  trace @"Close.Con": @"Constraints"
  trace @"Close.Con.0": @"If `by_opener` then `keys_in == keys_out` else keys are reversed"
  expect
    if by_opener {
      keys_out == keys_in
    } else {
      keys_out.1st == keys_in.2nd && keys_out.2nd == keys_in.1st
    }
  let (closer_key, non_closer_key) = keys_out
  trace @"Close.Con.0.1: closer has signed the tx"
  expect is_vk_signer(closer_key, signers)

  let (possible_sn, receipt_chqs) = receipt
  let snapshot_out =
    when possible_sn is {
      None -> {
        trace @"Close.Con.1": @"If no snapshot provided then `snapshot_out` equals `snapshot_in`"
        snapshot_in
      }
      Some((snp, snp_sig)) -> {
        trace @"Close.Con.2": @"Else "
        trace @"Close.Con.2.0": @"Snapshot signed by non-closer key"
        expect snapshot.verify(cid, snp, non_closer_key, snp_sig)
        trace @"Close.Con.2.1": @"`snapshot_out` equals provided union `snapshot_in`"
        snapshot.union(snapshot_in, snp)
      }
    }
  let (received, sent) =
    received_and_sent(closer_key, non_closer_key, snapshot_out)
  trace @"Close.Con.3": @"ReduceCheques succeeds with `chqs_amt` for the provided cheques and the `pends_out`"
  let chqs_amt =
    reduce_cheques(cid, non_closer_key, receipt_chqs, received, ub, pends_out)
  trace @"Close.Con.4 : `closer_amt == closer_amt_in + chqs_amt + sq_diff` where"
  expect closer_amt_out == {
      let closer_amt_in =
        if by_opener {
          trace @"Close.Con.4.1: If the closer is also the opener then `amt_in = tot_in - non_opener_amt_in`"
          tot_in - non_opener_amt_in
        } else {
          trace @"Close.Con.4.2: Else `amt_in = non_opener_amt_in`"
          non_opener_amt_in
        }

      trace @"Close.Con.4.3: And `sq_diff = sq_received.1st - sq_sent.1st` where `sq_*` are parts of the latest snapshot"
      let sq_diff = received.amount - sent.amount
      closer_amt_in + chqs_amt + sq_diff
    }
  trace @"Close.Con.5": @"`sq_non_closer_received_out == sq_closer_sent`"
  expect closer_sent_out == sent
  trace @"Close.Con.6": @"`timeout_out >= ub + respond_period`"
  expect timeout_out >= ub + respond_period
  trace @"Close.Con.7": @"tot_out >= tot_in"
  tot_out >= tot_in
}

fn sum_pends(pend: t.Pend) -> Amount {
  when pend is {
    [p, ..rest] -> {
      let (amt, _timeout, _lock) = p
      amt + sum_pends(rest)
    }
    [] -> 0
  }
}

// A rather specialized reduction which is isolated here because it is
// repeated in respond and respond-end.
pub type ReducedReceiptAmount =
  Amount

pub fn reduce_respond_receipt(
  cid: t.ChannelId,
  sq_in: t.Squash,
  non_closer_receipt: t.Receipt,
  non_closer_pends_out: t.Pend,
  closer_key: VerificationKey,
  non_closer_key: VerificationKey,
  ub: PosixMilliseconds,
) -> ReducedReceiptAmount {
  let (possible_snp, chqs) = non_closer_receipt
  let (sq_received, sq_diff) =
    when possible_snp is {
      Some((snp, snp_sig)) -> {
        trace @"ApplyReceipt.Con.1: If the receipt contains snapshot with updated `sq_received`"
        trace @"ApplyReceipt.Con.1.0: Snapshot signed by the closer key"
        expect snapshot.verify(cid, snp, closer_key, snp_sig)
        let (sq_received, _) =
          received_and_sent(non_closer_key, closer_key, snp)
        // TODO: Is this check necessary?
        trace @"ApplyReceipt.Con.1.1: `sq_received.index > sq_in.index`": (
          sq_received.index,
          sq_in.index,
        )
        expect sq_received.index > sq_in.index
        trace @"ApplyReceipt.Con.1.2: `sq_diff = sq_received.amount - sq_in.amount`": (
          sq_received.amount,
          sq_in.amount,
        )
        (sq_received, sq_received.amount - sq_in.amount)
      }
      None -> {
        trace @"ApplyReceipt.Con.2: @If the receipt does not contain snapshot then `sq_received == sq_in` and `sq_diff = 0`"
        (sq_in, 0)
      }
    }
  let unlocked_amt =
    reduce_cheques(cid, closer_key, chqs, sq_received, ub, non_closer_pends_out)
  unlocked_amt + sq_diff
}

pub fn do_respond(
  cid: t.ChannelId,
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  receipt: t.Receipt,
  drop_old: Bool,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"Respond.In: Input state"
  trace @"Respond.In.0: Keys `keys_in`": keys_in
  trace @"Respond.In.1: `Closed(closer_amt_in, sq_in, timeout_in, closer_pends_in) = stage_in`": stage_in
  expect t.Closed(closer_amt_in, sq_in, _timeout, closer_pends_in) = stage_in
  trace @"Respond.In.2: Amount `tot_in`": tot_in

  trace @"Respond.Out: Output state"
  trace @"Respond.Out.0: Keys `keys_out`": keys_out
  // non-closer is becoming here the resolver.
  // So `Resolved(non_resolver_amt, resolver_pends, non_resolver_pends)
  // translates to the below:
  trace @"Respond.Out.1: `Resolved(closer_amt_out, non_closer_pends_out, closer_pends_out) = stage_out`": stage_out
  expect t.Resolved(closer_amt_out, non_closer_pends_out, closer_pends_out) =
    stage_out
  trace @"Respond.Out.2: Amount `tot_out`": tot_out

  trace @"Respond.Con: Constraints"
  trace @"Respond.Con.0: non-closer which is `keys_in.1` has singed the tx"
  let (closer_key, non_closer_key) = keys_in
  expect is_vk_signer(non_closer_key, signers)

  trace @"Respond.Con.1: `keys_out` are swapped `keys_in`"
  expect keys_out == (non_closer_key, closer_key)

  trace @"Respond.Con.2: `timeout_in < lb` (respond period has passed)"
  let reduced_receipt_amt =
    reduce_respond_receipt(
      cid,
      sq_in,
      receipt,
      non_closer_pends_out,
      closer_key,
      non_closer_key,
      ub,
    )

  if drop_old {
    trace @"Respond.Con.3: If `drop_old` then `closer_pends_in` is reduced using the `lb` and results in `closer_pends_out`": (
      closer_pends_in,
      lb,
      closer_pends_out,
    )
    expect _ = reduce_sent_pends(closer_pends_in, closer_pends_out, lb)
  } else {
    trace @"Respond.Con.4: Else `closer_pends_in == closer_pends_out`": (
      closer_pends_in,
      closer_pends_out,
    )
    expect closer_pends_out == closer_pends_in
  }

  let closer_pends_out_amt = sum_pends(closer_pends_out)
  trace @"Respond.Con.5: `closer_amt_out == closer_amt_in - reduced_receipt_amt - sum_pends(non_closer_pends_out)`": (
    closer_amt_out,
    closer_amt_in,
    reduced_receipt_amt,
    closer_pends_out_amt,
  )
  let non_closer_pends_out_amt = sum_pends(non_closer_pends_out)
  expect
    closer_amt_out == closer_amt_in - reduced_receipt_amt - non_closer_pends_out_amt

  trace @"Respond.Con.7: `tot_out` is at least `closer_amt_out + sum(closer_pends_out_amt)`": (
    tot_out,
    closer_amt_out,
    closer_pends_out_amt,
  )
  tot_out >= closer_amt_out + closer_pends_out_amt + non_closer_pends_out_amt
}

pub type UnlockedAmount =
  Amount

fn do_reduce_received_pends(
  curr_idx: Int,
  pends_in: t.Pend,
  pends_out: t.Pend,
  secrets: t.Secrets,
  ub: PosixMilliseconds,
) -> UnlockedAmount {
  when (pends_in, secrets) is {
    (_, []) -> {
      trace @"ReduceReceivedPend.Con.0: At the end of reduction `secrets == []` && `pends_in == pends_out`": (
        pends_in,
        pends_out,
      )
      expect pends_out == pends_in
      0
    }
    ([(amt, timeout, lock), ..rest_in], [(secret_idx, secret), ..rest_secrets]) ->
      if curr_idx == secret_idx {
        // We found the indexed position - verify secret
        expect lock == cheque.hash_htlc_secret(secret)
        expect timeout > ub
        // Secret matches, skip this entry in output and add amount to total
        amt + do_reduce_received_pends(
          curr_idx + 1,
          rest_in,
          pends_out,
          rest_secrets,
          ub,
        )
      } else {
        // Please note that we keep the expired cheques as these should
        // be reduced by the partner.
        // Not the indexed position - keep entry in output
        expect [(amt_out, timeout_out, lock_out), ..rest_out] = pends_out
        expect amt_out == amt && timeout_out == timeout && lock_out == lock
        do_reduce_received_pends(curr_idx + 1, rest_in, rest_out, secrets, ub)
      }
    ([], _) -> fail @"Pend/Secrets mismatch"
  }
}

// The below two reduction function have subtle but important difference in how they handle timeouts:
// * When the user reduces received cheques he should prove that they are still valid so their timeout should be in the future. He should provide a `ub` which is smaller than the cheque timeout in such a case.
// * When the user frees sent cheques he should prove that a given cheque which he signed has expired. He should provide an `lb` which is larger than the cheque timeout in this case.
fn reduce_received_pends(
  pends_in: t.Pend,
  pends_out: t.Pend,
  secrets: t.Secrets,
  ub: PosixMilliseconds,
) -> UnlockedAmount {
  do_reduce_received_pends(0, pends_in, pends_out, secrets, ub)
}

type ExpiredAmount =
  Amount

fn reduce_sent_pends(
  pends_in: t.Pend,
  pends_out: t.Pend,
  lb: PosixMilliseconds,
) -> ExpiredAmount {
  when pends_in is {
    [] -> {
      trace @"ReduceSentPend.Con.0: At the end of reduction `pends_in == []` && `pends_out == []`": (
        pends_in,
        pends_out,
      )
      expect pends_out == []
      0
    }
    [(amt_in, timeout_in, lock_in), ..rest_in] ->
      if timeout_in < lb {
        trace @"ReduceSentPend.Con.1: `pend.timeout < lb`": (timeout_in, lb)
        // Timeout has passed - skip this entry in the output.
        // Add its amount to the released amount.
        amt_in + reduce_sent_pends(rest_in, pends_out, lb)
      } else {
        trace @"ReduceSentPend.Con.2: `pend.timeout >= lb`": (timeout_in, lb)
        expect [(amt_out, timeout_out, lock_out), ..rest_out] = pends_out
        // Timeout has not passed - keep entry in the output
        // checking if it is honestly preserved
        expect
          amt_in == amt_out && timeout_in == timeout_out && lock_in == lock_out
        reduce_sent_pends(rest_in, rest_out, lb)
      }
  }
}

pub fn do_elapse(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  secrets: t.Secrets,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"Elapse.In: Input state"
  trace @"Elapse.In.0: Keys `keys_in`": keys_in
  trace @"Elapse.In.1: `Closed(amt_in, squash_in, timeout_in, pends_in) = stage_in`": stage_in
  expect t.Closed(closer_amt_in, _sq_in, timeout_in, closer_pends_in) = stage_in
  trace @"Elapse.In.2: Amount `tot_in`": tot_in

  trace @"Elapse.Out: Output state"
  trace @"Elapse.Out.0: Keys `keys_out`": keys_out
  expect keys_out == keys_in
  trace @"Elapse.Out.1: `Resolved(non_closer_amt_out, closer_pends_out, non_close_pends_out) = stage_out`": stage_out
  // The closer becomes the non-resolver here.
  // The `Resolved(non_resolver_amt, resolver_pends, non_resolver_pends)`
  expect t.Resolved(non_closer_amt_out, closer_pends_out, non_closer_pends_out) =
    stage_out
  trace @"Elapse.Out.2: Amount `tot_out`": tot_out

  trace @"Elapse.Con: Constraints"
  trace @"Elapse.Con.0: The closer (`keys_in.0`) has signed the tx"
  let (closer_key, _) = keys_in
  expect is_vk_signer(closer_key, signers)

  trace @"Elapse.Con.1: `timeout_in < lb` (respond period has passed)"
  expect timeout_in < lb

  trace @"Elapse.Con.2: `closer_pends_out` is reduced from `closer_pends_in` using provided secrets and results in `unlocked_amt`"
  let unlocked_amt =
    reduce_received_pends(closer_pends_in, closer_pends_out, secrets, ub)

  trace @"Elapse.Con.3: `non_closer_pends_out == []`": non_closer_pends_out
  expect non_closer_pends_out == []

  // Helper values to increase readability of the constraint
  trace @"Elapse.Con.4: Given `closer_amt_out = closer_amt_in + unlocked_amt`": (
    closer_amt_in,
    unlocked_amt,
  )
  let closer_amt_out = closer_amt_in + unlocked_amt

  trace @"Elapse.Con.5: `tot_out == tot_in - closer_amt_out`": (
    tot_out,
    tot_in,
    closer_amt_out,
  )
  expect tot_out == tot_in - closer_amt_out

  trace @"Elapse.Con.6: `non_closer_amt_out == tot_out - sum_pends(closer_pends_out)`": (
    non_closer_amt_out,
    tot_out,
    sum_pends(closer_pends_out),
  )
  non_closer_amt_out == tot_out - sum_pends(closer_pends_out)
}

pub fn do_free_in_closed(
  signers: List<VerificationKeyHash>,
  ub: PosixMilliseconds,
  secrets: t.Secrets,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"FreeInClosed.In: Input state"
  trace @"FreeInClosed.In.0: Keys `keys_in`": keys_in
  trace @"FreeInClosed.In.1: `Closed(closer_amt_in, sq_in, timeout_in, closer_pends_in) = stage_in`": stage_in
  expect t.Closed(closer_amt_in, sq_in, timeout_in, closer_pends_in) = stage_in
  trace @"FreeInClosed.In.2: Amount `tot_in`": tot_in

  trace @"FreeInClosed.Out: Output state"
  trace @"FreeInClosed.Out.0: Keys `keys_out`": keys_out
  trace @"FreeInClosed.Out.1: `Closed(closer_amt_out, sq_out, timeout_out, closer_pends_out) = stage_out`": stage_out
  expect t.Closed(closer_amt_out, sq_out, timeout_out, closer_pends_out) =
    stage_out
  trace @"FreeInClosed.Out.2: Amount `tot_out`": tot_out

  trace @"Free.Con": @"Constraints"
  trace @"Free.Con.0": @"`keys_in == keys_out`"
  expect keys_in == keys_out

  trace @"Free.Con.1.0: closer (`keys_in.0`) has signed the tx"
  let (closer_key, _) = keys_in
  expect is_vk_signer(closer_key, signers)

  trace @"Free.Con.1.2: `closer_pends_out` is reduced from `closer_pends_in` using provided secrets and results in `unlocked_amt`": (
    closer_pends_in,
    closer_pends_out,
    secrets,
    ub,
  )
  let unlocked_amt =
    reduce_received_pends(closer_pends_in, closer_pends_out, secrets, ub)

  trace @"Free.Con.1.3": @"`unlocked_amt != 0` to prevent noop looping"
  expect unlocked_amt != 0

  trace @"Free.Con.1.4": @"`closer_amt_out == closer_amt_in + unlocked_amt`"
  expect closer_amt_out == closer_amt_in + unlocked_amt

  trace @"Free.Con.1.5": @"`sq_out == sq_in`"
  expect sq_out == sq_in

  trace @"Free.Con.1.6": @"`timeout_out == timeout_in`"
  expect timeout_out == timeout_in

  trace @"Free.Con.1.7": @"`tot_out == tot_in`"
  tot_out == tot_in
}

pub fn do_reduce_pends(
  received_pends_in,
  sent_pends_in,
  received_pends_out,
  sent_pends_out,
  secrets,
  drop_old,
  lb,
  ub,
) -> Amount {
  trace @"ReduceCheques.Con.1": @"`received_pends_out` is `received_pends_in` reduced with secrets and results in `received_freed`"
  let received_freed =
    reduce_received_pends(received_pends_in, received_pends_out, secrets, ub)
  let sent_freed =
    if drop_old {
      trace @"ReduceCheques.Con.2": @"If `drop_old` then `sent_pends_out` is `sent_pends_in` reduced by `timeout < lb` resulting in `sent_freed`"
      reduce_sent_pends(sent_pends_in, sent_pends_out, lb)
    } else {
      trace @"ReduceCheques.Con.3": @"Else `sent_pends_out == sent_pends_in`"
      expect sent_pends_out == sent_pends_in
      0
    }
  received_freed + sent_freed
}

pub fn do_free_in_resolved(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  by_resolver: Bool,
  secrets: t.Secrets,
  drop_old: Bool,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"Free.In: Input state"
  trace @"Free.In.0: `Resolved(non_resolver_amt_in, resolver_pends_in, non_resolver_pends_in) = stage_in`": stage_in
  expect t.Resolved(non_resolver_amt_in, closer_pends_in, non_closer_pends_in) =
    stage_in

  trace @"Free.Out: Output state"
  trace @"Free.Out.0: `Resolved(resolved_amt_out, resolver_pends_out, non_resolver_pends_out) = stage_out`": stage_out
  expect t.Resolved(
    non_resolver_amt_out,
    closer_pends_out,
    non_closer_pends_out,
  ) = stage_out

  trace @"Free.Con: Constraints"
  trace @"Free.Con.0: `keys_in == keys_out`"
  expect keys_in == keys_out

  let amt_freed =
    if by_resolver {
      trace @"Free.Con.1": @"If `by_resolver` then resolver (`keys_in.1st`) has signed the tx"
      expect is_vk_signer(keys_in.1st, signers)

      trace @"Free.Con.1.0: `non_resolver_amt_out == non_resolver_amt_in`"
      expect non_resolver_amt_out == non_resolver_amt_in

      trace @"Free.Con.1.1: Pends are reduced where resolver is the receiver resulting in `amt_freed`"
      do_reduce_pends(
        closer_pends_in,
        non_closer_pends_in,
        closer_pends_out,
        non_closer_pends_out,
        secrets,
        drop_old,
        lb,
        ub,
      )
    } else {
      trace @"Free.Con.2": @"Else non-resolver (`keys_in.2nd`) has signed the tx"
      expect is_vk_signer(keys_in.2nd, signers)

      trace @"Free Con.2.0: Pends are reduced where non-closer is the receiver resulting in `pends_freed`"
      let pends_amt =
        do_reduce_pends(
          non_closer_pends_in,
          closer_pends_in,
          non_closer_pends_out,
          closer_pends_out,
          secrets,
          drop_old,
          lb,
          ub,
        )

      trace @"Free.Con.2.1: `non_resolver_amt_out == 0`"
      expect non_resolver_amt_out == 0

      trace @"Free.Con.2.2: `amt_freed = non_resolver_amt_in + pends_amt`"
      pends_amt + non_resolver_amt_in
    }
  trace @"Free.Con.3": @"`amt_freed != 0` to prevent noop looping"
  expect amt_freed != 0

  trace @"Free.Con.4": @"`tot_out == tot_in - amt_freed`"
  tot_out == tot_in - amt_freed
}

pub fn do_end_resolved(
  signer_idx: t.KeyIdx,
  secrets: t.Secrets,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  stage: t.Stage,
) -> Bool {
  trace @"EndResolved.In: Input state"
  trace @"EndResolved.In.0: `Resolved(non_resolver_amt, resolver_pends, non_resolver_pends) = stage`": stage
  expect t.Resolved(non_resolver_amt, resolver_pends, non_resolver_pends) =
    stage

  trace @"End.Con: Constraints by stage"
  trace @"End.Con.0: `signer_idx == 0` indicates if the user is the resolver"
  let by_resolver = signer_idx == 0
  let (received_pends, sent_pends) =
    if by_resolver {
      (resolver_pends, non_resolver_pends)
    } else {
      (non_resolver_pends, resolver_pends)
    }
  trace @"End.Con.1: All pends are fully reduced"
  expect _ =
    do_reduce_pends(received_pends, sent_pends, [], [], secrets, True, lb, ub)

  trace @"End.Con.2: `non_resolver_amt == 0` when executed by resolver"
  !by_resolver || non_resolver_amt == 0
}

pub fn do_elapse_end(
  signer_idx: t.KeyIdx,
  secrets: t.Secrets,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  tot_in: Amount,
  stage_in: t.Stage,
) -> Bool {
  trace @"ElapseEnd.In": @"Input state"
  trace @"ElapseEnd.In.0: `Closed(closer_amt, squash, timeout, closer_pends) = stage_in`": stage_in
  expect t.Closed(closer_amt, _squash, timeout, closer_pends) = stage_in
  trace @"ElapseEnd.In.1: `tot_in = `": tot_in

  trace @"ElapseEnd: Constraints by stage"
  trace @"ElapseEnd.Con.0: closer (`signer_idx == 0`) has signed the tx"
  expect signer_idx == 0

  trace @"ElapseEnd.Con.1: `timeout < lb` (respond period has passed)"
  expect timeout < lb

  trace @"ElapseEnd.Con.2: All closer_pends are fully reduced resulting in `amt_freed`"
  let amt_freed =
    do_reduce_pends(closer_pends, [], [], [], secrets, True, lb, ub)

  trace @"ElapseEnd.Con.3: `tot_in == closer_amt + amt_freed`"
  tot_in == closer_amt + amt_freed
}

pub fn do_respond_end(
  cid: t.ChannelId,
  signer_idx: t.KeyIdx,
  keys_in: t.Keys,
  receipt: t.Receipt,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  tot_in: Amount,
  stage_in: t.Stage,
) -> Bool {
  trace @"RespondEnd.In": @"Input state"
  trace @"RespondEnd.In.0: `Closed(closer_amt, squash, timeout, closer_pends) = stage_in`": stage_in
  expect t.Closed(closer_amt, sq_in, _timeout, closer_pends) = stage_in
  trace @"RespondEnd.In.1: `tot_in = `": tot_in

  trace @"RespondEnd: Constraints by stage"
  trace @"RespondEnd.Con.0: non-closer (`signer_idx == 1`) has signed the tx"
  expect signer_idx == 1

  trace @"RespondEnd.Con.1: Received cheques are fully reduced resulting in `reduced_receipt_amt`": (
    receipt,
    ub,
  )
  let (closer_key, non_closer_key) = keys_in
  let reduced_receipt_amt =
    reduce_respond_receipt(
      cid,
      sq_in,
      receipt,
      [],
      closer_key,
      non_closer_key,
      ub,
    )

  trace @"RespondEnd.Con.2: All closer_pends have expired"
  expect _ = reduce_sent_pends(closer_pends, [], lb)

  trace @"RespondEnd.Con.3: `closer_amt - reduced_receipt_amt == 0`": (
    closer_amt,
    reduced_receipt_amt,
  )
  closer_amt - reduced_receipt_amt == 0
}
