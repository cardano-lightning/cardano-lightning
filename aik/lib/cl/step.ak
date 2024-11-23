use aiken/crypto.{VerificationKeyHash}
use cl/prelude.{Amount, Signed}
use cl/sign
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

/// Utitlity to order the keys
fn signer_other(keys: t.Keys, is_vk0: Bool) {
  if is_vk0 {
    keys
  } else {
    let (vk0, vk1) = keys
    (vk1, vk0)
  }
}

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
) {
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
      expect sign.verify(cid, other_key(keys_in, is_vk0), snp, sig)
      trace @"Add.Con.3.1": @"`snapshot_out` equals provided union `snapshot_in`"
      snapshot_out == snapshot.union(snapshot_in, snp)
    }
  }
}
