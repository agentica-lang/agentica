# Library area notes

What the checker enforces and the VM keeps for each library area: stdio, JSON,
tasks, TCP, TLS and HTTP, files and paths, processes. VM internals are in
`references/vm.md`. Read the section for the area you are changing.

## Stdio bytes and flushing

- `IO.read_bytes(count)` returns Result[Bytes]: it waits for count bytes or
  EOF, returns short or empty success at EOF, and does not consume input for
  zero or invalid counts. The fixed 1 MiB per-call cap prevents eager
  allocations from arbitrary Int sizes.
- `IO.flush` flushes stdout and returns completion. On Linux, macOS and Windows
  it returns once the data is in the pipe or file (it can wait for a slow
  reader, §10.2.2); the other output functions do not wait for it. On other
  systems stdout and stderr are blocking `FILE` writes, and a write waits for
  its reader without a timeout.

## JSON

- Typed decoding uses a type-expression AST node accepted only in JSON type
  argument positions. JSON.decode returns located-path Result errors, validates
  signed Int/finite Float bounds, and ignores extra fields. Recursive type
  validation visits each struct once. The source may be a String or a JSON.Value
  (two catalog forms, one rule and one VM builtin that skips the parse for a
  JSON.Value). JSON.schema uses the same eligibility check, emits 64-bit bounds
  and $defs/$ref for nested or recursive types, and lists in required every
  field that is not a JSON.Field or an Optional. JSON.Field[T] is only the
  direct type of a struct field (CHECK-JSON-FIELD-PLACE, checked before the
  decodable and encodable walks; the walk looks inside Optional). Optional[T] is
  type kind 8, valid at any depth; the encoders unwrap Optional values anywhere
  (program->optional, found by the loader), and JSON.Field[Optional[T]] and
  Optional[Nil] are refused by the walks. JSON.from shares encode eligibility
  and non-finite diagnostics.

- `JSON.Value` is opaque, not primitive for equality. `JSON` is a reserved name;
  `JSON.Value` and `JSON.Field` are members of its family.
- Encoding eligibility is checked recursively, including declared struct fields
  and empty containers; a seen-struct path prevents infinite recursion without
  skipping other fields.
- JSON for enums: a user enum is the tagged object {"tag", "values"}
  (`enum_walk` in check_types.agc for encode and decode, `place_enum` for
  JSON.Field in a payload). The writer is the generic walk of vm/json_value.c
  (an enum value is an object of two children); decode and schema are in
  vm/json_typed.c. The payload types of a decodable enum are the optional last
  section of the .agcb (docs/vm/03-ir-and-bytecode.md 4.6), type kind 9; only
  the enums that a decode target or a decodable struct reaches are in it
  (`with_reachable_enums` in lower_program.agc), and a program with none writes
  no section.
- Parse rejects non-finite numbers, while large integer JSON.Value payloads
  remain valid. Non-finite Floats halt encoding with RUNTIME-JSON-ENCODE at the
  call span.

## Lightweight I/O tasks

- Task.spawn_owning takes a handle type as the argument, or a struct, enum,
  List, Map or Result whose type holds one (`holds_handle?` in
  `compiler/check/check_collections.agc`, else `CHECK-NOT-A-HANDLE`; keep it in
  step with the tag lists of `agc_owned_of` in `vm/loop.c` and `handle_tag` in
  `vm/task.c`, so a new handle kind goes into all three) and gives every handle
  in it to the new task, all or none (`RUNTIME-HANDLE-NOT-OWNED` at run time).
  A `Channel[T]` is accepted too: a channel is not in `agc_owned_of`, it gets
  its registry entry from `agc_channel_claim` at the first hand-off, so an
  unowned channel can be handed over by any task and `Channel.new` stays free.
  A task that ends closes the handles it owns, so a handle returned through
  await is closed, and the await returns only after the regular-file closes
  (pool jobs) of that task have finished, so the data is on disk; a FIFO or pipe
  flush is not counted. Await returns the cached R, including false/nil/error
  Results.
- `Task.await(task, timeout_ms)` is a second arity of the same catalog row (rule
  `TaskAwaitTimeout`) and returns the builtin enum `Await[T]` (`Done(T)`,
  `TimedOut`); see "TCP, TLS and HTTP" for how a builtin enum is wired.
  Channels are VM-only builtins in `vm/channel.c` (`docs/vm/10-io-scheduler.md`
  §10.2.2). `ATS[K, V]` is the type variant `Types.Type.ATS`, checked by the
  rules `AtsNew` and `AtsCall` (`check_collections.agc`: the row's `K` and `V`
  become the table's, so `ATS.add`'s `ATS[K, Int]` refuses other values) and the
  value rule `ats_value?` (`CHECK-ATS-VALUE`); the VM side is `vm/ats.c`
  (`references/vm-tasks.md`).
