## 17. Faster lists: a persistent vector behind `List`

**Status:** roadmap item 8d
([`08-data-structures.md`](../roadmap/08-data-structures.md)) is built: PR 1 of
§17.9 (the API over the flat array) and PR 2 (the trie behind it). It fills in
[`docs/future/12-data-structures.md`
§12.4](../future/12-data-structures.md#124-faster-lists) for the C VM, which is
the only backend since 7i. Line numbers are from master at 5713a2c, before PR 1
moved the code. The implementation PRs were built from this file. A line that no
longer matches means the code moved, not that the design changed.

### 17.1 Goal and non-goals

**Goal.** `xs = xs.push(x)` in a loop costs O(n) in total, and `xs[i]`,
`List.at` and `List.set` cost O(log32 n). Today `List.append` copies the whole
array (`vm/builtins.c:151-157`). Measured while writing this design (release
build of this tree, VM only, bytecode compiled first, one machine, rough): a
loop of n pushes takes 0.41 s for n = 10,000, 6.0 s for 40,000 and 88 s for
160,000. The `lists` benchmark takes 0.23 to 0.27 s and `maze-bfs` 0.08 s.

**Unchanged.**
- The `List` API and its meaning: no language change, no new builtin, no new
  opcode, no change to the `.agcb` format (version 3).
- Output, diagnostic codes and spans (`list_index` keeps `span + 2`,
  `vm/builtins.c:159-163`), `--max-steps` step counts and every golden under
  `tests/fixtures/vm/` (§17.5).
- No program can see a mutation: lists stay immutable values (§17.6).

**Non-goals.**
- No transients and no in-place `push` on an unshared list (§17.6).
- No relaxed (RRB) nodes. `take`, `drop`, `reverse`, `sort`, `Map.keys` and a
  `concat` with a large right side stay O(n).
- No unboxed leaves in this design. `List[Int]` and `List[Float]` leaves are the
  first step of
  [§38.6](../future/38-value-representation.md#386-direction-use-the-static-types);
  the owner scheduled them as step 3 of 8d on 2026-10-14
  ([`08-data-structures.md`](../roadmap/08-data-structures.md)). Because every
  site goes through the API of §17.4, that step changes `vm/list.c` and the
  places that create a list, which get the element type from the front end.
- No shared empty list ([§34](../future/34-shared-small-values.md) is separate).
- No cursor opcode for `for` (§17.3, row 4).

### 17.2 Representation

A 32-way trie with a tail buffer, as in Clojure. It has the same width as the
map's HAMT (`HAMT_BITS 5`, `vm/map.c:5`).

```c
#define AGC_LIST_WIDTH 32
typedef struct { void *child[AGC_LIST_WIDTH]; } list_branch;
typedef struct { agc_value item[AGC_LIST_WIDTH]; } list_leaf;
struct agc_list { size_t len; list_branch *root; uint32_t shift; agc_value tail[]; };
```

`struct agc_list` and the two node types live in `vm/list.c` only. Outside it
the type is opaque (§17.4). The algorithms below were run in a throwaway C model
against a flat array at every length of §17.8, so the boundaries quoted here are
measured, not only derived. The model is not in the repository.

- `tail_len(n)` is 0 for n = 0, else `((n - 1) & 31) + 1`. `tail_off(n)` is
  `n - tail_len(n)`. The list object holds the last `tail_len(len)` items inline
  in `tail`, so the tail is 1 to 32 items. The trie holds the first
  `tail_off(len)` items in full leaves of 32.
- `root` is NULL exactly when `tail_off(len) == 0`, that is when `len <= 32`. A
  small list is one allocation of 24 bytes plus 16 per item: the shape it has
  today, 16 bytes bigger.
- `shift` is canonical: the smallest multiple of 5 that is at least 5 and has
  `tail_off <= 2^(shift + 5)`; 0 when `root` is NULL. A branch at level L (L =
  `shift`, then `shift - 5`, down to 5) picks `child[(i >> L) & 31]`; a child of
  a level-5 branch is a leaf. The shift grows at len 33 (to 5), 1,057 (10),
  32,801 (15) and 1,048,609 (20). Branches exist only where a leaf exists. So a
  list has one shape, whichever way it was built (the unit test compares the two
  ways).
- **Read** `get(i)`: `i >= tail_off` reads `tail[i - tail_off]`; otherwise walk
  `shift / 5` branches and read `item[i & 31]`. That is one compare up to 32
  items, then 2, 3 and 4 loads up to 1,056, 32,800 and 1,048,608 items.
- **Allocation.** The list object, branches and leaves all come from `agc_alloc`
  (`GC_MALLOC`, zeroed, scanned): they hold GC pointers or `agc_value`s, which
  can hold them (§5.3). Never `agc_alloc_atomic` for them. Atomic stays for
  temporary index arrays (the sort's `order`, `vm/interp.c:256-257`) and, in the
  later §38 step, for leaves of Int or Float only. A branch is 256 bytes and a
  leaf 512, so they are small Boehm objects, served from size-class free lists.
  A flat list of 100,000 items is one large object of 1.6 MB. Under `AGC_NO_GC`
  (the ASan build) `agc_alloc` is `calloc` kept until `agc_release_all`
  (`vm/value.c:82-98`), so a test that makes many versions holds all of them
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
  (An earlier version allocated and attached one leaf per 32 items; it took six
  times as long as the flat array to build a million items, mostly in the
  collections its allocations triggered.) `push` writes item `count`: items
  below `tail_off(n)` go into that array, and the last `tail_len(n)` items go
  straight into the list's `tail`. `finish` returns the list, and aborts
  (`abort()`, as `vm/value.c:641` does) if fewer or more than n items were
  pushed. Every node a builder writes was created by that builder after it
  began, so writing in place is safe. Pushing the wrong number is a C bug, not a
  program error. A later `set` copies the leaf it changes, so the array lives as
  long as any list still shares one of its leaves. Bulk copies (`slice`,
  `concat`, `from_array`) fill the builder a leaf at a time with `memcpy`, not
  one `push` per item.
- **Unknown count.** `filter`, and the planned `Task.map`
  ([§27.1](../future/27-iteration-and-concurrency.md#271-taskmap), results
  arrive out of order), fill a flat staging array of the input length and call
  `agc_list_from_array(items, n)` at the end. `filter` already allocates its
  output this way, then lowers `len` in place (`vm/interp.c:365`). After the
  change the result is right-sized, which also closes the "related candidate" in
  [§34.2](../future/34-shared-small-values.md#342-design).

### 17.3 Operations

New algorithms and costs. Every row migrates to the API of §17.4. "Cursor" means
`agc_list_cursor`: one descent per leaf, O(1) per item inside it.

| # | Operation and site | Today | New | Cost |
|---|---|---|---|---|
| 1 | `LIST a b c` (`vm/interp.c:598-603`); literals above 255 items are chunks joined by `List.concat` (`src/lower.rkt:538-556`) | `agc_new_list(c)`, copy the window | `agc_list_from_array` over the register window (the same as a sized builder with `c` pushes, in one call) | O(c); c is a 16-bit operand |
| 2 | `LIST_LEN` (`interp.c:604`), `List.size` (`builtins.c:146`) | field read | `agc_list_len` | O(1) |
| 3 | `LIST_GET`, `xs[i]` (`interp.c:605-610`), `List.at` (`builtins.c:165-168`) | `items[i]` | same bounds check on `agc_list_len` (message, code and span unchanged, `interp.c:485`), then `agc_list_get` | O(log32 n) |
| 4 | `for x in xs` (`src/lower.rkt:792`, `801`) | `LIST_LEN` once, `LIST_GET` per item | same bytecode, n gets | O(n log32 n): at most 4 loads per item at 1M items. A cursor opcode would save them but is a new opcode and an `.agcb` change |
| 5 | `List.map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by` (`interp.c:304-375`, `387-424`; table `builtins.c:408-414`) | `st->index` into the list, output in `st->out` | `agc_native` (`interp.c:7-17`) keeps a cursor over the input and the current item (filter needs it after the call; today it re-reads `items->items[st->index - 1]`, `:332`). `map` and `sort_by` keys use a sized builder of n; `filter` stages and calls `from_array`. The input list stays in `st->list` for `sort_by` | O(n); one cursor step and one turn-cost unit per callback (`:357`), as today |
| 6 | `agc_sort_by_keys` (`interp.c:250-276`); `List.sort` (`builtins.c:212-216`); `Dir.list` (`files.c:1009`) | merge sort over `order` indexes, `keys->items[order[j]]` | copy the keys to one flat array (`agc_list_to_array`; for `sort` the keys are the items), same merge on indexes, result by a sized builder that reads the items with `list_get` (no second copy of the items) | O(n log n) plus O(n) temporary memory; the charge `n * rounds` (`:253-255`) is unchanged |
| 7 | `agc_value_units` (`value.c:332-340`) | `len` | `agc_list_len` | O(1); every size cost keeps its number (§17.5) |
| 8 | `List.append`, `push` (`builtins.c:151-157`) | copy n, add 1 | `agc_list_append` | O(1) amortized; O(log32 n) worst |
| 9 | `List.set` (`builtins.c:170-176`) | copy n | `agc_list_set` | O(log32 n) |
| 10 | `List.concat` (`builtins.c:126-133`) | copy a and b | b empty gives a; a empty gives b; `b.len <= 32` appends b's items to a (shares a's trie); else a sized builder filled with `memcpy` from a then b | O(b.len) for a small b, else O(a + b) |
| 11 | `List.take`, `List.drop` (`builtins.c:193-202`, `list_slice` `:140-144`) | `memcpy` | `agc_list_slice(l, from, count)`: a sized builder filled leaf by leaf with `memcpy`, starting at `from`. `take(k >= len)` and `drop(0)` return the input; `take(k)` with `k > tail_off` may share `root` and `shift` and copy only the tail | O(count); stays O(n): without relaxed nodes a shifted tail cannot share leaves |
| 12 | `List.reverse` (`builtins.c:204-210`) | reversed copy | `agc_list_reverse`: a sized builder fed from the leaves, last to first | O(n) |
| 13 | `List.repeat` (`builtins.c:178-185`), `Range.to_a` (`:335-343`), `Map.keys` and `values` (`map_walk`, `:229-239`; the `agc_map_get(.., &l->items[k])` at `:235` writes to a local, then pushes) | fill a new list | `Range.to_a`, `Map.keys` and `values`: sized builder. `List.repeat` (`agc_list_repeat`): one leaf filled with the value, shared by every slot of the trie, and one full and one last branch per level | O(n); `repeat` is O(log32 n) in time and memory |
| 14 | `System.args` (`main.c:292-300`, empty list `interp.c:73`), `IO.read_bytes` (`input.c:340-353`), stream bytes (`stream.c:129-136`), `File.read_bytes` (`files.c:1012-1016`), `Dir.list` (`files.c:1001-1010`), HTTP header lists for client and server (`http_fields.c:114-127`), `String.split` (`strings.c:288-316`) | fill a new list | sized builder with the known count | O(n) |
| 15 | `String.join` (`strings.c:318-339`), `Path.join` (`files.c:1471-1495`, three passes), `String.from_bytes` (`strings.c:466-478`), `agc_byte_list` (`value.c:519-528`, used by `files.c:1323`, `process.c:867`, `tcp.c:1089`), process arguments (`process.c:599-605`, `728-731`), header scans (`http_fields.c:37-41`, `150-156`, `http_server.c:360-366`; the client passes its list at `http_client.c:717`) | index loop | one cursor per pass | O(n) |
| 16 | `Test.run` and its helpers (`testing.c:69-71`, `92-95`, `129-134`, `245-246`) | index into the list | `agc_list_get` for the test index and the two arguments, a cursor for scans | O(log32 n) per access |
| 17 | `agc_equal` (`equal.c:47-50`, `67-70`) | `push_items` pushes pairs 0 to n-1, then pops from the end | two cursors, push in the same order, so the first mismatch and the units charged are the same | O(n) |
| 18 | `inspect`, `to_text` (`text.c:182-198`) | index per item | `agc_list_len` and `agc_list_get` per item. These walkers keep one small frame per nesting level, because the tests nest 1,000,000 deep (`docs/vm/12-testing-and-pr-plan.md` §12.1, "Depth"); a cursor in each frame would add 40 bytes to every level | O(n log32 n) |
| 19 | JSON encode and `JSON.from` (`json_value.c:166-181`, `191-212`, `262-303`), `JSON.at` (`json.c:311-318`) | index per item | `agc_list_get` (same reason as row 18) | O(n log32 n) |
| 20 | JSON array builders: `agc_json_container`, `agc_json_store`, `agc_json_finish`, `agc_json_array` (`json_value.c:55-72`, `74-77`, `317`; `value.h:362-368`), used by the parser (`json.c:107-150`), `JSON.from` (`json_value.c:283-298`) and the schema (`json_typed.c:219-223`) | `agc_list **` filled by index; the node already holds the list at creation | the container takes an `agc_list_builder *`; `store` pushes (the calls come in order k = 0, 1, ...); `finish` finishes the builder and sets `scalar`; an array with n = 0 finishes at once. `JSON.list` returns that same list (`json.c:342-345`, `extract` `:321-325`), so a Json array node must hold a finished list before it is returned. `parse_frame` and `walk_frame` swap an 8-byte list pointer for a 24-byte builder | O(n) |
| 21 | Typed decode (`json_typed.c:5-14`, `46-50`, `62-73`, `87-91`) | `f->list` filled by index, read as `f->items->items[next]` | `decode_frame` holds a builder and reads the JSON array with `agc_list_get`. `frame_value` is called at `:131` before the children are decoded, so the list must be finished only at `:152`, or at once when n = 0 | O(n) |

Not call sites: the loader (§17.7); `Channel`, which holds values in a ring and
no list; the stepper protocol (`File.each_line` installs an `agc_stepper` and no
list, `interp.c:283-302`). There is no `List.contains?`, `index`, `first`,
`last` or `join` in the catalog (`src/builtins.rkt:139-155`): `String.join` is
the only join (row 15). A new builtin that returns a list follows rows 13 and
14; the planned `Task.map` follows §17.2, "Unknown count".

### 17.4 The C API

In `vm/value.h`, next to the map functions (`value.h:316-326`), and implemented
in a new `vm/list.c`. `list.c` is core, like `map.c` (`docs/vm/15-layers.md`
§15.1): it includes `core.h`, calls only `agc_alloc` and the size helpers, and
takes no `agc_vm` (so it adds nothing to the port). It goes in `VM_SRC`
(`Makefile:128`), in the `core` list of `vm/tools/check-layers.sh:10`, in the
table of §15.1 and in the file table of the development skill
(`.agents/skills/agentica-development/references/vm.md`, next to `vm/map.c`).

```c
typedef struct agc_list agc_list;
typedef struct { agc_list *out; size_t count; void *leaves; } agc_list_builder;
typedef struct { const agc_list *list; size_t index, start, end; const agc_value *chunk; } agc_list_cursor;

size_t agc_list_len(const agc_list *l);
agc_value agc_list_get(const agc_list *l, size_t i);
void agc_list_builder_sized(agc_list_builder *b, size_t n);
void agc_list_builder_push(agc_list_builder *b, agc_value v);
agc_list *agc_list_builder_finish(agc_list_builder *b);
agc_list *agc_list_from_array(const agc_value *items, size_t n);
void agc_list_to_array(const agc_list *l, agc_value *out);
void agc_list_cursor_begin(agc_list_cursor *c, const agc_list *l, size_t at);
bool agc_list_cursor_next(agc_list_cursor *c, agc_value *out);
agc_list *agc_list_append(const agc_list *l, agc_value v);
agc_list *agc_list_set(const agc_list *l, size_t i, agc_value v);
agc_list *agc_list_slice(const agc_list *l, size_t from, size_t count);
agc_list *agc_list_concat(const agc_list *a, const agc_list *b);
agc_list *agc_list_reverse(const agc_list *l);
agc_list *agc_list_repeat(agc_value v, size_t n);
```

- `agc_list_get` and `agc_list_set` need `i < len`. The caller checks and fails
  with the program's diagnostic, as `LIST_GET` and `list_index` do now; a bad
  index inside the API aborts. `agc_list_to_array` fills `len` slots that the
  caller allocated with `agc_alloc` (scanned memory).
- `agc_list_builder` and `agc_list_cursor` are in `value.h` because callers put
  them on the stack. Their fields are private by convention. They live on the C
  stack or in `agc_alloc` memory (a native frame, a parse or decode frame),
  never in `malloc` memory, in an atomic object or in a `_Thread_local` (§5.3).
  A cursor's `chunk` points inside a leaf or the tail; the build keeps interior
  pointers (`vm/value.c:53`), so the object stays alive.
- `typedef struct agc_list agc_list;` replaces the anonymous struct at
  `value.h:39-42`. `agc_as_list` and `agc_list_value` keep their signatures.
  `agc_new_list` is removed.
- **Every call site migrates; none reads the old fields.** Because
  `struct agc_list` is defined only in `list.c` and the private `vm/list_impl.h`
  (which only `list.c` and `interp.c` include, checked by `make vm-layers`), a
  missed site is a compile error (incomplete type), including in `vm/tests/`. To
  list the sites before the change:
  `rg -n 'agc_new_list|agc_as_list|agc_list \*|->items\b' vm --glob '!vm/third_party/**'`
  (28 files at 5713a2c), then read every `->len` in those files. The false hits
  are fields that are not lists: the registry in `vm/loop.c` (`reg->items`) and
  the pair stack in `vm/equal.c` (`s->items`). The C tests move too:
  `vm/tests/map_test.c:124-126`, `vm/tests/json_test.c:96-100`,
  `vm/tests/text_test.c:56-79`, `vm/tests/process_test.c:22-24` and
  `vm/tests/task_cancel_test.c:308`.

### 17.5 Turn costs and step counts

**Step counts do not change.** Steps are charged by `STEP` instructions, which
`src/lower.rkt` emits (`lower-list` starts with one, `src/lower.rkt:528`) and
the interpreter counts (`vm/interp.c:532-539`, `step_slow` `:132-144`). The only
natives that call `count_step` (`:146-152`) are the counting ones (`Range.each`,
`times`, `upto`, `downto`, `:318`) and steppers (`:291`), not the list natives.
A builtin charges `agc_charge` (`:81-85`), which adds to the task's turn cost;
`apply_cost` (`:154-167`) lowers only `turn_left`, never `steps_left`
([§10.2.1](10-io-scheduler.md): "Turn costs never touch it"). The list natives
charge one turn unit per callback (`:357`). The new code changes no opcode, no
callback count and no `STEP` the lowerer emits, so no count moves. The gate is
the goldens: each `.expected` holds `steps`, and the sweep fails when a run
takes more than the golden plus `max(10, 10%)`
(`tests/vm-diff-common.rkt:416-424`, `504-512`). No `.expected` changes in
either PR; a diff there is a bug.

**Turn costs.** `AGC_COST_SIZE` charges `units(args)` before the call and
`units(result)` after (`interp.c:713-715`, `731`), and `agc_value_units` of a
list is `len` (`value.c:336`). The rule is one unit per item copied or scanned,
and "constant work charges nothing" ([§10.2.1](10-io-scheduler.md),
`docs/vm/10-io-scheduler.md:51-64`).

| Builtin | Today | PR 1 | PR 2 |
|---|---|---|---|
| `size`, `at`, `LIST_LEN`, `LIST_GET` | 0 | same | same |
| `take`, `drop`, `reverse`, `repeat`, `Range.to_a`, `String.split`, `join`, `from_bytes`, `Map.keys`, `values`, `Dir.list`, `read_bytes`, header lists | `AGC_COST_SIZE`: args + result | same | same, same numbers, still O(n) work |
| `sort`, `sort_by` | `n * ceil(log2 n)` inside `agc_sort_by_keys` (`:253-255`) | same | same |
| `map`, `filter`, `reduce`, `each`, `any?`, `all?` | 1 per callback | same | same |
| `append` | `AGC_COST_SIZE`: n + (n + 1) | same | 0 (`AGC_COST_NONE`) |
| `set` | `AGC_COST_SIZE`: 2n | same | 0 |
| `concat` | `AGC_COST_SIZE`: 2(a + b) | same | `AGC_COST_NONE`; 0 when `b.len <= 32`; else `agc_charge(vm, 2 * (a + b))` in the builtin, the same number as today |

From PR 2 the work of `append` and `set` is bounded: one tail of at most 32
items and one path of at most 12 nodes (§17.2), so the rule gives 0. Keeping 2n
would make a task yield after every push once its list passes 1,000 items
(`AGC_TURN_STEPS` is 2,000). The change moves only the point where a task
yields. Output and `--max-steps` do not depend on it. A golden with two tasks
and a big push loop could print in another order. If any golden changes, find
the cause first; do not run `make goldens` to hide it. `make vm-latency`, run
alone (`tests/fixtures/latency/latency.agc`: a sorter of 100,000 items and a `+`
loop), must still pass its 250 ms limit.

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
- **No transients in this PR.** A builder lives in one C frame or in a
  task-private object (`agc_native`, a parse, decode or walk frame) that no
  value refers to until `finish`. A task runs on one scheduler at a time, and
  the hand-off between turns is already ordered by the run queue and the park
  and wake protocol (§10.2.3). A task cancelled halfway leaves a builder as
  garbage. An in-place `push` on a list proven unshared is excluded: §10.2.3
  requires such a change to be proven unshared or made atomic, and the
  persistent `append` is fast enough (§17.8). If the gate there fails, that is a
  new design, not a patch.
- **Entry rule (§14.6).** No new subsystem and no new way to wait, time out,
  cancel, end or own a handle: this is a data structure inside the value layer
  that replaces `agc_new_list` and the flat copies. `list.c` has no mutable
  global (`make vm-lint` enforces it).
- **Sharing between versions is invisible.** There is no object identity for
  lists (`==` does not apply to them), and nothing prints an address.

### 17.7 Loader and untrusted input

- A `.agcb` has no list constants. Constant kinds are 0 to 6: Void, Nil, false,
  true, Int, Float, String (`vm/loader.c:433-451`). Lists exist only as the
  result of `LIST`, a builtin or the runtime. The loader checks the registers of
  `LIST_LEN` and `LIST_GET` (`loader.c:168`, `224-230`) and the register window
  of `LIST` (`:231-234`). There is no loader change and no format change.
- The limits that exist stay as they are: 1,048,576 items for `List.repeat` and
  `Range.to_a` (`AGC_MAX_LIST_COUNT`, `builtins.c:180`, `337`), 1 MiB for
  `IO.read_bytes` (`builtins.c:81`) and for byte writes (`agc_byte_list`,
  `value.c:520`; `files.c:1323`, `process.c:867`, `tcp.c:1089`). `append`,
  `concat` and nested lists have no limit today and get none: `--max-steps`
  bounds instructions, not memory ([§1](README.md#1-overview)), and a hostile
  file can reach the out-of-memory exit 70 as before.
- Size arithmetic uses the checked helpers (§5.2): `agc_size_add`,
  `agc_size_mul` for every allocation size. `len` cannot pass `SIZE_MAX / 16`,
  because `agc_size_mul(len, 16)` ends in the out-of-memory exit first, so
  `shift` stays at 55 or less and `1 << (shift + 5)` fits.
- No value-driven C recursion (§7.3): `get`, `set`, `append`, the builder and
  the cursor are loops over at most 11 levels. Recursion over the levels is
  allowed if marked as `map.c` does (`vm/map.c:94`); loops are preferred. Nested
  lists are walked by the same explicit-stack code as now (`text.c`, `equal.c`,
  `json*.c`).
- The fuzzer (`agc_fuzz_one`) frees every block after each mutant under
  `AGC_NO_GC` and stops at the allocation limit. Nodes use `agc_alloc` only, so
  both keep working. Each node counts `BLOCK_COST` (64 bytes) in that limit, so
  list-heavy mutants reach it sooner than before; that is fine.

### 17.8 Test plan

Rules: `AGENTS.md` (`rackunit` for Racket; C tests are plain-assert files in
`vm/tests/`; goldens for features; no new framework).

- **C unit tests, `vm/tests/list_test.c`** (the `vm/tests/*_test.c` wildcard
  builds it, `Makefile:389`; it runs in `make vm-test`, the ASan run and
  `make vm-gc-stress`). Lengths 0, 1, 2, 31, 32, 33, 63, 64, 65, 1,023, 1,024,
  1,025, 1,056, 1,057, 32,768, 32,769 (32·32·32 + 1), 32,800, 32,801, and
  1,048,576, 1,048,608, 1,048,609. For each length n:
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
  `steps` included. PR 1 adds one fixture, `tests/fixtures/vm/list-vector.agc`,
  run against the flat VM and checked by hand: lists of 31, 32, 33, 1,056 and
  1,057 items built by `push`, one of 32,769 from `(0...32769).to_a` (not by
  pushes: the flat VM is O(n²) and the sweep runs a fixture about 60 times),
  then `set`, `take`, `drop`, `concat`, `reverse`, `sort`, `map`, `filter`,
  `for`, an index at the boundary and out of range, and old versions printed
  after new ones were made. PR 2 must leave its golden unchanged: that is the
  proof that the swap kept the behavior.
- **Racket tests that cover lists today:** `tests/vm-diff-{1..8}-test.rkt` over
  the fixtures `lists`, `list-library`, `list-callbacks`, `list-chunks`,
  `list-at-index`, `list-set-index`, `list-take-count`, `list-drop-count`,
  `list-repeat-count`, `list-repeat-negative`, `index-out-of-range`,
  `sort-by-error`, `ranges`, `range-to-a-count`, `json-*`, `std-queue` and
  `test-list`; `tests/examples-test.rkt`; `tests/site-examples-test.rkt` (the
  site list page runs); `tests/bytecode-test.rkt` (opcode order and builtin
  names, unchanged); `tests/unit-test-test.rkt` with `tests/std/*_test.agc`;
  `tests/bdd-test.rkt`; `tests/vm-latency-test.rkt` (run alone).
- **Commands for the implementation PRs:** locally, only the localized checks:
  `make vm vm-test` (the C tests), the new `list-vector` golden alone,
  `tests/bytecode-test.rkt`, `make vm-layers` and `make vm-lint`, and
  `make bench` for the gates above. CI runs the rest: the `vm-diff` shards,
  `make vm-gc-stress`, the sanitizer build, the fuzz smoke, `make dup-check`,
  `make vm-latency` and `make smoke`. This design PR changes only documents.
- **Benchmarks, before and after** (`make bench`, record in
  `docs/vm-benchmarks.md`). Add `benchmarks/programs/list-build.agc` with a
  Python twin `benchmarks/python/list_build.py` and its name in `NAMES`
  (`benchmarks/run.py:21`): n pushes in a loop (n = 20,000 times `scale()`), n
  `set` calls at scattered indexes, a `for` sum, and a checksum line. Run
  `make bench BENCH_ARGS="--runs 5 --only lists,maze-bfs,list-build,maps --runners vm,python"`
  on the PR 1 tip and on PR 2, and `--size 2` and `--size 4` for the scaling.
  Gates:
  - 160,000 pushes in a loop run in under 1 s (88 s today), and the time of 2n
    pushes is under 2.5 times the time of n (it is about 4 today).
  - Bulk builds (`List.repeat`, `Range.to_a`, `reverse`, `take`, `drop`, a big
    `concat`, `join`, `String.split` and `sort` over 60,000 to 500,000 items,
    `benchmarks/programs/list-bulk.agc`) take no more than 1.3 times the flat
    array's time. A builder allocates its trie
    in a few big blocks, not one node per push: a first version that attached a
    new leaf per 32 pushes took six times as long for a million items, and a
    GC-stress test that builds a 1 MB string through `List.repeat` ran out of
    its time window.
  - No other benchmark is slower than 2% in either PR
    ([§34.4](../future/34-shared-small-values.md#344-measurement-first) uses the
    same figure). If a `for` or `at` heavy program is, the first fix is an
    inline fast path for `agc_list_get` and `agc_list_len`; it is not a reason
    to change the design. PR 1 did it for the two opcodes that run once per item
    of a `for` loop: `struct agc_list` and the inline versions are in the
    private `vm/list_impl.h`, which only `list.c` and `interp.c` (`LIST_LEN`,
    `LIST_GET`) include; everything else uses the opaque API of `value.h`. PR 2
    changes `list_impl.h` and `list.c`. Before blaming the list code for a
    loop-bound slowdown, time the program with more than one link layout (pad a
    file with unused functions): in PR 1 the same interpreter ran 15 to 20%
    apart on loops with no list operation, from the alignment of `agc_run_turn`
    alone.
  - `lists` gets faster. `maze-bfs` is not expected to move: its lists hold at
    most 4 items (`neighbors`, `benchmarks/programs/maze-bfs.agc:25-42`).
    Removing its `queue.delete` line did not change its time either (measured
    while writing this design), so `Map.delete` is not what bounds it. It is a
    no-regression check. Report peak RSS; a growth above 10% needs an
    explanation (a list gets 16 bytes more).

### 17.9 PR plan

Two PRs, in this order. Recommended over one.

1. **The API over the flat array, every call site migrated, no behavior
   change.** `vm/list.c` with the flat representation
   (`struct agc_list { size_t len; agc_value items[]; }` moves into it), the API
   and opaque type in `value.h`, all sites of §17.3 and the C tests migrated,
   `vm/tests/list_test.c` (the cases of §17.8 pass on the flat array), the
   `list-vector` golden, `VM_SRC`, `check-layers.sh`, `docs/vm/15-layers.md`
   §15.1 and §15.4, the development skill's file table, and the
   `docs/vm/05-values-execution-builtins.md` §5.1 row (the access rule). Costs
   unchanged. Gate: no benchmark slower than 2% (the cost is the out-of-line
   calls).
2. **Swap the representation behind the API.** The trie in `vm/list.c`, the cost
   changes of §17.5 in `vm/builtins.c`, more cases in `list_test.c`,
   `list-build` and the numbers in `docs/vm-benchmarks.md` (lines 69-72 and the
   conclusions), and the documents that state list costs:
   `docs/grammar/06b-builtins.md:19-20`, `docs/grammar/06-semantics.md:79`, the
   programming skill
   (`.agents/skills/agentica-programming/references/language.md:90`,
   `.agents/skills/agentica-programming/references/builtins.md:99`, `:106`, and
   `.agents/skills/agentica-programming/references/modules.md:52` for
   `std/queue`: push gets fast, pop stays O(n)), the site
   (`site/content/vm.md:24`, `site/content/library/data-structures/list.md`),
   the catalog texts (`src/builtins.rkt:140-141`, `149`, `152-153`),
   `docs/vm/05-values-execution-builtins.md` §5.1,
   `docs/future/12-data-structures.md` §12.4 ("both backends"), the 8d tick in
   the roadmap and the development skill.

Why two. PR 1 is mechanical and the compiler checks it: the opaque type turns a
missed site into a compile error, and the goldens plus the new fixture show that
nothing changed. The tests of PR 1 then run unchanged against the trie in PR 2,
so they are a real oracle, written against the old behavior. A regression is
either in a migrated site (PR 1) or in the trie (PR 2), which makes bisecting
easy. Each PR holds its own contracts (tests, layer lists, documents). One PR
would add a data structure and about 70 site edits in some 30 files to one
review. If the owner wants one PR, keep the same two steps as commits.

### 17.10 Decisions

Decided on 2026-10-14, when this design was merged:

1. **Turn cost of `append`, `set` and small `concat`:** 0 from PR 2. Their work
   is bounded (§17.5), and the rule of §10.2.1 charges nothing for constant
   work.
2. **The 8d benchmark claim:** PR 2 adds `list-build` as the gate and rewords
   the three sentences that name `maze-bfs`
   (`docs/roadmap/08-data-structures.md`, 8d; `docs/roadmap/07-vm.md:255-262`;
   `docs/vm-benchmarks.md:69-72`). `maze-bfs` stays a no-regression check.
3. **`take`, `drop` and a large `concat` stay O(n)** (no RRB). `Queue[T]` (8c)
   is the answer for FIFO use.
