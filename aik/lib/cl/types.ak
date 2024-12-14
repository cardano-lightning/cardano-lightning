use aiken/collection.{Index}
use aiken/crypto.{ScriptHash, VerificationKey}
use cardano/transaction.{OutputReference}
use cl/prelude.{Amount, Bytes32, Period, Signed, Timeout}

// ## Cheques

pub type Normal =
  (Index, Amount)

pub type HashLock {
  Blake2b256Lock(Bytes32)
  Sha2256Lock(Bytes32)
  Sha3256Lock(Bytes32)
}

pub type Htlc =
  (Index, Amount, Timeout, HashLock)

pub type Locked {
  HtlcLocked(Htlc)
}

pub type Cheque {
  NormalCheque(Normal)
  LockedCheque(Locked)
}

pub type Secret =
  ByteArray

pub type Unlocked {
  Unhtlc(Htlc, Secret)
}

pub type MCheque {
  MNormal(Normal)
  MLocked(Locked)
  MUnlocked(Unlocked)
}

// ## Channel

/// Unique 20 byte channel ID formed formed on init
pub type ChannelId =
  ByteArray

// ## Snapshot

pub type Exclude =
  List<Index>

///
pub type Squash =
  (Amount, Index, Exclude)

///
pub type Snapshot =
  (Squash, Squash)

// ## Receipt 

/// 
pub type Receipt =
  (Option<Signed<Snapshot>>, List<Signed<MCheque>>)

pub type LockedReduced {
  HtlcReduced(Amount, Timeout, HashLock)
}

// ## Pend

pub type Pend =
  (Amount, List<LockedReduced>)

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
