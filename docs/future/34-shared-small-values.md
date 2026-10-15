## 34. Shared small values in the VM

**Status:** a candidate (roadmap 7g), kept only if a measurement shows it helps.
Partly built by the list performance PR
([§17.11](../vm/17-lists.md)): `agc_runtime` has the 128 one-character ASCII
Strings (`chars`, made in `agc_vm_init`) and `String.split` uses them, which
took `split(big, "")` of a million characters from 85 ms to 9 ms. The other
paths and the empty list, map and string are still open.
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

### 34.1 Today

Checked at `5fb7ed7`:

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
fills them before any task runs. The 129 strings can share one `GC_MALLOC_ATOMIC` block (24 bytes
each). Cost: about 3 KB for the strings, 48 bytes for the empty list and map, 1
KB of pointers in the runtime, and 131 or fewer small allocations at start-up
(microseconds; the VM starts in about 1 ms).

**The constructors.** `agc_new_string`, `agc_new_list` and `agc_new_map` stay as
they are: builders fill and grow the objects they return. New helpers in
`vm/value.c` return the shared object or fall back to them:
`agc_small_string(vm, data, bytes, chars)` (shared when `bytes == 0`, or
`bytes == 1` and the byte is below 0x80), `agc_empty_list(vm)`,
`agc_empty_map(vm)` and `agc_empty_set(vm)`. The paths that switch to them:

| Value | Paths |
|---|---|
| One-character or empty String | `split("")` `vm/strings.c:304`; `split` parts `vm/strings.c:131`; `trim` `:291`; `slice` `:421`; `at` `:440`; `from_code` `:469`; `join` of `[]` `:328`; `Result.message` of `ok` `vm/builtins.c:317`; empty input `vm/input.c:247`; JSON strings and keys `vm/json.c:170`, `:180`; `to_s` of a digit `vm/text.c:290` |
| `[]` | `LIST` with no items `vm/interp.c:552`; `filter`, `map`, `sort_by` with no result `vm/interp.c:341`; `take` `vm/builtins.c:200`; `drop` `:206`; `concat` `:134`; `repeat` `:187`; `reverse` `:212`; `Map.keys`, `values` `:237`; `Range.to_a` `:344`; `sort` `vm/interp.c:274`; JSON arrays `vm/json.c:138` |
| `Set.new([])` | `Set.new` with no items, `Set.delete` of the last element, and an `intersection` or `difference` with no element left (`builtin_set_new`, `builtin_set_delete`, `set_filter` in `vm/builtins.c`); the VM has no empty-set literal. |
| `{}` | `MAP` `vm/interp.c:566` (also as the start of a non-empty literal: `agc_map_put` never writes its input); `Map.delete` of the last key `vm/map.c:273`; typed JSON maps `vm/json_typed.c:93` |

Other paths may keep allocating: nothing depends on sharing, so coverage can
grow with the numbers.

**Related, separate candidate.** `filter` allocates its output list as long as
its input and only lowers `len` at the end (`vm/interp.c:341`), so a filter that
keeps few items holds the whole allocation. The fix to evaluate is shrinking the
list to the kept length (`GC_REALLOC`) or copying the kept items into a new
list; it needs its own measurement, peak RSS above all, with the same benchmark.

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
  Record the numbers in `docs/vm-benchmarks.md` either way.

### 34.5 Tests

- Goldens do not change: `make test` with no `make goldens` diff, and the
  `vm-sanitizers` job (ASan, GC stress).
- A C test in `vm/tests/string_test.c`: two `at` results of the same ASCII
  character, two `split("")` items, and two empty lists from `LIST` share
  storage; a non-ASCII character does not; the table still holds the right text
  after `GC_gcollect` (`make vm-gc-stress`).
