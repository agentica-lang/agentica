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
- [ ] 8b `Set[T]`.
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
  tests, PR plan). Steps 1 and 2 (the API, then the trie) are done; step 3 is
  the next item.
- [ ] 8d step 3: unboxed leaves for `List[Int]` and `List[Float]`
  ([§38.6](../future/38-value-representation.md#386-direction-use-the-static-types)
  item 1), scheduled by the owner on 2026-10-14. The trie leaves of these lists
  hold 8 bytes per item in an atomic array that the GC does not scan, and the
  checker's static type of the element decides it when the list is created, so
  the front end passes the element type to the VM. `Int` stays 64 bits. Goals:
  half the memory of a numeric list (which also offsets the extra memory of the
  trie), and faster `sort` and scans. Measure it against master and Python 3.13,
  time and peak RSS, like the step 2 table of
  [`docs/vm-benchmarks.md`](../vm-benchmarks.md). Because it needs the element
  type from the front end, it lands before the freeze of the Racket front end
  (order row 7.2.7 in the [README](README.md)). At that time, compare it with
  the owner's alternative of a doubling growable vector.
- [ ] Later (`docs/future/12-data-structures.md` §12.5), each after a real
  program needs it: tuples (then `Queue.pop`), `Bytes`, `Heap[T]`, a sorted map
  or set, a deque.

**Done when:** ranges, sets, queues and the faster lists run on both backends,
and an evaluation round shows agents use ranges without `while` workarounds.

