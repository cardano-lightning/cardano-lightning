use aiken/primitive/bytearray
use cl/main as main
use cl/tests/benchmarks/gen

// use aiken/fuzz
// use aiken/collection/list

const max_cheques = 10

const channel_num = 1

const own_hash =
  #"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
    |> bytearray.take(28)

test test_new_channels(
  (seed, n_mint, outputs) via gen.gen_new_channels_outputs(
    own_hash,
    channel_num,
  ),
) {
  main.reduce_new_channels(own_hash, seed, n_mint, outputs) == []
}

bench bench_new_channels(
  (seed, n_mint, outputs) via gen.gen_new_channels_outputs(own_hash, _),
) {
  main.reduce_new_channels(own_hash, seed, n_mint, outputs)
}

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

test test_add_steps(
  (transaction, redeemer) via gen.gen_add_steps(own_hash, channel_num),
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
    max_cheques,
    channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_close_steps(
  (transaction, redeemer) via gen.gen_close_steps(own_hash, max_cheques, _),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_respond_steps(
  (transaction, redeemer) via gen.gen_respond_steps(
    own_hash,
    max_cheques,
    channel_num,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_respond_steps(
  (transaction, redeemer) via gen.gen_respond_steps(own_hash, max_cheques, _),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_elapse_steps(
  (transaction, redeemer) via gen.gen_elapse_steps(own_hash, max_cheques, 1),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_free_in_closed_steps(
  (transaction, redeemer) via gen.gen_free_in_closed_steps(
    own_hash,
    max_cheques,
    1,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_free_in_closed_steps(
  (transaction, redeemer) via gen.gen_free_in_closed_steps(
    own_hash,
    max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_free_in_resolved_steps(
  (transaction, redeemer) via gen.gen_free_in_resolved_steps(
    own_hash,
    max_cheques,
    1,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_free_in_resolved_steps(
  (transaction, redeemer) via gen.gen_free_in_resolved_steps(
    own_hash,
    max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_end_resolved_steps(
  (transaction, redeemer) via gen.gen_end_resolved_steps(
    own_hash,
    max_cheques,
    1,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_end_resolved_steps(
  (transaction, redeemer) via gen.gen_end_resolved_steps(
    own_hash,
    max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_elapse_end_steps(
  (transaction, redeemer) via gen.gen_elapse_end_steps(own_hash, max_cheques, 1),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_elapse_end_steps(
  (transaction, redeemer) via gen.gen_elapse_end_steps(own_hash, max_cheques, _),
) {
  main.mint(redeemer, own_hash, transaction)
}

test test_respond_end_steps(
  (transaction, redeemer) via gen.gen_respond_end_steps(
    own_hash,
    max_cheques,
    1,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}

bench bench_respond_end_steps(
  (transaction, redeemer) via gen.gen_respond_end_steps(
    own_hash,
    max_cheques,
    _,
  ),
) {
  main.mint(redeemer, own_hash, transaction)
}
