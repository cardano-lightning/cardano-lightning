use aiken/collection/list
use aiken/crypto.{blake2b_224}

fn work(n: Int) {
  let key =
    #[0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
      0,
    ]
  let pkh = blake2b_224(key)
  let pkh1 = blake2b_224(key)
  expect pkh == pkh1
  n
}

fn do_map(n) {
  let idx = list.range(0, n)
  let dummy = list.range(0, n)
  idx
    |> list.map2(dummy, fn(i0, i1) { work(i0) == work(i1) })
    |> list.all(fn(i) { i })
}

fn do_lookups(n) {
  let idx = list.range(0, n)
  let dummy = list.range(0, n)
  idx |> list.all(fn(i) { ( dummy |> list.at(i) ) == Some(i) })
}

test test_lookups_00001() {
  do_lookups(1)
}

test test_map_00001() {
  do_map(1)
}

test test_lookups_00002() {
  do_lookups(2)
}

test test_map_00002() {
  do_map(2)
}

test test_lookups_00004() {
  do_lookups(4)
}

test test_map_00004() {
  do_map(4)
}

test test_lookups_00008() {
  do_lookups(8)
}

test test_map_00008() {
  do_map(8)
}

test test_lookups_00016() {
  do_lookups(16)
}

test test_map_00016() {
  do_map(16)
}

test test_lookups_00032() {
  do_lookups(32)
}

test test_map_00032() {
  do_map(32)
}

test test_lookups_00064() {
  do_lookups(64)
}

test test_map_00064() {
  do_map(64)
}

test test_lookups_00128() {
  do_lookups(128)
}

test test_map_00128() {
  do_map(128)
}

test test_lookups_00256() {
  do_lookups(256)
}

test test_map_00256() {
  do_map(256)
}
