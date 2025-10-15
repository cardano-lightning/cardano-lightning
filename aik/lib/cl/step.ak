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
  trace @"ReduceCheques.Con.1": @"`chq_idex > prev_chq_idx`"
  expect chq_idx > prev_chq_idx
  if chq_idx > sq_idx {
    []
  } else {
    trace @"ReduceCheques.Con.2.2": @"Or `chq_idx elem sq_excl` && all `idx < chq_idx` from sq_excl are discarded"
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
  trace @"ReduceCheques.In.0: The other party verification key `other`"
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

type NonExpiredAmount =
  Amount

// Returns actual sum of *the remaining non-expired* pends.
pub fn expire_pends(
  pends_in: t.Pend,
  pends_out: t.Pend,
  lb: PosixMilliseconds,
) -> NonExpiredAmount {
  when pends_in is {
    [] -> {
      expect pends_out == []
      0
    }
    [(amt_in, timeout_in, lock_in), ..rest_in] ->
      if timeout_in < lb {
        // Timeout has passed - skip this entry in the output.
        // Add its amount to the released amount.
        expire_pends(rest_in, pends_out, lb)
      } else {
        expect [(amt_out, timeout_out, lock_out), ..rest_out] = pends_out
        // Timeout has not passed - keep entry in the output
        // checking if it is honestly preserved
        expect
          amt_in == amt_out && timeout_in == timeout_out && lock_in == lock_out
        amt_in + expire_pends(rest_in, rest_out, lb)
      }
  }
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

  let (possible_snp, chqs) = receipt
  let (sq_received, sq_diff) =
    when possible_snp is {
      Some((snp, snp_sig)) -> {
        trace @"Respond.Con.2: @If the receipt contains snapshot with updated `sq_received`"
        trace @"Respond.Con.2.0": @"Snapshot signed by the closer key"
        expect snapshot.verify(cid, snp, closer_key, snp_sig)
        let (sq_received, _) =
          received_and_sent(non_closer_key, closer_key, snp)
        // TODO: Is this check necessary?
        trace @"Respond.Con.2.1: `sq_received.index > sq_in.index`": (
          sq_received.index,
          sq_in.index,
        )
        expect sq_received.index > sq_in.index
        trace @"Respond.Con.2.2: `sq_diff = sq_received.amount - sq_in.amount`": (
          sq_received.amount,
          sq_in.amount,
        )
        (sq_received, sq_received.amount - sq_in.amount)
      }
      None -> {
        trace @"Respond.Con.3: @Else `sq_received == sq_in` and `sq_diff = 0`"
        (sq_in, 0)
      }
    }
  trace @"Respond.Con.3": @"ReduceCheques succeeds with `chqs_amt` for the provided cheques and the `resolver_pends_out`"
  let unlocked_chqs_amt =
    reduce_cheques(cid, closer_key, chqs, sq_received, ub, non_closer_pends_out)

  let closer_pends_out_amt =
    if drop_old {
      trace @"Respond.Con.4: If `drop_old` then `closer_pends_in` is reduced using the `lb` and results in `closer_pends_out`": (
        closer_pends_in,
        lb,
        closer_pends_out,
      )
      expire_pends(closer_pends_in, closer_pends_out, lb)
    } else {
      trace @"Respond.Con.5: Else `closer_pends_in == closer_pends_out`": (
        closer_pends_in,
        closer_pends_out,
      )
      expect closer_pends_out == closer_pends_in
      sum_pends(closer_pends_out)
    }
  trace @"Respond.Con.6: `closer_amt_out == closer_amt_in - unlocked_chqs_amt - sq_diff - sum_pends(non_closer_pends_out)`": (
    closer_amt_in,
    unlocked_chqs_amt,
    sq_diff,
  )
  let non_closer_pends_out_amt = sum_pends(non_closer_pends_out)
  expect
    closer_amt_out == closer_amt_in - unlocked_chqs_amt - sq_diff - non_closer_pends_out_amt

  trace @"Respond.Con.7: `tot_out` is at least `closer_amt_out + sum(closer_pends_out_amt)`": (
    tot_out,
    closer_amt_out,
    closer_pends_out_amt,
  )
  tot_out >= closer_amt_out + closer_pends_out_amt + non_closer_pends_out_amt
}

fn do_reduce_received_pends(
  curr_idx: Int,
  pends_in: t.Pend,
  pends_out: t.Pend,
  secrets: t.Secrets,
  ub: PosixMilliseconds,
) -> Amount {
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
) -> Amount {
  do_reduce_received_pends(0, pends_in, pends_out, secrets, ub)
}

// fn reduce_sent_pend(
//   pends_in: t.Pend,
//   pends_out: t.Pend,
//   lb: PosixMilliseconds,
// ) -> Amount {
//   when pends_in is {
//     [] -> {
//       trace @"ReduceSentPend.Con.0: At the end of reduction `pends_in == []` && `pends_out == []`": (
//         pends_in,
//         pends_out,
//       )
//       expect pends_out == []
//       0
//     }
//     [(amt_in, timeout_in, lock_in), ..rest_in] ->
//       if timeout_in < lb {
//         trace @"ReduceSentPend.Con.1: `pend.timeout < lb`": (timeout_in, lb)
//         // Timeout has passed - skip this entry in the output.
//         // Add its amount to the released amount.
//         amt_in + reduce_sent_pend(rest_in, pends_out, lb)
//       } else {
//         trace @"ReduceSentPend.Con.2: `pend.timeout >= lb`": (timeout_in, lb)
//         expect [(amt_out, timeout_out, lock_out), ..rest_out] = pends_out
//         // Timeout has not passed - keep entry in the output
//         // checking if it is honestly preserved
//         expect
//           amt_in == amt_out && timeout_in == timeout_out && lock_in == lock_out
//         reduce_sent_pend(rest_in, rest_out, lb)
//       }
//   }
// }
// 
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

  trace @"Elapse.Con": @"Constraints"
  trace @"Elapse.Con.0": @"The closer (`keys_in.0`) has signed the tx"
  let (closer_key, _) = keys_in
  expect is_vk_signer(closer_key, signers)

  trace @"Elapse.Con.1": @"`timeout_in < lb` (respond period has passed)"
  expect timeout_in < lb

  trace @"Elapse.Con.2": @"`closer_pends_out` is reduced from `closer_pends_in` using provided secrets and results in `unlocked_amt`"
  let unlocked_amt =
    reduce_received_pends(closer_pends_in, closer_pends_out, secrets, ub)
  let closer_amt_out = closer_amt_in + unlocked_amt
  let closer_pends_out_amt = sum_pends(closer_pends_out)

  trace @"Elapse.Con.3: `non_closer_pends_out == []`"
  expect non_closer_pends_out == []

  trace @"Elapse.Con.4: `non_closer_amt_out == tot_in - closer_amt_out + sum_pends(closer_pends_out)`"
  expect non_closer_amt_out == tot_in - closer_amt_out + closer_pends_out_amt

  trace @"Elapse.Con.5: `tot_out == non_closer_amt_out + sum_pends(closer_pends_out)`"
  tot_out == non_closer_amt_out + closer_pends_out_amt
}

