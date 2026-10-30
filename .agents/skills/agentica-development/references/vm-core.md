# VM core: values, lists, maps, text, interpreter, loader, JSON, diagnostics

Read first: `references/vm.md` and `references/vm-c.md`.

## Files

Each `vm/` file starts with a comment saying what it owns; this list keeps the
rules those comments do not carry.

- `vm/value.h`, `vm/port.h`, `vm/core.h`, `vm/services.h`: the layer headers
  ("Which layer" in `vm.md`). `value.h` has `agc_opcode`, in the same order as
  `OPCODES` in `compiler/bytecode/bytecode_tables.agc`. `port.h` has the stepper
  protocol (`agc_stepper`, `agc_step_fn`, `agc_task_stepper`; "Adding a
  builtin").
- `vm/tools/check-layers.sh`, `check-layers-test.sh`: the layer check run by
  `make vm-layers` (`docs/vm/15-layers.md` §15.5); link rules use `nm` on the
  objects (Linux only).
- `vm/loader.c`: full validation of untrusted `.agcb` input
  (`docs/vm/08-loader-and-cli.md` §8). It holds the collector off with
  `agc_gc_pause` and `agc_gc_resume` while it loads. The struct and enum tables
  use one variant array sized by a first pass and one shared empty value per
  nullary variant. Updates (`load_updates`): strictly increasing field indexes
  below the field count, and the `STRUCT_WITH` operand check against it. Types
  (`load_types`): back-pointing List/Map entries at most 1024 deep, struct
  records with unique `json_name`s and `field_types`. Globals (`load_globals`):
  at most `AGC_MAX_GLOBALS` slots; `check_function` and `check_not_entry`
  enforce the `GLOBAL_SET` and entry rules (Gotchas of `vm-lowering.md`).
- `vm/value.c`: allocation (and the GC stress hook), the constructors and
  accessors of the service resources, String allocation (`agc_small_string`
  returns the shared empty String for no bytes and the shared one-character
  String for one ASCII byte, else a new one: use it wherever a builtin cuts or
  builds a String from bytes it does not own), UTF-8 checks, `agc_error_value`
  (an `error` Result from C text), OOM/abort handlers.
- `vm/map.c`: maps and sets: SipHash-1-3 keyed by `vm->hash_key` (from OS
  entropy in `vm/launch.c`), the persistent HAMT (`_hash` variants take a given
  hash, for tests; `agc_map_add_hash` puts only a new key and returns the same
  map for a member, which `Set.add` and `Set.new` use), and `agc_map_keys`
  (insertion order from the reversed key list).
- `vm/list_impl.h`: private to the core: `struct agc_list`, the trie node type
  and the `static inline` accessors (`list_at` has no bounds check). `list.c`,
  `interp.c` (`LIST_LEN`, `LIST_GET`, hot in `for` loops) and
  `vm/tests/list_test.c` include it; `make vm-layers` fails any other include.
- `vm/text.c`: text and debug forms (`agc_text`, `agc_debug`, and
  `agc_test_text`, the debug form with each `Json` as its canonical text, for
  `Test.eq`) through one explicit `agc_alloc`'d stack and a growing String;
  `agc_write_form` is the one `write`-form escaper for Strings.
- `vm/unicode_data.c`: frozen, checked-in Unicode 17.0 data (see its header);
  edit by hand only for a deliberate Unicode update.
- `vm/strings.c`: the `String` builtins. The shared Strings of `rt->chars` and
  `rt->empty_string` (made in `agc_vm_init`) come back through
  `agc_small_string`, and `trim`, `reverse` and the case maps return their
  argument when nothing changes. Also `agc_utf8_offset` with each task's
  one-entry cursor (string, code point index, byte offset) and the KMP search
  (`agc_text_find`).
- `vm/bytes.c`: the `Bytes` builtins (`Bytes.*` and `String.bytes`). Results
  come from `agc_make_bytes` (the `agc_empty_bytes` constant for no bytes);
  `slice`, `take` and `drop` charge what they copy, not the parent's size.
  `==` is the builtin `Bytes.equal`: `EQ` refuses a Bytes, since a case in
  `equal_values` moves `plain_turn` (`make layout-check`).
- `vm/builtins.c`: the core builtins (`agc_core_builtins`: `IO`, `System`,
  `List`, `Map`, `Set`, `Result`, `Range`) and `agc_find_builtin`, which matches
  by implementation key and arity over `agc_builtin_tables`;
  `agc_builtin_struct` and `agc_builtin_variant` find a builtin struct or an
  enum variant by name in the program's tables, else `RUNTIME-INTERNAL`.
  `vm/builtin_tables.c` lists every library's own table in lookup order (the
  first match wins): a new builtin library adds its table there and its
  `extern` to `vm/services.h`.
