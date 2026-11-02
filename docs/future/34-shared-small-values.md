## 34. Shared small values in the VM

**Status:** built (roadmap 7g). The 128 one-character ASCII Strings and the
empty List, Map, Set and String came first, with the list performance PR and the
speed pass (PR #319). An implementation proposal with no language change, in the
spirit of CPython's small-int cache: the VM makes some values once and returns
the same object every time a program computes them.

### 34.3 Why it is safe

- **Immutable.** No VM path writes to a value after a program can see it. The
  writes in `vm/` all go to fresh objects before they are returned: the text
  builder (`vm/text.c`), the callback output that `filter` shrinks
  (`vm/interp.c`), `String.from_bytes` (`vm/strings.c`), the loader, and JSON
  and typed-decode fills. `List.append` and `List.set` copy, then write into the
  copy (`list_slice`, `vm/builtins.c`), so `list_slice` itself must keep
  returning a fresh list; maps are persistent. The rule for later code: only
  objects from `agc_new_*` are written, and only before they are returned. Any
  future update in place (the transients of 8d, `docs/vm/10-io-multicore.md`
  §10.2.3) must treat the shared objects as never unique.
- **No identity.** `==` compares Strings by bytes and does not apply to lists or
  maps (`grammar.md` §6); there is no object id, and printing shows no
  addresses. Sharing cannot change output.
- **GC.** The table lives in the runtime, a GC object reachable from every
  scheduler, so Boehm keeps it alive; strings are atomic and hold no pointers.
- **Multicore.** The runtime is read-only after start-up and shared by all
  schedulers (`docs/vm/10-io-multicore.md` §10.2.3); values are immutable, so
  schedulers read the table with no lock. No global is added.

### 34.6 As built

The numbers are in [`docs/vm-benchmarks.md`](../vm-benchmarks.md) ("Shared small
values"). The table is in `agc_runtime` (`vm/port.h`), made by `agc_vm_init`:
`empty_list`, `empty_map` and `empty_set` (the Map and the Set are one `agc_map`
under two tags), `empty_string` and `chars[128]`. Nothing writes them.
`agc_small_string` (`vm/value.c`) returns the shared String for no bytes or one
ASCII byte, else a new one; the other paths read the table directly (one field
read needs no helper). Callers: `rg agc_small_string vm/`.

Left out, after a measurement or because the gain is small:

- `CONCAT` with an empty side returning the other String: a loop of `(s + "")`
  allocates 198 MB before and 6.7 MB after, but `check
  compiler/syntax/parser.agc` allocates the same, so no real program gains.
- `filter` and `map` with nothing to return: it saves one list of about 40 bytes
  per call, and the edit in `resume_native` (shared with `File.each_line`) moved
  that loop by +12% in one link layout (layouts differ by that much without any
  edit).
- The strings of `agc_utf8_decode`, HTTP bodies and `Dir.list` (one allocation
  per I/O operation), and the `[]` of a Json array (`agc_json_container` has no
  vm).

Every shared path keeps the turn cost it had, since the cost rule reads sizes
and not objects. Tests: `shared_strings`, `shared_empties` and the keys test in
`vm/tests`, and the golden `shared-small-values`.
