use aiken/collection.{Index}
use aiken/crypto.{ScriptHash, VerificationKey}
use cardano/transaction.{OutputReference}
use cl/prelude.{Amount, Bytes32, Period, Signed, Timeout}

// ## Cheques
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

// ## Channel

/// Unique 20 byte channel ID formed formed on init
pub type ChannelId =
  ByteArray

// ## Snapshot

pub type Exclude =
  List<Index>

pub type Squash =
  (Amount, Index, Exclude)

pub type Snapshot =
  (Squash, Squash)

// ## Receipt
pub type Receipt =
  (Option<Signed<Snapshot>>, List<Signed<Cheque>>)

pub type HtlcLockedReduced =
  (Amount, Timeout, HtlcLock)

// ## Pend

pub type Pend =
  List<HtlcLockedReduced>

// ## Spend Redeemer

pub type Keys =
  (VerificationKey, VerificationKey)

// ## Stages 
pub type Stage {
  Opened(Amount, Snapshot, Period)
  Closed(Amount, Squash, Timeout, Pend)
  Responded(Amount, Pend, Pend)
  Resolved(Pend, Pend)
  Elapsed(Pend)
}

// ## Datum 

pub type Datum =
  (ScriptHash, Keys, Stage)

// ## Spend Redeemer

pub type SpendRedeemer {
  DeferToMint
}

// ## Mint Redeemer
pub type MintRedeemer =
  (Option<OutputReference>, List<NStep>)

pub type Secret {
  HtlcSecret(HtlcSecret)
}

pub type Secrets =
  List<(Index, Secret)>

pub type NStep {
  Continuing(CStep)
  End(Secrets)
}

pub type CStep {
  Add(Option<Signed<Snapshot>>)
  Close(Receipt)
  Respond(Receipt, Bool)
  Resolve(Secrets)
  Elapse(Secrets)
  Free(Secrets, Bool)
}
