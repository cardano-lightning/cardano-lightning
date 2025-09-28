use aiken/collection.{Index}
use aiken/crypto.{ScriptHash, VerificationKey}
use cardano/transaction.{OutputReference}
use cl/prelude.{Amount, Bytes32, Period, Signed, Timeout}
use cardano/address.{Address}

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

pub type Secrets =
  List<(Index, HtlcSecret)>

// This is a slight optimization to avoid
// iteration over `sent` cheques to
// release expired ones.
// This flag is just ignored by some steps.
pub type DropOld =
  Bool

pub type MintRedeemer = (Option<OutputReference>, List<NStep>)

pub type NStep {
  Continuing(CStep)
  End(Secrets)
}

pub type CStep {
  Add {
    by_opener: Bool,
    snapshot: Option<Signed<Snapshot>>
  }
  Close {
    by_opener: Bool,
    receipt: Receipt
  }
  Respond(Receipt, DropOld)
  Resolve(Secrets, DropOld)
  Elapse(Secrets)
  Free(Secrets, DropOld)
  FreeInResolved {
    by_closer: Bool,
    secrets: Secrets,
    drop_old: DropOld
  }
}


pub type MinUTxODest {
  UseAddress { address: Address }
  // 0 - means first key, non 0 - means second key
  OwnerKey { keyIdx: Int }
}

pub type MinUTxOAmount = Int

pub type OrigDatum = (ScriptHash, Keys, MinUTxOAmount, MinUTxODest, Stage)

pub type ExtDatum = (ScriptHash, Keys, Stage)

pub fn compare_datums(_orig: OrigDatum, _ext: ExtDatum) -> Bool {
  True
}

