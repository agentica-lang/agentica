## 34. Shared small values in the VM

**Status:** built (roadmap 7g). The 128 one-character ASCII Strings and the
empty List and Map came first, with the list performance PR
([§17.11](../vm/17-lists.md)) and the speed pass (PR #319). The empty String,
the empty Set, and the other paths that compute these values landed with the
PR "VM: shared small values (§34)"; [§34.6](#346-as-built) says what is shared
where, what was left out, and the numbers are in
[`docs/vm-benchmarks.md`](../vm-benchmarks.md).
An implementation proposal with no language change, in the spirit of CPython's
small-int cache: the VM makes some values once and returns the same object every
time a program computes them.

- The 128 one-character ASCII strings and the empty string `""`.
- The empty list `[]` and the empty map `{}`.
- The empty `Set` (8b, §12.2). A set is an `agc_map` under another tag, so the
  empty set is one `agc_map` with no table, shared like `empty_map`.

Ints are not part of this. An `agc_value` (`vm/value.h:29-32`) holds `Int`,
`Float`, `Bool` and `nil` inline in 16 bytes and never allocates them, so a
small-int cache would save nothing.

### 34.1 Before

Checked at `5fb7ed7`, before any of it was built:

- Some values are shared already. The bytecode writer keeps one constant per
  distinct value (`constant!`, `src/bytecode.rkt:110-118`) and the loader reads
  each once (`vm/loader.c:448`), so every `""` or `"a"` literal in a program is
  one object. Nullary enum variants are made once at load time
  (`docs/vm/05-values-execution-builtins.md` §5.1). `Map.delete` of a missing
  key returns the same map (`vm/map.c:271`).
- Computed values are not shared. Every `[]` literal runs `LIST` with no items
  (`src/lower.rkt:550`) and allocates (`vm/interp.c:552`); every `{}` runs `MAP`
  (`src/lower.rkt:587`, `vm/interp.c:566`). So `m.get(k, [])` in a loop
  allocates a list per call. Every one-character result allocates a 32-byte
  string.
- The VM had a shared empty string (a `static` in `vm/builtins.c` and
  `vm/strings.c`). `d6c37a6` removed it when mutable globals were forbidden
  (`docs/vm/10-io-multicore.md` §10.2.3).

### 34.2 Design

**The table.** `agc_runtime` gets `agc_string *chars[128]`, `empty_string`,
`empty_list`, `empty_map` and `empty_set`. `agc_vm_init` (`vm/interp.c:64`)
fills them before any task runs. The 129 strings can share one
`GC_MALLOC_ATOMIC` block (24 bytes each). Cost: about 3 KB for the strings, 72
bytes for the empty list, map and set, 1 KB of pointers in the runtime, and 132
or fewer small allocations at start-up (microseconds; the VM starts in about 1
ms).

**The constructors.** `agc_new_string`, `agc_new_list` and `agc_new_map` stay as
they are: builders fill and grow the objects they return. New helpers in
`vm/value.c` return the shared object or fall back to them:
`agc_small_string(vm, data, bytes, chars)` (shared when `bytes == 0`, or
`bytes == 1` and the byte is below 0x80), `agc_empty_list(vm)`,
`agc_empty_map(vm)` and `agc_empty_set(vm)`. The paths that switch to them
(the design as written, with the line numbers of that time;
[§34.6](#346-as-built) says what was built):

- **Value:** One-character or empty String
  - **Paths:** `split("")` `vm/strings.c:304`; `split` parts `vm/strings.c:131`;
    `trim` `:291`; `slice` `:421`; `at` `:440`; `from_code` `:469`; `join` of
    `[]` `:328`; `Result.message` of `ok` `vm/builtins.c:317`; empty input
    `vm/input.c:247`; JSON strings and keys `vm/json.c:170`, `:180`; `to_s` of a
    digit `vm/text.c:290`

- **Value:** `[]`
  - **Paths:** `LIST` with no items `vm/interp.c:552`; `filter`, `map`,
    `sort_by` with no result `vm/interp.c:341`; `take` `vm/builtins.c:200`;
    `drop` `:206`; `concat` `:134`; `repeat` `:187`; `reverse` `:212`;
    `Map.keys`, `values` `:237`; `Range.to_a` `:344`; `sort` `vm/interp.c:274`;
    JSON arrays `vm/json.c:138`

- **Value:** `Set.new([])`
  - **Paths:** `Set.new` with no items, `Set.delete` of the last element, and an
    `intersection` or `difference` with no element left (`builtin_set_new`,
    `builtin_set_delete`, `set_filter` in `vm/builtins.c`); the VM has no
    empty-set literal.

- **Value:** `{}`
  - **Paths:** `MAP` `vm/interp.c:566` (also as the start of a non-empty
    literal: `agc_map_put` never writes its input); `Map.delete` of the last key
    `vm/map.c:273`; typed JSON maps `vm/json_typed.c:93`

Other paths may keep allocating: nothing depends on sharing, so coverage can
grow with the numbers.

**Related candidate, already done.** The design noticed that `filter`
allocated its output as long as its input and only lowered `len` at the end.
The list rewrite (§17) fixed it: `filter` keeps its items in a staging array
and builds the result with `agc_list_from_array`, so the result is as long as
what was kept.

### 34.3 Why it is safe

- **Immutable.** No VM path writes to a value after a program can see it. The
  writes in `vm/` all go to fresh objects before they are returned: the text
  builder (`vm/text.c:124-156`, `:229`), the callback output that `filter`
  shrinks (`vm/interp.c:306-341`), `String.from_bytes` (`vm/strings.c:479-482`),
  the loader, and JSON and typed-decode fills. `List.append` and `List.set`
  copy, then write into the copy (`list_slice`, `vm/builtins.c:145-179`), so
  `list_slice` itself must keep returning a fresh list; maps are persistent. The
  rule for later code: only objects from `agc_new_*` are written, and only
  before they are returned. Any future update in place (the transients of 8d,
  `docs/vm/10-io-multicore.md` §10.2.3) must treat the shared objects as never
  unique.
- **No identity.** `==` compares Strings by bytes and does not apply to lists or
  maps (`grammar.md` §6); there is no object id, and printing shows no
  addresses. Sharing cannot change output.
- **GC.** The table lives in the runtime, a GC object reachable from every
  scheduler, so Boehm keeps it alive; strings are atomic and hold no pointers.
- **Multicore.** The runtime is read-only after start-up and shared by all
  schedulers (`docs/vm/10-io-multicore.md` §10.2.3); values are immutable, so
  schedulers read the table with no lock. No global is added.

### 34.4 Measurement first

- Add `benchmarks/programs/small-values.agc` and its Python twin: `split("")`
  and `at(i)` over a 1 MB ASCII text, `from_code` in a loop, `reduce` with `[]`
  and `{}` seeds over many small lists, grouping with `m.get(k, [])`, and a
  `filter` that keeps nothing.
- Run `make bench` before and after (`BENCH_ARGS="--runs 10"`): wall time and
  peak RSS for the new program and the ten existing ones. Count collections and
  bytes with `AGENTICA_VM_TRACE=gc` (add `total=`, from `GC_get_total_bytes`, to
  its end line).
- The gain may be small: Boehm already takes small atomic objects from a free
  list, and short-lived ones die cheaply. Drop the idea if the new program gains
  less than 10% wall time, or if any existing program slows by more than 2%.
  Record the numbers in `docs/vm-benchmarks.md` either way. The result: the
  new program takes 23% less time, and the existing programs stay within the
  noise of the link layout (§34.6).

### 34.5 Tests

- Existing goldens do not change: `make test` with no `make goldens` diff,
  and the `vm-sanitizers` job (ASan, GC stress). As built, one new golden
  (`shared-small-values`) prints the same output on the old and new VM.
- A C test in `vm/tests/string_test.c`: two `at` results of the same ASCII
  character and two `split("")` items share storage; a non-ASCII character does
  not; the table still holds the right text after `GC_gcollect`
  (`make vm-gc-stress`). As built, `LIST` with no items still allocates (the
  shared empty List in `vm/interp.c` was dropped, §34.6), so there is no `LIST`
  case. Not covered by a sharing assert: `IO.gets`, `IO.read`,
  `File.each_line` and a typed JSON decode of `{}` into a Map field.

### 34.6 As built

The table is in `agc_runtime` (`vm/port.h`) and `agc_vm_init` (`vm/interp.c`)
makes it: `empty_list`, `empty_map` and `empty_set` (values; the Map and the
Set are one `agc_map` under two tags), `empty_string` and `chars[128]`
(`agc_string *`). Nothing writes them. `agc_small_string(vm, data, bytes,
chars)` in `vm/value.c` returns the shared String for no bytes or one ASCII
byte, else a new one; the paths below call it, or read the table. There are no
`agc_empty_list`, `agc_empty_map` or `agc_empty_set` helpers: one field read
needs no function.

- **Value:** One-character or empty String
  - **Paths:** `String.at`, `slice` (a length of 0 returns before any scan),
    `trim` (it also returns its argument when there is nothing to trim),
    `from_code`, `from_bytes` (`[]` and one ASCII byte), `upcase` and `downcase`
    (the empty String is its own result, one ASCII character maps by itself),
    `reverse` (fewer than two characters is its own result), `join` and
    `replace` with nothing left, the pieces of `split`, the text of a one-digit
    number (`to_s`, `"#{3}"`), `Result.message` of `ok`, the strings and keys of
    `JSON.parse` and `JSON.decode` (`agc_json_parse` takes the vm), and the
    lines of `IO.gets`, `IO.read`, `File.each_line` and a stream

- **Value:** `[]`
  - **Paths:** `split("")` of the empty String, `take` of 0, `drop` of
    everything, `repeat` of 0, `Map.keys`, `Map.values` and `Set.to_a` of an
    empty collection, `Range.to_a` of an empty range; `reverse` of fewer than
    two items returns its argument

- **Value:** `Set.new([])`
  - **Paths:** `Set.new` with no items, `Set.delete` of the last element,
    `intersection` and `difference` with nothing left

- **Value:** `{}`
  - **Paths:** `Map.delete` of the last key, and the start of a typed JSON map

`Set.new`, the set filters and the typed JSON map start from the shared empty
value: `agc_map_put` and `agc_map_add_hash` never write their input.

Left out, after a measurement or because the gain is small:

- `CONCAT` with an empty side returning the other String. A loop of
  `(s + "")` allocates 198 MB before and 6.7 MB after, but
  `check compiler/parser.agc` allocates the same bytes, so no real program
  gains.
- `filter` and `map` with nothing to return. It saves one list of about 40
  bytes for each call. The edit is in `resume_native`, which also runs
  `File.each_line`, and in one link layout it moved that loop by +12%; the
  layouts differ by that much without any edit
  ([`docs/vm-benchmarks.md`](../vm-benchmarks.md), "Shared small values").
- The strings of `agc_utf8_decode` (process output, TCP reads, `read_text`),
  HTTP bodies and `Dir.list`: they allocate once for each I/O operation.
- The `[]` of a Json array: `agc_json_container` has no vm.

Every shared path keeps the turn cost it had, since the cost rule reads sizes
and not objects, and `make goldens` rewrites nothing.

Tests: `shared_strings` in `vm/tests/string_test.c`, `shared_empties` in
`vm/tests/map_test.c` and the keys of a parse in `vm/tests/json_test.c` check
that the builtins return the shared objects (and not for a non-ASCII or longer
result), and that a shared String still holds its text after a collection. The
golden `shared-small-values` builds on every shared value across tasks and
prints them again at the end.
