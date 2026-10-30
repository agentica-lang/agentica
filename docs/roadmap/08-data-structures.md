## Phase 8: Core data structures

Each item lands on the VM only, with `grammar.md`, the programming skill, the
site docs and tests. Sets and queues can proceed in parallel with order steps 6
to 11; faster lists (8d) have their own place in the order (step 8).

- [x] 8a Ranges (reserving `Range` breaks a user type of that name; say so in
  the changelog, as for `Set` in 8b): `a..b`, `a...b`, `for` over a range,
  `Range` methods, `Int#times`, `upto` and `downto`.
- [x] 8b `Set[T]` (reserving `Set` breaks a user type of that name, noted in the
  changelog): `Set.new`, `add`, `delete`, `include?`, `size`, `empty?`, `to_a`,
  `union`, `intersection`, `difference`, `subset?`, `for` over a set, the text
  form `Set[1, 2]`; no `==`, not JSON-encodable. The VM keeps a set as a map
  with nil values under its own tag (`docs/vm/05-values-execution-builtins.md`
  §5.1). Done by the owner's decision of 2026-10-15, which relaxed the freeze of
  row 7.2.7 (`compiler/` uses `Set`). Numbers in `docs/vm-benchmarks.md`.
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
  for `as Queue`, noted in the changelog). `std/queue` is removed later, in its
  own PR, once another `std/` module covers the `std/` path.
- [x] 8d Faster lists: a persistent vector behind `List` on the VM, no language
  change (design, representation, costs: [`docs/vm/17-lists.md`](../vm/17-lists.md)).
  `push` and `set` are near constant time, indexing takes at most 4 loads up to
  a million items. Order step 8: before any instruction-dispatch
  micro-optimization (7g).
- [x] 8d step 3: unboxed leaves for `List[Int]` and `List[Float]`
  ([§38.6](../future/38-value-representation.md) item 1), scheduled by the
  owner on 2026-10-14. The VM decides by itself when it builds a list (the
  owner's decision of 2026-10-15; the first plan had the front end pass the
  element type): the first item gives the kind, an empty list has none, and a
  list that is given another kind, which only a hostile `.agcb` can do, becomes
  boxed. So there is no change to the front end, the lowering, the bytecode or
  the loader. `Int` stays 64 bits. Design:
  [`docs/vm/17-lists.md`](../vm/17-lists.md) §17.12; numbers in
  [`docs/vm-benchmarks.md`](../vm-benchmarks.md). The comparison with the
  owner's alternative of a doubling growable vector is still open.
- [x] `Bytes` (binary data instead of `List[Int]`, with `std/binary` on it)
  landed in 0.17.0 (#805).
- [ ] Later, each after a real program needs it: tuples (`(Int, String)`
  values and destructuring, to return two values; then `Queue.pop`); `Heap[T]`
  (a priority queue for Dijkstra and scheduling; `Int`, `Float` or `String`, or
  a key function); a sorted map or set (iterate in key order; today sort the
  keys); and a deque (both ends).

**Done when:** ranges, sets, queues and the faster lists run on the VM,
and an evaluation round shows agents use ranges without `while` workarounds.