- `vm/ffi.c`, `vm/ffi_os.h`, `vm/ffi_libffi.c`, `vm/ffi_none.c`: native calls.
  `Native.call` (`agc_ffi_builtins`) is the builtin that each `extern`
  function lowers to, with a signature string `"CODES SYMBOL LIBRARY"` from
  `compiler/lower/lower_native.agc` (the codes: `i l g h u w j n` for the
  integer types, capitals for `out`, `f` for `C.Float`, `.` for the variadic
  part, `c` for a call through a C function pointer, `e` for a resource freed
  through a pointer, `{N:CODES}` for a C struct by value, N the record's index
  in the struct table; the VM checks it against the program). A `compute def`'s
  signature starts with `compute `: the call goes to the compute pool
  (`vm/compute.c`) through `agc_io_compute` in `vm/loop.c`, and the task parks.
  Resources that extern functions return are `agc_c_resource` (`vm/value.h`):
  a registry entry owned like a handle, freed by `Native.close` or the owner's
  end; a compute call holds its resource arguments in `jobs`, and the last one
  runs a deferred free. `Native.memory_pointer` and `Native.from_string` make
  an owned buffer (an `agc_c_resource` with `buffer` set; the program types it
  as a `C.Pointer`; `buffer_of` and `pointer_of` take either); `Native.offset`
  of a buffer makes a view with `parent` set (`root_of`), and every closed check
  and hold (`held_by`, `struct_held`) goes to the parent. Typed reads and
  writes go through `memory_at`, which checks a buffer's bounds and freed state
  and only NULL and a negative offset of a raw pointer; those rows are not
  shared: `memory_at` takes `rt->sync` only for a buffer, and the caller drops
  it after the copy (`memory_done`), so no free comes between the check and the
  copy. `Native.memory_pointer`, `Native.free`, `size_of`, `get_struct` and
  `put_struct` are shared rows. `fits_bits` is the one range rule of
  arguments, fields and `put_*`. Every `Native.*` import counts as native code
  for the refusal at load (`agc_ffi_refusal`, called by `agc_launch_native`).
  `vm/ffi_libffi.c` (`AGC_FFI`, Linux x86_64, Windows x64 and macOS) opens
  libraries with `dlopen` or `LoadLibraryExW` and calls with libffi;
  `vm/ffi_none.c` refuses elsewhere. `Native.wait_readable` and `wait_writable`
  are a wait on the loop (`agc_io_start_then`, a poller on a duplicate of the
  descriptor from `agc_poller_open_copy`).
- `vm/numbers.c` (`Float`, `Time` and `Random` builtins) and `vm/random.c`
  (xoshiro256** seeded with splitmix64;
  `docs/vm/05-values-execution-builtins.md` §7.4).
- `vm/crypto.c`, `vm/digest.h`, `vm/digest_openssl.c`: the `Digest`, `HMAC`,
  `Cipher`, `CMAC`, `KDF`, `SecureRandom` and `Base64` builtins; `digest.h` is
  the adapter interface (also an incremental SHA-256 for the `File` hash), the
  OpenSSL code is only in `digest_openssl.c`.
- `vm/json.c`: the `JSON` builtins and `agc_json_parse` (the control-character
  pass, top-level numbers and literals by hand, strings, arrays and objects
  through yyjson with `STOP_WHEN_DONE` and `NUMBER_AS_RAW`, then a copy into GC
  nodes with an explicit stack; `docs/vm/02-reference-behavior.md` §2.6).
  `vm/json_value.c` is the `Json` value (`agc_json` nodes), in the core because
  `text.c` and `equal.c` print and compare a Json: `agc_json_encode` (the one
  writer, for `JSON.encode` and the text form of a Json) and `agc_json_from`,
  both over one explicit stack; `agc_json_finish` sorts the members by key bytes
  and drops repeated keys. `vm/json_typed.c` is `agc_json_decode` and
  `agc_json_schema` (§2.7): one explicit frame stack over the Json tree and the
  type table, the error path built from the frames only on failure.
