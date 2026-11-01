# VM core: values, lists, maps, text, interpreter, loader, JSON, diagnostics

Read first: `references/vm.md` and `references/vm-c.md`.

Each `vm/` file starts with a comment saying what it owns. This file keeps the
rules those comments do not carry.

## Layers and headers

- `value.h` has `agc_opcode`, in the same order as `OPCODES` in
  `compiler/bytecode/bytecode_tables.agc`. `port.h` holds the stepper protocol
  (`references/vm-builtins.md`).
- `vm/list_impl.h` is private to the core: `list.c`, `interp.c` (`LIST_LEN`,
  `LIST_GET`, hot in `for` loops) and `vm/tests/list_test.c` may include it.
  `make vm-layers` fails any other include; it reads `nm`, so Linux only
  (`docs/vm/15-layers.md` §15.5).
## Loader

- `vm/loader.c` validates all untrusted `.agcb` input
  (`docs/vm/08-loader-and-cli.md` §8). It holds the collector off with
  `agc_gc_pause` and `agc_gc_resume` while it loads.
- Load budget: 4 bytes per file byte plus 1 MiB. Keep per-entry costs low: one
  array for all variants (sized by a first pass), one shared empty value per
  nullary variant, no temporary copies. A real program with 65535 variants must
  load. `load_alloc(0)` returns NULL and charges nothing.
- `check_function` and `check_not_entry` enforce the `GLOBAL_SET` and entry
  rules (Gotchas of `vm-lowering.md`).

## Values, strings and bytes

- `value.c`: allocation and the GC stress hook; `agc_error_value` (an `error`
  Result from C text); the OOM and abort handlers.
- `agc_small_string` returns the shared empty String for no bytes, the shared
  one-character String for one ASCII byte, else a new String. Use it wherever a
  builtin cuts or builds a String from bytes it does not own.
- `strings.c`: `trim`, `reverse` and the case maps return their argument when
  nothing changes. `agc_utf8_offset` keeps each task's one-entry cursor (string,
  code point index, byte offset). Search is the KMP finder (`agc_text_find`).
- `text.c`: `agc_text`, `agc_debug` and `agc_test_text` (the debug form with
  each Json as its canonical text, for `Test.eq`) share one explicit
  `agc_alloc`'d stack and a growing String. `agc_write_form` is the one escaper
  of `write`-form Strings.
- `bytes.c`: results come from `agc_make_bytes` (`agc_empty_bytes` for no
  bytes). `slice`, `take` and `drop` charge what they copy, not the parent's
  size. `==` on Bytes is the builtin `Bytes.equal`: `EQ` refuses a Bytes, since
  a case in `equal_values` moves `plain_turn` (`make layout-check`).
- `digest.h` is the adapter interface; the OpenSSL code is only in
  `digest_openssl.c`.

## Lists (`vm/list.c`)

- `struct agc_list` is defined in `list_impl.h` and opaque everywhere else.
- The kind comes from the values stored: 0 for 16-byte `agc_value` items;
  `AGC_T_INT` or `AGC_T_FLOAT` when every item has that tag, and then leaves and
  tail hold 8 raw bytes per item (leaves from `agc_alloc_atomic`, branches and
  the list object from `agc_alloc`). An empty list has kind 0; the first item
  decides (`docs/vm/17-lists.md` §17.12).
- Shared leaves exist only between lists of one kind.
- The sized builder allocates at its first push. `agc_list_builder_more` is its
  slow path: it turns a numeric builder boxed when a tag differs. `append`,
  `set`, `concat` (of lists of different kinds) and `agc_list_from_array` box in
  the same case, which only hostile bytecode causes.
- Only `agc_list_builder_sized`, `_push` and `_finish` write a list, and only
  before it is returned; a wrong count aborts. Use the builder for any new list
  whose count is known, and `agc_list_from_array` for a staged array (`filter`).
  Builders and cursors live on the C stack or in `agc_alloc` memory.
