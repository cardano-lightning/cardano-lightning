use aiken/collection/list as list
use aiken/fuzz.{and_then}

// Folding List over Fuzzers. Returns Fuzzer of the accumulated value.
pub fn foldl(elems: List<a>, acc: b, f: fn(b, a) -> Fuzzer<b>) -> Fuzzer<b> {
  when elems is {
    [] -> fuzz.constant(acc)
    // In here we return the accumulated value
    [x, ..xs] -> {
      let new_acc <- and_then(f(acc, x))
      foldl(xs, new_acc, f)
    }
  }
}

pub fn foldr(elems: List<a>, init: b, f: fn(a, b) -> Fuzzer<b>) -> Fuzzer<b> {
  when elems is {
    [] -> fuzz.constant(init)
    // In here we return the accumulated value
    [x, ..xs] -> {
      let acc <- and_then(foldr(xs, init, f))
      f(x, acc)
    }
  }
}

// Traversing over list of Fuzzers. Returns Fuzzer of the accumulated list.
pub fn traverse_list(elems: List<a>, f: fn(a) -> Fuzzer<b>) -> Fuzzer<List<b>> {
  foldr(
    elems,
    [],
    fn(a, acc) {
      let b <- and_then(f(a))
      fuzz.constant(acc |> list.push(b))
    },
  )
}

// Try to pick `num` random elements. If the list is shorter
// than `num`, return the whole list.
// The order of elements is not preserved.
pub fn many_of(num: Int, elems: List<a>) -> Fuzzer<List<a>> {
  if num == 0 {
    fuzz.constant([])
  } else {
    let length = list.length(elems)
    let nth <- and_then(fuzz.int_between(0, length))
    when elems |> list.drop(nth) |> list.head is {
      Some(x) -> {
        let rest =
          elems |> list.take(nth) |> list.concat(elems |> list.drop(nth + 1))
        let xs <- and_then(many_of(num - 1, rest))
        fuzz.constant(xs |> list.push(x))
      }
      None -> fuzz.constant([])
    }
  }
}

// This is unsafe as `fuzz.pick` itself is unsafe
pub fn pick_elem(elems: List<a>) -> Fuzzer<a> {
  let (_, elem) <- and_then(fuzz.pick(elems))
  fuzz.constant(elem)
}

// This gives you hopefully a subset of `elems`.
// The size of the set can be between 0 and `length`.
pub fn pick_subset(elems: List<a>, desired_length: Int) -> Fuzzer<List<a>> {
  if desired_length >= list.length(elems) {
    fuzz.constant(elems)
  } else {
    fuzz.set_between(pick_elem(elems), 0, desired_length)
  }
}
