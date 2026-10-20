## 34. Shared small values in the VM

**Status:** built (roadmap 7g). The 128 one-character ASCII Strings and the
empty List, Map, Set and String came first, with the list performance PR and the
speed pass (PR #319). An implementation proposal with no language change, in the
spirit of CPython's small-int cache: the VM makes some values once and returns
the same object every time a program computes them.

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

### 34.6 As built

The numbers are in [`docs/vm-benchmarks.md`](../vm-benchmarks.md)
("Shared small values"). The table is in `agc_runtime` (`vm/port.h`) and
`agc_vm_init` (`vm/interp.c`)
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

- `CONCAT` with an empty side returning the other String. A loop of `(s + "")`
  allocates 198 MB before and 6.7 MB after, but `check
  compiler/syntax/parser.agc` allocates the same bytes, so no real program
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