- `agc_list_get` aborts on a bad index; the caller checks first and fails with
  the program's diagnostic. `agc_list_append`, `_set`, `_slice` and `_concat`
  never write their input. `agc_list_repeat` shares one leaf over the whole
  trie, so `List.repeat` is O(log n).
- Never allocate one node per push: a flat array is about six times faster for a
  million items, and the per-node version starves the GC-stress fixtures.
- A leaf is a slice of the array of the build that made it, so a list that
  shares leaves keeps that array alive (`slice` shares only when it keeps at
  least half of the source).
- A persistent vector with an inline tail; the costs are in
  `docs/vm/17-lists.md`. `reverse`, a `drop` inside a leaf and the right side of
  a `concat` stay O(n).
- `List.append`, `List.set` and `List.concat` with 32 items or fewer cost no
  turn units; a longer right list is charged `2 * (a + b)`. The gate is
  `benchmarks/programs/list-build.agc`.

## Maps and sets

- Maps keep insertion order: a HAMT from key to value plus a reversed cons list
  of keys. A new key conses one cell carrying its insertion number (`seq`); a
  replaced key keeps its cell. Never keep order in an array copied on every put.
- The hash is keyed per run, so nothing observable may depend on it. The
  printer, `Map.keys` and `Map.values` walk the key list, not the trie.
- `Map.delete` copies the trie path, shares the key list and adds the key's
  `seq` to the map's `dropped` list. Walks skip dead cells by `seq` (a bitmap or
  a sorted merge, never a key lookup). When dead cells outnumber live ones, the
  delete rebuilds the list in one block. A missing key returns the same map.
- Cost: O(log32 n) amortized, `AGC_COST_NONE` like `Map.put`; the rebuild
  charges the list length as turn cost. `MAP` and `Map.put` share `agc_map_put`.
  HAMT recursion is bounded by 14 levels; nested maps print through the
  explicit-stack printer, never C recursion.
- Sets are the same `agc_map` with nil values under `AGC_T_SET`
  (`agc_set_value`, `agc_as_set`); nothing else reads their layout. `Set.add`,
  `Set.new` and `union` use `agc_map_add_hash`, which returns the input map for
  a member (no copy; the first insertion keeps its place). `union`,
  `intersection` and `difference` return an input set when nothing changes;
  `intersection` and `difference` count the survivors first and build a result
  only when one is dropped. `subset?` and the set case of `agc_equal` call
  `agc_set_subset`, so the key-list layout stays in `vm/map.c`. `Set.delete` is
  `agc_map_delete`.
- `agc_equal` compares sets by size and membership (for `Test.eq`; there is no
  `==`) and charges the size. Set builtins are `AGC_COST_SIZE` when they walk or
  copy a set or a list, `AGC_COST_NONE` for `add`, `delete`, `include?`, `size`
  and `empty?`. A hostile `.agcb` that puts a value other than an Int, String or
  Bytes in a set stops in `agc_key_hash` (`agc_wrong_tag`).

## Builtins and native calls

- `builtins.c`: `agc_find_builtin` matches by implementation key and arity over
  `agc_builtin_tables`. `agc_builtin_struct` and `agc_builtin_variant` find a
  builtin struct or enum variant by name, else `RUNTIME-INTERNAL`. A new builtin
  library adds its table to `vm/builtin_tables.c` (lookup order, first match
  wins) and its `extern` to `vm/services.h`.
- `ffi.c`: `Native.call` (`agc_ffi_builtins`) is what each `extern` function
  lowers to. Its signature string is `"CODES SYMBOL LIBRARY"`, built by
  `compiler/lower/lower_native.agc`; the VM checks it against the program. The
  codes: `i l g h u w j n` integer types, capitals for `out`, `f` for `C.Float`,
  `.` variadic, `c` a call through a C function pointer, `e` a resource freed
  through a pointer, `{N:CODES}` a C struct by value (N is its struct-table
  index).
