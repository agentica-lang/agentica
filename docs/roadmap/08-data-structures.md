## Phase 8: Core data structures

Specified in [`docs/future/12-data-structures.md` section
12](../future/12-data-structures.md#12-data-structures). Each item lands on the
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
  which relaxes the freeze of row 7.2.7 (`compiler/` uses `Set`, and has no
  checker yet; the port of step 4 in `docs/future/35-self-hosting.md` must
  handle `Set[T]`). Tests: the goldens `sets` and `set-vectors` (a Python peer,
  `tests/fixtures/set-vectors.py`), the checker tests, and `map_test.c`. Numbers
  in `docs/vm-benchmarks.md`; the `sets` benchmark has a Python twin.
- [ ] 8c `Queue[T]`; `std/queue` stays deprecated under the alias `StringQueue`
  (breaking change for `as Queue`). It is removed later, in its own PR, only
  when another `std/` module covers the `std/` path
  (`docs/future/12-data-structures.md` §12.3); 8c and phase 13 do not remove it.
- [x] 8d Faster lists: a persistent vector behind `List` on the VM, no language
  change (`docs/future/12-data-structures.md` §12.4). Reason: `List.append`
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
- [ ] Later (`docs/future/12-data-structures.md` §12.5), each after a real
  program needs it: tuples (then `Queue.pop`), `Bytes`, `Heap[T]`, a sorted map
  or set, a deque.

**Done when:** ranges, sets, queues and the faster lists run on both backends,
and an evaluation round shows agents use ranges without `while` workarounds.


[agentica-link-1]: ../future/38-value-representation.md
