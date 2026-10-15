# Library area notes

What the checker enforces and the VM keeps for each library area: stdio, JSON, tasks, TCP, TLS and HTTP, files and paths, processes. VM internals are in `references/vm.md`. Read the section for the area you are changing.

## Stdio bytes and flushing

- `IO.read()` remains the all-text-until-EOF API. `IO.read_bytes(count)` returns Result[List[Int]]; wait for count bytes or EOF, return short/empty success at EOF, and do not consume input for zero or invalid counts. The fixed 1 MiB per-call cap prevents eager allocations from arbitrary Int sizes; larger streams use repeated reads. Port read failures are local Results, not exceptions around argument evaluation.
- `IO.flush` flushes stdout and returns completion. On Linux it returns once the data is in the pipe or file (it can wait for a slow reader, §10.2.2); the other output functions do not wait for it, since the loop writes their buffer as the reader takes it, and none closes a port. On other systems stdout and stderr are blocking `FILE` writes, and a write waits for its reader without a timeout.

## JSON (phase 5f)

- Typed decoding (5f2) uses a type-expression AST node accepted only in JSON type argument positions. JSON.decode returns located-path Result errors for bad data, validates signed Int/finite Float bounds, and ignores extra fields. Recursive type validation visits each struct once. Decoded map keys are sorted. JSON.schema uses the same eligibility check, emits required fields/64-bit bounds and $defs/$ref for nested or recursive types. Builders construct opaque Json directly; JSON.from shares encode eligibility and non-finite diagnostics. Builtin record declarations participate in decoding and schemas.

- `Json` is opaque, not primitive for equality. Reserve `Json` and `JSON`; all calls use existing parser/AST forms. The catalog has nine JSON functions; `json-encode` is the only new generic checker rule.
- Recursively check encoding eligibility, including declared struct fields and empty containers. A seen-struct path prevents infinite recursion without skipping other fields. Results and Int-keyed maps are CHECK-NOT-ENCODABLE.
- False/null are present values. Int extraction is signed 64-bit and rejects decimal/exponent forms; Float extraction permits integer conversion only if finite. Parse rejects non-finite numbers, while large integer Json payloads remain valid.
- Encoding writes objects in stored map/declared field order. Non-finite Floats halt with RUNTIME-JSON-ENCODE at the call span. Debug output is `<Json>`, not the host contents.

## Lightweight I/O tasks

