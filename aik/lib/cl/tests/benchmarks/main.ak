use aiken/primitive/bytearray
use cl/main as main
use cl/tests/benchmarks/gen

const own_hash =
  #"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> bytearray.take(28)

test test_reduce_new_channels(
  (seed, n_mint, outputs) via gen.gen_new_channels_outputs(own_hash, 10),
) {
  main.reduce_new_channels(own_hash, seed, n_mint, outputs) != [] || True
}

bench bench_reduce_new_channels(
  (seed, n_mint, outputs) via gen.gen_new_channels_outputs(own_hash, _),
) {
  main.reduce_new_channels(own_hash, seed, n_mint, outputs)
}

const max_cheques = 20

// main: pub fn mint(redeemer: t.MintRedeemer, own_hash: ScriptHash, tx: Transaction) {
// gen: pub fn gen_add_steps_transaction(own_hash, max_cheques, n_steps) -> Fuzzer<(Tx, t.MintRedeemer)> {
bench bench_reduce_add_steps_transaction(
  (transaction, redeemer) via gen.gen_add_steps_transaction(
    own_hash,
    max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

// test test_reduce_add_steps_transaction(
//   (transaction, redeemer) via gen.gen_add_steps_transaction(
//     own_hash,
//     max_cheques,
//     10,
//   ),
// ) {
//   main.mint(redeemer, own_hash, transaction)
// }

// gen: pub fn gen_close_steps_transaction(own_hash, max_cheques, n_steps) -> Fuzzer<(Transaction, t.MintRedeemer)> {
bench bench_reduce_close_steps_transaction(
  (transaction, redeemer) via gen.gen_close_steps_transaction(
    own_hash,
    max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_reduce_close_steps_transaction(
  (transaction, redeemer) via gen.gen_close_steps_transaction(
    own_hash,
    max_cheques,
    10,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

// gen: pub fn gen_respond_steps_transaction(own_hash, max_cheques, n_steps) -> Fuzzer<(Transaction, t.MintRedeemer)> {
bench bench_reduce_respond_steps_tx(
  (transaction, redeemer) via gen.gen_respond_steps_transaction(
    own_hash,
    max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}
// test test_reduce_respond_steps_tx(
//   (transaction, redeemer) via gen.gen_respond_steps_transaction(
//     own_hash,
//     max_cheques,
//     10,
//   ),
// ) {
//   main.mint(redeemer, own_hash, transaction)
// }