- `Native.callback` gets `"CODES NAME"` (`callback_signature` in
  `lower_native.agc`) and the function, and makes an `agc_ffi_closure`
  (`ffi_libffi.c`: a page mapped read-write, then sealed read-execute; libffi's
  trampoline table on Apple arm64). A callback parameter of an extern function
  is code `r`, passed as its resource; `Optional[Name]` is code `o`, `none` for
  NULL. A fast call sets the thread's `native_site`; the closure runs the
  function with `agc_task_run_nested` (`interp.c`: the frame and register
  arrays of its level, reused and cleared when the native call returns
  (`agc_task_clear_nested`), over a barrier native frame; the outer frames
  linked for stack traces and folded profiles by `agc_frame_segment`; rt->sync
  let go; `t->callbacks` counted, which makes `agc_task_parking` fail; timers
  and the runnext slot handed on at each turn boundary) and keeps a failure for
  `agc_raise` once C has returned. A free function gets a refusing site. The
  nested run is `cold`, so `plain_turn` keeps its place (`make layout-check`).
- A signature that starts with `compute ` runs on the compute pool
  (`vm/compute.c`, `agc_io_compute` in `vm/loop.c`), and the task parks.
- Resources that extern functions return are `agc_c_resource` (`vm/value.h`): a
  registry entry owned like a handle, freed by `Native.close` or the owner's
  end. A compute call holds its resource arguments in `jobs`; the last one runs
  a deferred free.
- Buffers: `Native.memory_pointer` and `Native.from_string` make an owned buffer
  (an `agc_c_resource` with `buffer` set; the program types it as a
  `C.Pointer`). `Native.offset` makes a view with `parent` set; every closed
  check and hold (`held_by`, `struct_held`) goes to the parent.
- `memory_at` checks a buffer's bounds and freed state, and only NULL and a
  negative offset of a raw pointer. Those rows are not shared: `memory_at` takes
  `rt->sync` only for a buffer, and the caller drops it after the copy
  (`memory_done`), so no free comes between the check and the copy.
  `Native.memory_pointer`, `Native.free`, `size_of`, `get_struct` and
  `put_struct` are shared rows.
- `fits_bits` is the one range rule for arguments, fields and `put_*`.
- Every `Native.*` import counts as native code for the refusal at load
  (`agc_ffi_refusal`, called by `agc_launch_native`).
- `ffi_libffi.c` (`AGC_FFI`: Linux and macOS on x86_64 and arm64, Windows x64)
  is the libffi adapter; `ffi_none.c` refuses elsewhere. `Native.wait_readable`
  and `wait_writable` wait on the loop (`agc_io_start_then`, on a duplicate
  descriptor from `agc_poller_open_copy`).

## Interpreter (`vm/interp.c`)

- The turn loop keeps the top frame's code, spans, register window and next `pc`
  in locals and reloads them at `reload:`. An opcode that pushes or pops a
  frame, replaces one, or can move the frame or register arrays
  (`ensure_registers`, `new_frame`) must `goto reload` before it reads a local
  again. `frame->pc` is still written before each instruction (the stack trace,
  a park and a yield read it), and `SPAN` is the span of the running
  instruction.
- Fused STEP (`docs/vm/03-ir-and-bytecode.md` §4.2): the loader's `fuse_steps`
  and `fuse_consts` make `AGC_FUSED_STEP_*` and `AGC_FUSED_CONST_*` forms. The
  CONST forms come last in the enum (`AGC_FUSED_CONST_FIRST`), so the profile
  maps them back to `CONST`. A new fused form needs the opcode in
  `agc_fused_opcode`, a `fuse_steps` case, and a case and label in `turn_loop`.
  The profiling copy runs fused STEPs plain, so the profile is the unfused
  reference (`tests/test_vm_trace.py`).