- A diagnostic in `main`, RUNTIME-STEP-LIMIT, RUNTIME-INTERNAL or System.exit
  ends the run; any other diagnostic in a task is a crash that ends only that
  task, and an unobserved crash makes the run exit 1 when `main` returns.
- `std/bdd` fails a step with RUNTIME-BDD-PENDING-TASKS when
  `Task.pending_count()` is above zero after its handler, then with
  RUNTIME-TASK-CRASHED when `Task.unobserved_crash()` is `ok`. The runner skips
  stderr lines with `"task": true` when it reads a child's last diagnostic.

## TCP, TLS and HTTP

- The catalog data (`compiler/catalog/builtins_data.agc`) centralizes opaque
  atoms, builtin record field layouts and builtin enums (`Await`). A builtin
  enum reuses the user-enum paths: the checker starts its enum table with them
  and adds their names to the reserved type names (`CHECK-REDEFINED-NAME`), so
  annotation, constructors, patterns, exhaustiveness and printing need no
  special case, and the data-type check also accepts a `Void` payload for them
  (`Await[Void]`); the linker keeps the name unmangled and turns
  `Await.TimedOut` and `Await.Done(...)` into `EnumConstructor`; the lowering
  appends the IR enum after the user enums only when the program mentions it, as
  for builtin structs, and picks `Task.await_result` for the timed form when the
  payload is a Result; the VM finds the variants by name
  (`agc_builtin_variant`), and `vm/text.c` prints `Await.Done()` for a Void
  payload. Handles cannot be constructed, compared or JSON encoded.
- TCP and TLS are C builtins (`vm/tcp.c`, `vm/tls_openssl.c`); HTTP is
  `std/http` in Agentica over the std-only `HttpWire` builtins (`vm/http_*.c`),
  imported as `HTTP`, which re-exports its records and handles
  (`HTTP.Request`, `HTTP.Response`, `HTTP.Header`, `HTTP.Client`, ...); the
  server runs each connection as a task in the
  server's task group. See `references/vm-net.md`.
- tests/test_vm_tcp.py, test_vm_tls.py and test_vm_http.py use independent Node
  and Python standard-library peers and checked-in localhost certificates.

## Logging

- `std/logger` (`stdlib/logger.agc`) is Agentica over the std-only `LogRegistry`
  builtins (`vm/logger.c`, imported as `Logger`). The registry is the language's
  one piece of global state: `log` in `agc_runtime` (`vm/port.h`), reached
  through `vm->rt`, so the GC keeps the handlers alive and no `static` exists.
  No builtin calls a handler: `dispatch` in `logger.agc` takes the handlers of
  an event (`LogRegistry.handlers(rank)`, a copy) and calls them in the logging
  task. Ranks are Ints (debug 0 to error 3), so no row mentions an enum.
- `LogRegistry.Event` is a builtin record and `LogRegistry.Level` a builtin
  enum (`compiler/catalog/builtins_data.agc`); `logger.agc` re-exports them as
  `Logger.Event` and `Logger.Level`. A builtin record with an enum field
  has no JSON types (`compiler/lower/lower_program.agc` skips it as not
  decodable), because the bytecode writer's type section (`bytecode_types.agc`)
  has no Enum clause.
- The JSON line is `JSON.encode` of the private struct `JsonLine`, not of
  `JSON.object`: `JSON.object` and `JSON.from` sort keys, a struct keeps
  declaration order and a map keeps its order.
- A level function does one comparison when disabled or when no handler accepts
  the level (`if LogRegistry.floor() <= N`; -1 is below every threshold and
  takes the slow path through `ready`), measured by
  `benchmarks/programs/logger-disabled.agc`. `logger-tasks.expected` holds the
  stack lines of `std/logger.agc`: change `logger.agc` and rewrite the goldens.

## Files and paths

- File builtins are `vm/files.c` (`references/vm-io.md`). File reads/writes
  serialize on one per-handle lock and include lock wait in the deadline; a
  timed-out active operation closes the handle. Symlink targets resolve relative
  to the link's own directory, and link cycles stop at the first repeated path.
  The end of a run flushes stdout first, then closes open files with pool close
  jobs and waits for them (at most the flush limit, always on: 30000 ms,
  `AGC_FLUSH_TIMEOUT_MS` in `vm/port.h`; then a warning line and the same exit
  code); other handles close on the loop thread. `--flush-timeout MS` or
  `AGENTICA_FLUSH_TIMEOUT_MS` (read in `vm/launch.c`, the flag wins, a bad value
  exits 2) sets the limit, and the FIFO test uses small values.