- `vm/equal.c`: `agc_equal`, the deep compare of §25.4 for `Test.eq`: one
  explicit stack of value pairs, one turn unit per pair, Floats by IEEE 754,
  maps by key in any order, a `Json` by its canonical `agc_json_encode` text,
  `RUNTIME-INTERNAL` for values with no equality.
- `vm/trace.[ch]`, `vm/profile.c`: VM tracing (`AGENTICA_VM_TRACE`, as built in
  `docs/vm/08-loader-and-cli.md` §9; `agc_trace_emit` writes one 512-byte stack
  line with one `write(2)`) and the `profile` category (counters, the report,
  `Profile.measure` sections, folded stacks).
- `vm/launch.[ch]`: driver code shared by the two runs of the binary
  (`agentica run` and the front end): `agc_launch_parse` (the VM options),
  seeds, `agc_launch_vm` (a runtime from a loaded program; a front end gets
  `rt->front_end`, no stdin and no parent channel), `agc_launch_settle` /
  `agc_launch_exit` (the one exit path).
- `vm/agentica.c`, `vm/embedded.h`: the single binary: loads the front end
  with `agc_load_front_end`, runs it, and when it called `FrontEnd.hand_off`
  and ended with status 0 retires it (`agc_launch_settle`, `agc_io_close`,
  `agc_gc_collect`) and runs the handed program in a new runtime;
  `--front-end FILE.agcb` replaces the carried front end; the embedded data is
  `agc_embedded_data` and `agc_embedded_index` (`vm/tools/gen-embedded.sh`).
- `vm/front_end.c`: `FrontEnd.hand_off`, `FrontEnd.std_source` and
  `FrontEnd.stdin_bytes`: they fail with `RUNTIME-FRONT-END-ONLY` when
  `rt->front_end` is NULL (every runtime except the front end of the single
  binary); `Std.source` (not guarded) reads the std sources of `rt->std`.
- `vm/fuzz.c`, `vm/fuzz_libfuzzer.c`: `agc_fuzz_one` and the libFuzzer entry
  point (not in the release binary).