- Shared values: `LIST` and `MAP` with no items return `rt->empty_list` and
  `rt->empty_map`. The runtime also holds `rt->empty_set`, `rt->empty_string`
  and `rt->chars[128]`, all made by `agc_vm_init`
  (`docs/future/34-shared-small-values.md` §34.6 lists the paths). Nothing
  writes a list or map after it is returned, so the sharing cannot be seen. New
  code writes only objects from `agc_new_*`, and only before they are returned;
  a path with nothing to return gives the shared value; never compare or key
  anything on a pointer; keep the turn cost the path charged before (it reads
  sizes, not objects). Do not add the shared empty value to `filter` and `map`
  in `interp.c` (measured: +12% for `File.each_line` in one link layout).
- Turn budgets: `agc_run_turn` returns yield, parked or done. The "next stop"
  counter of `STEP` covers the turn; its batch comes from the runtime's atomic
  `steps_left` (`agc_turn_begin`, `agc_turn_finish`, the slow path). Turn cost
  is applied after `CALL_BUILTIN`, between callbacks, and after `CONCAT`,
  `TO_TEXT`, `INSPECT`, `EQ`, `NE`, `SAME`, `MAP` and `MAP_GET` (`agc_charge`,
  `agc_charge_bytes`; `AGENTICA_VM_TEST_NO_TURN_COST=1` skips it). Each call
  costs one step plus the turn cost.
- Globals: `GLOBAL_SET` runs at most once and before `main`, and only the entry
  runs it. So `agc_program.globals` is read-only afterwards, and a scheduler on
  another thread needs no lock (`docs/vm/10-io-multicore.md` §10.2.3). A zeroed
  slot is `AGC_T_VOID` ("never set"); `GLOBAL` of one is `RUNTIME-INTERNAL`. A
  loaded program runs once; a test that reads an unset slot loads a fresh
  program. If a program ever runs twice for real, the table moves into
  `agc_runtime`.
- `TRY` returns an error like `RETURN`; one that would empty the call stack is
  `RUNTIME-INTERNAL`.
- `call_builtin` takes `rt->sync` around a builtin whose row has `shared` set,
  once the VM is shared (`agc_share`) (`vm/sync.c`, `references/vm-tasks.md`);
  `resume_stepper` takes it around each step. Stepper builtins: `CALL_BUILTIN`
  sees `t->stepper` and pushes an `AGC_NATIVE_STEPPER` frame whose block is the
  builtin's last argument (`references/vm-builtins.md`).
