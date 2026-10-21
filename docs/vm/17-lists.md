## 17. Faster lists: a persistent vector behind `List`

**Status:** built (roadmap item 8d,
[`08-data-structures.md`](../roadmap/08-data-structures.md)): the API over the
flat array, the trie behind it, and the unboxed leaves of Int and Float lists
(§17.12). The code is `vm/list.c` and `vm/list_impl.h`.

### 17.1 Goal and non-goals

**Goal.** `xs = xs.push(x)` in a loop costs O(n) in total, and `xs[i]`,
`List.at` and `List.set` cost O(log32 n). The flat array copied the whole list
on every `List.append`: 160,000 pushes in a loop took 88 s
(numbers: `docs/vm-benchmarks.md`, "Lists (roadmap 8d)").

**Unchanged.**
- The `List` API and its meaning: no language change, no new builtin, no new
  opcode, no change to the `.agcb` format.
- Output, diagnostic codes and spans (`list_index` keeps `span + 2`),
  `--max-steps` step counts and every golden under `tests/fixtures/vm/`
  (§17.5).
- No program can see a mutation: lists stay immutable values (§17.6).

**Non-goals.**
- No transients and no in-place `push` on an unshared list (§17.6).
- No relaxed (RRB) nodes. `reverse`, `sort`, `Map.keys`, a `drop` that does not
  start at a multiple of 32 and a `concat` with a large right side stay O(n);
  `take`, an aligned `drop` and `concat` share leaves (§17.11).