- `vm/jit/` (core, `docs/vm/05-values-execution-builtins.md` §6.4; `--jit`,
  `AGENTICA_JIT`; `on` is the default on x86-64): `jit.h` is the one header
  (the interpreter's boundary first, then the emitter and code memory that
  only `vm/jit/` and `vm/tests/jit_test.c` use). `jit.c` decides every function
  once in `agc_jit_new` (for `on`: a backward jump and innermost loops that
  seldom leave the code; a call of a builtin that may park, from the sorted
  `agc_jit_parking` list that `jit_test.c` checks against the tables, counts as
  `AGC_JIT_PARK_WEIGHT` trips out of the code), and returns NULL when no
  function is left, so the run takes the plain turn loop. `agc_jit_turn` (from
  `agc_run_turn`) samples turns at random for `on`; the jit copy interprets up
  to 1.4 times slower than the plain one. The scheduler that claims a function
  compiles it (one `agc_emit_*` call per instruction; fused ones as their STEP
  or CONST), seals it in the run's code chunks and publishes it with a release
  store (`agc_jit_code_of`). The compile budget of a run (`AGC_JIT_BUDGET`
  work units and `AGC_JIT_CODE_CAP` bytes; `AGENTICA_VM_TEST_JIT_BUDGET` sets a
  small one for tests): the first compile that fits neither claims every
  function not claimed yet (`spend`), so the rest of the run interprets them,
  and the jit trace says `budget spent=work` or `spent=bytes` once.
  `emit_x64.c` has the machine code of each kind for the SysV and Win64
  registers (`AGC_JIT_HOST` is 0 elsewhere and nothing is compiled);
  `mem_posix.c` and `mem_windows.c` give W^X pages.
  - `run_compiled` in `vm/interp.c` enters at each reload of the jit copy of
    `turn_loop` (after the one-byte `agc_jit_may_run` test; the plain copy has
    no JIT test, as one cost arithmetic 20% by code layout alone) and handles
    each exit as the interpreter handles that instruction (STEP `step_slow`,
    COST `apply_cost`, a failure `op_failed`, INTERPRET a leaf builtin or a
    block call, CALL and RETURN the shared frame handlers). A change to
    `resume_native` or `call_value` needs the same change there.
  - A CALL, CALL_VALUE or TAIL_CALL of a function with code is native
    (`agc_emit_call`, `agc_jit_call_value`, `agc_emit_tail_call`); a tail call
    replaces the top frame in place and exits only when the callee has no code,
    the register file would grow or it takes more than `AGC_JIT_TAIL_PARAMS`
    (32) arguments. `on` counts a self TAIL_CALL within that limit as a loop
    (`backward` in `jit.c`).
  - A new instruction with code: a case in `has_code` and in the walk, its
    `agc_emit_*`, a case in `jit_test.c` and in `tests/test_vm_jit.py`. Any
    slow path leaves for the interpreter: compiled code never fails, allocates
    or parks, and pushes or pops a frame only in room the task already has. It
    calls a builtin only when the row is marked `direct` (`agc_builtin.direct`,
    checked by `sync_test.c`) or `leaf` (through `agc_jit_call_builtin`,
    `agc_jit_call_leaf` or `agc_jit_call_plain`; their catch `vm->jit_catch`
    keeps `agc_fail` from jumping across compiled code). Mark a row only if it
    never parks, starts a block or moves frames.
  - An edit of `turn_loop`, even in its jit copy, changes the plain copy's
    machine code: keep JIT logic in `run_compiled`, and put new JIT exit
    handling there in out-of-line `noinline` helpers. Growth of `run_compiled`
    moves `plain_turn`, and a move of 128 bytes with the same instructions cost
    `--jit off` up to 12% (`make layout-check` fails on it,
    `references/ci.md`).

