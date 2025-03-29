use aiken/builtin as builtin
use aiken/collection.{Index}
use aiken/collection/list as list
use aiken/crypto.{VerificationKey, VerificationKeyHash}
use cl/cheque
use cl/prelude.{Amount, PosixMilliseconds, Signed}
use cl/snapshot
use cl/types as t

/// True if signed by `vkh0`, false if signed by `vkh1`, and fails if neither. 
/// Recall that signed by both keys is illegal and is undefined behaviour. 
fn has_vkh0(
  vkh0: VerificationKeyHash,
  vkh1: VerificationKeyHash,
  signers: List<VerificationKeyHash>,
) -> Bool {
  when signers is {
    [vkh, ..rest] ->
      if vkh == vkh0 {
        True
      } else if vkh == vkh1 {
        False
      } else {
        has_vkh0(vkh0, vkh1, rest)
      }
    [] -> fail @"No vkh match"
  }
}

fn has_vk0(keys: t.Keys, signers: List<VerificationKeyHash>) -> Bool {
  let (vk0, vk1) = keys
  has_vkh0(crypto.blake2b_224(vk0), crypto.blake2b_224(vk1), signers)
}

fn has_vk1(keys: t.Keys, signers: List<VerificationKeyHash>) -> Bool {
  !has_vk0(keys, signers)
}

fn self_and_other_keys(
  keys: t.Keys,
  signers: List<VerificationKeyHash>,
) -> (VerificationKey, VerificationKey) {
  let (vk0, vk1) = keys
  if has_vkh0(crypto.blake2b_224(vk0), crypto.blake2b_224(vk1), signers) {
    (vk0, vk1)
  } else {
    (vk1, vk0)
  }
}

fn other_key(keys: t.Keys, is_vk0: Bool) {
  if is_vk0 {
    keys.2nd
  } else {
    keys.1st
  }
}

pub fn do_add(
  cid: t.ChannelId,
  signers: List<VerificationKeyHash>,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  possible_snapshot: Option<Signed<t.Snapshot>>,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  let is_vk0 = has_vk0(keys_in, signers)
  trace @"Add.In": @"Input state"
  trace @"Add.In.0": @"Keys `keys_in`"
  trace @"Add.In.1": @"`Opened(amt1_in, snapshot_in, period_in) = stage_in`"
  expect t.Opened(amt1_in, snapshot_in, period_in) = stage_in
  trace @"Add.In.2": @"Amount `tot_in`"

  trace @"Add.Out": @"Output state"
  trace @"Add.Out.0": @"Keys `keys_in`"
  expect keys_out == keys_in
  trace @"Add.Out.1": @"`Opened(amt1_out, snapshot_out, period_out) = stage_out`"
  expect t.Opened(amt1_out, snapshot_out, period_out) = stage_out
  trace @"Add.Out.2": @"Amount `tot_out`"

  trace @"Add.Con": @"Constraints"
  trace @"Add.Con.0": @"Total amount has increased by `x = tot_out - tot_in`, `x > 0`"
  let x = tot_out - tot_in
  expect x > 0
  trace @"Add.Con.1": @"If tx signed by `vk0` then `amt1_in == amt1_out` else `amt1_in + x == amt1_out`"
  expect
    if is_vk0 {
      amt1_out == amt1_in
    } else {
      amt1_out == amt1_in + x
    }
  when possible_snapshot is {
    None -> {
      trace @"Add.Con.2": @"If no snapshot provided then `snapshot_out` equals `snapshot_in`"
      expect snapshot_out == snapshot_in
    }
    Some((snapshot, sig)) -> {
      trace @"Add.Con.3": @"Else "
      trace @"Add.Con.3.0": @"Snapshot signed by other key"
      expect snapshot.verify(cid, snapshot, other_key(keys_in, is_vk0), sig)
      trace @"Add.Con.3.1": @"`snapshot_out` equals provided union `snapshot_in`"
      expect snapshot_out == snapshot.union(snapshot_in, snapshot)
    }
  }
  trace @"Add.Con.4": @"`period_out == period_in`"
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
  trace @"ReduceCheques.Con.2": @"Cheques index is valid"
  trace @"ReduceCheques.Con.2.1": @"Either `ch_idx > sq_idx`"
  if chq_idx > sq_idx {
    []
  } else {
    trace @"ReduceCheques.Con.2.2": @"Or `chq_idx elem sq_excl` && all `idx < chq_idx` from sq_excl are discarded"
    expect [excl_idx, ..sql_excl_rest] =
      list.drop_while(sq_excl, fn(i) { i < chq_idx })
    expect chq_idx == excl_idx
    sql_excl_rest
  }
}

