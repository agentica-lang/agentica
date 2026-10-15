# Add a C builtin or a trace point

Read before adding or changing a builtin implemented in C, or a trace point.

Read first: `references/vm.md` and `references/vm-c.md`.

## Add a C builtin

1. `src/lower.rkt`: let the call through the builtin check (today only the
   `vm-builtins` keys `puts`, `IO.print`, `IO.warn`, `IO.inspect`,
   `IO.gets`, `IO.gets!`, `IO.read`, `IO.read_bytes`, `IO.flush`,
   `IO.eof?`, `System.args`, `System.exit`, `System.env`, `String.from_int`,
   `String.from_float`, `ok` (arities 0 and 1), `error`, `Result.ok?`,
   `Result.unwrap!`, `Result.unwrap_or`, `Result.message`, the callback
   builtins `List.map`, `List.filter`, `List.reduce`, `List.each`,
   `List.any?`, `List.all?` and `List.sort_by`, and the range builtins
   `Range.size`, `Range.to_a`, `Range.include?`, `Range.first`,
   `Range.last`, `Range.each`, `Int.times`, `Int.upto` and `Int.downto`,
   and the `List` and `Map` library (`List.size`, `append`, `set`,
   `repeat`, `concat`, `take`, `drop`, `at`, `reverse`, `sort`;
   `Map.has_key?`, `keys`, `size`, `put`, `get` at arities 2 and 3,
   `delete`, `values`), the `Set` library (`Set.new`, `add`, `delete`,
   `include?`, `size`, `empty?`, `to_a`, `union`, `intersection`,
   `difference`, `subset?`), every `String.*` builtin, and `Float.from_int`,
   `Float.to_int`, `Float.to_int!`, `Time.now_ms`, `Time.monotonic_ms`,
   `Time.monotonic_ns`, `Random.int` and `Random.float`, and every `JSON.*`
   builtin (the type argument of `JSON.decode` and `JSON.schema` lowers to a
   String constant with the struct's linked name; a struct without JSON field
   types, such as `Header` or a struct that contains one, is
   `LOWER-UNSUPPORTED`), and
   every `File.*`, `Dir.*` and `Path.*` builtin (with `FileHandle` in
   `value-types` and `FileInfo` appended to the struct table when a checked
   type mentions it), every `Process.*` builtin, and every `TCP.*` builtin
   (with `Process`, `Socket` and `Listener` in `value-types`) are
   accepted; everything else is
   `LOWER-UNSUPPORTED`; the lowerer also emits `List.concat` and `Map.put`
   for list and map literals above 255 elements; the loader rejects `MAP`
   with more than 255 pairs) and emit `call-builtin` with the catalog's
   implementation key and arity. The import table carries the
   implementation key, not the written name: `puts` and `IO.puts` both
   import `"puts"`.
2. `vm/builtins.c`: add the entry under that key and arity.
3. Add a fixture to `tests/fixtures/vm/` for the happy path and for each
   runtime code or span the builtin can raise; add a loader assert if the import
   rules change. The fixture sidecars (`.stdin`, `.args`, `.env` and `.channel`)
   are described under the golden harness in `references/vm-build.md`.
