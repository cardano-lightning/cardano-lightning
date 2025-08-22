use aiken/primitive/bytearray
use cl/main as main
use cl/tests/benchmarks/gen
// use aiken/fuzz
// use aiken/collection/list

const own_hash =
  #"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> bytearray.take(28)

test test_reduce_new_channels(
  (seed, n_mint, outputs) via gen.gen_new_channels_outputs(own_hash, 10),
) {
  main.reduce_new_channels(own_hash, seed, n_mint, outputs) != []
}

bench bench_reduce_new_channels(
  (seed, n_mint, outputs) via gen.gen_new_channels_outputs(own_hash, _),
) {
  main.reduce_new_channels(own_hash, seed, n_mint, outputs)
}

const max_cheques = 10

// mem:        max: 14000000
// ## add:
//              01: 00599937
//              30: 08689825
// ## close:
//              01: 00812919
//              30: 13576441
//
// steps:      max: 10000000000
// ## add:
//              01: 00189256432
//              30: 02755232256
// ## close:
//              01: 00503756288
//              30: 08594974720


test test_reduce_add_steps_transaction(
  (transaction, redeemer) via gen.gen_add_steps_transaction(
    own_hash,
    10,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_reduce_add_steps_transaction(
  (transaction, redeemer) via gen.gen_add_steps_transaction(
    own_hash,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_reduce_close_steps_transaction(
  (transaction, redeemer) via gen.gen_close_steps_transaction(
    own_hash,
    max_cheques,
    1,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_reduce_close_steps_transaction(
  (transaction, redeemer) via gen.gen_close_steps_transaction(
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
//     1,
//   ),
// ) {
//   main.mint(redeemer, own_hash, transaction)
// }
// 
// bench bench_reduce_respond_steps_tx(
//   (transaction, redeemer) via gen.gen_respond_steps_transaction(
//     own_hash,
//     max_cheques,
//     _,
//   ),
// ) {
//   main.mint(redeemer, own_hash, transaction)
// }
// 