// * Verifies the cheques signatures
// * Verifies correspondence between cheques and pend
// * Returns the sum of the cheques amounts which are not locked
fn reduce_cheques(
  cid: t.ChannelId,
  other: VerificationKey,
  cheques: List<Signed<t.Cheque>>,
  prev_cheque_idx: Index,
  sq_idx: Index,
  sq_excl: List<Index>,
  pend: t.Pend,
  ub: PosixMilliseconds,
) -> Amount {
  trace @"ReduceCheques.In": @"Input parameters"
  trace @"ReduceCheques.In.0": @"The other party verification key `other`"
  trace @"ReduceCheques.In.1": @"List of signed cheques `cheques`"
  trace @"ReduceCheques.In.2": @"Previous cheque index `prev_cheque_idx`"
  trace @"ReduceCheques.In.3": @"Max cheque index included in the squash `sq_idx`"
  trace @"ReduceCheques.In.4": @"List of excluded indices from the squash `sq_excl`"
  trace @"ReduceCheques.In.5": @"Expected pending cheque list after the reduction `pend`"
  trace @"ReduceCheques.In.6": @"A point in time 'in the future' (transaction upper bound) `ub`"
  when cheques is {
    [signed_cheque, ..rest] -> {
      let (cheque, sig) = signed_cheque
      trace @"ReduceCheques.Con.0": @"`chq` is signed by the `other`"
      expect cheque.verify(cid, cheque, other, sig)
      when cheque is {
        t.Normal(idx, amt) -> {
          expect idx > prev_cheque_idx
          let sq_excl_rest =
            verify_cheque_idx(prev_cheque_idx, idx, sq_idx, sq_excl)
          trace @"ReduceCheques.Out": @"Total amount of the reduced cheques"
          amt + reduce_cheques(
            cid,
            other,
            rest,
            idx,
            sq_idx,
            sq_excl_rest,
            pend,
            ub,
          )
        }
        t.HtlcUnlocked(idx, timeout, _secret, amt) -> {
          let sq_excl_rest =
            verify_cheque_idx(prev_cheque_idx, idx, sq_idx, sq_excl)
          trace @"ReduceCheques.Con.3": @"(Un)locked `cheque.timeout < ub`"
          expect timeout < ub
          trace @"ReduceCheques.Out": @"Total amount of the reduced cheques"
          amt + reduce_cheques(
            cid,
            other,
            rest,
            idx,
            sq_idx,
            sq_excl_rest,
            pend,
            ub,
          )
        }
        t.Htlc(idx, timeout, lock, amt) -> {
          let sq_excl_rest =
            verify_cheque_idx(prev_cheque_idx, idx, sq_idx, sq_excl)
          trace @"ReduceCheques.Con.3": @"(Un)locked `cheque.timeout < ub`"
          expect timeout < ub
          trace @"ReduceCheques.Con.4": @"If `Htlc(_, timeout, lock, amt) = chq` then `pend.pop() == (amt, timeout, lock)`"
          expect [p, ..pend_rest] = pend
          expect (amt, timeout, lock) == p
          reduce_cheques(
            cid,
            other,
            rest,
            idx,
            sq_idx,
            sq_excl_rest,
            pend_rest,
            ub,
          )
        }
      }
    }
    [] -> {
      trace @"ReduceCheques.Con.5": @"At the end of reduction `pend == []`"
      expect pend == []
      trace @"ReduceCheques.Out": @"Total amount of the reduced cheques"
      0
    }
  }
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
  trace @"Close.In": @"Input state"
  trace @"Close.In.0": @"Keys `keys_in`"
  trace @"Close.In.1": @"`Opened(amt_in, snapshot_in, respond_period) = stage_in`"
  trace @"Close.In.2": @"Amount `tot_in`"
  expect t.Opened(amt_in, snapshot_in, respond_period) = stage_in

  trace @"Close.Out": @"Output state"
  trace @"Close.Out.0": @"Keys `keys_out`"
  trace @"Close.Out.1": @"`Closed(amt_out, squash_out, timeout_out, pend_out) = stage_out`"
  expect t.Closed(amt_out, squash_out, timeout_out, pend_out) = stage_out
  trace @"Close.Out.2": @"Amount `tot_out`"
  let (self, other) = self_and_other_keys(keys_in, signers)
  let is_vk0 = self == keys_in.1st

  trace @"Close.Con": @"Constraints"
  trace @"Close.Con.0": @"If tx signed by `vk0` then `keys_in == keys_out` else keys are reversed"
  expect
    if is_vk0 {
      keys_out == keys_in
    } else {
      keys_out.1st == keys_in.2nd && keys_out.2nd == keys_in.1st
    }
  let (possible_snapshot, chqs) = receipt
  let snapshot_out =
    when possible_snapshot is {
      None -> {
        trace @"Close.Con.1": @"If no snapshot provided then `snapshot_out` equals `snapshot_in`"
        snapshot_in
      }
      Some((snp, snp_sig)) -> {
        trace @"Close.Con.2": @"Else "
        trace @"Close.Con.2.0": @"Snapshot signed by other key"
        expect snapshot.verify(cid, snp, other, snp_sig)
        trace @"Close.Con.2.1": @"`snapshot_out` equals provided union `snapshot_in`"
        snapshot.union(snapshot_in, snp)
      }
    }
  let (sq_received, sq_sent) = received_and_sent(self, other, snapshot_out)
  trace @"Close.Con.3": @"ReduceCheques succeeds with `chqs_amt` for the provided cheques and the `pend_out`"
  let chqs_amt = {
    let sq_idx = sq_received.2nd
    let sq_excl = sq_received.3rd

    trace @"ReduceCheques.Pre": @"`prev_cheque_idx` initialized by `-1`"
    let prev_cheque_idx = -1
    reduce_cheques(
      cid,
      other,
      chqs,
      prev_cheque_idx,
      sq_idx,
      sq_excl,
      pend_out,
      ub,
    )
  }
  let sq_diff = sq_received.1st - sq_sent.1st
  trace @"Close.Con.4": @"`amt_rec + chqs_amt + sq_diff == amt_out`"
  let amt_rec =
    if is_vk0 {
      amt_in
    } else {
      tot_in - amt_in
    }
  expect amt_rec + chqs_amt + sq_diff == amt_out
  trace @"Close.Con.5": @"`sq_out == sq_sent`"
  expect sq_sent == squash_out
  trace @"Close.Con.6": @"`timeout_out > ub + respond_period`"
  expect timeout_out > ub + respond_period
  trace @"Close.Con.7": @"tot_out >= tot_in"
  tot_out >= tot_in
}

