# VM core files: values, lists, maps, text, interpreter, loader, JSON, diagnostics

What each core file owns, then the gotchas of the core. Layers: `vm.md`.

## Files

| Path | Owns |
|---|---|
| `vm/value.h`, `vm/port.h`, `vm/core.h`, `vm/services.h` | the layer headers ("Which layer" in `vm.md`): `value.h` the values, program tables, memory and Json value API, with `agc_opcode` (same order as `opcodes` in `src/bytecode.rkt`); `port.h` the runtime structs and the port a service uses (with `agc_step`, `agc_stepper`, `agc_step_fn` and `agc_task_stepper`, the stepper protocol under "Adding a builtin"); `core.h` what only the core and the driver call; `services.h` the exports of the services |
| `vm/tools/check-layers.sh`, `vm/tools/check-layers-test.sh` | the layer check run by `make vm-layers` (`docs/vm/15-layers.md` §15.5): include rules with `rg`, link rules with `nm` on the objects (Linux only), the header chain; the self-test plants one violation at a time in a temporary copy and rebuilds the object for the link cases |
| `vm/loader.c` | full validation of untrusted `.agcb` input (`docs/vm/08-loader-and-cli.md` §8), including the struct and enum tables (one variant array sized by a first pass, one shared empty value per nullary variant) and the Types section (`load_types`: kinds, back-pointing List/Map entries at most 1024 deep, struct records with unique `json_name`s and `field_types`) |
| `vm/value.c` | allocation (and the GC stress hook), checked accessors, String allocation, UTF-8 checks and code point count (`agc_utf8_count`), `agc_error_value` (an `error` Result from C text), OOM/abort handlers |
| `vm/map.c` | maps: SipHash-1-3 over the value tag word then the key bytes keyed by `vm->hash_key` (set by `agc_vm_init`, then from OS entropy in `vm/main.c`: `getrandom`, then `/dev/urandom`, else the fixed key), the persistent HAMT (`agc_map_put`, `agc_map_get`, `agc_map_delete`, and `_hash` variants that take a given hash, for tests), and `agc_map_keys` (insertion order from the reversed key list) |
| `vm/list_impl.h` | private to the core: `struct agc_list` (`{ len, root, shift, tail[] }`), the trie node types and the `static inline` `list_len`, `list_at` (no bounds check; reads the tail in line and calls `agc_list_trie_get` of `list.c` for the trie) and `list_get`. `list.c` and `interp.c` (`LIST_LEN`, `LIST_GET`, hot in `for` loops) include it, and so does `vm/tests/list_test.c` for the shape checks; `make vm-layers` fails any other include |
| `vm/list.c` | lists: `struct agc_list` is defined in `list_impl.h` and opaque everywhere else, so no other file reads the layout; the layout is a persistent vector (a 32-way trie of leaves of 32 items plus an inline tail of 1 to 32 items, `root` NULL up to 32 items, canonical `shift` 5, 10, 15, 20 from 33, 1,057, 32,801 and 1,048,609 items; `append` and `set` copy the tail and the path and share the rest, so `push` and `set` are near constant time and `get` is one compare up to 32 items and at most 4 loads up to a million; `slice` (`take`, `drop`) and `concat` take the leaves of the source for the part that starts at a leaf (a `drop` from a multiple of 32 with at least half the list left, the left side of a `concat`, a `take`) and rebuild only the branches, and copy the rest; `reverse`, a `drop` from inside a leaf and the right side of a `concat` stay O(n)); the API of `value.h`: `agc_list_len`, `agc_list_get` (a bad index aborts; the caller checks it and fails with the program's diagnostic), a sized builder (`agc_list_builder_sized`, `_push`, `_finish`; `_push` and `agc_list_cursor_next` are `static inline` in `value.h` over the write pointer and the chunk, with `_advance` and `_fill` as the slow path; the only code that writes a list, and only before it returns it; a wrong count aborts) for every new list whose count is known, `agc_list_from_array` for a staged array (`filter`), `agc_list_to_array`, `agc_list_reverse`, `agc_list_repeat` (one leaf shared by the whole trie, so `List.repeat` is O(log n)), `agc_list_cursor_begin`/`_next` for scans, and `agc_list_append`, `_set`, `_slice` and `_concat`, which never write to their input. Builders and cursors live on the C stack or in `agc_alloc` memory. A sized builder allocates the whole trie at once, the branches of each level as one array and the items of all leaves as one array (a leaf is a 32-item slice of it), so a build makes a handful of allocations and a push is a store; never allocate one node per push, that was six times slower than a flat array for a million items and starved the GC-stress fixtures. `slice`, `concat` and `from_array` copy a leaf at a time with `memcpy`; a leaf is a slice of the array of the build that made it, so a list that shares leaves keeps that array alive (`slice` shares only when it keeps at least half of the source). A cursor reads leaf by leaf (one descent per leaf). `List.append`, `List.set` and a `List.concat` with 32 items or fewer cost no turn units (the builtin charges `2 * (a + b)` for a longer right list). `docs/vm/17-lists.md`; the gate is `benchmarks/programs/list-build.agc` |
| `vm/text.c` | text and debug forms (`agc_text`, `agc_debug`, and `agc_test_text`, the debug form with each `Json` as its canonical text, for `Test.eq`; lists, maps, structs, enums and Results through one explicit `agc_alloc`'d stack and a growing String, names from the program's tables), `agc_concat`, and `agc_write_form`, the one Racket `write` escaper for Strings |
| `vm/unicode_data.c` | generated by `vm/tools/gen-unicode.rkt` from Racket (`make vm-unicode`); never edit by hand: write-escape ranges, full case maps, cased and case-ignorable ranges (final sigma) |
| `vm/strings.c` | the `String` builtins (`agc_string_builtins`, one of the tables `agc_find_builtin` loops over) and their helpers: `split` returns the shared one-character ASCII Strings of `rt->chars` (made in `agc_vm_init`) for a one-byte ASCII piece; UTF-8 encode, `agc_utf8_offset` with each task's one-entry cursor (string, code point index, byte offset), KMP search (`agc_text_find`), `agc_change_case`, `agc_parse_int`, `agc_parse_float` |
| `vm/interp.c` | one turn of the current task (`agc_run_turn`, returns yield, parked or done) and the budgets: the "next stop" counter of `STEP` over the turn and the batch taken from the runtime's atomic `steps_left` (`agc_turn_begin`, `agc_turn_finish`, the slow path), the turn-cost apply path after `CALL_BUILTIN`, between callbacks and after `CONCAT`, `TO_TEXT`, `INSPECT`, `EQ`, `NE`, `SAME`, `MAP`, `MAP_GET` (`agc_charge`, `agc_charge_bytes`; skipped with `AGENTICA_VM_TEST_NO_TURN_COST=1`); frames, registers, call depth, `TAIL_CALL` frame replacement, `TRY` (returns an error like `RETURN`; one that would empty the call stack is `RUNTIME-INTERNAL`), Int rules, `CLOSURE`/`CALL_VALUE`, and the resumable `List` callback builtins (native frames, `agc_native` state); `agc_sort_by_keys` sorts `(key, index)` entries, with Int and Float keys turned into `uint64_t` that order alike, returns the input for keys in order and `agc_list_reverse` of it for keys strictly falling, and the stepper builtins (7.2.1h): a builtin calls `agc_task_stepper(vm, &state->stepper)` and returns, then `CALL_BUILTIN` sees `t->stepper` and `start_stepper` pushes an `AGC_NATIVE_STEPPER` frame whose block is the builtin's last argument; `resume_stepper` asks the step function (`agc_step_fn`) what to do next: `AGC_STEP_CALL` calls the block with one argument and the block's result is the next `last` (read from the native frame's base register), `AGC_STEP_WAIT` parks the task (the step function started a job, so `t->parking` must be set, else `RUNTIME-INTERNAL`) and the job's result is the next `last`, `AGC_STEP_END` finishes the builtin with the step's value; a native top frame is resumed at the start of every turn; each call costs one step plus the turn cost; core code cannot call services, so the function pointer is installed at run time |
| `vm/builtins.c` | the core builtins (`agc_core_builtins`: `IO`, `System`, `List`, `Map`, `Result`, `Range`) and `agc_find_builtin`, which matches by implementation key and arity from the import table over `agc_builtin_tables`; `agc_builtin_struct` and `agc_builtin_variant` find a builtin struct or an enum variant (`Await.Done`, `Await.TimedOut`) by name in the program's tables, else `RUNTIME-INTERNAL` |
| `vm/builtin_tables.c` | `agc_builtin_tables`, the list of every library's own table in lookup order (the first match wins): the one place that names the services' tables; a new builtin library adds its table here and its `extern` to `vm/services.h` |
| `vm/numbers.c` | `Float`, `Time` and `Random` builtins (`agc_number_builtins`) |
| `vm/random.c` | xoshiro256** seeded with splitmix64, both public domain (`agc_random_seed`, `agc_random_next`, `agc_random_float`, `agc_random_int`; `docs/vm/05-values-execution-builtins.md` §7.4) |
| `vm/json.c` | the `JSON` builtins (`agc_json_builtins`) and `agc_json_parse` (the Racket control-character pass, top-level numbers and literals by hand, strings, arrays and objects through yyjson with `STOP_WHEN_DONE` and `NUMBER_AS_RAW`, then a copy into GC nodes with an explicit stack, built with the node functions of `vm/json_value.c`; `docs/vm/02-reference-behavior.md` §2.6) |
| `vm/json_value.c` | the `Json` value (`agc_json` nodes, 5.1), in the core because `text.c` and `equal.c` print and compare a Json: `agc_json_encode` (the one `write-json` writer, for `JSON.encode` and the text form of a Json) and `agc_json_from` (builders), both over one explicit stack; the node functions the parser and the builtins share (`agc_json_leaf`, `agc_json_object`, `agc_json_array`, `agc_json_container`, `agc_json_store` and `agc_json_finish`, which sorts the members by key bytes and drops repeated keys, and `agc_json_find`); the buffer, stack growth and ASCII helpers (`agc_json_put`, `agc_json_grow`, `agc_json_ascii`) |
| `vm/json_typed.c` | `agc_json_decode` and `agc_json_schema` (`docs/vm/02-reference-behavior.md` §2.7): one explicit frame stack over the Json tree and the type table, the error path built from the frames only on failure; schema marks the types and structs reachable from the target with a queue, then builds their schemas in index order. The buffer, stack growth and ASCII helpers are `agc_json_put`, `agc_json_grow` and `agc_json_ascii` from `vm/json_value.c`. The builtins in `vm/json.c` find the struct by its linked name (`json_name`) |
| `vm/equal.c` | `agc_equal`, the deep compare of §25.4 pulled forward for `Test.eq`: one explicit stack of value pairs, one turn unit per pair, Strings through `agc_same_string` (also used by `EQ` and the map key compare), Floats by IEEE 754, maps by key in any order, a `Json` by its canonical `agc_json_encode` text, `RUNTIME-INTERNAL` for values with no equality; meant for `==` (15d) and BDD (25b) too |
| `vm/diag.c` | the plain, `--ai` and `--json` diagnostic formats, the same formats as `src/diagnostic.rkt`; only the code must match; a task crash adds ` in a task` (plain, `--ai`) or `"task":true` (`--json`); `agc_crash_text` and the unobserved summary line (`agc_print_unobserved`); the stack trace of a runtime error (14b): `agc_stack_capture`, called by `agc_fail` while a task runs, walks the task's frames (native frames skipped, equal neighbours merged, 15 innermost and 5 outermost kept) into the fixed `outcome.stack`, and the three printers write it (`  = stack, innermost first:` in plain, `  stack:` in `--ai`, `stack`, `stack_omitted` and `spawned_at` in `--json`); `Child.stderr_diagnostic` and `Child.stderr_text` (`stdlib/test/child.agc`) recognise a child's `--json` diagnostic or task-crash line by its exact keys, so `vm_shape?` accepts `spawned_at`, `stack` and `stack_omitted` as optional keys: add any new key to the diagnostic there too, or a crash of a test handler becomes `RUNTIME-BDD-PREMATURE-EXIT`; it allocates nothing and clamps every index, so a bad `pc` or span index in a hand-built program cannot read out of bounds; the printers cut a function name or path to 256 bytes at a character boundary (`...` marks the cut; the diagnostic's own first line is not cut); `crash` in `vm/task.c` copies `outcome.stack` into the task (`crash_stack`), and `agc_stack_members` builds the `stack`, `stack_omitted` and `spawned_at` members that `fail_line` in `vm/testing.c` adds to the `fail` record of a test whose task crashed |
| `vm/trace.h`, `vm/trace.c` | VM tracing (`AGENTICA_VM_TRACE`, `docs/future/24-logging.md` §24.4, as built in `docs/vm/08-loader-and-cli.md` §9): the `agc_trace` struct, category bits, `AGC_TRACE_ON` and `AGC_TRACE`; `agc_trace_parse`, `agc_trace_message`, `agc_trace_format` (for the C test) and `agc_trace_emit` (one 512-byte stack line, one `write(2)`) |
| `vm/fuzz.c`, `vm/fuzz_main.c` | `agc_fuzz_one` and the mutation driver (not in the release binary) |

## Gotchas

- JSON parsing matches what the old evaluator did (Racket's `read-json` plus the checks of its deleted `src/json.rkt`),
  not RFC 8259 alone: the control-character pass runs first over the whole
  text, a top-level number or literal stops early (`01` is unexpected
  content, `truex` invalid), the finite check comes after the trailing
  check, a mantissa of zeros is `0.0` whatever its sign, and duplicate
  keys keep the last value (`docs/vm/02-reference-behavior.md` §2.6). yyjson reads numbers as
  raw text so the VM converts them itself; never turn on its `ALLOW_*`
  flags or its writer. Bumping yyjson: check out the new tag inside
  `vm/third_party/yyjson`, `git add vm/third_party/yyjson`, and rerun the
  sanitizer and diff tests.
- `Random` differs from the evaluator by design: the VM uses xoshiro256**
  and the evaluator Racket's `random`, so seeded sequences differ between
  backends (`docs/vm/05-values-execution-builtins.md` §7.4). A `Random` fixture prints only what both
  share (counts of in-range values, `[0, 1)` checks), never drawn
  numbers.
- Float text is not `printf("%.17g")` or "first `%.*e` that round-trips":
  Racket breaks exact ties upward and uses the asymmetric interval at powers
  of two. Keep `agc_float_text` as `docs/vm/02-reference-behavior.md` §2.2 describes it, and add
  any new tricky value to `vm/tests/float_text_test.c` with the text Racket
  prints.
- The load budget is 4 bytes per file byte plus 1 MiB. Keep per-entry
  costs low (one array for all variants, sized by a first pass; no
  temporary copies): a real program with 65535 variants must load.
  `load_alloc(0)` returns NULL without charging anything.
- Callback builtins are native frames, not C calls into the loop: the C
  table entry has an `agc_native_kind`; `CALL_BUILTIN` copies the
  arguments into an `agc_native` GC object and pushes a frame with
  `native` set at `R[a]`; callbacks run at `R[a+1]` with result register
  `R[a]`, and `return_value` resumes the native frame when it is on top.
  `frame_count` counts every frame, `depth` only bytecode frames, so the
  call-depth limit matches the evaluator (callback push fails at the
  builtin's call span). Deep recursion through a callback must not use
  `return f(...)` in the block in a fixture: that is a tail call on the
  VM only.
- Maps keep insertion order exactly, as the old evaluator did: a HAMT from
  key to value plus a reversed cons list of keys (the old `mapping` of the
  deleted `src/runtime-values.rkt`). A new key conses one cell; a replaced key
  keeps its cell. Never keep order in an array copied on every put. The
  hash is keyed per run, so nothing observable may depend on it; the
  printer, `Map.keys` and `Map.values` walk the key list, not the trie.
  `Map.delete` copies the trie path and the key list up to the key's cell
  (the rest is shared); a missing key returns the same map. `List.sort`
  reuses `agc_sort_by_keys` (`vm/interp.c`) with the items as their own
  keys. `MAP` and `Map.put` share
  `agc_map_put`; HAMT recursion is bounded by 14 levels, printing nested
  maps goes through the explicit-stack printer.
- Lists can share items, so a list's text can be exponential in the code
  that built it (`a1 = [a0, a0]`, `a2 = [a1, a1]`, ...); printing then ends in the out-of-memory exit, as the trust
  model allows. Never print or compare nested values with C recursion.
- Racket `write` prints the joiners U+200C, U+200D and U+E0020 to U+E007F
  raw only after a raw non-blank character, so the debug form has state;
  see `docs/vm/02-reference-behavior.md` §2.3 before touching `agc_write_form`.
- `--max-steps` bounds instructions, not bytes: string ops cost in
  proportion to their size.
- Strings: `agc_string` keeps the byte and code point counts; build every
  `String` result with a sizing pass then a fill pass (or one copy), never
  by repeated concatenation, and search with the KMP finder in
  `vm/strings.c`, not a naive loop. Racket's `String.trim` is `\s` only
  (five ASCII bytes); case mapping is the tables plus final sigma
  (`docs/vm/02-reference-behavior.md` §2.3), and a new contextual case rule must come with a
  generator check, not by hand. Float text goes to `strtod` only after
  the evaluator's pattern check.
- `string-trim` in `format-diagnostic-ai` trims only ASCII `[ \t\n\f\r]`,
  not Unicode whitespace; the VM matches that.