- Task.spawn takes Fn[A, R] and one argument and returns Task[R] and moves no handle; Task.spawn_owning (24b) takes a handle type as the argument (`handle-types` in `src/builtin-types.rkt`, else `CHECK-NOT-A-HANDLE`; keep it in step with the tag list of `agc_owned_of` in `vm/loop.c`, so a new handle kind goes into both) and gives it to the new task (`RUNTIME-HANDLE-NOT-OWNED` at run time); a `Channel[T]` is accepted too (24c, `channel-type?` in the checker): a channel is not in `agc_owned_of`, it gets its registry entry (no native object, `close` is the channel's own shut) from `agc_channel_claim` at the first hand-off, so an unowned channel can be handed over by any task and `Channel.new` stays free; a task that ends closes the handles it owns, so a handle returned through await is closed, and the await returns only after the regular-file closes (pool jobs) of that task have finished, so the data is on disk; a FIFO or pipe flush is not counted; await returns the cached R, including false/nil/error Results. Sleep takes nonnegative milliseconds, zero yields and negative values halt with RUNTIME-INVALID-DURATION. Reserve Task, Await and Channel; use Todo for the demonstration struct. `Task.await(task, timeout_ms)` (17c) is a second arity of the same catalog row in `src/builtins.rkt` (rule `task-await-timeout` in the checker: the task is a `Task`, the timeout an `Int`, the result `Await[R]`) and returns the builtin enum `Await[T]` (`Done(T)`, `TimedOut`); see the next bullet for how a builtin enum is wired. No CPU parallelism. Channels (17b) are VM-only builtins in `vm/channel.c`; see `docs/vm/10-io-scheduler.md` §10.2.2.
- Entrypoint return cancels pending work and closes the run's resources. A diagnostic in `main`, RUNTIME-STEP-LIMIT, RUNTIME-INTERNAL or System.exit ends the run; any other diagnostic in a task is a crash that ends only that task (phase 24, §37), and an unobserved crash makes the run exit 1 when `main` returns. Tasks inherit ports and arguments; cross-task stream ordering is unspecified.
- `std/bdd` fails a step with RUNTIME-BDD-PENDING-TASKS when `Task.pending_count()` is above zero after its handler, then with RUNTIME-TASK-CRASHED when `Task.unobserved_crash()` is `ok`. The runner skips stderr lines with `"task": true` when it reads a child's last diagnostic.
- The `task-*` goldens own task behavior. tests/bdd-integration.rkt verifies concurrent streams of a program under test and cleanup. examples/concurrency.agc is a hermetic CI smoke check.

## TCP, TLS and HTTP

- builtin-types.rkt centralizes opaque atoms, builtin record field layouts and builtin enums (`builtin-enum-declarations`, `builtin-enums`: `Await`). A builtin enum reuses the user-enum paths: the checker starts its `enums` table with them and adds their names to `reserved-type-names` (`CHECK-REDEFINED-NAME`), so annotation, constructors, patterns, exhaustiveness and printing need no special case, and `data-type?` also accepts a `Void` payload for them (`Await[Void]`); `src/modules.rkt` keeps the name unmangled and turns `Await.TimedOut` and `Await.Done(...)` into `enum-constructor`; `src/lower.rkt` appends the `ir-enum` after the user enums only when the program mentions it, as for builtin structs, and picks `Task.await_result` for the timed form when the payload is a Result; the VM finds the variants by name (`agc_builtin_variant`), and `vm/text.c` prints `Await.Done()` for a Void payload. Handles cannot be constructed, compared or JSON encoded. Grammar and the programming reference describe the same public API.
- TCP and TLS are C builtins (`vm/tcp.c`, `vm/tls_openssl.c`); HTTP is `std/http` in Agentica over the std-only `HttpWire` builtins (`vm/http_*.c`), imported as `HTTP`; the server (20c) runs each connection as a task in the server's task group. See `references/vm-net.md`.
- tests/vm-tcp-test.rkt, vm-tls-test.rkt and vm-http-test.rkt use independent Node and Python standard-library peers. CI installs Node 24 and Python 3; absence fails CI and visibly skips locally. Checked-in localhost test certificates exercise trusted TLS, untrusted certificates and hostname rejection.

## Files and paths

- File builtins are `vm/files.c` (`references/vm-io.md`). File reads/writes serialize on one per-handle lock and include lock wait in the deadline; a timed-out active operation closes the handle. Symlink targets resolve relative to the link's own directory, and link cycles stop at the first repeated path. The end of a run flushes stdout first, then closes open files with pool close jobs and waits for them (at most the flush limit: 30000 ms, `--flush-timeout MS` or `AGENTICA_FLUSH_TIMEOUT_MS`; then a warning line and the same exit code); other handles close on the loop thread.
- File.open accepts read/write/append modes and only regular files or links to regular files. Whole-text calls and individual stream operations cap data at 1 MiB; strict UTF-8 errors become Result errors. Dir.mkdir is recursive and idempotent, Dir.list is sorted, Path.resolve is lexical without symlink resolution, and Path.real is POSIX `realpath` through `uv_fs_realpath` in a pool job (no timeout argument; a path that does not exist is an error). System.env (in `vm/process.c`) needs no flag. builtin-types.rkt owns FileHandle and FileInfo registration; grammar.md and the self-contained programming reference document matching semantics.
- File.each_line (7.2.1h) is a stepper builtin (`references/vm-io.md`, `vm/interp.c`): it reads one line at a time through a buffer of `buffer_bytes + 1` bytes, one pool job (regular file) or one poller read (FIFO, pipe, or a device that can wait) per read, each with its own `timeout_ms`; the file closes on every return path, and a task cancelled while it waits leaves the handle open until the end of run, as `File.open` does. `buffer_bytes` outside 1,024 to 16,777,216 is `RUNTIME-INVALID-COUNT` at the argument, before the file opens; a timeout of zero or less is an error Result. `tests/vm-file-lines-test.rkt` (with `tests/fixtures/lines-peer.py`) and `vm/tests/each_line_test.c` cover it; `tests/fixtures/vm/file-each-line*.agc` are the goldens.
- tests/filesystem-test.rkt runs checked Agentica programs on the VM against temporary directories, including Path.real through link chains, loops and long paths and System.env with bytes that are not UTF-8, both compared with Python's `os.path.realpath` and `os.environ` (`tests/fixtures/os-peer.py`, required in CI), plus stream/whole-file round trips, error Results, metadata, paths and EOF, FIFOs on the loop (with `mkfifo` and `tests/fixtures/fifo-peer.py`, a Python reader that is slow or leaves, giving `EPIPE`; both are required in CI), a crash cancelling a parked FIFO read, and stdin on the loop. The end-of-run file flush limit is always on (`AGC_FLUSH_TIMEOUT_MS`, 30000, in `vm/port.h`); `--flush-timeout MS` or `AGENTICA_FLUSH_TIMEOUT_MS` (read in `vm/main.c`, the flag wins, a bad value exits 2) sets it, and the FIFO test there uses small values. `tests/vm-diff-common.rkt` and the Makefile clear that variable, as they do `AGENTICA_VM_TRACE`. Keep filesystem tests local and clean temporary trees on every outcome.

## Void and processes

- Void completes a function without data. Only return/Fn-result/Result/Task completion positions accept it; reject inferred Void values except statements and forwarded Void returns. Nil remains data and requires explicit returns. Main and side-effect callbacks return Void. Result[Void] success uses ok(). Migrate fixtures by meaning, preserving Nil and false data cases.
- --allow-run defaults off and reaches the VM. `agentica test --allow-run` passes it to step handlers and programs under test. The end of a run kills and reaps directly spawned children. Expected operations return Results.
- tests/process-test.rkt uses independent Node standard-library children, CLI capability checks, binary/full-duplex streams, nonzero exits, deadline policies and PID cleanup. Node is required in CI; local absence visibly skips. CI also exercises the compiled executable and examples/process-tool.agc with --allow-run.

## Int and Float bits, std/binary (phases 13a, 13b)

- Int and Float bit builtins (`vm/numbers.c`, 13a): shifts and masks run on
  `uint64_t` and `int_from_bits` turns the result back into an `int64_t` without
  implementation-defined casts; a count of 64 or more is decided before the
  shift (`shift_left` and `shift_right_unsigned` give 0, `shift_right` gives 0
  or -1), a negative count is `RUNTIME-INVALID-COUNT` at argument 1 (`span +
  2`). `Float.to_bits` and `from_bits` return the canonical NaN
  `0x7FF8000000000000` for any NaN; `to_bits32` decides the binary32 overflow
  (`>= 2^128 - 2^103`) before the `(float)` cast, so the cast never sees an
  out-of-range value, and gives `0x7FC00000` for NaN. The vectors of
  `bits-vectors.agc` are the file `tests/fixtures/vm/bits-vectors.stdin`, which
  `python3 tests/fixtures/bits-vectors.py` writes (standard library only; it
  checks `struct` against its own exact `Fraction` rounding). CI does not run
  the script: run it by hand and commit both files when the vectors change.
  `tests/vm-bits-test.rkt` checks the spans of the errors.

- `std/binary` (`stdlib/binary.agc`, 13b) is Agentica on the 13a builtins, with
  no C. A reader is `window` (offset range, no overflow for any offset), a
  `load8/16/32/64_{be,le}` that indexes the items, ORs them with `bit_or` and
  tests the result once (`bytes_ok`), and walks the bytes (`first_bad_byte`)
  only to name the first bad one; `extend` sign-extends with `shift_left` then
  `shift_right`. A writer is `fits` plus a list literal from `bytesN_{be,le}`.
  `concat` splits in halves (`join_parts`), so it recurses about log2 k deep.
  The goldens are `std-binary` (round trips both ways, error order and messages,
  `concat`, frames) and `std-binary-vectors`, which checks
  `tests/fixtures/vm/std-binary-vectors.stdin` that `python3
  tests/fixtures/std-binary-vectors.py` writes (standard library only; it loads
  `bits-vectors.py` for the float helpers and checks `struct` against the 13a
  exact f32 rounding). CI does not run the script: run it by hand and commit
  both files when the vectors change. `tests/std-binary-test.rkt` checks the
  fixed output.

## Comments in stdlib/

- Give the module a `##` doc block (its first block, followed by a blank
  line), and give every exported `def`, `struct` and `enum` you add or touch
  one, as `stdlib/queue.agc` does; do not add docs to code you do not touch.
  Say what the code does and returns, not how. A `#` comment goes inside the
  body or above the `##` block, never between the block and its `def` (that is
  `PARSE-DETACHED-DOC`).
- Add a `#` comment where the Agentica is complex: a bit trick, a bound that
  keeps input safe, an order that matters, or a copy of a Racket or VM
  behavior (name it). Never narrate obvious code.