- File.open accepts read/write/append modes and only regular files or links to
  regular files; `create_private` makes a new 0600 file with O_EXCL (BDD driver
  port, `references/vm-io.md`). Whole-text calls and individual stream
  operations cap data at 1 MiB; strict UTF-8 errors become Result errors.
  Dir.mkdir is recursive and idempotent, Dir.list is sorted, Path.resolve is
  lexical without symlink resolution, and Path.real is POSIX `realpath` through
  `uv_fs_realpath` in a pool job (no timeout argument; a path that does not
  exist is an error). System.env (in `vm/system.c`) is off with --deny-env.
- File.each_line is a stepper builtin (`references/vm-io.md`, `vm/interp.c`): it
  reads one line at a time through a buffer of `buffer_bytes + 1` bytes, one
  pool job (regular file) or one poller read (FIFO, pipe, or a device that can
  wait) per read, each with its own `timeout_ms`; the file closes on every
  return path, and the end of a task cancelled while it waits closes the
  handle, as for `File.open`. `buffer_bytes` outside 1,024 to 16,777,216 is
  `RUNTIME-INVALID-COUNT` at the argument, before the file opens; a timeout of
  zero or less is an error Result.
- File.open with a block is the block form of the `File.open` row: an
  alternative with the same parameters and a last `Fn`, `Rule.Prelude`, body
  `open` in `stdlib/prelude/file.agc` (open, call the block, `File.close`; no
  VM code). `Builtins.form_for_call` picks it when the last argument is a
  block, in the checker and the lowering; it is the one alternative a builtin
  with defaults may have (`default_problem`). A block whose `Result` item is
  open gets the expected type of the call, else `Slot.InferResult`
  (`check_prelude.agc`, `block_result`).
- File.foreach and ch.lazy are the I/O sources of `Lazy` (`vm/lazy.c`,
  `LAZY_FILE` and `LAZY_CHANNEL`): prelude rows like the other sources. The
  terminal drives the line reader of `File.each_line` (`agc_lines_*` in
  `services.h`) or `agc_channel_receive` (`port.h`), parks on the file job or
  the channel (`WAIT_IO`, a retry park for the channel), and closes the file in
  `lazy_done` before every END (`WAIT_CLOSE`). The run is `unlocked`, and
  takes `rt->sync` only around those two calls (`lazy_lines_next`,
  `lazy_receive`); `resume_stepper` fails `RUNTIME-INTERNAL` if an unlocked step
  returns holding it. `CHECK-LAZY-NO-STEP` (`compiler/check/check_method.agc`)
  rejects `File.foreach(...).each` written as one chain.
- `lz.write_lines(path, ms)` is the terminal `LAZY_WRITE`, driving the line
  writer `agc_line_writer` of `vm/files.c` (`agc_writer_*` in `services.h`): it
  opens before the first pull (`sink_ready`), parks on each write job
  (`WAIT_SINK`) and is flushed and closed in `lazy_done` after the reader
  (`WAIT_SINK_CLOSE`); its close error replaces an ok result. `try` in any
  block of a `Lazy` method: `check_prelude.agc` checks the blocks of
  `module == "lazy"` rows with `St.step`, `check_try` records the ids
  (`Checked.step_tries`), the lowering emits `try-step`, and the interpreter
  sets `agc_stepper.escaped` (`mark_escape`) so `lazy_resume` ends the run with
  the error.

## Void and processes

- Void completes a function without data. Only return/Fn-result/Result/Task
  completion positions accept it; reject inferred Void values except statements
  and forwarded Void returns. Nil remains data and requires explicit returns.
  Main and side-effect callbacks return Void. Result[Void] success uses ok().
- The --deny-* flags reach the VM: --deny-run in `vm/process.c`, --deny-net
  in `vm/tcp.c` (`net_denied`: every socket and listener starts there),
  --deny-fs in `vm/files.c` (`fs_denied`, every row but `Path.join`, and the
  line reader and writer) and for TLS files in `vm/tcp.c`, --deny-env in
  `vm/system.c`. `vm/launch.c` expands --sandbox and turns on --deny-native
  for any of them; `agentica test` passes them to the user's code only (test
  files, step programs, programs under test). The end of a run kills and
  reaps directly spawned children. Expected operations return Results.
- `tests/test_process.py` uses Node and Python peer children; it is not in
  `WINDOWS_TEST_MODULES`: Wine cannot start host peers.

## Int and Float bits, std/binary

- Int and Float bit builtins (`vm/numbers.c`): shifts and masks run on
  `uint64_t`; a count of 64 or more is decided before the shift (`shift_left`
  and `shift_right_unsigned` give 0, `shift_right` gives 0 or -1), a negative
  count is `RUNTIME-INVALID-COUNT` at argument 1 (`span + 2`). `Float.to_bits`
  and `from_bits` return the canonical NaN `0x7FF8000000000000` for any NaN;
  `to_bits32` decides the binary32 overflow before the `(float)` cast and gives
  `0x7FC00000` for NaN. The vectors of `bits-vectors.agc` are the file
  `tests/fixtures/vm/bits-vectors.stdin`, which `python3
  tests/fixtures/bits-vectors.py` writes (standard library only). CI does not
  run the script: run it by hand and commit both files when the vectors change.
  `std-binary-vectors` works the same way with `std-binary-vectors.py`.