- `vm/list.c` (Lists, the persistent vector behind the opaque list API)
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
  - the layout is a persistent vector with an inline tail (the trie, the
    shifts, the costs of `append`, `set`, `slice` and `concat`:
    `docs/vm/17-lists.md`); `reverse`, a `drop` from inside a leaf and the
    right side of a `concat` stay O(n)
  - the API of `value.h` (`rg 'agc_list_' vm/value.h`): a sized builder
    (`agc_list_builder_sized`, `_push`, `_finish`) is the only code that writes
    a list, and only before it returns it; a wrong count aborts. Use it for
    every new list whose count is known, and `agc_list_from_array` for a
    staged array (`filter`). `agc_list_get` aborts on a bad index (the caller
    checks it and fails with the program's diagnostic). `agc_list_repeat`
    shares one leaf by the whole trie, so `List.repeat` is O(log n).
    `agc_list_append`, `_set`, `_slice` and `_concat` never write to their
    input.
  - Builders and cursors live on the C stack or in `agc_alloc` memory.
  - never allocate one node per push, that was six times slower than a flat
    array for a million items and starved the GC-stress fixtures.
  - a leaf is a slice of the array of the build that made it, so a list that
    shares leaves keeps that array alive (`slice` shares only when it keeps at
    least half of the source).
  - `List.append`, `List.set` and a `List.concat` with 32 items or fewer cost no
    turn units (the builtin charges `2 * (a + b)` for a longer right list).
  - the gate is `benchmarks/programs/list-build.agc`
- `vm/interp.c` (one turn of the current task, its step and cost budgets)
  - the turn loop keeps the top frame's code, spans, register window and next
    `pc` in locals and reloads them at `reload:`. An opcode that pushes or
    pops a frame, replaces one, or can move the frame or register arrays
    (`ensure_registers`, `new_frame`) must `goto reload` before it reads a
    local again; `frame->pc` is still written before each instruction (the
    stack trace, a park and a yield read it), and `SPAN` is the span of the
    running instruction, read where a failure or a call needs it
  - fused STEP (`docs/vm/03-ir-and-bytecode.md` §4.2): the loader's
    `fuse_steps` turns a checked `STEP` into an `AGC_FUSED_STEP_*` opcode when
    the next instruction has a fused form; `FUSED_STEP()` is the `STEP`, then
    fetches the next instruction as the loop does and jumps to its case label
    (`op_move`, ...). A new fused form needs the opcode in `agc_fused_opcode`,
    a case in `fuse_steps`, a case and a label in `turn_loop`. The profiling
    copy runs fused STEPs plain, so the profile is also the unfused reference
    (`tests/test_vm_trace.py`). `fuse_consts` runs first and turns a `CONST`
    before an Int operator or a compare into an `AGC_FUSED_CONST_*` opcode
    (`FUSED_CONST()`: the `CONST`'s write, then the next instruction); a `STEP`
    before one becomes `AGC_FUSED_STEP_CONST_*`. The CONST forms come last in
    the enum (`AGC_FUSED_CONST_FIRST`), so the profile maps them back to `CONST`
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
  - `TRY` returns an error like `RETURN`; one that would empty the call stack
    is `RUNTIME-INTERNAL`
  - `agc_sort_by_keys` sorts `(key, item)` entries (the item is the index, or
    the raw 8 bytes of the number when a numeric list sorts by itself), with Int
    and Float keys turned into `uint64_t` that order alike, returns the input
    for keys in order and `agc_list_reverse` of it for keys strictly falling
  - stepper builtins: `CALL_BUILTIN` sees `t->stepper` and
    `start_stepper` pushes an `AGC_NATIVE_STEPPER` frame whose block is the
    builtin's last argument (protocol: `references/vm-builtins.md`)
  - `call_builtin` (`vm/interp.c`) is the one call of a builtin function: once
    the VM is shared (`agc_share`) it takes `rt->sync` around a builtin whose
    row has `shared` set (`vm/sync.c`, `references/vm-tasks.md`), and
    `resume_stepper` takes it around each step
  - on `AGC_STEP_WAIT` the step function started a job, so `t->parking` must
    be set, else `RUNTIME-INTERNAL`; the block's or job's result is the next
    `last` (read from the native frame's base register)
  - a native top frame is resumed at the start of every turn
  - each call costs one step plus the turn cost
  - core code cannot call services, so the function pointer is installed at run
    time
- `vm/diag.c` (diagnostics in the plain, `--ai` and `--json` forms, the stack
  trace of a runtime error)
  - formats as `compiler/diagnostics/diagnostic_*.agc`; only the code must
    match
  - a task crash adds ` in a task` (plain, `--ai`) or `"task":true` (`--json`)
  - `agc_crash_text` and the unobserved summary line (`agc_print_unobserved`)
  - the stack trace of a runtime error: `agc_stack_capture`, called by
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

- JSON parsing follows `docs/vm/02-reference-behavior.md` §2.6, not RFC 8259
  alone: the control-character pass runs first over
  the whole text, a top-level number or literal stops early (`01` is unexpected
  content, `truex` invalid), the finite check comes after the trailing check, a
  mantissa of zeros is `0.0` whatever its sign, and duplicate keys keep the last
  value. yyjson reads numbers as raw
  text so the VM converts them itself; never turn on its `ALLOW_*` flags or its
  writer. Bumping yyjson: check out the new tag inside `vm/third_party/yyjson`,
  `git add vm/third_party/yyjson`, and rerun the sanitizer and diff tests.
- `Random` is xoshiro256** (`docs/vm/05-values-execution-builtins.md` §7.4).
  A `Random` fixture prints only properties (counts of in-range values,
  `[0, 1)` checks), never drawn numbers.
- Float text is not `printf("%.17g")` or "first `%.*e` that round-trips": it
  breaks exact ties upward and uses the asymmetric interval at powers of two.
  Keep `agc_float_text` as `docs/vm/02-reference-behavior.md` §2.2 describes
  it, and add any new tricky value to `vm/tests/float_text_test.c`.
- The load budget is 4 bytes per file byte plus 1 MiB. Keep per-entry
  costs low (one array for all variants, sized by a first pass; no
  temporary copies): a real program with 65535 variants must load.
  `load_alloc(0)` returns NULL without charging anything.
- Callback builtins are native frames, not C calls into the loop: the C table
  entry has an `agc_native_kind`; `CALL_BUILTIN` copies the arguments into an
  `agc_native` GC object and pushes a frame with `native` set at `R[a]`;
  callbacks run at `R[a+1]` with result register `R[a]`, and `return_value`
  resumes the native frame when it is on top. `frame_count` counts every frame,
  `depth` only bytecode frames (a callback push past the limit fails at the
  builtin's call span). Deep recursion through a callback must not use `return
  f(...)` in the block in a fixture: that is a tail call on the VM only.
- Maps keep insertion order exactly: a HAMT from
  key to value plus a reversed cons list of keys. A new key conses one cell
  carrying its insertion number (`seq`); a replaced key keeps its cell. Never
  keep order in an array copied on every put. The hash is keyed per run, so
  nothing observable may depend on it; the printer, `Map.keys` and `Map.values`
  walk the key list, not the trie. `Map.delete` copies the trie path, shares
  the key list and adds the key's `seq` to the map's `dropped` list: that cell
  is dead, and walks skip dead cells by `seq` (a bitmap or a sorted merge, never
  a key lookup). Once dead cells outnumber live ones, the delete rebuilds the
  list without them in one block. A missing key returns the same map. It is
  O(log32 n) amortized along one line of versions, so it is `AGC_COST_NONE`
  like `Map.put`; the rebuild charges the list length as turn cost. `List.sort`
  reuses `agc_sort_by_keys` (`vm/interp.c`) with the items as their own
  keys. `MAP` and `Map.put` share
  `agc_map_put`; HAMT recursion is bounded by 14 levels, printing nested
  maps goes through the explicit-stack printer.
- Sets are the same `agc_map` with nil values under `AGC_T_SET`
  (`agc_set_value`, `agc_as_set`), so they share the trie, the first-insertion
  key list and the persistence; nothing else reads their layout. `Set.add` and
  `Set.new` go through `agc_map_add_hash`, which returns the input map for a
  member (no copy, the first insertion keeps its place); `union` walks
  `agc_map_keys` of the second set and adds with the same call, and returns an
  input set when nothing changes. `intersection` and `difference` count the
  survivors first with lookups only, return the first set itself when none is
  dropped, and build the result in a second pass only otherwise. `subset?` and
  the set case of `agc_equal` call `agc_set_subset`, so the key-list layout
  stays in `vm/map.c`. `Set.delete` is `agc_map_delete`, like
  `Map.delete`. `agc_equal` compares sets by size and membership (for
  `Test.eq`; there is no `==`) and charges the size. Set builtins are
  `AGC_COST_SIZE` when they walk or copy a set or a list and
  `AGC_COST_NONE` for `add`, `delete`, `include?`, `size` and `empty?`. A
  hostile `.agcb` that puts a value other than an Int, String or Bytes in a set
  stops in `agc_key_hash` (`agc_wrong_tag`).
- Lists can share items, so a list's text can be exponential in the code that
  built it (`a1 = [a0, a0]`, `a2 = [a1, a1]`, ...); printing then ends in the
  out-of-memory exit, as the trust model allows. Never print or compare nested
  values with C recursion.
- The `write` form prints the joiners U+200C, U+200D and U+E0020 to U+E007F raw
  only after a raw non-blank character, so the debug form has state; see
  `docs/vm/02-reference-behavior.md` §2.3 before touching `agc_write_form`.
- `--max-steps` bounds instructions, not bytes: string ops cost in
  proportion to their size.
- Strings: `agc_string` keeps the byte and code point counts; build every
  `String` result with a sizing pass then a fill pass (or one copy), never by
  repeated concatenation, and search with the KMP finder in `vm/strings.c`, not
  a naive loop. `String.trim` is `\s` only (five ASCII bytes); case
  mapping is the tables plus final sigma (`docs/vm/02-reference-behavior.md`
  §2.3), and a new contextual case rule must come with a generator check, not by
  hand. Float text goes to `strtod` only after the pattern check.
- `string-trim` in `format-diagnostic-ai` trims only ASCII `[ \t\n\f\r]`,
  not Unicode whitespace; the VM matches that.