- No empty list of its own: `[]` and the builtins that return nothing give the
  runtime's one shared empty list
  ([§34.6](../future/34-shared-small-values.md#346-as-built)).
- No cursor opcode for `for` (§17.3, `for x in xs`).

Unboxed `List[Int]` and `List[Float]` leaves are the first step of
[§38.6](../future/38-value-representation.md), built as §17.12. Every site goes
through the API of §17.4, so that step changed `vm/list.c` and little else. The
VM decides the kind of a list by itself from its values, so the front end
passes nothing.

### 17.2 Representation

A 32-way trie with a tail buffer, as in Clojure. It has the same width as the
map's HAMT (`HAMT_BITS 5`, `vm/map.c`). `struct agc_list`
(`{ len, root, shift, kind, tail[] }`) and the node types (`list_branch`: 32
child pointers; a leaf: 32 items of the list's kind, 512 bytes or 256 for
numeric kinds, §17.12) live in `vm/list.c` and the private `vm/list_impl.h`
only. Outside them the type is opaque (§17.4).

- `tail_len(n)` is 0 for n = 0, else `((n - 1) & 31) + 1`. `tail_off(n)` is
  `n - tail_len(n)`. The list object holds the last `tail_len(len)` items inline
  in `tail`, so the tail is 1 to 32 items. The trie holds the first
  `tail_off(len)` items in full leaves of 32.
- `root` is NULL exactly when `tail_off(len) == 0`, that is when `len <= 32`. A
  small list is one allocation of 24 bytes plus 16 per item (8 for a numeric
  kind).
- `shift` is canonical: the smallest multiple of 5 that is at least 5 and has
  `tail_off <= 2^(shift + 5)`; 0 when `root` is NULL. A branch at level L (L =
  `shift`, then `shift - 5`, down to 5) picks `child[(i >> L) & 31]`; a child of
  a level-5 branch is a leaf. The shift grows at len 33 (to 5), 1,057 (10),
  32,801 (15) and 1,048,609 (20). Branches exist only where a leaf exists. So a
  list has one shape, whichever way it was built (`vm/tests/list_test.c`
  compares the two ways at every boundary length).
- **Read** `get(i)`: `i >= tail_off` reads `tail[i - tail_off]`; otherwise walk
  `shift / 5` branches and read `item[i & 31]`. That is one compare up to 32
  items, then 2, 3 and 4 loads up to 1,056, 32,800 and 1,048,608 items.
- **Allocation.** The list object, branches and leaves all come from `agc_alloc`
  (`GC_MALLOC`, zeroed, scanned): they hold GC pointers or `agc_value`s, which
  can hold them (§5.3). Never `agc_alloc_atomic` for them. Atomic stays for
  temporary arrays (the sort's entries for Int and Float keys) and, since
  §17.12, for the leaves of a list of Ints or of Floats. A branch is 256 bytes
  and a boxed leaf 512, so they are small Boehm objects, served from size-class
  free lists. Under `AGC_NO_GC` (the ASan build) `agc_alloc` is `calloc` kept
  until `agc_release_all`, so a test that makes many versions holds all of them
  (§17.8).
- **Why the tail is inline.** A push then allocates one object of 24 + 16·k
  bytes, not a header plus a tail. The price is that a `set` inside the trie
  also copies the tail (at most 512 bytes). Pushes dominate real programs.
- **Operations that return a new list** never write to their input: copy the
  nodes on the path, change the copy, share the rest.
  - `append`: while `tail_len < 32`, copy the header and tail with one more
    slot. When the tail is full, copy it into a new leaf and attach the leaf:
    with no root, a root with `child[0] = leaf` and shift 5; when
    `tail_off == 2^(shift + 5)`, a new root whose `child[0]` is the old root and
    `child[1]` is a fresh chain of one-child branches down to the leaf, shift +
    5; otherwise copy the branches on the path and put the leaf in its slot,
    which is `(tail_off >> L) & 31` at level L (a missing branch on the way is a
    fresh chain). The new tail is the one new item.
  - `set(i, v)`: in the tail, copy the header and tail and write the slot. In
    the trie, also copy each branch on the path and the leaf (shift/5 branches +
    1 leaf) and write the slot in the leaf copy.
  - Costs: `append` copies at most 536 bytes, and every 32nd also one leaf and
    at most 4 branches. `set` in the trie copies at most 536 + 512 + 4·256 bytes
    (1M items). The branches add 1.6% to memory.
- **Builders** are the only code that writes to a list, and only before it is
  returned (the rule of
  [§34.3](../future/34-shared-small-values.md#343-why-it-is-safe)). A literal, a
  builtin result, a parsed or decoded list: all are built by a sized builder.
  `agc_list_builder_sized(&b, n)` allocates the final list object, with the
  final tail, and for n > 32 the whole trie at once: the branches of each level
  as one array per level, then one array of the `tail_off(n)` items that the
  leaves point into (it is allocated last, so nothing is allocated after it).
  Each leaf is a 32-item slice of that array, so a build of n items makes at
  most about 15 allocations, as the flat array did, and a push is a store.
  Attaching one separately allocated leaf per 32 items took six times as long as
  the flat array for a million items, mostly in the collections its allocations
  triggered; that is why leaves are slices (the build is also what keeps the
  memory of a million-item list at the flat array's, `docs/vm-benchmarks.md`,
  "Bulk builds and memory"). `push` writes item `count`: items below
  `tail_off(n)` go into that array, and the last `tail_len(n)` items go
  straight into the list's `tail`. `finish` returns the list, and aborts
  (`abort()`) unless both runs are full, that is unless exactly n items were
  pushed. Every node a builder writes was created by that builder after it
  began, so writing in place is safe. Pushing the wrong number is a C bug, not a
  program error. A later `set` copies the leaf it changes, so the array lives as
  long as any list still shares one of its leaves. Bulk copies (`slice`,
  `concat`, `from_array`) fill the builder a leaf at a time with `memcpy`, not
  one `push` per item. The builder holds a write pointer and the end of the
  run it fills (`next`, `stop`; the run is the new array, then the tail), so
  `push` is a compare and a store, inline in `value.h`, and so is the cursor
  read.
- **Unknown count.** `filter`, and `Task.map` (`vm/task_map.c`,
  [§27.1](../future/27-iteration-and-concurrency.md#271-taskmap), results
  arrive out of order), fill a flat staging array of the input length and call
  `agc_list_from_array(items, n)` at the end, so the result is right-sized
  ([§34.6](../future/34-shared-small-values.md#346-as-built)).

### 17.3 Operations

Every site uses the API of §17.4. "Cursor" means `agc_list_cursor`: one descent
per leaf, O(1) per item inside it. List the sites with
`rg -n 'agc_list_(get|len|builder|cursor|from_array)' vm`.

- **`LIST`** (a literal; above 255 items, chunks joined by `List.concat`):
  `agc_list_from_array` over the register window. O(c), `c` a 16-bit operand.
- **`LIST_LEN`, `List.size`:** `agc_list_len`, O(1).
- **`LIST_GET`, `xs[i]`, `List.at`:** the bounds check on `agc_list_len` keeps
  its message, code and span, then `agc_list_get`. O(log32 n).
- **`for x in xs`:** `LIST_LEN` once, `LIST_GET` per item, so O(n log32 n)
  (at most 4 loads per item at 1M items). A cursor opcode would save them but is
  a new opcode and an `.agcb` change.
- **`List.map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`:** the
  native frame keeps a cursor over the input and the current item (`filter`
  needs it after the call). `map` and the `sort_by` keys use a sized builder of
  n; `filter` stages and calls `from_array`. The input list stays in `st->list`
  for `sort_by`. O(n); one cursor step and one turn-cost unit per callback.
- **`agc_sort_by_keys`, `List.sort`, `Dir.list`:** one flat array of
  `(key, index)` entries made once, a check for keys that never decrease (the
  input is the result) or all fall (one `reverse`), else a bottom-up merge of
  the entries; the result by a sized builder that reads the items with
  `list_get` (§17.11). O(n log n), O(n) when the keys are in order, plus O(n)
  temporary memory; the charge `n * rounds` is unchanged.
- **`agc_value_units`:** `agc_list_len`, O(1); every size cost keeps its number
  (§17.5).
- **`List.append`, `push`:** `agc_list_append`, O(1) amortized, O(log32 n)
  worst. **`List.set`:** `agc_list_set`, O(log32 n).
- **`List.concat`:** b empty gives a; a empty gives b; `b.len <= 32` appends b's
  items to a (shares a's trie); else a builder whose first leaves are a's own,
  filled with `memcpy` from a's tail then b (§17.11). O(b.len + a.len / 32).
- **`List.take`, `List.drop`:** `agc_list_slice(l, from, count)`: `take(k >=
  len)` and `drop(0)` return the input; `take(k)` with `k > tail_off` shares
  `root` and `shift` and copies only the tail; from a multiple of 32, with
  `count` at least half of `len`, the result's leaves are the source's leaves
  and only the branches and the tail are new (§17.11); else a sized builder
  filled leaf by leaf with `memcpy`, starting at `from`. O(count / 32) when it
  shares, else O(count): without relaxed nodes a shifted tail cannot share
  leaves.
- **`List.reverse`:** `agc_list_reverse`, a sized builder written directly from
  the leaves, last to first. O(n).
- **`List.repeat`:** `agc_list_repeat`: one leaf filled with the value, shared
  by every slot of the trie, and one full and one last branch per level. O(log32
  n) in time and memory. **`Range.to_a`, `Map.keys`, `Map.values`:** sized
  builder, O(n).
- **Builtins that fill a list of known size** (`System.args`, `IO.read_bytes`,
  stream bytes, `File.read_bytes`, `Dir.list`, HTTP header lists,
  `String.split`): a sized builder with the known count. O(n).
- **Builtins that scan a list** (`String.join`, `Path.join`,
  `String.from_bytes`, `agc_byte_list`, process arguments, header scans,
  `Test.run` and its helpers): one cursor per pass, or `agc_list_get` by index.
- **`agc_equal`:** two cursors, pushed in the same order as before, so the first
  mismatch and the units charged are the same. O(n).
- **`inspect`, `to_text`, JSON encode, `JSON.from`, `JSON.at`:** `agc_list_len`
  and `agc_list_get` per item, O(n log32 n). These walkers keep one small frame
  per nesting level, because the tests nest 1,000,000 deep
  (`docs/vm/12-testing-and-pr-plan.md` §12.1, "Depth"); a cursor in each frame
  would add 40 bytes to every level.
- **JSON array builders** (`agc_json_container`, `agc_json_store`,
  `agc_json_finish`, used by the parser, `JSON.from` and the schema): the
  container takes an `agc_list_builder *`; `store` pushes (the calls come in
  order k = 0, 1, ...); `finish` finishes the builder and sets `scalar`; an
  array with n = 0 finishes at once. `JSON.list` returns that same list, so a
  Json array node must hold a finished list before it is returned.
- **Typed decode** (`vm/json_typed.c`): `decode_frame` holds a builder and
  reads the JSON array with `agc_list_get`. `frame_value` is called before the
  children are decoded, so the list must be finished only after them, or at once
  when n = 0.

Not call sites: the loader (§17.7); `Channel`, which holds values in a ring and
no list; the stepper protocol (`File.each_line` installs an `agc_stepper` and no
list). A new builtin that returns a list uses a sized builder; `Task.map`
follows §17.2, "Unknown count".

### 17.4 The C API

In `vm/value.h`, next to the map functions, implemented in `vm/list.c`.
`list.c` is core, like `map.c` (`docs/vm/15-layers.md` §15.1): it includes
`core.h`, calls only `agc_alloc` and the size helpers, and takes no `agc_vm` (so
it adds nothing to the port). The declarations are in `vm/value.h`
(`rg 'agc_list_' vm/value.h`): `len`, `get`, a sized builder (`builder_sized`,
`builder_push`, `builder_finish`), `from_array`, `to_array`, a cursor
(`cursor_begin`, `cursor_next`), `append`, `set`, `slice`, `concat`, `reverse`
and `repeat`.

- `agc_list_get` and `agc_list_set` need `i < len`. The caller checks and fails
  with the program's diagnostic, as `LIST_GET` and `list_index` do; a bad index
  inside the API aborts. `agc_list_to_array` fills `len` slots that the caller
  allocated with `agc_alloc` (scanned memory).
- `agc_list_builder` and `agc_list_cursor` are in `value.h` because callers put
  them on the stack. Their fields are private by convention. They live on the C
  stack or in `agc_alloc` memory (a native frame, a parse or decode frame),
  never in `malloc` memory, in an atomic object or in a `_Thread_local` (§5.3).
  A cursor's `chunk` points inside a leaf or the tail; the build keeps interior
  pointers, so the object stays alive.
- `agc_list` is an incomplete type outside `list.c` and `vm/list_impl.h` (which
  only `list.c`, `interp.c` and `vm/tests/list_test.c` include, checked by `make
  vm-layers`), so a site that reads the layout is a compile error.

### 17.5 Turn costs and step counts

**Step counts do not change.** Steps are charged by `STEP` instructions, which
the lowerer emits (`lower-list` starts with one) and the interpreter counts. The
only natives that call `count_step` are the counting ones (`Range.each`,
`times`, `upto`, `downto`) and steppers, not the list natives. A builtin
charges `agc_charge`, which adds to the task's turn cost; `apply_cost` lowers
only `turn_left`, never `steps_left`
([§10.2.1](10-io-scheduler.md): "Turn costs never touch it"). The list natives
charge one turn unit per callback. The list code changes no opcode, no
callback count and no `STEP` the lowerer emits, so no count moves. The gate is
the goldens: each `.expected` holds `steps`, and the sweep fails when a run
takes more than the golden plus `max(10, 10%)`. A diff in an `.expected` from a
list change is a bug.

**Turn costs.** `AGC_COST_SIZE` charges `units(args)` before the call and
`units(result)` after, and `agc_value_units` of a list is `len`. The rule is
one unit per item copied or scanned, and "constant work charges nothing"
([§10.2.1](10-io-scheduler.md)).

- `size`, `at`, `LIST_LEN`, `LIST_GET`: 0.
- `take`, `drop`, `reverse`, `repeat`, `Range.to_a`, `String.split`, `join`,
  `from_bytes`, `Map.keys`, `values`, `Dir.list`, `read_bytes`, header lists:
  `AGC_COST_SIZE` (args + result), still O(n) work.
- `sort`, `sort_by`: `n * ceil(log2 n)` inside `agc_sort_by_keys`.
- `map`, `filter`, `reduce`, `each`, `any?`, `all?`: 1 per callback.
- `append`, `set`: 0 (`AGC_COST_NONE`).
- `concat`: `AGC_COST_NONE`; 0 when `b.len <= 32`; else `agc_charge(vm, 2 * (a +
  b))` in the builtin.

The work of `append` and `set` is bounded: one tail of at most 32 items and one
path of at most 12 nodes (§17.2), so the rule gives 0. Charging 2n would make a
task yield after every push once its list passes 1,000 items (`AGC_TURN_STEPS`
is 2,000). The cost moves only the point where a task yields. Output and
`--max-steps` do not depend on it, but a golden with two tasks and a big push
loop could print in another order. If any golden changes, find the cause first;
do not run `make goldens` to hide it. `make vm-latency`, run alone, must still
pass its 250 ms limit.

### 17.6 Multicore and invariants

- **Values are immutable after they are returned**
  ([§10.2.3](10-io-multicore.md), "Values are immutable";
  [§16.7](16-architecture.md#167-sharing)). Tasks on different schedulers share
  lists with no lock and no copy. The API gives that: `append`, `set`, `slice`
  and `concat` never write to their input; a builder writes only nodes it made,
  before `finish`. After `finish` (or after `append` or `set` returns) nothing
  is written again: no cached cursor or last-leaf in the list object, no
  counter, no lazy field. Such a cache would be a write after publication, a
  data race once N > 1.
- **No transients.** A builder lives in one C frame or in a task-private object
  (`agc_native`, a parse, decode or walk frame) that no value refers to until
  `finish`. A task runs on one scheduler at a time, and the hand-off between
  turns is already ordered by the run queue and the park and wake protocol
  (§10.2.3). A task cancelled halfway leaves a builder as garbage. An in-place
  `push` on a list proven unshared is excluded: §10.2.3 requires such a change
  to be proven unshared or made atomic, and the persistent `append` is fast
  enough (§17.8). If the gate there fails, that is a new design, not a patch.
- **Entry rule (§14.6).** No new subsystem and no new way to wait, time out,
  cancel, end or own a handle: this is a data structure inside the value layer.
  `list.c` has no mutable global (`make vm-lint` enforces it).
- **Sharing between versions is invisible.** There is no object identity for
  lists (`==` does not apply to them), and nothing prints an address.

### 17.7 Loader and untrusted input

- A `.agcb` has no list constants. Constant kinds are 0 to 6: Void, Nil, false,
  true, Int, Float, String. Lists exist only as the result of `LIST`, a builtin
  or the runtime. The loader checks the registers of `LIST_LEN` and `LIST_GET`
  and the register window of `LIST`.
- The limits stay as they are: 1,048,576 items for `List.repeat` and
  `Range.to_a` (`AGC_MAX_LIST_COUNT`), 1 MiB for `IO.read_bytes` and for byte
  writes (`agc_byte_list`). `append`, `concat` and nested lists have no limit
  and get none: `--max-steps` bounds instructions, not memory
  ([§1](README.md#1-overview)), and a hostile file can reach the out-of-memory
  exit 70.
- Size arithmetic uses the checked helpers (§5.2): `agc_size_add`,
  `agc_size_mul` for every allocation size. `len` cannot pass `SIZE_MAX / 16`,
  because `agc_size_mul(len, 16)` ends in the out-of-memory exit first, so
  `shift` stays at 55 or less and `1 << (shift + 5)` fits.
- No value-driven C recursion (§7.3): `get`, `set`, `append`, the builder and
  the cursor are loops over at most 11 levels. Recursion over the levels is
  allowed if marked as `map.c` does; loops are preferred. Nested lists are
  walked by the explicit-stack code of `text.c`, `equal.c` and `json*.c`.
- The fuzzer (`agc_fuzz_one`) frees every block after each mutant under
  `AGC_NO_GC` and stops at the allocation limit. Nodes use `agc_alloc` only, so
  both keep working. Each node counts `BLOCK_COST` (64 bytes) in that limit, so
  list-heavy mutants reach it sooner; that is fine.

### 17.8 Test plan

Rules: `AGENTS.md` (C tests are plain-assert files in `vm/tests/`; goldens for
features; no new framework).

- **C unit tests, `vm/tests/list_test.c`** (run by `make vm-test`, the ASan run
  and `make vm-gc-stress`). Lengths 0, 1, 2, 31, 32, 33, 63, 64, 65, 1,023,
  1,024, 1,025, 1,056, 1,057, 32,768, 32,769 (32·32·32 + 1), 32,800, 32,801,
  and 1,048,576, 1,048,608, 1,048,609. For each length n:
  - build with the builder and, up to 33,000 items, with repeated `append`;
    compare `len`, `get` for every index, the cursor order, `agc_list_to_array`,
    and the shape (root NULL exactly when n <= 32, shift 5, 10, 15, 20 at the
    boundaries of §17.2). The million lengths use the builder only, then one
    `append` and one `set`: under `AGC_NO_GC` every version of an append-built
    list stays allocated until `agc_release_all`. Under `AGC_GC_STRESS` the cap
    is 1,000 items, as the depth tests do.
  - persistence: from one old list make two `append` results and `set` results
    at 0, 31, 32, `tail_off - 1`, `tail_off` and n - 1; the old list is
    unchanged in full, and each new list differs from it only where it should.
    Keep all versions of a 5,000-item append-built list and check them at the
    end (like `half` in `vm/tests/map_test.c`).
  - `slice` (take and drop) at 0, 1, 31, 32, 33, n - 1 and n; `concat` with
    `b.len` 0, 1, 32, 33 and an empty a; `reverse`; `agc_debug` of a 100-item
    list.
  - `agc_list_repeat`: the shape and every item, then `set` at 0, 31, 32,
    `tail_off - 1`, `tail_off` and n - 1, `append`, `reverse` and `slice`: the
    repeated list is unchanged and the other items still read the value (the
    leaf and the branches are shared, so a `set` that wrote in place would show
    here).
- **Goldens.** Every `tests/fixtures/vm/*.expected` stays byte-identical,
  `steps` included. `tests/fixtures/vm/list-vector.agc` covers lists at the trie
  boundaries (31, 32, 33, 1,056, 1,057 items by `push`, one of 32,769 from
  `(0...32769).to_a`), then `set`, `take`, `drop`, `concat`, `reverse`, `sort`,
  `map`, `filter`, `for`, an index at the boundary and out of range, and old
  versions printed after new ones were made.
- **Benchmark gates** (`make bench`; numbers in `docs/vm-benchmarks.md`;
  programs `benchmarks/programs/list-build.agc` and `list-bulk.agc`):
  - 160,000 pushes in a loop run in under 1 s, and the time of 2n pushes is
    under 2.5 times the time of n.
  - Bulk builds (`List.repeat`, `Range.to_a`, `reverse`, `take`, `drop`, a big
    `concat`, `join`, `String.split` and `sort` over 60,000 to 500,000 items)
    take no more than 1.3 times the flat array's time. A builder allocates its
    trie in a few big blocks, not one node per push (§17.2); a GC-stress test
    that builds a 1 MB string through `List.repeat` ran out of its time window
    with the per-leaf version.
  - No other benchmark is slower than 2% (the measurement gate of the
    shared-value work uses the same figure). If a `for` or `at` heavy program
    is, the first fix is an inline fast path for `agc_list_get` and
    `agc_list_len`, not a change of the design: `struct agc_list` and the inline
    versions are in the private `vm/list_impl.h`, which only `list.c` and
    `interp.c` (`LIST_LEN`, `LIST_GET`) include. Before blaming the list code
    for a loop-bound slowdown, time the program with more than one link layout
    (pad a file with unused functions): the same interpreter ran 15 to 20%
    apart on loops with no list operation, from the alignment of `agc_run_turn`
    alone.
  - `maze-bfs` is not expected to move (its lists hold at most 4 items, and
    `Map.delete` is not what bounds it); it is a no-regression check. Report
    peak RSS; a growth above 10% needs an explanation.

### 17.10 Decisions

Decided on 2026-10-14, when this design was merged:

1. **Turn cost of `append`, `set` and small `concat`:** 0. Their work is
   bounded (§17.5), and the rule of §10.2.1 charges nothing for constant work.
2. **The 8d benchmark claim:** `list-build` is the gate; `maze-bfs` stays a
   no-regression check.
3. **`take`, `drop` and a large `concat` stay O(n)** (no RRB). `Queue[T]` (8c)
   is the answer for FIFO use. §17.11 keeps this for a `drop` that does not
   start at a multiple of 32 and for the right side of a `concat`, and makes
   `take`, an aligned `drop` and the left side of a `concat` share leaves.
4. **Two PRs, not one:** first the API over the flat array with every call site
   migrated and no behavior change (the compiler checks it: the opaque type
   turns a missed site into a compile error, and the goldens plus the new
   fixture show nothing changed), then the trie behind the API (the tests of
   the first PR run unchanged against it, so they are a real oracle). A
   regression is either in a migrated site or in the trie.

### 17.11 Bulk operations after the trie

A follow-up to the trie, found by timing each operation on a million items
against the flat array and CPython 3.13 (`docs/vm-benchmarks.md`, "Bulk
operations after the trie").

- **What cost the time.** The trie itself was cheap: a reverse into a fresh
  array takes 3 ms. The rest of an operation on a million items was the
  collector (a collection scans every live array of 16-byte values, about 8 ms
  per 16 MB allocated here) and, for `sort` and `split`, work per item:
  `agc_sort_by_keys` called four checked accessors per comparison and read the
  keys through an index array, and `split("")` allocated one 32-byte String per
  character.
- **Shared leaves.** `builder_begin` can take the first leaves of a list from
  another list (a source list, the index of its first leaf and how many
  leaves) instead of allocating them; only the branches (1.6% of the items)
  are rebuilt, in one array per level, and the new items go to one array as
  before. `take(k)`,
  `drop(k)` for `k` a multiple of 32, and `concat(a, b)` (a's leaves, then a's
  tail and b copied) use it. A leaf is a slice of the array of the build that
  made it, so a list that shares a leaf keeps that array, and every item in it,
  alive. To bound that, `slice` shares only when `count` is at least half of
  `len`; a smaller slice, or one that starts inside a leaf, copies. `concat`
  keeps all of a, so it loses nothing. A chain of halving slices can still hold
  the first array.
- **Sort.** The keys are read once (`agc_as_int`, `agc_as_float` or
  `agc_as_string`, which also checks every key's type) into an array of
  `(key, index)` entries, 16 bytes each, atomic for Int and Float keys. An Int
  becomes `i ^ 2^63` and a Float its IEEE bits turned into a total order (`-0.0`
  as `0.0`, every NaN as the largest key), so one unsigned compare orders both
  as `key_less` did; a String entry holds the pointer and compares with
  `memcmp`. One scan finds keys that never decrease (the sort returns the input)
  or that strictly decrease (one `reverse`: equal keys are never reversed, so
  the sort stays stable). Otherwise a bottom-up merge of the entries, then a
  sized builder reads the items with `list_get`. The charge `n * ceil(log2 n)`
  is unchanged.
- **Split.** `agc_runtime` holds the 128 one-character ASCII Strings, made in
  `agc_vm_init`; `split` returns them for a one-byte ASCII piece. Strings have
  no identity ([§34.3](../future/34-shared-small-values.md#343-why-it-is-safe)),
  so a program cannot tell. A million-character `split("")` allocates no
  String.
- **Cursor and builder.** `agc_list_builder_push` and `agc_list_cursor_next`
  are inline in `value.h` (`agc_list_builder_more` and
  `agc_list_cursor_fill` take the slow path), so `map`, `join`, `Range.to_a` and
  the JSON builders do not call into `list.c` per item.
- **Tried and left out.** A chunked staging area for `filter` (leaves filled
  one at a time, then linked into the trie) saved 4% on a filter that keeps
  half and cost 3% on one that keeps everything, so `filter` still stages in a
  flat array. `map` and `filter` spend 70 to 100 ns per item in the callback
  (frame, registers, turn cost); the list is about 10% of it.

### 17.12 Unboxed numeric leaves

Step 3 of roadmap item 8d
([§38.6](../future/38-value-representation.md), item 1). The owner decided on
2026-10-15 that the VM decides, not the front end. The first plan had the
checker's element type reach the VM, which needs a new operand or a new builtin
argument, a loader change, and a type for every list that C code makes (JSON,
`String.split`, `Map.keys`, the byte lists of files and streams). The static
types already say that a `List[Int]` holds only Ints, so the list code looks at
the values it is given. There is no change to the front end, the lowering, the
bytecode format or the loader, and `Int` stays 64 bits.

**Kind.** A list has a kind, a `uint32_t` after `shift` that takes the padding
(the header stays 24 bytes):

- 0: boxed. The items are 16-byte `agc_value`s (§17.2).
- `AGC_T_INT` or `AGC_T_FLOAT`: every item has that tag. A leaf and the tail
  hold the 8 raw bytes of each item and no tag. A leaf is 256 bytes, not 512.

An empty list has kind 0, however it was made: it has no kind, and its first
item decides. In a valid program a list never changes kind after that, because
a `List[T]` has one element type (there is no `Any`, and `Nil` is not a
wildcard). Only a hostile `.agcb` can mix.

- **Operation:** sized builder
  - **Kind of the result:** the tag of the first item pushed (0 unless Int or
    Float); the list object is allocated at that push, since its size depends on
    the kind

- **Operation:** `agc_list_from_array` (a literal, `filter`)
  - **Kind of the result:** the tag of the first item when all items have it

- **Operation:** `append`
  - **Kind of the result:** the kind of the list; of the item for an empty list

- **Operation:** `set`, `slice`, `reverse`
  - **Kind of the result:** the kind of the list

- **Operation:** `repeat`
  - **Kind of the result:** the tag of the value

- **Operation:** `concat`
  - **Kind of the result:** the kind of both lists when equal; an empty side
    gives the other list as is

**Reads and writes.** `list_at` and `agc_list_trie_get` rebuild the value from
the kind: the tag is the kind and the payload is the 8 bytes. That is one more
compare, predictable because a list has one kind. The cursor and the inline
`agc_list_builder_push` of `value.h` carry the kind in their structs and branch
the same way. Two details keep the boxed code as fast as it was. The stores of
`push` are typed (`uint64_t` and `agc_value`): a `char *` store may alias the
builder's own fields, so the compiler reloaded `next`, `stop` and `kind` for
every item and `Range.to_a` took 25% longer. And a value is built from its two
8-byte words (`agc_word_value`, with `agc_value_word` the other way, both in
`value.h`), because the field-by-field form made the compiler merge the boxed
and the numeric path with masks.

**Memory and the GC.**

- The leaf blocks of a numeric list (the block of a build, a copied leaf, the
  leaf of `repeat`) come from `agc_alloc_atomic`: the collector does not scan
  them, and under Boehm they are not zeroed. Every word is written before the
  list is returned: `finish` aborts unless the builder is full, and a leaf copy
  is always given 32 items.
- Branches and the list object stay `agc_alloc`: the object holds `root`. A
  numeric tail (at most 256 bytes) is part of that object and is scanned, so an
  Int that looks like a pointer can keep garbage alive for as long as its list
  lives. Boehm already accepts that for the stack and the registers.
- A leaf is a slice of a block and the branches hold interior pointers into it.
  `GC_set_all_interior_pointers(1)` keeps the block alive. `list_test.c` forces
  collections while only such pointers refer to an atomic block, for each kind.
- The size bound of §17.7 is still checked on 16-byte items, for every kind, so
  `1 << (shift + 5)` fits.

**Mixing kinds.** The checker does not allow it, but a `.agcb` can ask for it:
`List.set` of a String into an Int list, a `map` block that returns an Int and
then a String, `List.concat` of an Int list and a Float list. The rule is that
no code reads an item as another kind and that the kind of a returned list never
changes. Where kinds meet, the result is boxed, and no operation fails:

- The builder: a push whose tag differs from the kind of a numeric builder
  replaces the builder by a boxed one of the same size that holds the items
  written so far (read back as values). It costs O(n) once. A boxed builder
  never becomes numeric. A builder that shares leaves (`slice`, `concat`) is
  only made for lists of one kind, so it never converts.
- `append` and `set` of a value of another tag onto a numeric list copy the list
  to boxed first, then do the operation. The input list is unchanged.
- `concat` of two non-empty lists of different kinds fills one boxed builder
  from both and shares nothing.
- `from_array` starts over as boxed at the first tag that differs.
- `sort` of such a list takes the boxed path, which checks the type of every key
  (`agc_as_int`, `agc_as_float`) and fails as it did before.

**Sort.** `agc_sort_by_keys` sorts `(key, item)` entries. For a boxed list the
item is the index. When a list sorts by itself (`List.sort`) and has a numeric
kind, the item is the raw 8 bytes of the number, and the result is built by
pushing the sorted words, with no read through the trie by index. The order
keys, the checks for keys that never decrease or strictly decrease, and the
merge are the same, so the order is the same: stable, `-0.0` equal to `0.0`,
every NaN last and equal. Sorting the 8-byte words directly with a second merge
was no faster for Float, because the order key had to be recomputed at every
compare, and it was a second copy of the merge, so it was dropped. `sort_by`
and the sort of Strings are unchanged.

**Costs.** A numeric item takes 8 bytes instead of 16; the branches are still
about 1.6% of that, and a list of at most 32 items is 24 + 8k bytes. A builder
is 48 bytes: the final length and the kind. Step counts, turn costs (one unit
per item) and the `.agcb` format do not change. The numbers are in
[`docs/vm-benchmarks.md`](../vm-benchmarks.md), "Unboxed numeric leaves".

**Left as it was.** `filter` still stages `agc_value`s in a flat array before
`from_array` packs the result. Registers, calls, structs, maps and Json values
stay `agc_value`.

**Tests.** `vm/tests/list_test.c` runs the whole API three times, with Int,
Float and boxed items, over the lengths of §17.8 (the million lengths for Int
only). It also builds mixed lists by hand through the C API at every boundary of
the block and the tail (builder, `append`, `set`, `concat`, `from_array`),
checks that an empty list has no kind, that `-0.0`, NaN and the limits of Int
survive each operation, and that leaves shared by `take`, `drop` and `concat`
stay correct when the other list has another kind. The golden
`tests/fixtures/vm/list-unboxed.agc` covers the same behavior end to end.
