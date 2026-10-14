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
  loop took about a minute; `docs/vm-benchmarks.md`). Done: `push`, `set` and
  indexing are near constant time, and the same loop takes 0.08 s. Order step
  8: after 7h processes and network, and before any instruction-dispatch
  micro-optimization (7g). Unboxed `List[Int]` and `List[Float]` leaves are the
  first step of
  [§38](../future/38-value-representation.md#386-direction-use-the-static-types),
  if the benchmarks ask for it. Design:
  [`docs/vm/17-lists.md`](../vm/17-lists.md) (representation, C API, costs,
  tests, PR plan).
- [ ] Later (`docs/future/12-data-structures.md` §12.5), each after a real
  program needs it: tuples (then `Queue.pop`), `Bytes`, `Heap[T]`, a sorted map
  or set, a deque.

**Done when:** ranges, sets, queues and the faster lists run on both backends,
and an evaluation round shows agents use ranges without `while` workarounds.

