## Phase 8: Core data structures

Each item lands on the
VM only (new features are VM-only and come after 7i), with `grammar.md`, the
programming skill, the site docs and tests. Ranges (done) and queues needed the
VM closures (7e PR 5e, done); sets need the VM maps (PR 5d, done). Sets and
queues can proceed in parallel with order steps 6 to 11; faster lists (8d) have
their own place in the order (step 8).

- [x] 8a Ranges (reserving `Range` breaks a user type of that name; say so in
  the changelog, as for `Set` in 8b): `a..b`, `a...b`, `for` over a range,
  `Range` methods, `Int#times`, `upto` and `downto`.
- [x] 8b `Set[T]` (reserving `Set` breaks a user type of that name, noted in the
  changelog): `Set.new`, `add`, `delete`, `include?`, `size`, `empty?`, `to_a`,
  `union`, `intersection`, `difference`, `subset?`, `for` over a set, the text
  form `Set[1, 2]`; no `==`, not JSON-encodable. The VM keeps a set as a map
  with nil values under its own tag (`docs/vm/05-values-execution-builtins.md`
  §5.1), so it reuses the HAMT of `vm/map.c`; `agc_map_add_hash` leaves a member
  alone. Done by the owner's decision of 2026-10-15 in the Racket front end,
  which relaxes the freeze of row 7.2.7 (`compiler/` uses `Set`; the Agentica
  checker handles `Set[T]`, `docs/future/18-front-end-language.md` §18.3).
  Tests: the goldens `sets` and `set-vectors` (a Python peer,
  `tests/fixtures/set-vectors.py`), the checker tests, and `map_test.c`. Numbers
  in `docs/vm-benchmarks.md`; the `sets` benchmark has a Python twin.
- [ ] 8c `Queue[T]`: a builtin generic, persistent FIFO (two lists).
  `Queue.new(items: List[T]) -> Queue[T]` (front first; `Queue.new([])` needs an
  expected type), `Queue.push(q, x: T) -> Queue[T]` (at the back),
  `Queue.peek(q) -> Result[T]` (the front), `Queue.drop(q) -> Queue[T]`
  (without the front; an empty queue stays empty, like `List.drop` with a large
  count), `Queue.size(q) -> Int`, `Queue.empty?(q) -> Bool`,
  `Queue.to_a(q) -> List[T]` (front to back), also as methods. Used linearly,
  each operation is O(1) amortized; reusing an old version can cost O(n) once.
  `for x in queue` iterates front to back; the text form is `Queue[1, 2]`,
  front first; no `==`, like `List`, and not JSON-encodable at first. `pop`
  waits for tuples (the "Later" item below). `Queue` becomes a reserved name,
  so `std/queue` stays as a deprecated `StringQueue` alias (a breaking change
  for `as Queue`): 8c renames the documented alias in `README.md`,
  `examples/queue.agc`, `docs/grammar.md`, the programming skill's modules
  reference and the tests, keeps `stdlib/queue.agc` and its `std/` coverage,
  and notes the break in the changelog. `std/queue` is removed later, in its
  own PR, only when 8c has landed and another `std/` module (such as
  `std/binary`, phase 13) covers the `std/` path.
- [x] 8d Faster lists: a persistent vector behind `List` on the VM, no language
  change (the persistent vector, [`docs/vm/17-lists.md`](../vm/17-lists.md)).
  Reason: `List.append`
  (`push`) copied the whole array in `vm/builtins.c`, so building a list with n
  pushes was O(n²) (the `list-build` benchmark shows it, 160,000 pushes in a
  loop took about a minute; `docs/vm-benchmarks.md`). Done: `push` and `set`
  are near constant time, indexing takes at most 4 loads up to a million items,
  and the same loop takes 0.08 s. Order step 8: after 7h processes and network,
  and before any instruction-dispatch micro-optimization (7g). Design:
  [`docs/vm/17-lists.md`](../vm/17-lists.md) (representation, C API, costs,
  tests, PR plan). Steps 1 to 3 (the API, the trie, the unboxed leaves) are
  done.
- [x] 8d step 3: unboxed leaves for `List[Int]` and `List[Float]`
([§38.6][agentica-link-1]
  item 1), scheduled by the owner on 2026-10-14. The trie leaves and the tail of
  a list whose items are all Ints, or all Floats, hold 8 bytes per item in an
  atomic array that the GC does not scan. The VM decides by itself when it
  builds a list (the owner's decision of 2026-10-15; the first plan had the
  front end pass the element type): the first item gives the kind, an empty list
  has none, and a list that is given another kind, which only a hostile `.agcb`
  can do, becomes boxed. So there is no change to the front end, the lowering,
  the bytecode or the loader, and the item does not wait for the freeze of the
  Racket front end (order row 7.2.7 in the [README](README.md)). `Int` stays 64
  bits. Done: a numeric list takes half the memory (which offsets the extra
  memory of the trie), and `sort` of a numeric list needs no read through the
  trie. Design: [`docs/vm/17-lists.md`](../vm/17-lists.md) §17.12; the numbers,
  time and peak RSS against master and Python 3.13, are in
  [`docs/vm-benchmarks.md`](../vm-benchmarks.md). The comparison with the
  owner's alternative of a doubling growable vector is still open.
- [ ] Later, each after a real program needs it: tuples (`(Int, String)`
  values and destructuring, to return two values; then `Queue.pop`); `Bytes`
  (binary data instead of `List[Int]`; until then `std/binary`, phase 13, packs
  numbers into `List[Int]`, and when `Bytes` lands that API moves to it in the
  same change as the `*_bytes` builtins); `Heap[T]` (a priority queue for
  Dijkstra and scheduling; `Int`, `Float` or `String`, or a key function); a
  sorted map or set (iterate in key order; today sort the keys); and a deque
  (both ends).

**Done when:** ranges, sets, queues and the faster lists run on the VM,
and an evaluation round shows agents use ranges without `while` workarounds.


[agentica-link-1]: ../future/38-value-representation.md