- On `AGC_STEP_WAIT` the step function has started a job, so `t->parking` must
  be set, else `RUNTIME-INTERNAL`. The block's or job's result becomes the next
  `last` (read from the native frame's base register). A native top frame is
  resumed at the start of every turn.
## JIT (`vm/jit/`)

Core layer, `docs/vm/05-values-execution-builtins.md` §6.4; `--jit` and
`AGENTICA_JIT` (`on` is the default on x86-64 and arm64).

- `jit.c` decides every function once, in `agc_jit_new`. For `on`: a backward
  jump, and innermost loops that seldom leave the code. A call of a builtin that
  may park counts as `AGC_JIT_PARK_WEIGHT` trips out of the code; the sorted
  `agc_jit_parking` list is checked against the tables by `jit_test.c`. It
  returns NULL when no function is left, so the run takes the plain turn loop.
- `agc_jit_turn` (from `agc_run_turn`) samples turns at random for `on`. The jit
  copy interprets up to 1.4 times slower than the plain one.
- The scheduler that claims a function compiles it (one `agc_emit_*` per
  instruction; fused ones as their STEP or CONST), seals it in the run's code
  chunks, and publishes it with a release store (`agc_jit_code_of`).
- Budget of a run: `AGC_JIT_BUDGET` work units and `AGC_JIT_CODE_CAP` bytes;
  `AGENTICA_VM_TEST_JIT_BUDGET` sets a small one for tests. The first compile
  that fits neither claims every function not yet claimed (`spend`), so the rest
  of the run interprets them. The jit trace says `budget spent=work` or
  `spent=bytes` once.
- `run_compiled` (`vm/interp.c`) enters at each reload of the jit copy of
  `turn_loop`, after the one-byte `agc_jit_may_run` test. The plain copy has no
  JIT test: one cost arithmetic moved 20% by code layout alone. Each exit is
  handled by the same handler the interpreter uses for that instruction. A
  change to `resume_native` or `call_value` needs the same change there.
- A CALL, CALL_VALUE or TAIL_CALL of a function with code is native
  (`agc_emit_call`, `agc_jit_call_value`, `agc_emit_tail_call`). A tail call
  replaces the top frame in place. It exits only when the callee has no code,
  the register file would grow, or it takes more than `AGC_JIT_TAIL_PARAMS` (32)
  arguments. `on` counts a self TAIL_CALL within that limit as a loop
  (`backward` in `jit.c`).
- Two emitters: `emit_x64.c` and `emit_a64.c` (arm64, Linux and macOS;
  `jit_a64_test.c` checks its words on any machine, the `jit-arm64` CI job and
  Platforms run it). On arm64 a code slot is read with `ldar` and new code is
  entered after `isb`. macOS seals with plain `mprotect`, so the binary must
  not have the hardened runtime (`tools/release-check.sh` checks it).
- A new instruction with code needs: a case in `has_code` and in the walk, its
  `agc_emit_*` in both emitters, a case in `jit_test.c`, `jit_a64_test.c` and
  `tests/test_vm_jit.py`. Compiled
  code never fails, allocates or parks, and pushes or pops a frame only in room
  the task already has; any slow path leaves for the interpreter. It calls a
  builtin only when the row is marked `direct` (`agc_builtin.direct`, checked by
  `sync_test.c`) or `leaf` (through `agc_jit_call_builtin`, `agc_jit_call_leaf`
  or `agc_jit_call_plain`). Their catch, `vm->jit_catch`, keeps `agc_fail` from
  jumping across compiled code. Mark a row only if it never parks, starts a
  block or moves frames.
- An edit of `turn_loop`, even in its jit copy, changes the plain copy's machine
  code. Keep JIT logic in `run_compiled`, and put new JIT exit handling in
  out-of-line `noinline` helpers. Growth of `run_compiled` moves `plain_turn`: a
  move of 128 bytes with the same instructions cost `--jit off` up to 12%
  (`make layout-check` fails on it; `references/ci.md`).

## Launch, front end and trace

- `launch.[ch]`: driver code shared by the two runs of the binary
  (`agentica run` and the front end): `agc_launch_parse`, seeds,
  `agc_launch_vm`. A front end gets `rt->front_end`, no stdin and no parent
  channel. `agc_launch_settle` and `agc_launch_exit` are the one exit path.
- `agentica.c` loads the front end (`agc_load_front_end`) and runs it. When it
  called `FrontEnd.hand_off` and ended with status 0, it retires it
  (`agc_launch_settle`, `agc_io_close`, `agc_gc_collect`) and runs the handed
  program in a new runtime. `--front-end FILE.agcb` replaces the carried front
  end; the embedded data comes from `vm/tools/gen-embedded.sh`.
- `front_end.c`: `FrontEnd.hand_off`, `FrontEnd.std_source` and
  `FrontEnd.stdin_bytes` fail with `RUNTIME-FRONT-END-ONLY` unless
  `rt->front_end` is set. `Std.source` is not guarded.
- `trace.[ch]`, `profile.c`: `AGENTICA_VM_TRACE` (`docs/vm/08-loader-and-cli.md`
  §9). `agc_trace_emit` writes one 512-byte line with one `write(2)`.
## Diagnostics (`vm/diag.c`)

- Formats as `compiler/diagnostics/diagnostic_*.agc`; only the code must match.
- A task crash adds ` in a task` (plain and `--ai`) or `"task":true` (`--json`).
- The stack of a runtime error: `agc_stack_capture`, called by `agc_fail` while
  a task runs, walks the task's frames (native frames skipped, equal neighbours
  merged, 15 innermost and 5 outermost kept) into `outcome.stack`. `crash`
  (`vm/task.c`) copies it into the task. `agc_stack_members` builds the `stack`,
  `stack_omitted` and `spawned_at` members that `fail_line` (`vm/testing.c`)
  adds to a failed test whose task crashed.
