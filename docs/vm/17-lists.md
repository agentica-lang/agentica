## 17. Faster lists: a persistent vector behind `List`

**Status:** built (roadmap item 8d,
[`08-data-structures.md`](../roadmap/08-data-structures.md)): the API over the
flat array, the trie behind it, and the unboxed leaves of Int and Float lists
(§17.12). The code is `vm/list.c` and `vm/list_impl.h`.

### 17.1 Goal and non-goals

**Goal.** `xs = xs.push(x)` in a loop costs O(n) in total, and `xs[i]`,
`List.at` and `List.set` cost O(log32 n). The flat array copied the whole list
on every `List.append` (numbers: `docs/vm-benchmarks.md`, "Lists (roadmap 8d)").

**Unchanged.** The `List` API and its meaning: no language change, builtin,
opcode or `.agcb` change. Output, diagnostic codes and spans (`list_index`
keeps `span + 2`), `--max-steps` step counts and every golden under
`tests/fixtures/vm/` (§17.5). No program can see a mutation: lists stay
immutable values (§17.6).

**Non-goals.**
- No transients and no in-place `push` on an unshared list (§17.6).
- No relaxed (RRB) nodes. `reverse`, `sort`, `Map.keys`, a `drop` that does not
  start at a multiple of 32 and a `concat` with a large right side stay O(n);
  `take`, an aligned `drop` and `concat` share leaves (§17.11).