pub fn do_free_in_closed(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  secrets: t.Secrets,
  drop_old: Bool,
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

  when stage_in is {
    t.Closed(amt_in, squash_in, timeout_in, pends_in) -> {
      expect has_vk0(keys_in, signers)

      trace @"Free.Con.1.1": @"`Close(amt_out, squash_out, timeout_out, pends_out) = stage_out`"
      expect t.Closed(amt_out, squash_out, timeout_out, pends_out) = stage_out

      trace @"Free.Con.1.2": @"`pends_out` is reduced from `pend` using provided secrets and results in `amt_freed`"
      let amt_freed = reduce_received_pends(pends_in, pends_out, secrets, ub)

      trace @"Free.Con.1.3": @"`amt_freed != 0` to prevent noop looping"
      expect amt_freed != 0

      trace @"Free.Con.1.4": @"`amt_out == amt_in + amt_freed`"
      expect amt_out == amt_in + amt_freed

      trace @"Free.Con.1.5": @"`squash_out == squash_in`"
      expect squash_out == squash_in

      trace @"Free.Con.1.6": @"`timeout_out == timeout_in`"
      expect timeout_out == timeout_in

      trace @"Free.Con.1.7": @"`tot_out == tot_in`"
      tot_out == tot_in
    }

    t.Responded(amt_in, pend0_in, pend1_in) -> {
      trace @"Free.Con.2": @"When `stage_in` is Responded(amt_in, pend0_in, pend1_in)"

      trace @"Free.Con.2.0": @"`keys_in.1` has signed the tx"
      expect has_vk1(keys_in, signers)

      trace @"Free.Con.2.1": @"`Responded(amt_out, pend0_out, pend1_out) = stage_out`"
      expect t.Responded(amt_out, pend0_out, pend1_out) = stage_out

      trace @"Free.Con.2.2": @"`amt_out == amt_in`"
      expect amt_out == amt_in

      trace @"Free.Con.2.3": @"`pend1_out` is reduced from `pend1_in` using provided secrets and results in `received_freed`"
      let received_freed =
        reduce_received_pends(pend1_in, pend1_out, secrets, ub)

      let sent_freed =
        if drop_old {
          trace @"Free.Con.2.4": @"If `drop_old` then `pend0_out` is reduced by timeout from `pend0_in` by `timeout < lb` resulting in `sent_freed`"
          reduce_sent_pend(pend0_in, pend0_out, lb)
        } else {
          trace @"Free.Con.2.5": @"Else `pend0_out == pend0_in`"
          expect pend0_out == pend0_in
          0
        }
      trace @"Free.Con.2.6": @"`amt_freed == received_freed + sent_freed` to prevent noop looping"
      let amt_freed = received_freed + sent_freed
      expect amt_freed != 0

      trace @"Free.Con.2.7": @"`tot_out == tot_in - amt_freed`"
      tot_out == tot_in - amt_freed
    }
    t.Elapsed(pend) -> {
      trace @"Free.Con.3": @"When `stage_in` is Elapsed(pend)"
      trace @"Free.Con.3.0": @"`keys_in.0` has signed the tx"
      expect has_vk0(keys_in, signers)

      trace @"Free.Con.3.1": @"`Elapsed(pends_out) = stage_out`"
      expect t.Elapsed(pends_out) = stage_out

      trace @"Free.Con.3.2": @"`pends_out` is reduced from `pend` using provided secrets and results in `amt_freed`"
      let amt_freed = reduce_received_pends(pend, pends_out, secrets, ub)

      trace @"Free.Con.3.3": @"`amt_freed != 0` to prevent noop looping"
      expect amt_freed != 0

      trace @"Free.Con.3.4": @"`tot_out == tot_in - amt_freed`"
      tot_out == tot_in - amt_freed
    }
    _ -> fail @"Invalid stage for the `free` step"
  }
}

