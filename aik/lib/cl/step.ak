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

fn has_vk0(keys: t.Keys, signers: List<VerificationKeyHash>) -> Bool {
  let (vk0, vk1) = keys
  has_vkh0(crypto.blake2b_224(vk0), crypto.blake2b_224(vk1), signers)
}

fn has_vk1(keys: t.Keys, signers: List<VerificationKeyHash>) -> Bool {
  !has_vk0(keys, signers)
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
    expect [excl_idx, ..sql_excl_rest] =
      list.drop_while(sq_excl, fn(i) { i < chq_idx })
    expect chq_idx == excl_idx
    sql_excl_rest
  }
}

// * Verifies the cheques signatures
// * Verifies correspondence between cheques and pend
// * Returns the sum of the cheques amounts which are not locked
fn do_reduce_cheques(
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
          amt + do_reduce_cheques(
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
          trace @"ReduceCheques.Con.3": @"(Un)locked `cheque.timeout >= ub`"
          expect timeout >= ub
          trace @"ReduceCheques.Out": @"Total amount of the reduced cheques"
          amt + do_reduce_cheques(
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
          trace @"ReduceCheques.Con.3": @"(Un)locked `cheque.timeout >= ub`"
          expect timeout >= ub
          trace @"ReduceCheques.Con.4": @"If `Htlc(_, timeout, lock, amt) = chq` then `pend.pop() == (amt, timeout, lock)`"
          expect [p, ..pend_rest] = pend
          expect (amt, timeout, lock) == p
          do_reduce_cheques(
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

fn reduce_cheques(
  cid: t.ChannelId,
  other: VerificationKey,
  cheques: List<Signed<t.Cheque>>,
  sq_idx: Index,
  sq_excl: List<Index>,
  pend: t.Pend,
  ub: PosixMilliseconds,
) -> Amount {
  let prev_cheque_idx = -1
  do_reduce_cheques(
    cid,
    other,
    cheques,
    prev_cheque_idx,
    sq_idx,
    sq_excl,
    pend,
    ub,
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
  trace @"Close.In": @"Input state"
  trace @"Close.In.0": @"Keys `keys_in`"
  trace @"Close.In.1": @"`Opened(amt_non_opener_in, snapshot_in, respond_period) = stage_in`"
  trace @"Close.In.2": @"Amount `tot_in`"
  expect t.Opened(amt_non_opener_in, snapshot_in, respond_period) = stage_in

  trace @"Close.Out": @"Output state"
  trace @"Close.Out.0": @"Keys `keys_out`"
  trace @"Close.Out.1": @"`Closed(amt_out, squash_out, timeout_out, pend_out) = stage_out`"
  expect t.Closed(
    amt_closer_out,
    sq_non_closer_received_out,
    timeout_out,
    pend_out,
  ) = stage_out
  trace @"Close.Out.2": @"Amount `tot_out`"

  trace @"Close.Con": @"Constraints"
  trace @"Close.Con.0": @"If `by_opener` then `keys_in == keys_out` else keys are reversed"
  expect
    if by_opener {
      keys_out == keys_in
    } else {
      keys_out.1st == keys_in.2nd && keys_out.2nd == keys_in.1st
    }
  let closer_key = keys_out.1st
  let non_closer_key = keys_out.2nd
  expect is_vk_signer(closer_key, signers)
  let (possible_snapshot, chqs) = receipt
  let snapshot_out =
    when possible_snapshot is {
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
  let (sq_closer_received, sq_closer_sent) =
    received_and_sent(closer_key, non_closer_key, snapshot_out)
  trace @"Close.Con.3": @"ReduceCheques succeeds with `chqs_amt` for the provided cheques and the `pend_out`"
  let chqs_amt = {
    let sq_idx = sq_closer_received.2nd
    let sq_excl = sq_closer_received.3rd

    trace @"ReduceCheques.Pre": @"`prev_cheque_idx` initialized by `-1`"
    reduce_cheques(cid, non_closer_key, chqs, sq_idx, sq_excl, pend_out, ub)
  }
  trace @"Close.Con.4 : `amt_closer_out == amt_in + chqs_amt + sq_diff` where"
  expect amt_closer_out == {
      let amt_in =
        if by_opener {
          trace @"Close.Con.4.1: If the closer is also the opener then `amt_in = tot_in - amt_non_opener_in`"
          tot_in - amt_non_opener_in
        } else {
          trace @"Close.Con.4.2: Else `amt_in = amt_non_opener_in`"
          amt_non_opener_in
        }

      trace @"Close.Con.4.3: And `sq_diff = sq_received.1st - sq_sent.1st` where `sq_*` are parts of the latest snapshot"
      let sq_diff = sq_closer_received.1st - sq_closer_sent.1st
      amt_in + chqs_amt + sq_diff
    }
  trace @"Close.Con.5": @"`sq_non_closer_received_out == sq_closer_sent`"
  expect sq_non_closer_received_out == sq_closer_sent
  trace @"Close.Con.6": @"`timeout_out >= ub + respond_period`"
  expect timeout_out >= ub + respond_period
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
  trace @"Respond.In.1": @"`Closed(amt_closer_in, sq_in, timeout_in, pend_closer_in) = stage_in`"
  expect t.Closed(amt_closer_in, sq_in, _, pend_closer_in) = stage_in
  trace @"Respond.In.2": @"Amount `tot_in`"

  trace @"Respond.Out": @"Output state"
  trace @"Respond.Out.0": @"Keys `keys_out`"
  trace @"Respond.Out.1": @"`Responded(amt_closer_out, pend_closer_out, pend_non_closer_out) = stage_out`"
  expect t.Responded(amt_closer_out, pend_closer_out, pend_non_closer_out) =
    stage_out
  trace @"Respond.Out.2": @"Amount `tot_out`"

  trace @"Respond.Con": @"Constraints"
  trace @"Respond.Con.0": @"non-closer which is `keys_in.1` has singed the tx"
  let (closer, non_closer) = keys_in
  expect is_vk_signer(non_closer, signers)
  trace @"Respond.Con.1": @"`keys_in == keys_out`"
  expect keys_out == keys_in
  let (possible_snapshot, chqs) = receipt
  trace @"Respond.Con.2": @"Verify the receipt snapshot with the closer key - `keys_in.0`"
  expect
    amt_closer_out == when possible_snapshot is {
      Some((snp, snp_sig)) -> {
        expect snapshot.verify(cid, snp, closer, snp_sig)
        let (sq_received, _) = received_and_sent(non_closer, closer, snp)
        trace @"Respond.Con.3": @"ReduceCheques succeeds with `chqs_amt` for the provided cheques and the `pend_non_closer_out`"
        let chqs_amt =
          reduce_cheques(
            cid,
            closer,
            chqs,
            sq_received.2nd,
            sq_received.3rd,
            pend_non_closer_out,
            ub,
          )
        trace @"Respond.Con.4": @"If new snapshot provided then `amt_closer_out` is `amt_closer_in - sq_diff - chqs_amt`"
        let sq_diff = sq_received.1st - sq_in.1st
        amt_closer_in - sq_diff - chqs_amt
      }
      None -> {
        trace @"Respond.Con.5": @"Else `amt_closer_out == amt_closer_in`"
        amt_closer_in
      }
    }
  if drop_old {
    trace @"Respond.Con.6": @"If `drop_old` then `pend_closer_out` is `pend_closer_in` with entries in which all the `chq.timeout <= lb` have been dropped. The total reflects this"
    // We are preserving the closer - the other partner non expired cheques.
    // The submitter - non-closer has to prove that they are expired.
    // Hence the proper check to prove expiration is `timeout <= lb`.
    // Hence we are leaving all the cheques where `timeout > lb`
    expect pend_closer_out == list.filter(pend_closer_in, fn(p) { p.2nd > lb })
  } else {
    trace @"Respond.Con.7": @"Else `pend_closer_out == pend_closer_in`"
    expect pend_closer_out == pend_closer_in
  }
  trace @"Respond.Con.8": @"`tot_out` is greater or equal to `amt_closer_out + sum(pend_non_closer_out)`"
  tot_out >= amt_closer_out + sum_pend(pend_non_closer_out)
}

fn do_reduce_received_pend(
  curr_idx: Int,
  pend_in: t.Pend,
  pend_out: t.Pend,
  secrets: t.Secrets,
  ub: PosixMilliseconds,
) -> Amount {
  when (pend_in, secrets) is {
    (_, []) -> {
      expect pend_out == pend_in
      0
    }
    ([(amt, timeout, lock), ..rest_in], [(secret_idx, secret), ..rest_secrets]) ->
      if curr_idx == secret_idx {
        // We found the indexed position - verify secret
        expect lock == cheque.hash_htlc_secret(secret)
        expect timeout > ub
        // Secret matches, skip this entry in output and add amount to total
        amt + do_reduce_received_pend(
          curr_idx + 1,
          rest_in,
          pend_out,
          rest_secrets,
          ub,
        )
      } else {
        // Please note that we keep the expired cheques as these should
        // be reduced by the partner.
        // Not the indexed position - keep entry in output
        expect [(amt_out, timeout_out, lock_out), ..rest_out] = pend_out
        expect amt_out == amt && timeout_out == timeout && lock_out == lock
        do_reduce_received_pend(curr_idx + 1, rest_in, rest_out, secrets, ub)
      }
    ([], _) -> fail @"Pend/Secrets mismatch"
  }
}

// The below two reduction function have subtle but important difference in how they handle timeouts:
// * When the user reduces received cheques he should prove that they are still valid so their timeout should be in the future. He should provide a `ub` which is smaller than the cheque timeout in such a case.
// * When the user frees sent cheques he should prove that a given cheque which he signed has expired. He should provide an `lb` which is larger than the cheque timeout in this case.
fn reduce_received_pend(
  pend_in: t.Pend,
  pend_out: t.Pend,
  secrets: t.Secrets,
  ub: PosixMilliseconds,
) -> Amount {
  do_reduce_received_pend(0, pend_in, pend_out, secrets, ub)
}

fn reduce_sent_pend(
  pend_in: t.Pend,
  pend_out: t.Pend,
  lb: PosixMilliseconds,
) -> Amount {
  when pend_in is {
    [] -> {
      expect pend_out == []
      0
    }
    [(amt_in, timeout_in, lock_in), ..rest_in] ->
      if timeout_in < lb {
        // Timeout has passed - skip this entry in the output.
        // Add its amount to the released amount.
        amt_in + reduce_sent_pend(rest_in, pend_out, lb)
      } else {
        expect [(amt_out, timeout_out, lock_out), ..rest_out] = pend_out
        // Timeout has not passed - keep entry in the output
        // checking if it is honestly preserved
        expect
          amt_in == amt_out && timeout_in == timeout_out && lock_in == lock_out
        reduce_sent_pend(rest_in, rest_out, lb)
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
  trace @"Elapse.In": @"Input state"
  trace @"Elapse.In.0": @"Keys `keys_in`"
  trace @"Elapse.In.1": @"`Closed(amt_in, squash_in, timeout_in, pend_in) = stage_in`"
  expect t.Closed(closer_amt_in, _, timeout_in, pend_in) = stage_in
  trace @"Elapse.In.2": @"Amount `tot_in`"

  trace @"Elapse.Out": @"Output state"
  trace @"Elapse.Out.0": @"Keys `keys_out`"
  expect keys_out == keys_in
  trace @"Elapse.Out.1": @"`Resolved(pend) = stage_out`"
  // There is no checking of the other partner's pend here - `pend1`.
  // That decision is in the hands of the closer if they
  // want to drop partner's cheques if any.
  expect t.Elapsed(pend_out) = stage_out
  // Provided by the caller
  trace @"Elapse.Out.2": @"Amount `tot_out`"

  trace @"Elapse.Con": @"Constraints"
  trace @"Elapse.Con.0": @"`keys_in.0` (closer) has signed the tx"
  let (closer, _) = keys_in
  expect is_vk_signer(closer, signers)

  trace @"Elapse.Con.1": @"`timeout_in < lb` (respond period has passed)"
  expect timeout_in < lb

  trace @"Elapse.Con.2": @"`pend_out` is reduced from `pend_in` using provided secrets and results in `amt_freed`"
  let amt_freed = reduce_received_pend(pend_in, pend_out, secrets, ub)

  trace @"Elapse.Con.3": @"`tot_out == tot_in - closer_amt_in - amt_freed`"
  trace @"Elapse.Con.3.tot_in = ": tot_in
  trace @"Elapse.Con.3.closer_amt_in = ": closer_amt_in
  trace @"Elapse.Con.3.amt_freed = ": amt_freed
  trace @"Elapse.Con.3.tot_out = ": tot_out

  tot_out == tot_in - closer_amt_in - amt_freed
}

pub fn do_resolve(
  signers: List<VerificationKeyHash>,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  secrets: t.Secrets,
  drop_old: Bool,
  keys_in: t.Keys,
  stage_in: t.Stage,
  tot_out: Amount,
  keys_out: t.Keys,
  stage_out: t.Stage,
) -> Bool {
  trace @"Resolve.In": @"Input state"
  trace @"Resolve.In.0": @"Keys `keys_in`"
  trace @"Resolve.In.1": @"Stage `stage_in`"
  trace @"Resolve.In.2": @"Amount `tot_in`"

  trace @"Resolve.Out": @"Output state"
  trace @"Resolve.Out.0": @"Keys `keys_out`"

  trace @"Resolve.Out.1": @"`Resolved(pend0_out, pend1_out) = stage_out`"
  expect t.Resolved(pend0_out, pend1_out) = stage_out

  trace @"Resolve.Out.2": @"Amount `tot_out`"

  trace @"Resolve.Con": @"Constraints"

  trace @"Resolve.Con.0": @"`keys_in == keys_out`"
  expect keys_in == keys_out

  when stage_in is {
    t.Elapsed(pend_in) -> {
      trace @"Resolve.Con.1": @"When `stage_in` is Elapsed(pend_in)"
      trace @"Resolve.Con.1.0": @"`keys_in.1` has signed the tx"
      expect has_vk1(keys_in, signers)

      if drop_old {
        trace @"Resolve.Con.1.1": @"If `drop_old` then `pend0_out` is `pend_in` with entries in which the `timeout < lb` have been dropped"
        expect pend0_out == list.filter(pend_in, fn(p) { p.2nd >= lb })
      } else {
        trace @"Resolve.Con.1.2": @"Else `pend0_out == pend_in`"
        expect pend0_out == pend_in
      }
      trace @"Resolve.Con.1.3": @"`pend1_out == []`"
      expect pend1_out == []
    }
    t.Responded(_, pend0_in, pend1_in) -> {
      trace @"Resolve.Con.2": @"When `stage_in` is Responded(amt_in, pend0_in, pend1_in)"
      trace @"Resolve.Con.2.0": @"`keys_in.0` has signed the tx"
      expect has_vk0(keys_in, signers)

      trace @"Resolve.Con.2.1": @"`pend0_out` is `pend0_in` reduced by secrets"
      let received_freed =
        reduce_received_pend(pend0_in, pend0_out, secrets, ub)

      let sent_freed =
        if drop_old {
          trace @"Resolve.Con.2.2": @"If `drop_old` then `pend1_out` is reduced by timeout from `pend1_in` by `timeout < lb` resulting in `sent_freed`"
          reduce_sent_pend(pend1_in, pend1_out, lb)
        } else {
          trace @"Resolve.Con.2.3": @"Else `pend1_out == pend1_in`"
          expect pend1_out == pend1_in
          0
        }
      // TODO: Tautology to preserve the above side effecting evaluations - is this necessary?
      let amt_freed = received_freed + sent_freed
      expect amt_freed != 0 || amt_freed == 0
    }
    _ -> fail @"Invalid stage for the `resolve` step"
  }
  trace @"Resolve.Con.2.4": @"`tot_out == sum(pend0_out) + sum(pend1_out)`"
  tot_out == sum_pend(pend0_out) + sum_pend(pend1_out)
}

pub fn do_free(
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
      let amt_freed = reduce_received_pend(pend_in, pend_out, secrets, ub)

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
        reduce_received_pend(pend1_in, pend1_out, secrets, ub)

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

      trace @"Free.Con.3.1": @"`Elapsed(pend_out) = stage_out`"
      expect t.Elapsed(pend_out) = stage_out

      trace @"Free.Con.3.2": @"`pend_out` is reduced from `pend` using provided secrets and results in `amt_freed`"
      let amt_freed = reduce_received_pend(pend, pend_out, secrets, ub)

      trace @"Free.Con.3.3": @"`amt_freed != 0` to prevent noop looping"
      expect amt_freed != 0

      trace @"Free.Con.3.4": @"`tot_out == tot_in - amt_freed`"
      tot_out == tot_in - amt_freed
    }
    _ -> fail @"Invalid stage for the `free` step"
  }
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
    reduce_received_pend(received_pends_in, received_pends_out, secrets, ub)
  let sent_freed =
    if drop_old {
      trace @"ReduceCheques.Con.2": @"If `drop_old` then `sent_pends_out` is `sent_pends_in` reduced by `timeout < lb` resulting in `sent_freed`"
      reduce_sent_pend(sent_pends_in, sent_pends_out, lb)
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
  trace @"Free.In": @"Input state"
  trace @"Free.In.0": @"`Resolved(closer_pends_in, non_closer_pends_in) = stage_in`"
  expect t.Resolved(closer_pends_in, non_closer_pends_in) = stage_in

  trace @"Free.Out": @"Output state"
  trace @"Free.Out.0": @"`Resolved(closer_pends_out, non_closer_pends_out) = stage_out`"
  expect t.Resolved(closer_pends_out, non_closer_pends_out) = stage_out

  trace @"Free.Con": @"Constraints"
  trace @"Free.Con.0": @"`keys_in == keys_out`"
  expect keys_in == keys_out

  let amt_freed =
    if by_closer {
      trace @"Free.Con.1": @"If `by_closer` then `keys_in.0` has signed the tx"
      expect is_vk_signer(keys_in.1st, signers)
      trace @"Free.Con.1.1": @"Pends are reduced where closer is the receiver"
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
      trace @"Free.Con.2": @"Else `keys_in.1` has signed the tx"
      expect is_vk_signer(keys_in.2nd, signers)
      trace @"Free Con.2.1": @"Pends are reduced where non-closer is the receiver"
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
    }
  trace @"Free.Con.3": @"`amt_freed != 0` to prevent noop looping"
  expect amt_freed != 0

  trace @"Free.Con.4": @"`tot_out == tot_in - amt_freed`"
  tot_out == tot_in - amt_freed
}

pub fn do_end(
  by_closer: Bool,
  secrets: t.Secrets,
  lb: PosixMilliseconds,
  ub: PosixMilliseconds,
  tot_in: Amount,
  stage_in: t.Stage,
) -> Bool {
  trace @"End.In": @"Input state"
  trace @"End.In.0: `stage_in =`": stage_in
  trace @"End.In.1: `tot_in = `": tot_in

  trace @"End.Out": @"Output state"
  trace @"End.Out.0": @"No continuing output (channel is ended)"

  trace @"End.Con": @"Constraints by stage"
  let (received_pends, sent_pends) =
    when stage_in is {
      t.Elapsed(closer_pends) -> {
        trace @"End.Con.1": @"When `stage_in` is Elapsed"
        trace @"End.Con.1.0": @"non-closer signed the tx"
        expect !by_closer
        ([], closer_pends)
      }
      t.Resolved(closer_pends, non_closer_pends) ->
        if by_closer {
          (closer_pends, non_closer_pends)
        } else {
          (non_closer_pends, closer_pends)
        }
      t.Responded(_, closer_pends, non_closer_pends) -> {
        trace @"End.Con.0": @"When `stage_in` is Responded"
        // At this stage the closer funds are still locked in the channel possibly together with some non reduced pends.
        // The non-closer can release the pends using `free` but is not able to really `end` the channel
        // even if the min-ADA belongs to him.
        trace @"End.Con.0.0": @"closer signed the tx"
        expect by_closer
        (closer_pends, non_closer_pends)
      }
      _ -> fail @"Invalid stage for the `end` step"
    }
  trace @"End.Con.2.0": @"All pends are reduced"
  expect _ =
    do_reduce_pends(received_pends, sent_pends, [], [], secrets, True, lb, ub)
  True
}
