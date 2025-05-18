use aiken/collection/list as list
use aiken/fuzz.{and_then}

pub fn traverse(elems: List<a>, f: fn(a) -> Fuzzer<b>) -> Fuzzer<List<b>> {
  when elems is {
    [] -> fuzz.constant([])
    [x, ..xs] -> {
      let x <- and_then(f(x))
      let xs <- and_then(traverse(xs, f))
      fuzz.constant(xs |> list.push(x))
    }
  }
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

pub fn pick_elem(elems: List<a>) -> Fuzzer<a> {
  let (_, elem) <- and_then(fuzz.pick(elems))
  fuzz.constant(elem)
}
