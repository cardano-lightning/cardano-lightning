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

// fn signer_other(keys: t.Keys, is_vk0: Bool) {
//   if is_vk0 {
//     keys
//   } else {
//     let (vk0, vk1) = keys
//     (vk1, vk0)
//   }
// }

/// Utitlity to order the keys
/// Utitlity to pick the key used to sign payloads (cheques, snapshots, _etc_) 
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
  maybe_snapshot: Option<Signed<t.Snapshot>>,
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
  trace @"Add.Out.1": @"`Opened(amt1_out, snapshot_out, period_in) = stage_out`"
  expect t.Opened(amt1_out, snapshot_out, period_out) = stage_out
  expect period_out == period_in
  trace @"Add.Out.2": @"Amount `tot_out`"
  trace @"Add.Con": @"Constraints"
  trace @"Add.Con.0": @"Total amount has increased by `x = tot_out tot_in`, `x > 0`"
  let x = tot_out - tot_in
  expect x > 0
  trace @"Add.Con.1": @"If tx signed by `vk0` then `amt1_in == amt1_out` else `amt1_in + x == amt1_out`"
  expect
    if is_vk0 {
      amt1_out == amt1_in
    } else {
      amt1_out == amt1_in + x
    }
  when maybe_snapshot is {
    None -> {
      trace @"Add.Con.2": @"If no snapshot provided then `snapshot_out` equals `snapshot_in`"
      snapshot_out == snapshot_in
    }
    Some((snp, sig)) -> {
      trace @"Add.Con.3": @"Else "
      trace @"Add.Con.3.0": @"Snapshot signed by other key"
      expect snapshot.verify(cid, snp, other_key(keys_in, is_vk0), sig)
      trace @"Add.Con.3.1": @"`snapshot_out` equals provided union `snapshot_in`"
      snapshot_out == snapshot.union(snapshot_in, snp)
    }
  }
}

fn process_cheque_idx(
  chq_idx: Index,
  sq_idx: Index,
  sq_excl: List<Index>,
) -> List<Index> {
  trace @"Add.Con.3.2": @"Either with `cheque.index > received.index`"
  if chq_idx > sq_idx {
    []
  } else {
    trace @"Add.Con.3.3": @"Or `cheque.index elem received.exclude`"
    expect [excl_idx, ..sql_excl_rest] =
      list.drop_while(sq_excl, fn(i) { i < chq_idx })
    expect chq_idx == excl_idx
    sql_excl_rest
  }
}

fn process_cheques(
  cid: t.ChannelId,
  other: VerificationKey,
  cheques: List<Signed<t.Cheque>>,
  sq_idx: Index,
  sq_excl: List<Index>,
  pend: t.Pend,
  ub: PosixMilliseconds,
) -> Amount {
  when cheques is {
    [signed_cheque, ..rest] -> {
      let (cheque, sig) = signed_cheque
      trace @"Add.Con.3.1": @"Signed by other key"
      expect cheque.verify(cid, cheque, other, sig)
      when cheque is {
        t.Normal(idx, amt) -> {
          let sq_excl_rest = process_cheque_idx(idx, sq_idx, sq_excl)
          amt + process_cheques(
            cid,
            other,
            rest,
            sq_idx,
            sq_excl_rest,
            pend,
            ub,
          )
        }
        t.HtlcUnlocked(idx, timeout, _secret, amt) -> {
          let sq_excl_rest = process_cheque_idx(idx, sq_idx, sq_excl)
          trace @"Add.Con.3.4": @"(Un)locked `cheque.timeout < ub`"
          expect timeout < ub
          amt + process_cheques(
            cid,
            other,
            rest,
            sq_idx,
            sq_excl_rest,
            pend,
            ub,
          )
        }
        t.Htlc(idx, timeout, lock, amt) -> {
          let sq_excl_rest = process_cheque_idx(idx, sq_idx, sq_excl)
          trace @"Add.Con.3.4": @"(Un)locked `cheque.timeout < ub`"
          expect timeout < ub
          trace @"Add.Con.3.5": @"The `pend` is correctly derived from the receipt"
          expect [p, ..pend_rest] = pend
          expect (amt, timeout, lock) == p
          process_cheques(cid, other, rest, sq_idx, sq_excl_rest, pend_rest, ub)
        }
      }
    }
    [] -> {
      trace @"Add.Con.3.5": @"The `pend` is correctly derived from the receipt"
      expect pend == []
      0
    }
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
  trace @"Add.In": @"Input state"
  trace @"Add.In.0": @"Keys `keys_in`"
  trace @"Add.In.1": @"`Opened(amt_in, snapshot_in, respond_period) = stage_in`"
  trace @"Add.In.2": @"Amount `tot_in`"
  expect t.Opened(amt_in, snapshot_in, respond_period) = stage_in
  trace @"Add.Out": @"Output state"
  trace @"Add.Out.0": @"Keys `keys_out`"
  trace @"Add.Out.1": @"`Closed(amt_out, squash_out, timeout_out, pend_out) = stage_out`"
  expect t.Closed(amt_out, squash_out, timeout_out, pend_out) = stage_out
  trace @"Add.Out.2": @"Amount `tot_out` and tot_out >= tot_in"
  expect tot_out >= tot_in
  let (self, other) = self_and_other_keys(keys_in, signers)
  let is_vk0 = self == keys_in.1st
  trace @"Add.Con": @"Constraints"
  trace @"Add.Con.0": @"If tx signed by `vk0` then `keys_in == keys_out` else keys are reversed"
  expect
    if is_vk0 {
      keys_out == keys_in
    } else {
      keys_out.1st == keys_in.2nd && keys_out.2nd == keys_in.1st
    }
  let (maybe_snapshot, chqs) = receipt
  let snapshot_out =
    when maybe_snapshot is {
      None -> {
        trace @"Add.Con.1": @"If no snapshot provided then `snapshot_out` equals `snapshot_in`"
        snapshot_in
      }
      Some((snp, snp_sig)) -> {
        trace @"Add.Con.2": @"Else "
        trace @"Add.Con.2.0": @"Snapshot signed by other key"
        expect snapshot.verify(cid, snp, other, snp_sig)
        trace @"Add.Con.2.1": @"`snapshot_out` equals provided union `snapshot_in`"
        snapshot.union(snapshot_in, snp)
      }
    }
  let (sq_received, sq_sent) =
    if builtin.less_than_bytearray(self, other) {
      snapshot_out
    } else {
      let (sq0, sq1) = snapshot_out
      (sq1, sq0)
    }
  trace @"Add.Con.3": @"Cheques"
  let amt_rec =
    if is_vk0 {
      amt_in
    } else {
      tot_in - amt_in
    }
  let cheques_amt =
    process_cheques(
      cid,
      other,
      chqs,
      sq_received.2nd,
      sq_received.3rd,
      pend_out,
      ub,
    )
  let squash_diff = sq_received.1st - sq_sent.1st
  trace @"Add.Con.4": @"`amt_rec + cheques_amt + squash_diff == amt_out`"
  expect amt_rec + cheques_amt + squash_diff == amt_out
  trace @"Add.Con.5": @"`sq_out == sq_sent`"
  expect sq_sent == squash_out
  trace @"Add.Con.6": @"`timeout_out > ub + respond_period`"
  timeout_out > ub + respond_period
}