fn sum_pend(pend: t.Pend) -> Amount {
  when pend is {
    [p, ..rest] -> {
      let (amt, _timeout, _lock) = p
      amt + sum_pend(rest)
    }
    [] -> 0
  }
}

pub fn do_respond(
  cid: t.ChannelId,
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  receipt: t.Receipt,
  drop_old: Bool,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"Respond.In": @"Input state"
  trace @"Respond.In.0": @"Keys `keys_in`"
  trace @"Respond.In.1": @"`Closed(amt_in, sq_in, timeout_in, pend_in) = stage_in`"
  expect t.Closed(amt_in, sq_in, _, pend_in) = stage_in
  trace @"Respond.In.2": @"Amount `tot_in`"

  trace @"Respond.Out": @"Output state"
  trace @"Respond.Out.0": @"Keys `keys_out`"
  trace @"Respond.Out.1": @"`Responded(amt_out, pend0, pend1) = stage_out`"
  expect t.Responded(amt_out, pend0, pend1) = stage_out
  trace @"Respond.Out.2": @"Amount `tot_out`"

  trace @"Respond.Con": @"Constraints"
  trace @"Respond.Con.0": @"`keys_in.1` has singed the tx - the step is executed by the non-closer"
  expect has_vk1(keys_in, signers)
  let self = keys_in.2nd
  let other = keys_in.1st
  trace @"Respond.Con.1": @"`keys_in == keys_out`"
  expect keys_out == keys_in
  let (possible_snapshot, chqs) = receipt
  trace @"Respond.Con.2": @"Verify the receipt snapshot with `keys_in.0`"
  expect
    amt_out == when possible_snapshot is {
      Some((snp, snp_sig)) -> {
        expect snapshot.verify(cid, snp, other, snp_sig)
        let (sq_received, _) = received_and_sent(self, other, snp)
        trace @"Respond.Con.3": @"ReduceCheques succeeds with `chqs_amt` for the provided cheques and the `pend1`"
        trace @"ReduceCheques.Pre": @"`prev_cheque_idx` initialized by `-1`"
        let prev_cheque_idx = -1
        let chqs_amt =
          reduce_cheques(
            cid,
            other,
            chqs,
            prev_cheque_idx,
            sq_received.2nd,
            sq_received.3rd,
            pend1,
            ub,
          )
        trace @"Respond.Con.5": @"If new snapshot provided then `amt_out` is `amt_in - sq_diff - chqs_amt`"
        let sq_diff = sq_received.1st - sq_in.1st
        amt_in - sq_diff - chqs_amt
      }
      None -> {
        trace @"Respond.Con.6": @"Else `amt_out == amt_in`"
        amt_in
      }
    }
  if drop_old {
    trace @"Respond.Con.7": @"If `drop_old` then `pend0` is `pend` with entries in which the `timeout < lb` have been dropped. The total reflects this"
    expect pend0 == list.filter(pend_in, fn(p) { p.2nd < lb })
  } else {
    trace @"Respond.Con.8": @"Else `pend0 == pend`"
    expect pend0 == pend_in
  }
  trace @"Respond.Con.9": @"`tot_out` is equal to `amt_out + sum(pend0) + sum(pend1)`"
  tot_out == amt_out + sum_pend(pend0) + sum_pend(pend1)
}