- `std/binary` (`stdlib/binary.agc`) is Agentica on the bit builtins, with no
  C. A reader checks `window` (offset range, no overflow for any offset); its
  only error is the offset. A writer packs a masked `List[Int]` with one
  `Bytes.from_list` (`pack`).

## std/toml

`stdlib/toml.agc` is pure Agentica, no C; its comments hold the design (the
`Node` tree and `Origin` against `Value`, the float path through `JSON.parse`,
the 256 limits, the `to_json` depth). A change keeps these contracts: the
encoder refuses the same depths as the reader, so no value built by a caller
halts with `RUNTIME-STACK-OVERFLOW` and what `encode` writes `parse` reads
back. `.gitattributes` marks the toml fixture folders `-text` to keep CRLF.

## std/regex

- `stdlib/regex.agc` is the parser and compiler in Agentica; the Pike VM is the
  std-only builtin `RegexEngine.search` (`vm/regex.c`), a stepper that checks
  the program on every call (a direct call may pass any lists), and
  `find_all`'s Go empty-match rules run in C too. `Program` holds an empty
  `Set` (`seal`) so that `JSON.decode` cannot build a `Regex`: `compile` is the
  only maker.
- `tests/test_std_regex.py` compares with Python `re` (`re.ASCII`, Go's
  empty-match rules applied to its spans).
- The front end imports `std/regex` (`compiler/check/check_regex.agc`, listed
  in `stdlib/CORE`) to check regex literals, so `compile`, its errors and
  any builtin it calls are part of the front end: a change there needs the
  stage0 refresh of `references/ci.md`.

## Where a new library feature goes

- Pure computation over types that exist (numbers to bytes, bit tricks on the
  `Int` builtins, text formatting, algorithms) starts as a `std/` module in
  Agentica (`stdlib/*.agc`, listed in `stdlib/MODULES`), not as a builtin.
- A function becomes a C builtin only when a measurement shows it is hot
  (`make bench`). Its `std/` API does not change, error strings included; the
  `std/` function becomes a one-line wrapper. The builtin is public (no
  internal helper builtins), goes in an existing builtin module whose first
  parameter type fits (`List.read_u32_be(data, offset)`), and never under a
  module named like the `std/` module's import alias.
- Builtins from day one, in C: anything that touches the OS (files, stdio,
  processes, sockets, TLS, time, signals, OS random bytes); crypto, always
  through the TLS/crypto provider adapter, never hand-written (a constant-time
  compare is impossible in an interpreter); parsers of untrusted input with a
  mature library (JSON on yyjson, HTTP on picohttpparser); anything that needs
  its own memory layout (`Bytes`, the insides of `Map` and `List`); operator
  level operations on core types (the `Int` bit operations); the log registry
  state of `std/logger`.
- Library code that is generic over the builtin type variables, or called as a
  method on a builtin type (`xs.find do ... end`), cannot be a `std/` module: it
  goes in the compiler prelude (`stdlib/prelude/*.agc`, `references/stages.md`).
  Only prelude functions may call the `PRELUDE_ONLY` builtins
  (`prelude_data.agc`). A concurrency helper that needs the scheduler is a C
  builtin.
- `HttpWire`, `LogRegistry` and `RegexEngine` are std-only builtin modules:
  the linker lets only modules embedded from `stdlib/` name them (`STD_ONLY` in
  `compiler/catalog/builtins.agc`), and user code gets `CHECK-UNKNOWN-NAME`
  with the std module to import. A public raw layer would be a second way to
  do the same job. A type of one reaches users through a re-export of its std
  module (`export LogRegistry.Event`, `bind_reexports` in `modules.agc`), so
  it reserves no name. A std-only family with records of its own reserves its
  name for enums (`Builtins.record_family?`). A new
  re-export also goes in `REEXPORTED_TYPES` (`compiler/syntax/types.agc`):
  messages, `help`, `doc` and the queries print it as `HTTP.Request`; a
  record or enum also goes in `written_names` of `vm/text.c` (a handle in
  `agc_scalar_text`), so a printed value shows `HTTP.Request` too, while the
  bytecode and lowering keep `HttpWire.Request`
  (`tests/test_frontend_catalog.py` checks both tables against `stdlib/`).
- Not retroactive: existing builtins, JSON included, stay as they are.

## Comments and style in stdlib/

As in `references/frontend.md` ("Comments and style"). Lines are at most 119
characters, checked by `tests/test_style_line_width.py`, not by
`CHECK-LINE-TOO-LONG`.
