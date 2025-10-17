use aiken/collection.{Index}
use aiken/crypto.{ScriptHash, Signature, VerificationKey}
use cardano/transaction.{OutputReference}
use cl/prelude.{Amount, Bytes32, Period, Signed, Timeout}

pub type HtlcLock =
  Bytes32

// Fully BLN compatible HTLC secret
pub type HtlcSecret =
  Bytes32

/// Unique 20 byte channel ID formed formed on init
pub type ChannelId =
  ByteArray

pub type Exclude =
  List<Index>

pub type Squash {
  amount: Amount,
  index: Index,
  exclude: Exclude,
}

pub type Snapshot =
  (Squash, Squash)

pub type Cheque {
  Locked {
    index: Index,
    timeout: Timeout,
    lock: HtlcLock,
    amount: Amount,
    signature: Signature,
  }
  Unlocked {
    index: Index,
    timeout: Timeout,
    secret: HtlcSecret,
    amount: Amount,
    signature: Signature,
  }
}

pub type Receipt =
  (Option<Signed<Snapshot>>, List<Cheque>)

pub type HtlcLockedReduced =
  (Amount, Timeout, HtlcLock)

pub type Pend =
  List<HtlcLockedReduced>

pub type Keys =
  (VerificationKey, VerificationKey)

pub type KeyIdx =
  Index

pub type NonOpenerWithdrawal =
  Amount

pub type CloserWithdrawal =
  Amount

pub type NonResolverWithdrawal =
  Amount

pub type Stage {
  Opened(NonOpenerWithdrawal, Snapshot, Period)
  Closed(CloserWithdrawal, Squash, Timeout, Pend)
  Resolved(NonResolverWithdrawal, Pend, Pend)
}

// min ADA expressed in ADA (1_000_000 Lovelace)
pub type MinAdaAmount =
  Int

pub type MinAdaOwner =
  Int

pub type Datum =
  (ScriptHash, Keys, Stage, MinAdaAmount, MinAdaOwner)

pub type SpendRedeemer {
  DeferToMint
}

pub type Secrets =
  List<(Index, HtlcSecret)>

pub type MintRedeemer =
  (Option<OutputReference>, List<Step>)

pub type Step {
  Continuing(ContinuingStep)
  End(EndStep)
}

pub type EndStep {
  ElapseEnd(Secrets)
  EndResolved(Secrets)
  RespondEnd(Receipt)
}

// This is a slight optimization to avoid
// iteration over `sent` cheques to
// release expired ones.
pub type DropOld =
  Bool

pub type ContinuingStep {
  Add { by_opener: Bool, snapshot: Option<Signed<Snapshot>> }
  Close { by_opener: Bool, receipt: Receipt }
  Elapse(Secrets)
  FreeInClosed(Secrets)
  FreeInResolved { by_resolver: Bool, secrets: Secrets, drop_old: DropOld }
  Respond { receipt: Receipt, drop_old: DropOld }
}