fn do_reduce_pend(
  curr_idx: Int,
  pend_in: t.Pend,
  pend_out: t.Pend,
  secrets: t.Secrets,
  lb: PosixMilliseconds,
) -> Amount {
  when (pend_in, secrets) is {
    ([], _) -> {
      expect pend_out == []
      0
    }
    ([(amt, timeout, lock), ..rest_in], [(secret_idx, secret), ..rest_secrets]) ->
      if curr_idx == secret_idx {
        // We found the indexed position - verify secret
        if lock == cheque.hash_htlc_secret(secret) {
          // Secret matches, skip this entry in output and add amount to total
          amt + do_reduce_pend(
            curr_idx + 1,
            rest_in,
            pend_out,
            rest_secrets,
            lb,
          )
        } else {
          fail @"Secret hash mismatch"
        }
      } else {
        if timeout < lb {
          // Timeout has passed - skip this entry in output and add amount to total
          do_reduce_pend(curr_idx + 1, rest_in, pend_out, secrets, lb)
        } else {
          // Not the indexed position - keep entry in output
          expect [(amt_out, timeout_out, lock_out), ..rest_out] = pend_out
          expect amt_out == amt && timeout_out == timeout && lock_out == lock
          do_reduce_pend(curr_idx + 1, rest_in, rest_out, secrets, lb)
        }
      }
    (rest_in, []) -> {
      // No more secrets - verify remaining output matches input
      expect rest_in == pend_out
      0
    }
  }
}

fn reduce_pend(
  pend_in: t.Pend,
  pend_out: t.Pend,
  secrets: t.Secrets,
  lb: PosixMilliseconds,
) -> Amount {
  do_reduce_pend(0, pend_in, pend_out, secrets, lb)
}

fn reduce_pend_by_timeout(
  pend_in: t.Pend,
  pend_out: t.Pend,
  lb: PosixMilliseconds,
) -> Amount {
  when (pend_in, pend_out) is {
    ([], []) -> 0
    (
      [(amt_in, timeout_in, lock_in), ..rest_in],
      [(amt_out, timeout_out, lock_out), ..rest_out],
    ) ->
      if timeout_in < lb {
        // Timeout has passed - skip this entry in output and add amount to total
        amt_in + reduce_pend_by_timeout(rest_in, rest_out, lb)
      } else {
        // Timeout has not passed - keep entry in output
        expect
          amt_in == amt_out && timeout_in == timeout_out && lock_in == lock_out
        reduce_pend_by_timeout(rest_in, rest_out, lb)
      }
    _ -> fail @"Pend mismatch"
  }
}

