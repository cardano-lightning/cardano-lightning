use aiken/builtin.{append_bytearray}
use aiken/cbor as cbor
use cl/prelude.{Amount, Period, Timeout}
use cl/types as t

// pub type Stage {
//   Opened(Amount, Snapshot, Period)
//   Closed(Amount, Squash, Timeout, Pend)
//   Responded(Amount, Pend, Pend)
//   Resolved(Pend, Pend)
//   Elapsed(Pend)
// }

pub fn serialise_stage_opened(
  amount: Amount,
  snapshot: t.Snapshot,
  period: Period,
) -> ByteArray {
  let val = t.Opened(amount, snapshot, period)
  cbor.serialise(val)
}

pub fn serialise_stage_closed(
  amount: Amount,
  squash: t.Squash,
  timeout: Timeout,
  pend: t.Pend,
) -> ByteArray {
  let val = t.Closed(amount, squash, timeout, pend)
  cbor.serialise(val)
}

pub fn serialise_stage_responded(
  amount: Amount,
  pend1: t.Pend,
  pend2: t.Pend,
) -> ByteArray {
  let val = t.Responded(amount, pend1, pend2)
  cbor.serialise(val)
}
// pub type Cheque {
//   Normal(Index, Amount)
//   Htlc(Index, Timeout, HtlcLock, Amount)
//   HtlcUnlocked(Index, Timeout, HtlcSecret, Amount)
// }

// pub type Datum = (ScriptHash, Keys, Stage)

// pub fn test_stage_closed_encoding(amount, squash, timeout, pend, expected) {
//   assert_eq!(stage_closed(amount, squash, timeout, pend), expected)
// }
