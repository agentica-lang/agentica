# Library area notes

What the checker enforces and the VM keeps for each library area: stdio, JSON,
tasks, TCP, TLS and HTTP, files and paths, processes. VM internals are in
`references/vm.md`. Read the section for the area you are changing.

## Stdio bytes and flushing

- `IO.read()` remains the all-text-until-EOF API. `IO.read_bytes(count)` returns
  Result[Bytes]; wait for count bytes or EOF, return short/empty success at
  EOF, and do not consume input for zero or invalid counts. The fixed 1 MiB
  per-call cap prevents eager allocations from arbitrary Int sizes; larger
  streams use repeated reads. Port read failures are local Results, not
  exceptions around argument evaluation.
- `IO.flush` flushes stdout and returns completion. On Linux, macOS and
  Windows it returns once the data is in the pipe or file (it can wait for a
  slow reader, §10.2.2); the other output functions do not wait for it, since
  the loop writes their buffer as the reader takes it, and none closes a port.
  On other systems stdout and stderr are blocking `FILE` writes, and a write
  waits for its reader without a timeout.

## JSON

- Typed decoding uses a type-expression AST node accepted only in JSON type
  argument positions. JSON.decode returns located-path Result errors for bad
  data, validates signed Int/finite Float bounds, and ignores extra fields.
  Recursive type validation visits each struct once. Decoded map keys are
  sorted. The source may be a String or a Json (two catalog forms, one rule and
  one VM builtin that skips the parse for a Json). JSON.schema uses the same
  eligibility check, emits 64-bit bounds and $defs/$ref for nested or recursive
  types, and lists in required every field that is not a JsonField or an
  Optional (no required key when that list is empty). JsonField[T] is only the
  direct type of a struct field (CHECK-JSON-FIELD-PLACE, checked before the
  decodable and encodable walks; the walk looks inside Optional). Optional[T] is
  type kind 8, valid at any depth; the encoders unwrap Optional values anywhere
  (program->optional, found by the loader), and JsonField[Optional[T]] and
  Optional[Nil] are refused by the walks. Builders construct opaque Json
  directly; JSON.from shares encode eligibility and non-finite diagnostics.
  Builtin record declarations participate in decoding and schemas.

- `Json` is opaque, not primitive for equality. `Json`, `JSON` and `JsonField`
  are reserved names.
- Recursively check encoding eligibility, including declared struct fields and
  empty containers. A seen-struct path prevents infinite recursion without
  skipping other fields. Results and Int-keyed maps are CHECK-NOT-ENCODABLE.
- False/null are present values. Int extraction is signed 64-bit and rejects
  decimal/exponent forms; Float extraction permits integer conversion only if
  finite. Parse rejects non-finite numbers, while large integer Json payloads
  remain valid.
- Encoding writes objects in stored map/declared field order. Non-finite Floats
  halt with RUNTIME-JSON-ENCODE at the call span. Debug output is `<Json>`, not
  the host contents.

## Lightweight I/O tasks