pub fn do_elapse(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  secrets: t.Secrets,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"Elapse.In": @"Input state"
  trace @"Elapse.In.0": @"Keys `keys_in`"
  trace @"Elapse.In.1": @"`Closed(amt_in, squash_in, timeout_in, pend_in) = stage_in`"
  expect t.Closed(amt_in, _, timeout_in, pend_in) = stage_in
  trace @"Elapse.In.2": @"Amount `tot_in`"

  trace @"Elapse.Out": @"Output state"
  trace @"Elapse.Out.0": @"Keys `keys_out`"
  expect keys_out == keys_in
  trace @"Elapse.Out.1": @"`Resolved(pend0_out, _) = stage_out`"
  // There is no checking of the other partner's pend here - `pend1`.
  // That decision is in the hands of the closer if they
  // want to drop partner's cheques if any.
  expect t.Resolved(pend0_out, _) = stage_out
  // Provided by the caller
  trace @"Elapse.Out.2": @"Amount `tot_out`"

  trace @"Elapse.Con": @"Constraints"
  trace @"Elapse.Con.0": @"`keys_in.0` has signed the tx"
  expect has_vk0(keys_in, signers)

  trace @"Elapse.Con.1": @"`timeout_in < lb` (respond period has passed)"
  expect timeout_in < lb

  trace @"Elapse.Con.2": @"`pend0_out` is reduced from `pend_in` using provided secrets"
  let amt_freed = reduce_pend(pend_in, pend0_out, secrets, lb)
  trace @"Elapse.Con.3": @"`tot_out == tot_in - amt_in - amt_freed`"
  tot_out == tot_in - amt_in - amt_freed
}

