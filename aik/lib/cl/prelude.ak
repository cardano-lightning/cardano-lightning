use aiken/crypto.{Signature}

/// Amount of funds associate to a cheque, a squash, an account, _etc_
pub type Amount =
  Int

/// Posix Timestamp
pub type Timeout =
  Int

/// Posix time delta
pub type Period =
  Int

/// A bytearray that ought to be 32 bytes in length.
pub type Bytes32 =
  ByteArray

pub type Signed<t> =
  (t, Signature)