- `Child.stderr_diagnostic` and `Child.stderr_text` (`stdlib/test/child.agc`)
  recognise a child's `--json` diagnostic or task-crash line by its exact keys.
  `vm_shape?` accepts `spawned_at`, `stack` and `stack_omitted` as optional
  keys: add any new key there too, or a crash of a test handler becomes
  `RUNTIME-BDD-PREMATURE-EXIT`.
- Diagnostics allocate nothing and clamp every index, so a bad `pc` or span in a
  hand-built program cannot read out of bounds.

## Gotchas

- JSON parsing follows `docs/vm/02-reference-behavior.md` §2.6, not RFC 8259
  alone. The control-character pass runs first over the whole text. A top-level
  number or literal stops early (`01` is unexpected content, `truex` is
  invalid). The finite check comes after the trailing check. A mantissa of zeros
  is `0.0` whatever its sign. Duplicate keys keep the last value. yyjson reads
  numbers as raw text so the VM converts them itself: never turn on its
  `ALLOW_*` flags or its writer. Bumping yyjson: check out the new tag in
  `vm/third_party/yyjson`, `git add` it, and rerun the sanitizer and diff tests.
- A Json is canonical: `agc_json_encode` is the one writer (for `JSON.encode`
  and the text form of a Json), and `agc_json_finish` sorts members by key bytes
  and drops repeated keys.
- `Random` is xoshiro256** (`docs/vm/05-values-execution-builtins.md` §7.4). A
  `Random` fixture prints only properties (counts of in-range values, `[0, 1)`
  checks), never drawn numbers.
- Float text is not `printf("%.17g")` or the first `%.*e` that round-trips: it
  breaks exact ties upward and uses the asymmetric interval at powers of two.
  Keep `agc_float_text` as `docs/vm/02-reference-behavior.md` §2.2 describes
  it, and add any new tricky value to `vm/tests/float_text_test.c`. Float text
  goes to `strtod` only after the pattern check.
- Callback builtins are native frames, not C calls into the loop: `CALL_BUILTIN`
  copies the arguments into an `agc_native` GC object and pushes a frame with
  `native` set at `R[a]`. Callbacks run at `R[a+1]` with result register `R[a]`,
  and `return_value` resumes the native frame when it is on top. `frame_count`
  counts every frame, `depth` only bytecode frames (a callback push past the
  limit fails at the builtin's call span). Deep recursion through a callback
  must not use `return f(...)` in the block in a fixture: that is a tail call on
  the VM only.
- The `write` form prints the joiners U+200C, U+200D and U+E0020 to U+E007F raw
  only after a raw non-blank character, so the debug form has state. Read
  `docs/vm/02-reference-behavior.md` §2.3 before touching `agc_write_form`.
- Lists can share items, so the text of a list can be exponential in the code
  that built it (`a1 = [a0, a0]`, `a2 = [a1, a1]`, ...). Printing then ends in
  the out-of-memory exit, as the trust model allows. Never print or compare
  nested values with C recursion.
- `--max-steps` bounds instructions, not bytes: string ops cost in proportion to
  their size.
- Strings: `agc_string` keeps the byte and code point counts. Build every
  `String` result with a sizing pass and then a fill pass (or one copy), never
  by repeated concatenation. Search with the KMP finder in `vm/strings.c`, not a
  naive loop. `String.trim` is `\s` only (five ASCII bytes). Case mapping is the
  tables plus final sigma (`docs/vm/02-reference-behavior.md` §2.3); a new
  contextual case rule needs a generator check, not a hand edit.
- `string-trim` in `format-diagnostic-ai` trims only ASCII `[ \t\n\f\r]`, not
  Unicode whitespace; the VM matches that.