// pub fn do_reduce_pends(
//   received_pends_in,
//   sent_pends_in,
//   received_pends_out,
//   sent_pends_out,
//   secrets,
//   drop_old,
//   lb,
//   ub,
// ) -> Amount {
//   trace @"ReduceCheques.Con.1": @"`received_pends_out` is `received_pends_in` reduced with secrets and results in `received_freed`"
//   let received_freed =
//     reduce_received_pends(received_pends_in, received_pends_out, secrets, ub)
//   let sent_freed =
//     if drop_old {
//       trace @"ReduceCheques.Con.2": @"If `drop_old` then `sent_pends_out` is `sent_pends_in` reduced by `timeout < lb` resulting in `sent_freed`"
//       reduce_sent_pend(sent_pends_in, sent_pends_out, lb)
//     } else {
//       trace @"ReduceCheques.Con.3": @"Else `sent_pends_out == sent_pends_in`"
//       expect sent_pends_out == sent_pends_in
//       0
//     }
//   received_freed + sent_freed
// }
// 
pub fn do_free_in_resolved(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  by_closer: Bool,
  secrets: t.Secrets,
  drop_old: Bool,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  False
}

//   trace @"Free.In": @"Input state"
//   trace @"Free.In.0": @"`Resolved(closer_pends_in, non_closer_pends_in) = stage_in`"
//   expect t.Resolved(closer_pends_in, non_closer_pends_in) = stage_in
// 
//   trace @"Free.Out": @"Output state"
//   trace @"Free.Out.0": @"`Resolved(closer_pends_out, non_closer_pends_out) = stage_out`"
//   expect t.Resolved(closer_pends_out, non_closer_pends_out) = stage_out
// 
//   trace @"Free.Con": @"Constraints"
//   trace @"Free.Con.0": @"`keys_in == keys_out`"
//   expect keys_in == keys_out
// 
//   let amt_freed =
//     if by_closer {
//       trace @"Free.Con.1": @"If `by_closer` then `keys_in.0` has signed the tx"
//       expect is_vk_signer(keys_in.1st, signers)
//       trace @"Free.Con.1.1": @"Pends are reduced where closer is the receiver"
//       do_reduce_pends(
//         closer_pends_in,
//         non_closer_pends_in,
//         closer_pends_out,
//         non_closer_pends_out,
//         secrets,
//         drop_old,
//         lb,
//         ub,
//       )
//     } else {
//       trace @"Free.Con.2": @"Else `keys_in.1` has signed the tx"
//       expect is_vk_signer(keys_in.2nd, signers)
//       trace @"Free Con.2.1": @"Pends are reduced where non-closer is the receiver"
//       do_reduce_pends(
//         non_closer_pends_in,
//         closer_pends_in,
//         non_closer_pends_out,
//         closer_pends_out,
//         secrets,
//         drop_old,
//         lb,
//         ub,
//       )
//     }
//   trace @"Free.Con.3": @"`amt_freed != 0` to prevent noop looping"
//   expect amt_freed != 0
// 
//   trace @"Free.Con.4": @"`tot_out == tot_in - amt_freed`"
//   tot_out == tot_in - amt_freed
// }
// 
pub fn do_end(
  user_idx: t.KeyIdx,
  secrets: t.Secrets,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  tot_in: Amount,
  stage_in: t.Stage,
) -> Bool {
  False
}
//   trace @"End.In": @"Input state"
//   trace @"End.In.0: `stage_in =`": stage_in
//   trace @"End.In.1: `tot_in = `": tot_in
// 
//   trace @"End.Out": @"Output state"
//   trace @"End.Out.0": @"No continuing output (channel is ended)"
// 
//   trace @"End.Con": @"Constraints by stage"
//   trace @"End.Con.0": @"`user_idx` indicates if the user is the closer (0) as we are not in the `Opened` stage anymore"
//   let by_closer = user_idx == 0
//   let (received_pends, sent_pends) =
//     // Closed(Amount, Squash, Timeout, Pend)
//     when stage_in is {
//       t.Closed(_amount, _non_closer_squash, timeout, closer_pends) -> {
//         trace @"End.Con.1": @"When Closed(amt, squash, timeout, pends) = stage_in"
//         trace @"End.Con.1.0": @"`timeout < lb` (respond period has passed)"
//         expect timeout < lb
//         trace @"End.Con.1.1": @"closer signed the tx"
//         expect by_closer
//         (closer_pends, [])
//       }
//       t.Elapsed(closer_pends) -> {
//         trace @"End.Con.1": @"When `stage_in` is Elapsed"
//         if by_closer {
//           trace @"End.Con.1.0: If closer signed the tx then the `tot_in == sum(closer_pends)`"
//           expect tot_in == sum_pend(closer_pends)
//           (closer_pends, [])
//         } else {
//           ([], closer_pends)
//         }
//       }
//       t.Resolved(closer_pends, non_closer_pends) -> {
//         trace @"End.Con.0": @"When `stage_in` is Resolved"
//         trace @"End.Con.0.0": @"Either party can sign the tx"
//         if by_closer {
//           (closer_pends, non_closer_pends)
//         } else {
//           (non_closer_pends, closer_pends)
//         }
//       }
//       t.Responded(_, closer_pends, non_closer_pends) -> {
//         trace @"End.Con.0": @"When `stage_in` is Responded"
//         // At this stage the closer funds are still locked in the channel possibly together with some non reduced pends.
//         // The non-closer can release the pends using `free` but is not able to really `end` the channel
//         // even if the min-ADA belongs to him.
//         trace @"End.Con.0.0": @"closer signed the tx"
//         expect by_closer
//         (closer_pends, non_closer_pends)
//       }
//       _ -> fail @"Invalid stage for the `end` step"
//     }
//   trace @"End.Con.2.0": @"All pends are reduced"
//   expect _ =
//     do_reduce_pends(received_pends, sent_pends, [], [], secrets, True, lb, ub)
//   True
// }