- Task.spawn takes Fn[A, R] and one argument, or an Fn[R] and none (a block
  works too: `Task.spawn do ... end`), and returns Task[R] and moves no
  handle; Task.spawn_owning takes a handle type as the argument, or a struct,
  enum, List, Map or Result whose type holds one (`holds_handle?` in
  `compiler/check/check_collections.agc`, with the handle types of the catalog,
  `compiler/catalog/builtins_data.agc`, else `CHECK-NOT-A-HANDLE`; keep it in
  step with the tag lists of `agc_owned_of` in `vm/loop.c` and `handle_tag` in
  `vm/task.c`, so a new handle kind goes into all three) and gives every handle
  in it to the new task, all or none (`RUNTIME-HANDLE-NOT-OWNED` at run time);
  a `Channel[T]` is accepted too (a
  `Channel` type in the checker): a channel is not in `agc_owned_of`, it gets
  its registry entry (no native object, `close` is the channel's own shut) from
  `agc_channel_claim` at the first hand-off, so an unowned channel can be handed
  over by any task and `Channel.new` stays free; a task that ends closes the
  handles it owns, so a handle returned through await is closed, and the await
  returns only after the regular-file closes (pool jobs) of that task have
  finished, so the data is on disk; a FIFO or pipe flush is not counted; await
  returns the cached R, including false/nil/error Results. Sleep takes
  nonnegative milliseconds, zero yields and negative values halt with
  RUNTIME-INVALID-DURATION. `Task`, `Await` and `Channel` are reserved names.
  `Task.await(task, timeout_ms)` is a second arity of the same catalog row in
  `compiler/catalog/builtins_data.agc` (rule `TaskAwaitTimeout` in the checker:
  the task is a `Task`, the timeout an `Int`, the result `Await[R]`) and returns
  the builtin enum `Await[T]` (`Done(T)`, `TimedOut`); see the next bullet for
  how a builtin enum is wired. Channels are VM-only builtins in `vm/channel.c`;
  see `docs/vm/10-io-scheduler.md` §10.2.2. `ATS[K, V]` (reserved too) is the
  type variant `Types.Type.ATS`, checked by the rules `AtsNew` and `AtsCall`
  (`check_collections.agc`: the row's `K` and `V` become the table's, so
  `ATS.add`'s `ATS[K, Int]` refuses other values) and the value rule
  `ats_value?` (`check_types.agc`, `CHECK-ATS-VALUE`); the VM side is
  `vm/ats.c` (`references/vm-tasks.md`).
- Entrypoint return cancels pending work and closes the run's resources. A
  diagnostic in `main`, RUNTIME-STEP-LIMIT, RUNTIME-INTERNAL or System.exit ends
  the run; any other diagnostic in a task is a crash that ends only that
  task, and an unobserved crash makes the run exit 1 when `main` returns. Tasks
  inherit ports and arguments; cross-task stream ordering is unspecified.
- `std/bdd` fails a step with RUNTIME-BDD-PENDING-TASKS when
  `Task.pending_count()` is above zero after its handler, then with
  RUNTIME-TASK-CRASHED when `Task.unobserved_crash()` is `ok`. The runner skips
  stderr lines with `"task": true` when it reads a child's last diagnostic.
- The `task-*` goldens own task behavior; `tests/test_bdd_integration.py`
  verifies concurrent streams of a program under test and cleanup.

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
  imported as `HTTP`; the server runs each connection as a task in the
  server's task group. See `references/vm-net.md`.
- tests/test_vm_tcp.py, test_vm_tls.py and test_vm_http.py use independent Node
  and Python standard-library peers. CI installs Node 24 and Python 3; absence
  fails CI and visibly skips locally. Checked-in localhost test certificates
  exercise trusted TLS, untrusted certificates and hostname rejection.

## Logging

- `std/logger` (`stdlib/logger.agc`) is Agentica over the std-only
  `LogRegistry` builtins (`vm/logger.c`, imported as `Logger`).
  The registry is the language's one piece of global state: `log` in
  `agc_runtime` (`vm/port.h`: the global level, -1 until `install_default`; the
  lowest handler rank; an `agc_alloc`'d array of name, rank and handler),
  reached through `vm->rt`, so the GC keeps the handlers alive and no `static`
  exists. No builtin calls a handler: `dispatch` in `logger.agc` takes the
  handlers of an event (`LogRegistry.handlers(rank)`, a copy) and calls them in
  the logging task. Ranks are Ints (debug 0 to error 3), so no row mentions an
  enum.
- `LogEvent` is a builtin record and `LogLevel` a builtin enum
  (`compiler/catalog/builtins_data.agc`). A builtin record with an enum field
  has no JSON types (`compiler/lower/lower_program.agc` skips it as not
  decodable), because the bytecode writer's type section (`bytecode_types.agc`)
  has no Enum clause.
- The JSON line is `JSON.encode` of the private struct `JsonLine`, not of
  `JSON.object`: `JSON.object` and `JSON.from` sort keys, a struct keeps
  declaration order and a map keeps its order.
- A level function does one comparison when disabled or when no handler accepts
  the level (`if LogRegistry.floor() <= N`; `floor` is the higher of the global
  level and the lowest handler rank, and -1 is below every threshold and takes
  the slow path through `ready`), measured by
  `benchmarks/programs/logger-disabled.agc`. The goldens `logger-*` hold the
  stack lines of `std/logger.agc` in `logger-tasks.expected`: change
  `logger.agc` and rewrite them.
- Tests: goldens `logger-*`; `tests/std/logger_test.agc` (one child VM per
  file, so each test restores the registry); `tests/test_vm_logger.py` with the
  Python peer `tests/fixtures/logger-peer.py` (the JSON lines and `time_text`
  against `datetime`).

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
  `tests/vm_diff_support.py`, `vm_environment` of `tests/agentica_test.py` and
  the Makefile clear that variable, as they do `AGENTICA_VM_TRACE`.
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
  zero or less is an error Result. Tests: `tests/test_vm_file_lines.py` (with
  `tests/fixtures/lines-peer.py`), `vm/tests/each_line_test.c` and the goldens
  `tests/fixtures/vm/file-each-line*.agc`.
- File.foreach and ch.lazy are the I/O sources of `Lazy` (`vm/lazy.c`,
  `LAZY_FILE` and `LAZY_CHANNEL`): prelude rows like the other sources. The
  terminal drives the line reader of `File.each_line` (`agc_lines_*` in
  `services.h`) or `agc_channel_receive` (`port.h`), parks on the file job or
  the channel (`WAIT_IO`, a retry park for the channel), and closes the file in
  `lazy_done` before every END (`WAIT_CLOSE`). The run is `unlocked`, and
  takes `rt->sync` only around those two calls (`lazy_lines_next`,
  `lazy_receive`); `resume_stepper` fails `RUNTIME-INTERNAL` if an unlocked step
  returns holding it. `CHECK-LAZY-NO-STEP` (`compiler/check/check_method.agc`)
  rejects `File.foreach(...).each` written as one chain. Goldens:
  `tests/fixtures/vm/lazy-file.agc`, `lazy-channel.agc`,
  `step-limited/lazy-channel-endless.agc`; closes on every path:
  `tests/test_vm_lazy_io.py`; N=4: `tests/test_vm_multicore.py`.
- `lz.write_lines(path, ms)` is the terminal `LAZY_WRITE`, driving the line
  writer `agc_line_writer` of `vm/files.c` (`agc_writer_*` in `services.h`): it
  opens before the first pull (`sink_ready`), parks on each write job
  (`WAIT_SINK`) and is flushed and closed in `lazy_done` after the reader
  (`WAIT_SINK_CLOSE`); its close error replaces an ok result. `try` in any
  block of a `Lazy` method: `check_prelude.agc` checks the blocks of
  `module == "lazy"` rows with `St.step`, `check_try` records the ids
  (`Checked.step_tries`), the lowering emits `try-step`, and the interpreter
  sets `agc_stepper.escaped` (`mark_escape`) so `lazy_resume` ends the run with
  the error. Goldens: `tests/fixtures/vm/lazy-try.agc`, `lazy-write.agc`; the
  round trip and the closes: `tests/test_vm_lazy_io.py`; the Python peer:
  `tests/test_stdlib_prelude.py`.
- `tests/test_filesystem.py` runs checked Agentica programs through the CLI on
  the VM against temporary directories, with Python peers for `Path.real` and
  `System.env` with bytes that are not UTF-8 (`tests/fixtures/os-peer.py`) and
  for FIFOs (`tests/fixtures/fifo-peer.py`, a reader that is slow or leaves,
  giving `EPIPE`). Keep filesystem tests local and clean temporary trees on
  every outcome.

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
- `tests/test_process.py` uses Node and Python peer children (required in CI);
  it is not in `WINDOWS_TEST_MODULES`: Wine cannot start host peers.

## Int and Float bits, std/binary

- Int and Float bit builtins (`vm/numbers.c`): shifts and masks run on
  `uint64_t`; a count of 64 or more is decided before the shift
  (`shift_left` and `shift_right_unsigned` give 0, `shift_right` gives 0 or
  -1), a negative count is `RUNTIME-INVALID-COUNT` at argument 1 (`span + 2`).
  `Float.to_bits` and `from_bits` return the canonical NaN
  `0x7FF8000000000000` for any NaN; `to_bits32` decides the binary32 overflow
  before the `(float)` cast, so the cast never sees an out-of-range value, and
  gives `0x7FC00000` for NaN. The vectors of `bits-vectors.agc` are the file
  `tests/fixtures/vm/bits-vectors.stdin`, which `python3
  tests/fixtures/bits-vectors.py` writes (standard library only). CI does not
  run the script: run it by hand and commit both files when the vectors change.
  `std-binary-vectors` works the same way with `std-binary-vectors.py`.
- `std/binary` (`stdlib/binary.agc`) is Agentica on the bit builtins, with no
  C. A reader takes a `Bytes`, checks `window` (offset range, no overflow for
  any offset) and reads the items with `b[i]`; its only error is the offset.
  A writer packs a masked `List[Int]` with one `Bytes.from_list` (`pack`);
  joining is `Bytes.concat`. Goldens: `std-binary` and `std-binary-vectors`.

## std/toml

- `std/toml` (`stdlib/toml.agc`) is pure Agentica, no C. The reader walks a
  list of code points with `while` loops; each function returns the next
  position in a small struct. CRLF is turned into LF before reading, so a lone
  CR is an error everywhere. Error text is built only on the error path.
- Floats go through `JSON.parse` and `JSON.float` (`String.to_float` has no
  exponent and rounds less well). A reader error on a valid float text means a
  magnitude over the largest float, which is inf, as in `tomllib`. A sign is
  applied afterwards so that `-0.0` survives.
- Tables are built as a `Node` tree (`Leaf` sealed, `Tab` with its `Origin`)
  because `Value` cannot tell which tables a header or a dotted key may still
  extend. `Origin.Dotted` carries the number of the section that made it: only
  that section adds keys (the rule set of `tomllib`'s flags).
- Limits, all 256: arrays and inline tables per value, parts of one header,
  parts of one dotted key. The encoder refuses the same depths, and `to_json`
  refuses 2,048 levels, so no value built by a caller halts with
  `RUNTIME-STACK-OVERFLOW`, and what `encode` writes `parse` reads back.
- Tests: `tests/test_std_toml.py` compares the tagged value with the vendored
  toml-test JSON (TOML 1.0.0, `tests/fixtures/toml-test/`) and with `tomllib`;
  `.gitattributes` marks both fixture folders `-text` to keep CRLF.

## std/regex

- `std/regex` (`stdlib/regex.agc`, §48): the parser to a `Node` tree and the
  compiler to the parallel `ops`/`xs`/`ys` lists of `Program` are Agentica;
  `x*` with a nullable `x` compiles as `(x+)?`, as in Go (issue 46123). The
  Pike VM is the std-only builtin `RegexEngine.search` (`vm/regex.c`, 48c), a
  stepper that checks the program on every call (a direct call may pass any
  lists) and returns flat capture lists; `find_all`'s Go empty-match rules run
  in C too. Match values are built in Agentica.
- `Program` is private and holds an empty `Set` (`seal`) so that
  `JSON.decode` cannot build a `Regex`: `compile` is the only maker.
- Tests: `tests/test_std_regex.py` compares with Python `re` (`re.ASCII`,
  Go's empty-match rules applied to its spans; a slow generated tier), checks
  error positions and the ReDoS step budget; golden `std-regex` pins the Go
  rules. The benchmark pair is `benchmarks/programs/regex.agc`.

## Comments and style in stdlib/

As in `references/frontend.md` ("Comments and style"): a module `##` doc block
and a `##` doc on every exported `def`, `struct` and `enum` you add or touch
(as `stdlib/queue.agc`), none on code you do not touch. A `#` comment names a
VM behavior that the code copies. Lines are at most 119 characters
(`stdlib/agentica.toml`, `tests/test_style_line_width.py`: std/ files are
library files, which `CHECK-LINE-TOO-LONG` does not cover).