pub fn do_free(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  secrets: t.Secrets,
  drop_old: Bool,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"Free.In": @"Input state"
  trace @"Free.In.0": @"Keys `keys_in`"
  trace @"Free.In.1": @"Stage `stage_in`"
  trace @"Free.In.2": @"Amount `tot_in`"

  trace @"Free.Out": @"Output state"
  trace @"Free.Out.0": @"Keys `keys_out`"
  trace @"Free.Out.1": @"Stage `stage_out`"
  trace @"Free.Out.2": @"Amount `tot_out`"

  trace @"Free.Con": @"Constraints"
  trace @"Free.Con.0": @"`keys_in == keys_out`"
  expect keys_in == keys_out

  when stage_in is {
    t.Closed(amt_in, squash_in, timeout_in, pend_in) -> {
      trace @"Free.Con.1": @"When `stage_in` is Closed(amt_in, squash_in, timeout_in, pend_in)"
      trace @"Free.Con.1.0": @"`keys_in.0` has signed the tx"
      expect has_vk0(keys_in, signers)

      trace @"Free.Con.1.1": @"`Close(amt_out, squash_out, timeout_out, pend_out) = stage_out`"
      expect t.Closed(amt_out, squash_out, timeout_out, pend_out) = stage_out

      trace @"Free.Con.1.2": @"`pend_out` is reduced from `pend` using provided secrets and results in `amt_freed`"
      let amt_freed = reduce_pend(pend_in, pend_out, secrets, lb)

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
      let received_freed = reduce_pend(pend1_in, pend1_out, secrets, lb)

      let sent_freed =
        if drop_old {
          trace @"Free.Con.2.4": @"If `drop_old` then `pend0_out` is reduced by timeout from `pend0_in` by `timeout < lb` resulting in `sent_freed`"
          reduce_pend_by_timeout(pend0_in, pend0_out, lb)
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
    t.Resolved(pend0_in, pend1_in) -> {
      trace @"Free.Con.3": @"When `stage_in` is Resolved(pend0_in, pend1_in)"
      trace @"Free.Con.3.0": @"`Resolved(pend0_out, pend1_out) = stage_out`"
      expect t.Resolved(pend0_out, pend1_out) = stage_out
      let is_vk0 = has_vk0(keys_in, signers)
      if is_vk0 {
        trace @"Free.Con.3.1": @"If signed by `keys_in.0`"
        trace @"Free.Con.3.1.0": @"`pend0_out` is `pend0` reduced with secrets and results in `received_freed`"
        let received_freed = reduce_pend(pend0_in, pend0_out, secrets, lb)

        let sent_freed =
          if drop_old {
            trace @"Free.Con.3.1.1": @"If `drop_old` then `pend1_out` is `pend1_in reduced by `timeout < lb` resulting in `sent_freed`"
            reduce_pend_by_timeout(pend1_in, pend1_out, lb)
          } else {
            trace @"Free.Con.3.1.2": @"Else `pend1_out == pend1_in`"
            expect pend1_out == pend1_in
            0
          }

        trace @"Free.Con.3.1.3": @"`amt_freed == received_freed + sent_freed` to prevent noop looping"
        let amt_freed = received_freed + sent_freed
        expect amt_freed != 0

        trace @"Free.Con.3.1.4": @"`tot_out == tot_in - amt_freed"
        tot_out == tot_in - amt_freed
      } else {
        trace @"Free.Con.3.2": @"If signed by `keys_in.1`"

        trace @"Free.Con.3.2.0": @"`pend1_out` is `pend1_in` reduced with secrets and results in `received_freed`"
        let received_freed = reduce_pend(pend1_in, pend1_out, secrets, lb)

        let sent_freed =
          if drop_old {
            trace @"Free.Con.3.2.1": @"If `drop_old` then `pend0_out` is `pend0_in reduced by `timeout < lb` resulting in `sent_freed`"
            reduce_pend_by_timeout(pend0_in, pend0_out, lb)
          } else {
            trace @"Free.Con.3.2.2": @"Else `pend0_out == pend0_in`"
            expect pend0_out == pend0_in
            0
          }

        // TODO: Tautology to preserve the above side effecting evaluations - is this necessary?
        let amt_freed = sent_freed + received_freed
        expect amt_freed != 0 || amt_freed == 0

        trace @"Free.Con.3.2.3": @"`tot_out == sum(pend0_out) + sum(pend1_out)` so locked assets are possibly released"
        expect tot_out == sum_pend(pend0_out) + sum_pend(pend1_out)

        trace @"Free.Con.3.2.4": @"`tot_out != tot_in` to prevent noop looping"
        tot_out != tot_in
      }
    }
    _ -> fail @"Invalid stage for the `free` step"
  }
}

pub fn do_end(
  signers: List<VerificationKeyHash>,
  secrets: t.Secrets,
  lb: PosixMilliseconds,
  tot_in: Amount,
  keys_in: t.Keys,
  stage_in: t.Stage,
) -> Bool {
  trace @"End.In": @"Input state"
  trace @"End.In.0": @"Keys `keys_in`"
  trace @"End.In.1": @"Stage `stage_in`"
  trace @"End.In.2": @"Amount `tot_in`"

  trace @"End.Out": @"Output state"
  trace @"End.Out.0": @"No continuing output (channel is ended)"

  trace @"End.Con": @"Constraints by stage"
  when stage_in is {
    t.Responded(_, pend0, pend1) -> {
      trace @"End.Con.0": @"When `stage_in` is Responded"
      trace @"End.Con.0.0": @"`keys_in.0` has signed the tx"
      expect has_vk0(keys_in, signers)

      trace @"End.Con.0.1": @"pend1 reduced by `timeout < lb` is empty"
      let sent_freed = reduce_pend_by_timeout(pend1, [], lb)

      trace @"End.Con.0.2": @"All pending cheques in `pend0` are unlocked with provided secrets and the total amount is positive"
      let received_freed = reduce_pend(pend0, [], secrets, lb)

      // TODO: Tautology to preserve the above side effecting evaluations - is this necessary?
      let amt_freed = sent_freed + received_freed
      amt_freed != 0 || amt_freed == 0
    }

    t.Resolved(pend0, pend1) -> {
      let is_vk0 = has_vk0(keys_in, signers)
      if is_vk0 {
        trace @"End.Con.1.0": @"If signed by `keys_in.0`"

        trace @"End.Con.1.0.0": @"`pend1 reduced by timeout < lb is empty`"
        let sent_freed = reduce_pend_by_timeout(pend1, [], lb)

        trace @"End.Con.1.0.1": @"All pending cheques in `pend0` are unlocked with provided secrets"
        let received_freed = reduce_pend(pend0, [], secrets, lb)

        trace @"End.Con.1.0.2": @"`tot_in == received_freed + sent_freed` so non-closer locked assets are protected"
        tot_in == received_freed + sent_freed
      } else {
        trace @"End.Con.1.1": @"If signed by `keys_in.1`:"
        trace @"End.Con.1.1.0": @"`pend0 reduced by timeout < lb is empty`"
        let sent_freed = reduce_pend_by_timeout(pend0, [], lb)

        trace @"End.Con.1.1.1": @"All pending cheques in `pend1` are unlocked with provided secrets"
        let received_freed = reduce_pend(pend1, [], secrets, lb)

        // TODO: Tautology to preserve the above side effecting evaluations - is this necessary?
        let amt_freed = sent_freed + received_freed
        amt_freed != 0 || amt_freed == 0
      }
    }
    _ -> fail @"Invalid stage for the `end` step"
  }
}
