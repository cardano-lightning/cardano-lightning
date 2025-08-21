use aiken/cbor as cbor
use cl/types as t

// Helper functions which we call from pyken in order to
// generate and maintain the fixtures.
pub fn serialise_datum(input_stage: t.Datum) -> ByteArray {
  // encoding round trip
  let data: Data = input_stage
  expect decoded_stage: t.Datum = data
  expect decoded_stage == input_stage
  cbor.serialise(decoded_stage)
}

pub fn serialise_redeemer(input_redeemer: t.SpendRedeemer) -> ByteArray {
  // encoding round trip
  let data: Data = input_redeemer
  expect decoded_redeemer: t.SpendRedeemer = data
  expect decoded_redeemer == input_redeemer
  cbor.serialise(decoded_redeemer)
}
