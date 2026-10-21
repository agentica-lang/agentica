# VM core: values, lists, maps, text, interpreter, loader, JSON, diagnostics

What each core file owns, then the gotchas of the core.

Read first: `references/vm.md` and `references/vm-c.md`.

## Files

- **Path:** `vm/value.h`, `vm/port.h`, `vm/core.h`, `vm/services.h`
  - **Owns:** the layer headers ("Which layer" in `vm.md`): `value.h` the
    values, program tables, memory and Json value API, with `agc_opcode` (same
    order as `OPCODES` in `compiler/bytecode/bytecode_tables.agc`); `port.h` the
    runtime structs and the port a service uses (with `agc_step`, `agc_stepper`,
    `agc_step_fn` and `agc_task_stepper`, the stepper protocol under "Adding a
    builtin"); `core.h` what only the core and the driver call; `services.h` the
    exports of the services

- **Path:** `vm/tools/check-layers.sh`, `vm/tools/check-layers-test.sh`
  - **Owns:** the layer check run by `make vm-layers` (`docs/vm/15-layers.md`
    §15.5): include rules with `rg`, link rules with `nm` on the objects (Linux
    only), the header chain; the self-test plants one violation at a time in a
    temporary copy and rebuilds the object for the link cases

- **Path:** `vm/loader.c`
  - **Owns:** full validation of untrusted `.agcb` input
    (`docs/vm/08-loader-and-cli.md` §8; it takes a table of fixed-size entries
    once and decodes it with `get_u16` and `get_u32`, indexes the lines of a
    source by words, and holds the collector off with `agc_gc_pause` and
    `agc_gc_resume` while it loads (value.c; the GC-stress build ignores them):
    the front end is 3.8 MB and loads in about 9 ms, half of it page faults;
    `agc_utf8_chars` and `agc_utf8_count` skip eight ASCII bytes at a time, with
    the one-character path as the reference in `string_test.c`), including the
    struct and enum tables (one variant array sized by a first pass, one shared
    empty value per nullary variant) the Updates section (`load_updates`: struct
    index, strictly increasing field indexes below the field count; the
    `STRUCT_WITH` operand check against it) and the Types section (`load_types`:
    kinds, back-pointing List/Map entries at most 1024 deep, struct records with
    unique `json_name`s and `field_types`) and the Globals section
    (`load_globals`: a slot count of at most `AGC_MAX_GLOBALS`, the zeroed slot
    array from `load_alloc` stored in `agc_program.globals`; `check_function`
    checks every `GLOBAL` and `GLOBAL_SET` index and, when the count is above
    zero, allows `GLOBAL_SET` only in the entry function and only where the
    function has no backward jump, and `check_not_entry` rejects a `CALL`,
    `TAIL_CALL` or `CLOSURE` of the entry)

- **Path:** `vm/value.c`
  - **Owns:** allocation (and the GC stress hook), `agc_wrong_tag` and the
    constructors and accessors of the service resources (the common ones are
    `static inline` in `value.h`), String allocation (`agc_small_string` returns
    the shared empty String for no bytes and the shared one-character String for
    one ASCII byte, else a new one; use it wherever a builtin cuts or builds a
    String from bytes it does not own), UTF-8 checks and code point count
    (`agc_utf8_count`), `agc_error_value` (an `error` Result from C text),
    OOM/abort handlers

- **Path:** `vm/map.c`
  - **Owns:** maps and sets: SipHash-1-3 over the value tag word then the key
    bytes keyed by `vm->hash_key` (set by `agc_vm_init`, then from OS entropy in
    `vm/launch.c`: `getrandom`, then `/dev/urandom`, else the fixed key), the
    persistent HAMT (`agc_map_put`, `agc_map_get`, `agc_map_delete`, and `_hash`
    variants that take a given hash, for tests; `agc_map_add_hash` puts only a
    new key and returns the same map for a member, which `Set.add` and `Set.new`
    use), and `agc_map_keys` (insertion order from the reversed key list)

- **Path:** `vm/list_impl.h`
  - **Owns:** private to the core: `struct agc_list` (`{ len, root, shift, kind,
    tail[] }`), the trie node type and the `static inline` `list_len`,
    `list_item` (builds the value from the list's kind), `list_at` (no bounds
    check; reads the tail in line and calls `agc_list_trie_get` of `list.c` for
    the trie) and `list_get`. `list.c` and `interp.c` (`LIST_LEN`, `LIST_GET`,
    hot in `for` loops) include it, and so does `vm/tests/list_test.c` for the
    shape checks; `make vm-layers` fails any other include

- **Path:** `vm/list.c`
  - **Owns:** Lists: the persistent vector behind the opaque list API. The
    layout stays private to this file and `list_impl.h`.

- **Path:** `vm/text.c`
  - **Owns:** text and debug forms (`agc_text`, `agc_debug`, and
    `agc_test_text`, the debug form with each `Json` as its canonical text, for
    `Test.eq`; lists, maps, structs, enums and Results through one explicit
    `agc_alloc`'d stack and a growing String, names from the program's tables),
    `agc_concat`, and `agc_write_form`, the one Racket `write` escaper for
    Strings

- **Path:** `vm/unicode_data.c`
  - **Owns:** frozen, checked-in data (it came from Racket 9.3's Unicode 17.0
    tables; the header says how a future generator must match it); edit by hand
    only for a deliberate Unicode update: write-escape ranges, full case maps,
    cased and case-ignorable ranges (final sigma)

- **Path:** `vm/strings.c`
  - **Owns:** the `String` builtins (`agc_string_builtins`, one of the tables
    `agc_find_builtin` loops over) and their helpers: the shared Strings of
    `rt->chars` and `rt->empty_string` (made in `agc_vm_init`) come back from
    `split`, `at`, `slice`, `trim`, `from_code`, `from_bytes`, `upcase`,
    `downcase`, `reverse`, `join` and `replace` through `agc_small_string` (or
    an inline check in the hot `piece`), and `trim`, `reverse` and the case maps
    return their argument when nothing changes; UTF-8 encode, `agc_utf8_offset`
    with each task's one-entry cursor (string, code point index, byte offset),
    KMP search (`agc_text_find`), `agc_change_case`, `agc_parse_int`,
    `agc_parse_float`

- **Path:** `vm/interp.c`
  - **Owns:** The interpreter: one turn of the current task and the step and
    cost budgets of a turn.

- **Path:** `vm/builtins.c`
  - **Owns:** the core builtins (`agc_core_builtins`: `IO`, `System`, `List`,
    `Map`, `Set`, `Result`, `Range`) and `agc_find_builtin`, which matches by
    implementation key and arity from the import table over
    `agc_builtin_tables`; `agc_builtin_struct` and `agc_builtin_variant` find a
    builtin struct or an enum variant (`Await.Done`, `Await.TimedOut`) by name
    in the program's tables, else `RUNTIME-INTERNAL`

- **Path:** `vm/builtin_tables.c`
  - **Owns:** `agc_builtin_tables`, the list of every library's own table in
    lookup order (the first match wins): the one place that names the services'
    tables; a new builtin library adds its table here and its `extern` to
    `vm/services.h`

- **Path:** `vm/numbers.c`
  - **Owns:** `Float`, `Time` and `Random` builtins (`agc_number_builtins`)

- **Path:** `vm/random.c`
  - **Owns:** xoshiro256** seeded with splitmix64, both public domain
    (`agc_random_seed`, `agc_random_next`, `agc_random_float`, `agc_random_int`;
    `docs/vm/05-values-execution-builtins.md` §7.4)

- **Path:** `vm/json.c`
  - **Owns:** the `JSON` builtins (`agc_json_builtins`) and `agc_json_parse`
    (the Racket control-character pass, top-level numbers and literals by hand,
    strings, arrays and objects through yyjson with `STOP_WHEN_DONE` and
    `NUMBER_AS_RAW`, then a copy into GC nodes with an explicit stack, built
    with the node functions of `vm/json_value.c`;
    `docs/vm/02-reference-behavior.md` §2.6)

- **Path:** `vm/json_value.c`
  - **Owns:** the `Json` value (`agc_json` nodes, 5.1), in the core because
    `text.c` and `equal.c` print and compare a Json: `agc_json_encode` (the one
    `write-json` writer, for `JSON.encode` and the text form of a Json) and
    `agc_json_from` (builders), both over one explicit stack; the node functions
    the parser and the builtins share (`agc_json_leaf`, `agc_json_number`,
    `agc_json_pair` (a number leaf and a key/value member, also used by `diag.c`
    and `testing.c`), `agc_json_object`, `agc_json_array`, `agc_json_container`,
    `agc_json_store` and `agc_json_finish`, which sorts the members by key bytes
    and drops repeated keys, and `agc_json_find`); the buffer, stack growth and
    ASCII helpers (`agc_json_put`, `agc_json_grow`, `agc_json_ascii`)

- **Path:** `vm/json_typed.c`
  - **Owns:** `agc_json_decode` and `agc_json_schema`
    (`docs/vm/02-reference-behavior.md` §2.7): one explicit frame stack over the
    Json tree and the type table, the error path built from the frames only on
    failure; schema marks the types and structs reachable from the target with a
    queue, then builds their schemas in index order. The buffer, stack growth
    and ASCII helpers are `agc_json_put`, `agc_json_grow` and `agc_json_ascii`
    from `vm/json_value.c`. The builtins in `vm/json.c` find the struct by its
    linked name (`json_name`)

- **Path:** `vm/equal.c`
  - **Owns:** `agc_equal`, the deep compare of §25.4 pulled forward for
    `Test.eq`: one explicit stack of value pairs, one turn unit per pair,
    Strings through `agc_same_string` (also used by `EQ` and the map key
    compare), Floats by IEEE 754, maps by key in any order, a `Json` by its
    canonical `agc_json_encode` text, `RUNTIME-INTERNAL` for values with no
    equality; meant for `==` (15d) and BDD (25b) too

- **Path:** `vm/diag.c`
  - **Owns:** Diagnostic output in the plain, `--ai` and `--json` formats, and
    the stack trace of a runtime error.

- **Path:** `vm/trace.h`, `vm/trace.c`
  - **Owns:** VM tracing (`AGENTICA_VM_TRACE`, as built in
    `docs/vm/08-loader-and-cli.md` §9): the `agc_trace`
    struct, category bits, `AGC_TRACE_ON` and `AGC_TRACE`; `agc_trace_parse`,
    `agc_trace_message`, `agc_trace_format` (for the C test) and
    `agc_trace_emit` (one 512-byte stack line, one `write(2)`),
    `agc_trace_write`

- **Path:** `vm/profile.c`
  - **Owns:** the profile category (`AGENTICA_VM_TRACE=profile`): its counters,
    the end-of-run report, the `Profile.measure` sections, the folded stacks
    (`AGENTICA_PROFILE_FORMAT=folded`) and the `Profile` builtins

- **Path:** `vm/launch.c`, `vm/launch.h`
  - **Owns:** driver code shared by the two runs of the binary (`agentica run`
    and the front end): `agc_launch_parse` (the VM options, with the program
    name in the messages), seeds, the trace file, `agc_launch_ignore_sigpipe`,
    `agc_launch_vm` (a runtime from a loaded program; a front end gets
    `rt->front_end`, no stdin and no parent channel), `agc_launch_settle` /
    `agc_launch_exit` (the one exit path)

- **Path:** `vm/agentica.c`, `vm/embedded.h`
  - **Owns:** the single binary (Linux): loads the front end with
    `agc_load_front_end` (any Agentica version), runs it, and when it called
    `FrontEnd.hand_off` and ended with status 0 retires it (`agc_launch_settle`,
    `agc_io_close`, `agc_gc_collect`) and runs the handed program in a new
    runtime; `--front-end FILE.agcb` replaces the carried front end; the
    embedded data is described by `agc_embedded_data` and `agc_embedded_index`
    (written by `vm/tools/gen-embedded.sh`)

- **Path:** `vm/front_end.c`
  - **Owns:** `FrontEnd.hand_off`, `FrontEnd.std_source` and
    `FrontEnd.stdin_bytes` (a service,
    `agc_front_end_builtins`): they fail with `RUNTIME-FRONT-END-ONLY` when
    `rt->front_end` is NULL, which it is for every runtime except the front end
    of the single binary

- **Path:** `vm/fuzz.c`, `vm/fuzz_main.c`
  - **Owns:** `agc_fuzz_one` and the mutation driver (not in the release binary)

- `vm/list.c`
  - lists: `struct agc_list` is defined in `list_impl.h` and opaque everywhere
    else, so no other file reads the layout
  - a list has a `kind` that the code decides from the values it stores: 0 for
    16-byte `agc_value` items, `AGC_T_INT` or `AGC_T_FLOAT` when every item has
    that tag, and then the leaves and the tail hold 8 raw bytes per item (leaf
    blocks from `agc_alloc_atomic`, branches and the list object from
    `agc_alloc`; an empty list has kind 0, the first item decides,
    `docs/vm/17-lists.md` §17.12)
  - the sized builder allocates at its first push, `agc_list_builder_more` is
    its slow path and turns a numeric builder into a boxed one when a tag
    differs, and `append`, `set`, `concat` (of lists of different kinds) and
    `agc_list_from_array` box in the same case, which only hostile bytecode
    causes
  - shared leaves exist only between lists of one kind
  - the layout is a persistent vector (a 32-way trie of leaves of 32 items plus
    an inline tail of 1 to 32 items, `root` NULL up to 32 items, canonical
    `shift` 5, 10, 15, 20 from 33, 1,057, 32,801 and 1,048,609 items; `append`
    and `set` copy the tail and the path and share the rest, so `push` and `set`
    are near constant time and `get` is one compare up to 32 items and at most 4
    loads up to a million; `slice` (`take`, `drop`) and `concat` take the leaves
    of the source for the part that starts at a leaf (a `drop` from a multiple
    of 32 with at least half the list left, the left side of a `concat`, a
    `take`) and rebuild only the branches, and copy the rest; `reverse`, a
    `drop` from inside a leaf and the right side of a `concat` stay O(n))
  - the API of `value.h`: `agc_list_len`, `agc_list_get` (a bad index aborts;
    the caller checks it and fails with the program's diagnostic), a sized
    builder (`agc_list_builder_sized`, `_push`, `_finish`; `_push` and
    `agc_list_cursor_next` are `static inline` in `value.h` over the write
    pointer and the chunk, with `_more` and `_fill` as the slow path; the only
    code that writes a list, and only before it returns it; a wrong count
    aborts) for every new list whose count is known, `agc_list_from_array` for a
    staged array (`filter`), `agc_list_to_array`, `agc_list_reverse`,
    `agc_list_repeat` (one leaf shared by the whole trie, so `List.repeat` is
    O(log n)), `agc_list_cursor_begin`/`_next` for scans, and `agc_list_append`,
    `_set`, `_slice` and `_concat`, which never write to their input.
  - Builders and cursors live on the C stack or in `agc_alloc` memory.
  - A sized builder allocates the whole trie at once, the branches of each level
    as one array and the items of all leaves as one array (a leaf is a 32-item
    slice of it), so a build makes a handful of allocations and a push is a
    store
  - never allocate one node per push, that was six times slower than a flat
    array for a million items and starved the GC-stress fixtures.
  - `slice`, `concat` and `from_array` copy a leaf at a time with `memcpy`
  - a leaf is a slice of the array of the build that made it, so a list that
    shares leaves keeps that array alive (`slice` shares only when it keeps at
    least half of the source).
  - A cursor reads leaf by leaf (one descent per leaf).
  - `List.append`, `List.set` and a `List.concat` with 32 items or fewer cost no
    turn units (the builtin charges `2 * (a + b)` for a longer right list).
  - `docs/vm/17-lists.md`
  - the gate is `benchmarks/programs/list-build.agc`
- `vm/interp.c`
  - the turn loop keeps the top frame's code, spans, register window and next
    `pc` in locals and reloads them at `reload:`. An opcode that pushes or
    pops a frame, replaces one, or can move the frame or register arrays
    (`ensure_registers`, `new_frame`) must `goto reload` before it reads a
    local again; `frame->pc` is still written before each instruction (the
    stack trace, a park and a yield read it), and `SPAN` is the span of the
    running instruction, read where a failure or a call needs it
  - `LIST` and `MAP` with no items return `rt->empty_list` and `rt->empty_map`
    (made once by `agc_vm_init`), and a map literal starts from the shared empty
    map: nothing writes a list or map after it is returned (`agc_map_put` copies
    its path), so the sharing cannot be seen. The runtime holds the other
    shared small values too: `rt->empty_set` (the same `agc_map` object as
    `empty_map`, under the Set tag), `rt->empty_string` and `rt->chars[128]`
    (`docs/future/34-shared-small-values.md` §34.6 lists the paths). Rules for
    new code: only objects from `agc_new_*` are written, and only before they
    are returned; a path that ends with nothing to return gives the shared
    value; never compare or key anything on a pointer, and keep the turn cost
    equal to what the path charged before (it reads sizes, not objects). Do
    not add the shared empty value to `filter` and `map` in `interp.c`
    (measured: a swing of +12% for `File.each_line` in one link layout)
  - one turn of the current task (`agc_run_turn`, returns yield, parked or done)
    and the budgets: the "next stop" counter of `STEP` over the turn and the
    batch taken from the runtime's atomic `steps_left` (`agc_turn_begin`,
    `agc_turn_finish`, the slow path), the turn-cost apply path after
    `CALL_BUILTIN`, between callbacks and after `CONCAT`, `TO_TEXT`, `INSPECT`,
    `EQ`, `NE`, `SAME`, `MAP`, `MAP_GET` (`agc_charge`, `agc_charge_bytes`;
    skipped with `AGENTICA_VM_TEST_NO_TURN_COST=1`)
  - `GLOBAL` and `GLOBAL_SET` read and write `agc_program.globals`, the one part
    of a loaded program that a run writes: only the entry writes it, each
    `GLOBAL_SET` runs at most once, before `main`, so after that it is read-only
    and a scheduler on another thread needs no lock
    (`docs/vm/10-io-multicore.md` §10.2.3, "The Globals table"). A zeroed slot
    has tag `AGC_T_VOID`, which means "never set": `GLOBAL` of one is
    `RUNTIME-INTERNAL`. A loaded program is run once and its slots keep their
    values after the run; a program run twice in one process (a test) would see
    the first run's slots, so tests that read an unset slot load a fresh
    program, and if a program is ever run twice for real the table moves into
    `agc_runtime`
  - frames, registers, call depth, `TAIL_CALL` frame replacement, `TRY` (returns
    an error like `RETURN`; one that would empty the call stack is
    `RUNTIME-INTERNAL`), Int rules, `CLOSURE`/`CALL_VALUE`, and the resumable
    `List` callback builtins (native frames, `agc_native` state)
  - `agc_sort_by_keys` sorts `(key, item)` entries (the item is the index, or
    the raw 8 bytes of the number when a numeric list sorts by itself), with Int
    and Float keys turned into `uint64_t` that order alike, returns the input
    for keys in order and `agc_list_reverse` of it for keys strictly falling,
    and the stepper builtins (7.2.1h): a builtin calls `agc_task_stepper(vm,
    &state->stepper)` and returns, then `CALL_BUILTIN` sees `t->stepper` and
    `start_stepper` pushes an `AGC_NATIVE_STEPPER` frame whose block is the
    builtin's last argument
  - `call_builtin` (`vm/interp.c`) is the one call of a builtin function: once
    the VM is shared (`agc_share`) it takes `rt->sync` around a builtin whose
    row has `shared` set (`vm/sync.c`, `references/vm-tasks.md`), and
    `resume_stepper` takes it around each step
  - `resume_stepper` asks the step function (`agc_step_fn`) what to do next:
    `AGC_STEP_CALL` calls the block with one argument and the block's result is
    the next `last` (read from the native frame's base register),
    `AGC_STEP_WAIT` parks the task (the step function started a job, so
    `t->parking` must be set, else `RUNTIME-INTERNAL`) and the job's result is
    the next `last`, `AGC_STEP_END` finishes the builtin with the step's value
  - a native top frame is resumed at the start of every turn
  - each call costs one step plus the turn cost
  - core code cannot call services, so the function pointer is installed at run
    time
- `vm/diag.c`
  - the plain, `--ai` and `--json` diagnostic formats, the same formats as
    `compiler/diagnostics/diagnostic_*.agc`
  - only the code must match
  - a task crash adds ` in a task` (plain, `--ai`) or `"task":true` (`--json`)
  - `agc_crash_text` and the unobserved summary line (`agc_print_unobserved`)
  - the stack trace of a runtime error (14b): `agc_stack_capture`, called by
    `agc_fail` while a task runs, walks the task's frames (native frames
    skipped, equal neighbours merged, 15 innermost and 5 outermost kept) into
    the fixed `outcome.stack`, and the three printers write it (`  = stack,
    innermost first:` in plain, `  stack:` in `--ai`, `stack`, `stack_omitted`
    and `spawned_at` in `--json`)
  - `Child.stderr_diagnostic` and `Child.stderr_text` (`stdlib/test/child.agc`)
    recognise a child's `--json` diagnostic or task-crash line by its exact
    keys, so `vm_shape?` accepts `spawned_at`, `stack` and `stack_omitted` as
    optional keys: add any new key to the diagnostic there too, or a crash of a
    test handler becomes `RUNTIME-BDD-PREMATURE-EXIT`
  - it allocates nothing and clamps every index, so a bad `pc` or span index in
    a hand-built program cannot read out of bounds
  - the printers cut a function name or path to 256 bytes at a character
    boundary (`...` marks the cut; the diagnostic's own first line is not cut)
  - `crash` in `vm/task.c` copies `outcome.stack` into the task (`crash_stack`),
    and `agc_stack_members` builds the `stack`, `stack_omitted` and `spawned_at`
    members that `fail_line` in `vm/testing.c` adds to the `fail` record of a
    test whose task crashed

## Gotchas

- JSON parsing matches what the old evaluator did (Racket's `read-json` plus its
  own checks),
  not RFC 8259 alone: the control-character pass runs first over the whole
  text, a top-level number or literal stops early (`01` is unexpected
  content, `truex` invalid), the finite check comes after the trailing
  check, a mantissa of zeros is `0.0` whatever its sign, and duplicate
  keys keep the last value (`docs/vm/02-reference-behavior.md` §2.6). yyjson
reads numbers as
  raw text so the VM converts them itself; never turn on its `ALLOW_*`
  flags or its writer. Bumping yyjson: check out the new tag inside
  `vm/third_party/yyjson`, `git add vm/third_party/yyjson`, and rerun the
  sanitizer and diff tests.
- `Random` differs from the evaluator by design: the VM uses xoshiro256**
  and the evaluator Racket's `random`, so seeded sequences differ between
  backends (`docs/vm/05-values-execution-builtins.md` §7.4). A `Random` fixture
prints only what both
  share (counts of in-range values, `[0, 1)` checks), never drawn
  numbers.
- Float text is not `printf("%.17g")` or "first `%.*e` that round-trips":
  Racket breaks exact ties upward and uses the asymmetric interval at powers
  of two. Keep `agc_float_text` as `docs/vm/02-reference-behavior.md` §2.2
describes it, and add
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
  deleted Racket evaluator). A new key conses one cell; a replaced key
  keeps its cell. Never keep order in an array copied on every put. The
  hash is keyed per run, so nothing observable may depend on it; the
  printer, `Map.keys` and `Map.values` walk the key list, not the trie.
  `Map.delete` copies the trie path and the key list up to the key's cell
  (the rest is shared); a missing key returns the same map. The key-list
  copy makes it O(n), so it is `AGC_COST_SIZE`. `List.sort`
  reuses `agc_sort_by_keys` (`vm/interp.c`) with the items as their own
  keys. `MAP` and `Map.put` share
  `agc_map_put`; HAMT recursion is bounded by 14 levels, printing nested
  maps goes through the explicit-stack printer.
- Sets (8b) are the same `agc_map` with nil values under `AGC_T_SET`
  (`agc_set_value`, `agc_as_set`), so they share the trie, the first-insertion
  key list and the persistence; nothing else reads their layout. `Set.add` and
  `Set.new` go through `agc_map_add_hash`, which returns the input map for a
  member (no copy, the first insertion keeps its place); `union` walks
  `agc_map_keys` of the second set and adds with the same call, and returns an
  input set when nothing changes. `intersection` and `difference` count the
  survivors first with lookups only, return the first set itself when none is
  dropped, and build the result in a second pass only otherwise. `subset?` and
  the set case of `agc_equal` call `agc_set_subset`, so the key-list layout
stays
  in `vm/map.c`. `Set.delete` is
  `agc_map_delete`, O(n) like `Map.delete`. The text printer opens `Set[` and
  reads the key array; `agc_equal` compares sets by size and membership
  (for `Test.eq`; there is no `==`) and charges the size. Set builtins are
  `AGC_COST_SIZE` when they walk or copy a set or a list (`delete` too) and
  `AGC_COST_NONE` for `add`, `include?`, `size` and `empty?`. A hostile `.agcb`
  that puts a non-Int, non-String in a set stops in `agc_key_hash`
  (`agc_wrong_tag`).
- Lists can share items, so a list's text can be exponential in the code
  that built it (`a1 = [a0, a0]`, `a2 = [a1, a1]`, ...); printing then ends in
the out-of-memory exit, as the trust
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
  (`docs/vm/02-reference-behavior.md` §2.3), and a new contextual case rule must
come with a
  generator check, not by hand. Float text goes to `strtod` only after
  the evaluator's pattern check.
- `string-trim` in `format-diagnostic-ai` trims only ASCII `[ \t\n\f\r]`,
  not Unicode whitespace; the VM matches that.
