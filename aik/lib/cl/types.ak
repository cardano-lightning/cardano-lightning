use aiken/collection.{Index}
use aiken/crypto.{ScriptHash, VerificationKey}
use cardano/transaction.{OutputReference}
use cl/prelude.{Amount, Bytes32, Period, Signed, Timeout}

pub type HtlcLock =
  Bytes32

pub type HtlcSecret {
  Sha2_256Secret(ByteArray)
  Sha3_256Secret(ByteArray)
  Blake2b_256Secret(ByteArray)
}

pub type Cheque {
  Normal(Index, Amount)
  Htlc(Index, Timeout, HtlcLock, Amount)
  HtlcUnlocked(Index, Timeout, HtlcSecret, Amount)
}

/// Unique 20 byte channel ID formed formed on init
pub type ChannelId =
  ByteArray

pub type Exclude =
  List<Index>

pub type Squash =
  (Amount, Index, Exclude)

pub type Snapshot =
  (Squash, Squash)

pub type Receipt =
  (Option<Signed<Snapshot>>, List<Signed<Cheque>>)

pub type HtlcLockedReduced =
  (Amount, Timeout, HtlcLock)

pub type Pend =
  List<HtlcLockedReduced>

pub type Keys =
  (VerificationKey, VerificationKey)

pub type Stage {
  Opened(Amount, Snapshot, Period)
  Closed(Amount, Squash, Timeout, Pend)
  Responded(Amount, Pend, Pend)
  Elapsed(Pend)
  Resolved(Pend, Pend)
}

pub type Datum =
  (ScriptHash, Keys, Stage)

pub type SpendRedeemer {
  DeferToMint
}

pub type MintRedeemer =
  (Option<OutputReference>, List<NStep>)

pub type Secrets =
  List<(Index, HtlcSecret)>

pub type NStep {
  Continuing(CStep)
  End(Secrets)
}

// This is a slight optimization to avoid
// iteration over `sent` cheques to
// release expired ones.
// Sometimes this flag is just ignored.
pub type DropOld =
  Bool

pub type CStep {
  Add(Option<Signed<Snapshot>>)
  Close(Receipt)
  Respond(Receipt, DropOld)
  Resolve(Secrets, DropOld)
  Elapse(Secrets)
  Free(Secrets, DropOld)
}
