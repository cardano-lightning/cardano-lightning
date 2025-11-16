use aiken/primitive/bytearray
use cl/main as main
use cl/tests/benchmarks/gen
use config

// This constant is used only by the test functions.
// Benchmarks will use varying channel numbers.
const test_channel_num = 1

const own_hash =
  #"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> bytearray.take(28)

test test_new_channels(
  (seed, n_mint, outputs) via gen.gen_new_channels_outputs(
    own_hash,
    test_channel_num,
  ),
) {
  main.reduce_new_channels(own_hash, seed, n_mint, outputs) == []
}

bench bench_new_channels(
  (seed, n_mint, outputs) via gen.gen_new_channels_outputs(own_hash, _),
) {
  main.reduce_new_channels(own_hash, seed, n_mint, outputs)
}

test test_add_steps(
  (transaction, redeemer) via gen.gen_add_steps(own_hash, test_channel_num),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_add_steps(
  (transaction, redeemer) via gen.gen_add_steps(own_hash, _),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_close_steps(
  (transaction, redeemer) via gen.gen_close_steps(
    own_hash,
    config.max_cheques,
    test_channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_close_steps(
  (transaction, redeemer) via gen.gen_close_steps(
    own_hash,
    config.max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_respond_steps(
  (transaction, redeemer) via gen.gen_respond_steps(
    own_hash,
    config.max_cheques,
    test_channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_respond_steps(
  (transaction, redeemer) via gen.gen_respond_steps(
    own_hash,
    config.max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_elapse_steps(
  (transaction, redeemer) via gen.gen_elapse_steps(
    own_hash,
    config.max_cheques,
    test_channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_elapse_steps(
  (transaction, redeemer) via gen.gen_elapse_steps(
    own_hash,
    config.max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_free_in_closed_steps(
  (transaction, redeemer) via gen.gen_free_in_closed_steps(
    own_hash,
    config.max_cheques,
    test_channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_free_in_closed_steps(
  (transaction, redeemer) via gen.gen_free_in_closed_steps(
    own_hash,
    config.max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_free_in_resolved_steps(
  (transaction, redeemer) via gen.gen_free_in_resolved_steps(
    own_hash,
    config.max_cheques,
    test_channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_free_in_resolved_steps(
  (transaction, redeemer) via gen.gen_free_in_resolved_steps(
    own_hash,
    config.max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_end_resolved_steps(
  (transaction, redeemer) via gen.gen_end_resolved_steps(
    own_hash,
    config.max_cheques,
    test_channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_end_resolved_steps(
  (transaction, redeemer) via gen.gen_end_resolved_steps(
    own_hash,
    config.max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_elapse_end_steps(
  (transaction, redeemer) via gen.gen_elapse_end_steps(
    own_hash,
    config.max_cheques,
    test_channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_elapse_end_steps(
  (transaction, redeemer) via gen.gen_elapse_end_steps(
    own_hash,
    config.max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_respond_end_steps(
  (transaction, redeemer) via gen.gen_respond_end_steps(
    own_hash,
    config.max_cheques,
    test_channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_respond_end_steps(
  (transaction, redeemer) via gen.gen_respond_end_steps(
    own_hash,
    config.max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}
// // The below are sanity checks to ensure that the fuzzers do not contribute to the benchmark time.
// // Use them whenever you encounter unexpected benchmark results to do sanity checks.
// fn reduce_new_channels_noop(
//   _own_hash: ByteArray,
//   _seed: OutputReference,
//   _n_mint: nat,
//   outputs: List<Output>
// ) -> Bool {
//   (outputs |> list.length()) >= 0
// }
//
// pub fn mint_noop(_redeemer: MintRedeemer, _own_hash: ByteArray, tx: Transaction) {
//   (tx.outputs |> list.length()) >= 0
// }
//
// bench bench_new_channels_fuzzer(
//   (seed, n_mint, outputs) via gen.gen_new_channels_outputs(own_hash, _),
// ) {
//   expect _ = reduce_new_channels_noop(own_hash, seed, n_mint, outputs)
// }
//
// bench bench_add_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_add_steps(own_hash, _),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
//
// bench bench_close_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_close_steps(own_hash, config.max_cheques, _),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
//
// bench bench_respond_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_respond_steps(own_hash, config.max_cheques, _),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
//
// bench bench_elapse_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_elapse_steps(own_hash, config.max_cheques, _),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
//
// bench bench_free_in_closed_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_free_in_closed_steps(
//     own_hash,
//     config.max_cheques,
//     _,
//   ),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
//
// bench bench_free_in_resolved_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_free_in_resolved_steps(
//     own_hash,
//     config.max_cheques,
//     _,
//   ),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
//
// bench bench_end_resolved_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_end_resolved_steps(
//     own_hash,
//     config.max_cheques,
//     _,
//   ),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
//
// bench bench_elapse_end_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_elapse_end_steps(own_hash, config.max_cheques, _),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
//
// bench bench_respond_end_steps_fuzzer(
//   (transaction, redeemer) via gen.gen_respond_end_steps(
//     own_hash,
//     config.max_cheques,
//     _,
//   ),
// ) {
//   expect _ = mint_noop(redeemer, own_hash, transaction)
// }