4. A blocking builtin (7h) checks its arguments, fills a `malloc`'d
   request (no GC pointers; strings through `agc_cstr` or a `malloc`'d
   copy), and calls `agc_io_start` with an `agc_io_kind`: `work` runs in
   the libuv pool and may only do system calls on that request; `done`
   and `expired` run on the interpreter thread and return the value;
   `drop` frees a request whose timeout already fired; the optional
   `cancel` half (last field, external kinds only) says whether a
   detached job (its task was cancelled) may end now through `drop`, at
   the cancel or at its deadline; leave it NULL unless the request can
   stop without closing the task's handle. It returns any
   value; `CALL_BUILTIN` then parks the task (`task->parking`) and the
   scheduler runs others; the result lands in the call's register when the
   task runs again. A builtin that must wait and then re-check (stdin,
   `Task.await`) calls `agc_task_park(vm, true)` (retry): `CALL_BUILTIN`
   keeps the arguments and re-runs the call on wake. A builtin that must
   call its block and also park between the calls (`File.each_line`) is a
   stepper: its state struct starts with an `agc_stepper` whose `step`
   function is set, the builtin calls `agc_task_stepper(vm, &state->stepper)`
   and returns, and `CALL_BUILTIN` pushes a native frame on the block (the
   builtin's last argument). Each time the frame runs, `step(vm, self, last)`
   returns `AGC_STEP_CALL` (call the block with `value`), `AGC_STEP_WAIT`
   (it started a job, so the task parks) or `AGC_STEP_END` (finish with
   `value`); `last` is the block's result or the finished job's result.
   Use `List`-style native frames for pure callbacks and a plain blocking
   builtin when there is no block. Every table entry
   has a `cost` (`AGC_COST_NONE` or `AGC_COST_SIZE`, `docs/vm/10-io-scheduler.md`
   §10.2.1, "Builtins"): a builtin whose work grows with its input takes
   `AGC_COST_SIZE` or charges `agc_charge` from inside; never touch
   `steps_left` for that. State goes in `vm->rt` (shared runtime),
   `vm` (the scheduler) or `vm->task`. Check `vm->rt->no_files`
   first in file builtins and in `TCP.connect` and `TCP.listen`, so the
   fuzzer never touches the disk or the network.

Rules for the C code:

- The catalog in `src/builtins.rkt` stays the source of keys and arity; the
  loader resolves each `(key, arity)` against the C table.
- Check argument tags generically from the table; check list and map
  elements when you touch them.
- Fail with the documented diagnostic code (`docs/grammar/`), at the call
  span or `span + 1 + i` for argument `i`, with a clear message.
- Every bounds check on an Int argument uses `__builtin_add_overflow` or
  `x < 0 || x > n - y`; never cast a negative `int64_t` to `size_t` first.
- Strings reach the OS or a library only through `agc_cstr` (a `malloc`'d
  copy, NUL terminated, NULL on an embedded NUL so the caller returns its
  error message; the caller frees it, usually with its request). Every String constructor validates UTF-8
  or decodes with U+FFFD. Build a String with `agc_make_string` (copies) or
  `agc_new_string` and fill every byte before it is stored anywhere.
- Debug text of a String (`inspect`, and later map-key, `index_of` and
  conversion messages) always goes through `agc_write_form`; never write a
  second escaper.
- No C recursion whose depth depends on a value (printing, `to_s`/`inspect`,
  JSON): use an explicit stack allocated with `agc_alloc`.
- Builtins never call the interpreter. Callback builtins are resumable
  native frames. A builtin must not keep `args` across anything that pushes a
  frame or grows registers.

## Add a trace point

`AGC_TRACE(tr, AGC_TRACE_IO, "start job=%" PRIu64 " kind=%s", id, name)`,
with `tr` a `const agc_trace *` (`&vm->rt->trace`, or the copy in a
`malloc`'d struct whose libuv callbacks have no runtime). Lines are `event
key=value ...`, at events only, never per instruction. When a trace needs
work first (a clock read, a GC getter), guard it with `AGC_TRACE_ON` or put
it in a small `trace_*` helper that returns early. Rules (a trace point
must never crash or change the run):

- The format is checked by `__attribute__((format(printf, ...)))`; only
  `d`, `i`, `u`, `x`, `X` (with `hh`, `h`, `l`, `ll`, `z`, `j`, `t`), `%s`,
  `%.*s` and `%%` are supported; anything else (`%c`, `%p`, floats, widths,
  flags) still compiles but ends the line with `?`. `vm/tests/trace_test.c`
  has one case per supported conversion; add one for any new conversion.
- Text goes through the escaper (plain, or JSON-quoted when empty or when it
  has a space, `=`, `"`, `\`, or a control byte). An `agc_string` or any
  (pointer, length) data is `%.*s` with `agc_trace_len(bytes)`, never `%s`.
  Trace only memory the code owns at that moment (trace a path before it is
  freed).
- No `FILE *`, stdio, locks, shared buffers, `malloc`, GC allocation or GC
  callbacks; `agc_trace_emit` saves and restores `errno`.
- Trace code only reads state: no steps, no turn cost, no change to when
  tasks switch. Bookkeeping that exists only for a trace (a job's start
  time) is set only when the category is on.
- Never trace from a real signal handler or from a libuv pool `work`
  function; libuv callbacks (`uv_signal_t` included) run on the loop thread
  and may trace.
- A new category gets a bit in `vm/trace.h` and a name in `category_names`
  in `vm/trace.c`, the regex in `tests/test_vm_trace.py`, and the list in
  `docs/vm/08-loader-and-cli.md` §9.
- Every test file that starts the VM itself removes `AGENTICA_VM_TRACE` and
  `AGENTICA_VM_TRACE_FILE` when it loads (the Makefile `unexport`s them).