- No empty list of its own: `[]` and the builtins that return nothing give the
  runtime's one shared empty list
  ([§34.6](../future/34-shared-small-values.md#346-as-built)).
- No cursor opcode for `for` (§17.3).

Unboxed `List[Int]` and `List[Float]` leaves are the first step of
[§38.6](../future/38-value-representation.md), built as §17.12. Every site goes
through the API of §17.4, so that step changed `vm/list.c` and little else. The
VM decides the kind of a list from its values; the front end passes nothing.

### 17.2 Representation

A 32-way trie with a tail buffer, as in Clojure. The width is that of the map's
HAMT (`HAMT_BITS 5`, `vm/map.c`). `struct agc_list` (`{ len, root, shift, kind,
tail[] }`) and the node types live in `vm/list.c` and the private
`vm/list_impl.h`; outside them the type is opaque (§17.4). A branch is 32 child
pointers. A leaf is 32 items of the list's kind (512 bytes, or 256 for numeric
kinds, §17.12).

- `tail_len(n)` is 0 for n = 0, else `((n - 1) & 31) + 1`; `tail_off(n)` is
  `n - tail_len(n)`.
- The list object holds the last `tail_len(len)` items inline in `tail`, so the
  tail has 1 to 32 items (none for an empty list). The trie holds the first
  `tail_off(len)` items in full leaves of 32. `root` is NULL exactly when `len
  <= 32`.
- `shift` is canonical: the smallest multiple of 5, at least 5, with `tail_off
  <= 2^(shift + 5)`; 0 when `root` is NULL. A branch at level L picks `child[(i
  >> L) & 31]`. The shift grows at len 33 (to 5), 1,057 (10), 32,801 (15) and
  1,048,609 (20). Branches exist only where a leaf exists, so a list has one
  shape whichever way it was built (`vm/tests/list_test.c` checks both ways at
  every boundary).
- **Allocation.** The list object, branches and leaves come from `agc_alloc`
  (`GC_MALLOC`, zeroed, scanned): they hold GC pointers or `agc_value`s (§5.3).
  Never `agc_alloc_atomic` for them. Atomic stays for temporary arrays and,
  since §17.12, for the leaves of numeric lists. Under `AGC_NO_GC` (the ASan
  build) `agc_alloc` is `calloc`, kept until `agc_release_all`, so a test that
  makes many versions holds all of them (§17.8).
- **Why the tail is inline.** A push allocates one object, not a header plus a
  tail. The price is that a `set` in the trie also copies the tail (at most 512
  bytes). Pushes dominate real programs.
- **New lists never write to their input.** `append` copies the path it changes
  and shares the rest. With a full tail, the tail becomes a new leaf, and the
  trie grows a root or a chain of one-child branches when `tail_off` reaches
  `2^(shift + 5)`. `set` copies the tail, or the branches and the leaf on its
  path. `append` copies at most 536 bytes, and every 32nd push also a leaf and
  at most 4 branches; a trie `set` copies at most 536 + 512 + 4·256 bytes (1M
  items). The branches add 1.6% to memory.
- **Builders** are the only code that writes to a list, and only before it is
  returned (the rule of
  [§34.3](../future/34-shared-small-values.md#343-why-it-is-safe)).
  `agc_list_builder_sized(&b, n)` allocates the final list object and, for n >
  32, the whole trie at once: one array per branch level, then one array of the
  `tail_off(n)` items. The leaves are 32-item slices of that array, so a build
  makes about 15 allocations for a million items. Separate leaves took six times
  as long as the flat array for a million items, which is why leaves are slices
  (`docs/vm-benchmarks.md`, "Bulk builds and memory"). `finish` aborts unless
  exactly n items were pushed; that is a C bug, not a program error. Every node
  a builder writes was created by that builder after it began, so writing in
  place is safe. A later `set` copies the leaf it changes, so the array lives as
  long as a list shares one of its leaves. Bulk copies fill the builder a leaf
  at a time with `memcpy`.
- **Unknown count.** `filter`, and `Task.map` (`vm/task_map.c`,
  [§27.1](../future/27-iteration-and-concurrency.md#271-taskmap), results arrive
  out of order), fill a flat staging array and call `agc_list_from_array(items,
  n)` at the end, so the result is right-sized
  ([§34.6](../future/34-shared-small-values.md#346-as-built)).

### 17.3 Operations

Every site uses the API of §17.4. "Cursor" means `agc_list_cursor`: one descent
per leaf, O(1) per item inside it. The call sites are listed by
`rg -n 'agc_list_(get|len|builder|cursor|from_array)' vm`.

- **`LIST`** (above 255 items, chunks are joined by `List.concat`):
  `agc_list_from_array`, O(c).
- **`LIST_LEN`, `List.size`:** O(1). **`LIST_GET`, `xs[i]`, `List.at`:** O(log32
  n). The bounds check keeps its message, code and span.
- **`for x in xs`:** `LIST_LEN` once and `LIST_GET` per item, so O(n log32 n). A
  cursor opcode would save that, but it is a new opcode and an `.agcb` change.
- **`map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`:** the native
  frame keeps a cursor over the input and the current item (`filter` needs it
  after the call). `map` and the `sort_by` keys use a sized builder; `filter`
  stages and calls `from_array`. O(n), with one turn-cost unit per callback.
- **`agc_sort_by_keys` (`List.sort`, `sort_by`, `Dir.list`):** one flat array of
  `(key, index)` entries. If the keys never decrease, the input is the result;
  if they all fall, one `reverse`; else a bottom-up merge. The result comes from
  a sized builder that reads the items (§17.11). O(n log n), O(n) for keys
  already in order, plus O(n) temporary memory.
- **`append`, `push`:** O(1) amortized, O(log32 n) worst. **`set`:** O(log32 n).
- **`List.concat`:** an empty side gives the other list. If `b.len <= 32`, b's
  items are appended to a, which shares its trie; else a builder takes a's
  leaves and copies a's tail and b (§17.11). O(b.len + a.len / 32).
- **`take`, `drop`:** `agc_list_slice`. `take(k >= len)` and `drop(0)` return
  the input. A result that shares leaves (the start is a multiple of 32 and at
  least half of the list is kept) makes only the branches and the tail new; any
  other result is a sized builder that copies leaf by leaf. Without relaxed
  nodes a shifted tail cannot share leaves.
- **`reverse`:** a sized builder, O(n). **`repeat`:** one leaf shared by every
  slot, and one full and one last branch per level: O(log32 n) in time and
  memory. **`Range.to_a`, `Map.keys`, `Map.values`:** sized builder, O(n).
- **Other builtins:** one that builds a list of known size uses a sized builder
  with that count; one that scans a list uses a cursor per pass or
  `agc_list_get` by index.
- **`agc_equal`:** two cursors, in the same order as before, so the first
  mismatch and the units charged do not change.
- **`inspect`, `to_text`, JSON encode, `JSON.from`, `JSON.at`:** `agc_list_len`
  and `agc_list_get` per item. They keep one small frame per nesting level,
  because the depth tests nest 1,000,000 deep (`vm/tests/json_test.c`); a cursor
  in each frame would add 40 bytes to every level.
- **JSON array builders** (`agc_json_container`, `agc_json_store`,
  `agc_json_finish`): the container takes an `agc_list_builder *`; `store`
  pushes (the calls come in order k = 0, 1, ...); `finish` finishes the builder
  and sets `scalar`; an array with n = 0 finishes at once. `JSON.list` returns
  that same list, so a Json array node must hold a finished list before it is
  returned.
- **Typed decode** (`vm/json_typed.c`): `decode_frame` holds a builder and reads
  the JSON array with `agc_list_get`. `frame_value` runs before the children are
  decoded, so the list is finished only after them, or at once when n = 0.

Not call sites: the loader (§17.7), `Channel` (a ring of values, no list) and
the stepper protocol. A new builtin that returns a list uses a sized builder;
`Task.map` follows §17.2, "Unknown count".

### 17.4 The C API

In `vm/value.h`, next to the map functions, implemented in `vm/list.c`. The
declarations are listed by `rg 'agc_list_' vm/value.h`. `list.c` is core, like
`map.c` (`docs/vm/15-layers.md` §15.1): it calls only `agc_alloc` and the size
helpers, and takes no `agc_vm`.

- `agc_list_get` and `agc_list_set` need `i < len`. The caller checks and fails
  with the program's diagnostic, as `LIST_GET` and `list_index` do; a bad index
  inside the API aborts. `agc_list_to_array` fills `len` slots that the caller
  allocated with `agc_alloc`.
- `agc_list_builder` and `agc_list_cursor` are in `value.h` because callers put
  them on the stack. Their fields are private. They live on the C stack or in
  `agc_alloc` memory, never in `malloc` memory, an atomic object or a
  `_Thread_local` (§5.3). A cursor's `chunk` points inside a leaf or the tail;
  the build keeps interior pointers, so the object stays alive.
- `agc_list` is an incomplete type outside `list.c` and `vm/list_impl.h` (only
  `list.c`, `interp.c` and `vm/tests/list_test.c` include the latter; `make
  vm-layers` checks it), so a site that reads the layout does not compile.

### 17.5 Turn costs and step counts

**Step counts do not change.** Steps are charged by `STEP` instructions, which
the lowerer emits (`lower_list` in `compiler/lower/lower_data.agc` starts with
one). The list natives do not call `count_step`. A builtin charges `agc_charge`,
which adds to the task's turn cost; `apply_cost` lowers only `turn_left`, never
`steps_left` ([§10.2.1](10-io-scheduler.md): "Turn costs never touch it"). The
goldens are the gate: each `.expected` holds `steps`, and the sweep fails when a
run takes more than the golden plus `max(10, 10%)` (`tests/vm_diff_support.py`).
A diff in an `.expected` from a list change is a bug.

**Turn costs.** `AGC_COST_SIZE` charges the units of the arguments before the
call and of the result after: one unit per item copied or scanned. "Constant
work charges nothing" ([§10.2.1](10-io-scheduler.md)). So `size`, `at`,
`LIST_LEN` and `LIST_GET` charge 0; the builtins that copy their input (`take`,
`drop`, `reverse`, `repeat`, `Range.to_a`, `split`, `join`, `Map.keys`, and the
header lists) charge their size; `sort` charges `n * ceil(log2 n)`; each
callback charges 1; `append` and `set` charge 0 (`AGC_COST_NONE`); `concat`
charges `2 * (a + b)` only when `b.len > 32`.

The work of `append` and `set` is bounded (one tail of at most 32 items and one
path of at most 12 nodes, §17.2). Charging 2n would make a task yield after
every push once its list passes 1,000 items (`AGC_TURN_STEPS` is 2,000). The
cost only moves the point where a task yields, but a golden with two tasks and a
big push loop could then print in another order. If a golden changes, find the
cause first; do not run `make goldens` to hide it. `make vm-latency`, run alone,
must still pass its 250 ms limit.

### 17.6 Multicore and invariants

- **Values are immutable after they are returned**
  ([§10.2.3](10-io-multicore.md), "Values are immutable";
  [§16.7](16-architecture.md#167-sharing)). Tasks on different schedulers share
  lists with no lock and no copy. `append`, `set`, `slice` and `concat` never
  write to their input, and a builder writes only nodes it made, before
  `finish`. Nothing writes a list after `finish`, or after `append` or `set`
  returns: no cached cursor or last leaf in the list object, no counter, no
  lazy field. Such a cache would be a write after publication, a data race
  once N > 1.
- **No transients.** A builder lives in one C frame or in a task-private object
  (`agc_native`, a parse, decode or walk frame) that no value refers to until
  `finish`. A task cancelled halfway leaves a builder as garbage. An in-place
  `push` on a list proven unshared is excluded: §10.2.3 requires such a change
  to be proven unshared or made atomic, and the persistent `append` is fast
  enough (§17.8). If that gate fails, the answer is a new design, not a patch.
- **Entry rule (§14.6).** No new subsystem and no new way to wait, time out,
  cancel, end or own a handle. `list.c` has no mutable global.
- **Sharing between versions is invisible.** Lists have no object identity (`==`
  does not apply to them), and nothing prints an address.

### 17.7 Loader and untrusted input

- A `.agcb` has no list constants: constant kinds 0 to 7 are none of them lists
  (§4.6). Lists exist only as the result of `LIST`, a builtin or the runtime.
  The loader checks the registers of `LIST_LEN`, `LIST_GET` and the window of
  `LIST`.
- The limits stay as they are: 1,048,576 items for `List.repeat` and
  `Range.to_a` (`AGC_MAX_LIST_COUNT`), 1 MiB for `IO.read_bytes` and byte
  writes. `append`, `concat` and nested lists have no limit:
  `--max-steps` bounds instructions, not memory ([§1](README.md#1-overview)),
  and a hostile file can reach the out-of-memory exit 70.
- Size arithmetic uses the checked helpers (§5.2). `len` cannot pass `SIZE_MAX /
  16`, because `agc_size_mul(len, 16)` ends in the out-of-memory exit first, so
  `shift` stays at 55 or less and `1 << (shift + 5)` fits.
- No value-driven C recursion (§7.3): `get`, `set`, `append`, the builder and
  the cursor loop over at most 11 levels. Nested lists are walked by the
  explicit-stack code of `text.c`, `equal.c` and `json*.c`.
- The fuzzer (`agc_fuzz_one`) counts each node's `BLOCK_COST` (64 bytes) in its
  allocation limit under `AGC_NO_GC`, so list-heavy mutants reach it sooner.

### 17.8 Tests

- **C unit tests,** `vm/tests/list_test.c` (`make vm-test`, the ASan run and
  `make vm-gc-stress`): every boundary length of §17.2, built both ways, with
  persistence of old versions, `slice`, `concat`, `reverse` and the shared
  leaves of `agc_list_repeat`.
- **Goldens.** `tests/fixtures/vm/list-vector.agc` covers the trie boundaries
  and old versions printed after new ones were made.
- **Benchmark gates** (`make bench`; numbers in `docs/vm-benchmarks.md`;
  programs `benchmarks/programs/list-build.agc` and `list-bulk.agc`): 160,000
  pushes in a loop run in under 1 s, and 2n pushes take under 2.5 times as long
  as n; bulk builds take at most 1.3 times the flat array's time; `maze-bfs` is
  a no-regression check. Before blaming the list code for a loop slowdown, time
  the program with another link layout: the same interpreter ran 15 to 20%
  apart on loops with no list operation.

### 17.10 Decisions

Decided on 2026-10-14:

1. **Turn cost of `append`, `set` and small `concat`:** 0. Their work is bounded
   (§17.5), and the rule of §10.2.1 charges nothing for constant work.
2. **The 8d benchmark claim:** `list-build` is the gate; `maze-bfs` stays a
   no-regression check.
3. **`take`, `drop` and a large `concat` stay O(n)** (no RRB). `Queue[T]` (8c)
   is the answer for FIFO use. §17.11 keeps this for a `drop` that does not
   start at a multiple of 32 and for the right side of a `concat`, and makes
   `take`, an aligned `drop` and the left side of a `concat` share leaves.
4. **Two PRs, not one:** first the API over the flat array with every call site
   migrated, then the trie behind the API, so the first PR's tests were an
   oracle for the second.

### 17.11 Bulk operations after the trie

Timing each operation on a million items against the flat array and CPython
3.13 showed that the trie was cheap. The rest of the time went to the collector
(a collection scans every live array of 16-byte values) and to per-item work in
`sort` and `split` (`docs/vm-benchmarks.md`, "Bulk operations after the trie").

- **Shared leaves.** `builder_begin` can take the first leaves of another list
  (a source, the index of its first leaf and how many leaves) instead of
  allocating them. Only the branches (1.6% of the items) are rebuilt. `take(k)`,
  `drop(k)` for `k` a multiple of 32, and `concat(a, b)` use it. A shared leaf
  keeps its build's whole array alive, so `slice` shares only when `count` is at
  least half of `len`; a smaller slice, or one that starts inside a leaf,
  copies. `concat` keeps all of a, so it loses nothing. A chain of halving
  slices can still hold the first array.
- **Sort.** The keys are read once (`agc_as_int`, `agc_as_float` or
  `agc_as_string`, which also checks each key's type) into `(key, index)`
  entries, atomic for Int and Float keys. An Int becomes `i ^ 2^63`, and a Float
  its IEEE bits as a total order (`-0.0` as `0.0`, every NaN the largest key),
  so one unsigned compare orders both. One scan finds keys that never decrease
  (the input is the result) or strictly decrease (one `reverse`: equal keys are
  never reversed, so the sort stays stable). Otherwise a bottom-up merge. The
  charge `n * ceil(log2 n)` is unchanged.
- **Split.** `split` returns the runtime's shared one-character Strings
  (`rt->chars`, made at start-up) for a one-byte ASCII piece. Strings have no
  identity ([§34.3](../future/34-shared-small-values.md#343-why-it-is-safe)), so
  a program cannot tell. A million-character `split("")` allocates no String.
- **Inline paths.** `agc_list_builder_push` and `agc_list_cursor_next` are
  inline in `value.h`, with `agc_list_builder_more` and `agc_list_cursor_fill`
  as the slow paths, so `map`, `join`, `Range.to_a` and the JSON builders do not
  call into `list.c` per item.
- **Tried and left out.** A chunked staging area for `filter` gained 4% when it
  keeps half of the items and lost 3% when it keeps all of them, so `filter`
  still stages in a flat array.

### 17.12 Unboxed numeric leaves

Step 3 of roadmap item 8d ([§38.6](../future/38-value-representation.md), item
1). The owner decided on 2026-10-15 that the VM decides the kind, not the front
end. The earlier plan had the checker's element type reach the VM. That needs a
new operand or builtin argument, a loader change, and a type for every list that
C code makes (JSON, `String.split`, `Map.keys`, byte lists). The static types
already say that a `List[Int]` holds only Ints, so the list code looks at the
values it is given. The front end, the lowering, the bytecode format and the
loader do not change, and `Int` stays 64 bits.

**Kind.** A list has a kind, a `uint32_t` after `shift` that fits in the padding
(the header stays 24 bytes):

- 0: boxed. The items are 16-byte `agc_value`s (§17.2).
- `AGC_T_INT` or `AGC_T_FLOAT`: every item has that tag. A leaf and the tail
  hold the 8 raw bytes of each item and no tag. A leaf is 256 bytes, not 512.

An empty list has kind 0, and its first item decides. In a valid program a list
never changes kind, because a `List[T]` has one element type (there is no `Any`,
and `Nil` is not a wildcard). Only a hostile `.agcb` can mix.

**Kind of the result.** The sized builder takes the tag of its first item, and
the list object is allocated at that push, since its size depends on the kind.
`from_array` (a literal, `filter`) takes the tag of the first item when all
items have it. `append` keeps the kind of the list (or takes the item's, for an
empty list); `set`, `slice` and `reverse` keep it. `repeat` takes the tag of the
value. `concat` gives the kind of both lists when equal; an empty side gives the
other list as it is.

**Reads and writes.** `list_at` and `agc_list_trie_get` rebuild the value from
the kind: the tag is the kind and the payload is the 8 bytes. The cursor and the
inline builder push carry the kind in their structs. Two details keep the boxed
path as fast as it was. The stores of `push` are typed (`uint64_t` and
`agc_value`): a `char *` store may alias the builder's own fields, and then the
compiler reloads them for every item. And a value is built from its two 8-byte
words (`agc_word_value` and `agc_value_word`, both in `value.h`), because the
field-by-field form made the compiler merge the boxed and numeric paths with
masks.

**Memory and the GC.**

- Numeric leaf blocks (a build's block, a copied leaf, the leaf of `repeat`)
  come from `agc_alloc_atomic`: the collector does not scan them, and under
  Boehm they are not zeroed. Every word is written before the list is returned:
  `finish` aborts unless the builder is full, and a leaf copy always gets 32
  items.
- Branches and the list object stay `agc_alloc`, since the object holds `root`.
  A numeric tail (at most 256 bytes) is scanned, so an Int that looks like a
  pointer can keep garbage alive for as long as its list lives. Boehm already
  accepts that for the stack and the registers.
- A leaf is a slice of a block, and the branches hold interior pointers into it.
  `GC_set_all_interior_pointers(1)` keeps the block alive. `list_test.c` forces
  collections while only such pointers refer to an atomic block, for each kind.
- The size bound of §17.7 still applies to 16-byte items, for every kind.

**Mixing kinds.** The checker does not allow it, but a `.agcb` can ask for it:
`List.set` of a String into an Int list, a `map` block that returns an Int and
then a String, `List.concat` of an Int and a Float list. No code reads an item
as another kind, and the kind of a returned list never changes. Where kinds
meet, the result is boxed, and no operation fails:

- A push whose tag differs from a numeric builder's kind replaces the builder by
  a boxed one of the same size, which holds the items written so far (read back
  as values). That costs O(n) once. A boxed builder never becomes numeric. A
  builder that shares leaves is only made for lists of one kind, so it never
  converts.
- `append` and `set` of a value with another tag onto a numeric list copy the
  list to boxed first. The input is unchanged.
- `concat` of two non-empty lists of different kinds fills one boxed builder
  from both and shares nothing. `from_array` starts over as boxed at the first
  tag that differs.
- `sort` of such a list takes the boxed path, which checks each key's type and
  fails as it did before.

**Sort.** For a list that sorts by itself (`List.sort`) and has a numeric kind,
the entry's item is the raw 8 bytes of the number, and the result is built by
pushing the sorted words, with no read through the trie by index. The order
keys, the checks and the merge are the same, so the order is the same: stable,
`-0.0` equal to `0.0`, every NaN last and equal. A second merge on the 8-byte
words was no faster for Float, because the order key had to be recomputed at
every compare, so it was dropped. `sort_by` and the sort of Strings are
unchanged.

**Costs.** A numeric item takes 8 bytes instead of 16, so a list of at most 32
items is 24 + 8k bytes. A builder is 48 bytes: the list, the write pointers, the
count and the kind. Step counts, turn costs (one unit per item) and the `.agcb`
format do not change. The numbers are in
[`docs/vm-benchmarks.md`](../vm-benchmarks.md), "Unboxed numeric leaves (roadmap
8d step 3)".

**Left as it was.** `filter` still stages `agc_value`s before `from_array` packs
the result. Registers, calls, structs, maps and Json values stay `agc_value`.

**Tests.** `vm/tests/list_test.c` runs the whole API with Int, Float and boxed
items over the boundary lengths of §17.2 (the million lengths for Int only). It
builds mixed lists by hand at every boundary, checks that an empty list has no
kind, and that `-0.0`, NaN and the limits of Int survive each operation. The
golden `tests/fixtures/vm/list-unboxed.agc` covers the same behavior end to
end.
