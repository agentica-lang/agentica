## 8. Loader safety

The loader validates the whole file before running anything. Failures print
`agentica-vm: invalid bytecode: <reason>` and exit with 2.

- **Input**: a regular file of at most 256 MiB. Every read is bounds-checked;
  every count is checked against the bytes left before allocating. All index
  and size sums use `uint64_t`. Loading has a memory budget of 4 times the
  file length plus 1 MiB; every allocation is charged to it first, and a file
  that needs more is rejected.
- **Header**: magic, format version and Agentica version must match exactly;
  the file must end right after the entry.
- **Strings**: valid UTF-8 with no surrogates; character counts are computed.
- **Spans**: an existing source; `start <= end`; for both start and end,
  `1 <= line <= ` the source's line count and `1 <= column <=` the line's
  length in characters plus 1.
- **Tables**: known constant kinds; field counts and arities fit 16 bits;
  builtin record names only with their exact C layout; builtin `(name,
  arity)` pairs exist.
- **Types**: at most 65535 types, each with a known kind; a List or Map
  entry names an earlier type and nests at most 1024 List and Map levels
  (the writer gives `BYTECODE-LIMIT` past that), a Struct entry a struct in range that has a
  decodable record; records name structs in range in increasing order (so
  at most one each) with distinct names (sorted, then adjacent names
  compared), have one field type per field (the count checked
  against the bytes left), and every field type index is in range. So the
  only cycles go through named structs. `vm/tests/loader_test.c` checks
  each rule and truncation at every byte of a file with a type table.
- **Functions**: `1 <= registers <= 65535` and `params + captures <= registers`; at least one
  instruction; the last is `RETURN` or `JUMP`; known opcodes; every register
  operand below `registers`, including ranges: `LIST` `b..b+c-1`, `MAP`
  `b..b+2c-1`, `STRUCT` `b..b+fields-1`, `ENUM` `b..b+arity-1`, call windows
  (`CALL` and `TAIL_CALL` with the callee's parameter count, `CALL_VALUE` `a..a+b`,
  `CALL_BUILTIN` with its arity, `CLOSURE` with the captures); constant, function, builtin, type, struct,
  field, variant and span indexes in range, including the extra spans of
  `STEP` and `CALL_BUILTIN`; jump targets inside the function; `STEP` count at
  least 1.
- **Termination**: every backward jump targets a `STEP`, and every function
  starts with a `STEP` unless it has at most 2 instructions and no `CALL`,
  `TAIL_CALL`, `CALL_VALUE` or `CALL_BUILTIN` (the `const`/`return` of an empty body). The
  lowering in 3.3 always meets these rules. Together they mean every
  unbounded repetition charges a step (a range loop charges its own `STEP`
  each iteration, and a counting native frame charges one step before each
  callback, like `STEP`; a cycle of tail calls runs only
  functions that call, so each one charges its leading `STEP`), so `--max-steps` holds even for
  hostile files: the step budget bounds the number of instructions to about
  steps × code size. It does not bound bytes: `CONCAT` and `INSPECT` cost
  time and memory in proportion to their strings (trust model, 1). `LIST`
  and `TAIL_CALL` copy up to 65534 values in one instruction, so they cost
  O(count) per step, still within steps × code size. `MAP` hashes and puts
  at most 255 pairs, so one step cannot pay for a huge literal; longer
  literals are extended one `Map.put` at a time.
- **Entry**: exists, with no parameters or captures.
- **Ranges**: `RANGE` checks `a`, the window `b..b+1` and that `c` is 0 or
  1; `RANGE_BOUNDS` checks `b` and the window `a..a+2`.
- **Closures**: `CALL_VALUE` checks the window `a..a+b`; `CLOSURE` checks
  the function index and the window of that function's captures (`a`
  itself when it has none). `CALL` and `TAIL_CALL` may not name a
  function with captures (only `CALL_VALUE` fills them). A `CALL_VALUE`
  counts as a call for the termination rules.
- **In the slice**: constant kinds above 6 are
  rejected. Struct field counts and variant arities are at most 65535. All
  variants go into one array sized by a first pass over the Enums section,
  and each nullary variant gets one small shared empty enum value, so a file
  with 65535 variants or a struct with 65535 fields stays within the load
  budget. `load_alloc` returns NULL for a zero size without charging the
  budget; callers never read or copy through a zero-size result.
  `STRUCT` checks `a`, `c`
  below the struct count and the window of that struct's field count;
  `ENUM` checks `a`, `c` below the variant count and the window of its
  arity (`b` itself when it is 0); `IS_VARIANT` checks two registers and the
  variant id; `FIELD` and `PAYLOAD` check two registers and `c` below the
  largest field count or arity (the run time checks the value's own `n`);
  `SAME` checks three registers; `TRY`, `IS_OK` and `RESULT_VALUE` two;
  `MAP` checks `a`, `c <= 255` (the lowerer's chunk size, 3.3) and the
  window `b..b+2c-1` (`b` itself when `c` is 0; `2c` is computed in 32
  bits), `MAP_GET` three registers.
  Builtin record layouts are not checked
  yet: the lowerer rejects builtin record types, and the check joins with
  the first library PR that reads one. `CONCAT`
  checks three registers, `TO_TEXT` and `INSPECT` two. `LIST` checks `a`
  and the window `b..b+c-1` (and `b` itself when `c` is 0), `LIST_LEN` two
  registers and `LIST_GET` three. `vm/tests/loader_test.c` checks each rejection by its reason:
  truncation at every byte, bad magic and versions, trailing bytes, entry out
  of range or with parameters, unknown builtins, invalid UTF-8 (overlong,
  surrogate, above U+10FFFF, and a truncated sequence in a String
  constant), span lines and columns out of range and spans
  that start after they end, bad register counts (0, above 65535, fewer than
  the parameters), out-of-range registers, constants, jumps and spans
  (including the extra spans of `STEP` and `CALL_BUILTIN`, and the
  registers of the Float, String, List, struct and enum opcodes, and the
  `LIST`, `STRUCT` and `ENUM` windows), every struct and enum table rule
  above (and that 65535 nullary variants and 65535 fields load), `CALL`,
  `TAIL_CALL` and `CALL_BUILTIN` windows, a `TAIL_CALL` to a function out of
  range, the registers of `TRY`, `IS_OK` and `RESULT_VALUE` (and, at run
  time, that they fail on a non-Result and that a `TRY` error in `main`
  is `RUNTIME-INTERNAL`), the `MAP` window, a `MAP` count of 256 (and that 255 loads) and
  `MAP_GET` registers (and, at
  run time, a missing key's code, span and message, a nested map printed,
  and `RUNTIME-INTERNAL` for a Void key or a `MAP_GET` on a list), a
  `Map.put` import of the wrong arity, the `CALL_VALUE` window, a
  `CALL_VALUE` that does not start its function with a `STEP`, a `CLOSURE`
  of a function out of range or with a capture window out of range, a
  `CALL` or `TAIL_CALL` of a function with captures,
  captures that do not fit the registers, an entry with captures (and, at
  run time, a `CLOSURE` called through `CALL_VALUE`, `List.map` with a
  closure, and `RUNTIME-INTERNAL` for a call of a non-function and for a
  wrong parameter count, directly or as a callback), a `List.map` import
  of the wrong arity, `STEP 0`, a backward jump that misses a `STEP`,
  functions that should start with one (one is just `TAIL_CALL`, `RETURN`), an unknown opcode, a missing final
  `RETURN`/`JUMP`, and a file over the memory budget.
- **Run time**: `CALL_VALUE` and callback parameter and capture counts,
  tags (5.2), list, map and string bounds, and the register cap (6.1).

Types are not verified statically; tag checks at run time are far simpler
and cost one predictable branch each.

## 9. CLI and packaging

- `agentica compile file.agc -o file.agcb` (7d) runs the front end and writes
  bytecode.
- `agentica-vm [--max-steps N] [--seed N] [--allow-run] [--ai|--json] --
  file.agcb [args...]` (7e; `--allow-run` since the 7h processes PR). The option parser is hand
  written: it stops at the first non-option and honors `--`. Option values are
  checked with exit code 2, as in `src/main.rkt`. Callers
  always pass `--` before the file. A test checks that `--allow-run` after the
  file is a program argument. On Windows, arguments come from `wmain`
  (`-municode`) and are converted to UTF-8; the input file is opened with `_wopen` on the original UTF-16 argument, so
  non-ASCII paths load and a lone surrogate never maps to another file. The
  size comes from `_fstat64`, so a file over 2 GiB is rejected, not read
  as a prefix. Paths over 260 characters fail with `_wopen` unless they use
  `\\?\` or the executable has a `longPathAware` manifest; 7h decides.
  `--schedulers N` (10.2.3) comes with the 7h multicore schedulers item;
  `agentica --schedulers N` passes it through, as it does `--seed`. A
  golden test runs a copy named `cálculo-λ-日本-𝔸.agcb`, and a CRLF
  program under a non-ASCII directory.
- `agentica-vm --version` prints the VM version and the versions of libgc
  (and libuv, picohttpparser and OpenSSL from 7h). OpenSSL is linked
  statically, so its version is the one built in (`agentica-vm 0.1.0
  (libgc 8.2.12, yyjson 0.13.0, libuv 1.53.0, OpenSSL 3.5.9)`).
- In the slice the VM accepts `--version`, `--max-steps N`, `--seed N`
  (7.4), `--ai`, `--json`, `--allow-run` (10.4) and `--`. `--ai` and `--json` may both appear; the last one
  wins, as with `command-line`. Giving one option twice prints `agentica-vm:
  the --ai option can only be specified once`. Racket's `command-line`
  exits 1 for every option error it raises itself (a repeated option, an
  unknown switch, a missing value); the VM exits 2 for all of them, since
  the 7i driver parses the user's options itself. Value errors that
  `src/main.rkt` checks (`--max-steps needs a positive integer`) exit 2 on
  both.
  Arguments after the file are the program's `System.args`.
- Tests in 7e and 7f spawn `dist/agentica-vm` directly.
- `agentica file.agc [args...]` runs on the VM (7i, Linux). The `--vm`
  flag, which did nothing once the VM was the default, went with the
  evaluator; it is now an unknown switch. `src/main.rkt`
  runs the front end and `lower`, then writes the bytecode to
  `agentica-<32 hex>.agcb` in the system temp directory (`TMPDIR`), created
  exclusively with mode 0600 (`#:exists 'error #:permissions #o600`). It
  runs the VM as `agentica-vm [--max-steps N] [--seed N] [--allow-run] [--ai|--json] --driver-pid
  PID -- file [args...]`. `--driver-pid` is a hidden VM flag (not in the
  usage text). On Linux the VM first sets `SIGTERM` back to its default
  action, calls `prctl(PR_SET_PDEATHSIG, SIGTERM)` (`SIGTERM`, not
  `SIGKILL`, so the VM kills its children before it ends, 10.4) and then
  checks that `getppid()` is `PID`; if not, the driver
  is already gone, so it prints a message and exits 2 without touching the
  input (Racket's `subprocess` cannot run code between fork and exec, so
  the check closes that race). Then it opens the input with `O_NOFOLLOW`
  and loads it only if it is a regular file owned by the VM's user, with
  one link and no group or other permission bits; otherwise it exits 2.
  The path is visible in `ps`, and a shared temp directory without the
  sticky bit would let another user swap the file between the driver's
  close and the VM's open; these checks refuse a swapped file. After those
  checks it deletes the input, but only if the path still names the file it
  opened (same device and inode). The driver deletes the file too, when the
  VM never ran or failed before loading, and on a break. On a break
  (`SIGINT`, `SIGTERM` or `SIGHUP` to the driver) the driver stops a
  running VM with `SIGTERM`, waits up to 2 seconds for it to end, and only
  then sends `SIGKILL`; the VM's watchers kill its children in that
  time (10.4). When a driver
  output port is not a file stream (rackunit, captured output) it copies
  that stream through a pipe, and a non-file stdin is copied into the VM's
  stdin by a thread that stops when the VM exits. The thread reads ahead
  of what the program consumes, so on a non-file stdin shared with other
  code the driver may take bytes the program never read. If reading the
  driver's stdin fails, the thread stops the VM the same way and the driver reports
  `RUNTIME-INTERNAL` (exit 1);
  a special (non-byte) value on the port ends the input like EOF. Otherwise it passes the real stdin, stdout
  and stderr, so the VM's output and exit code reach the user unchanged. Front-end and `LOWER-` diagnostics print as usual
  (exit 1). `--max-steps N`, `--seed N`, `--allow-run`, `--ai` and `--json`
  are passed to the VM; a seeded run repeats.
- No fallback (7i). A `LOWER-UNSUPPORTED` from `lower` prints like any
  diagnostic and exits 1; every catalog builtin is in `vm-builtins`, so no
  builtin reaches it today. Until 7i, such a program ran on the Racket
  evaluator after a one-line notice, and the hidden `--legacy-eval` flag
  forced the evaluator; 7i deleted both, with the evaluator, and the
  refusal of programs that needed VM-only builtins on those paths
  (`check-vm-only`, §30.8 of `docs/future/`).
  `agentica test` runs on the VM (roadmap 21f,
  `docs/future/31-bdd-in-agentica.md` §31): `src/bdd-driver.rkt` compiles
  the step program and the runner written in Agentica, starts the runner
  with `--driver-pid`, and the runner starts one VM per scenario; the
  programs under test run like `agentica FILE`.
- Finding the VM, never in the current directory: `AGENTICA_VM=path` wins;
  under `racket src/main.rkt` it is `dist/agentica-vm` of the checkout
  (from the module's own source path); in a `raco exe` build it is
  `agentica-vm` next to the executable (`run-file`, with symlinks
  resolved). The release archive has `agentica-vm` in `bin/` next to
  `agentica`, so the same rule finds it there, also through a symlink on
  `PATH`. A missing or non-executable VM prints `agentica: cannot find
  the VM at PATH; run make vm or set AGENTICA_VM` and exits 2 after the
  front end and the lowering, so a program diagnostic wins.
  It does not use `define-runtime-path`: `raco distribute` would then copy
  the VM into `lib/` and fail when it is not built.
- Future work: Windows (a kill-on-close job object instead of
  `PR_SET_PDEATHSIG`) and macOS (no parent-death signal; the closest safe
  thing is the delete-after-load flag alone, or a pipe the VM watches).
  On macOS the flag skips only the parent check: the `O_NOFOLLOW`,
  privacy and inode checks run on every non-Windows system. Windows skips
  both checks, and the VM may fail to delete its still-open input, but the
  driver deletes it anyway. The VM driver is tested on Linux only.
- `PR_SET_PDEATHSIG` follows the OS thread that forked the VM, so the
  driver must call `subprocess` from the main thread.
- The hidden flag deletes its private input after loading, so only a
  driver that hands the VM a private one-shot file may pass it: the normal
  run and the BDD runner of `agentica test` (`src/bdd-driver.rkt`).
- `check`, `help` and `test` stay Racket commands; since 21f (§31 of
  `docs/future/`), `test` only discovers the feature files, compiles the
  step program and an embedded runner written in Agentica and runs the
  runner on the VM, which starts a child VM per scenario; its handlers and
  the programs under test run there. `make vm`
  builds `dist/agentica-vm` (`.exe` on Windows), and `make exe` and
  `make test` build it first. The release workflow builds it with `zig cc`
  against glibc 2.28 (pinned zig, checked by sha256), checks that floor with
  `objdump -T`, and ships it in `bin/` next to `agentica`.

- **VM tracing (as built, roadmap 14a).** The rules are in
  `docs/future/24-logging.md` §24.4; this note lists only what the code
  chose. `vm/trace.h` holds `agc_trace` (category mask, descriptor, start
  time), the category bits and `AGC_TRACE(trace, category, format, ...)`;
  `vm/trace.c` holds `agc_trace_parse`, `agc_trace_message` (the
  `unknown category` and `cannot open` lines) and `agc_trace_emit`, which
  walks the format itself: numbers (`d`, `i`, `u`, `x` with `hh` to `j`,
  `z`, `t`) go through `snprintf`, every `%s` and `%.*s` through the
  escaper, and any other conversion (`%c`, `%p`, floats, widths, flags)
  ends the line with `?`. A text value with a byte that is not part of a
  valid UTF-8 sequence (a lone continuation byte, a cut lead byte) is
  quoted, and each such byte is written as `\u00XX`, so a trace line is
  always valid UTF-8. `vm/main.c`
  reads both variables after the option checks and before
  `agc_load_traced` (`agc_load` is the untraced form the tests and the
  fuzzer call), opens the file with `O_NONBLOCK` and `O_NOFOLLOW` and takes
  only a regular file owned by the VM's user (a FIFO, a device, a symlink
  or another user's file gives the `cannot open` line, so start-up never
  blocks), moves a trace descriptor that lands on 0, 1 or 2 to 3 or above (so a closed stderr stays closed), and stores the
  struct in `agc_runtime`. With `AGENTICA_VM_TRACE_FILE` set, the
  `unknown category` warning goes to the trace file, not to stderr; the
  `cannot open` line goes to stderr. `proc` and the process guard keep a copy, since
  libuv callbacks have no runtime pointer. Task ids come from the runtime's
  `next_task_id` (main is 1); job and handle ids are resource ids from the
  scheduler's registry. Event names: `sched` spawn, turn (`steps`, `cost`,
  `why`), wake (`by=job|await|lock|stdin`), cancel, stall, fail, exit; `io`
  start, done, timeout (`us` from the job start to its `done` callback,
  `result=ok|error|value`; lock jobs have none, `lock_handoff` and
  `lock_timeout` cover them), lock_wait, lock_handoff, lock_timeout, stdin,
  poll (`mode=once|nowait`, `us` blocked; a `nowait` poll that found no
  finished job writes nothing), close (`resources` left in the
  registry, `settled`), hard_exit, and the TCP events of 10.3.1:
  tcp_connect (`socket`, `host`, `port`), tcp_connected, tcp_connect_error
  (`error`, one per failed address), tcp_listen (`listener`, `host`, the
  bound `port`, the number of bound `addresses`), tcp_accept (`listener`,
  the new `socket`), tcp_accept_error, tcp_eof (`error=0` at EOF),
  tcp_close (`socket` or `listener`,
  `why=close|timeout|line|accept|failed|exit`); `proc` spawn
  (`captured=0|1`), spawn_failed (`rc`, `reason=unresolved` when
  the executable is not found, or `reason=dir` when a captured child's
  directory is not one), exit, close, term (the `SIGTERM` of a captured
  child), kill, reap, eof (`pipe=stdin|stdout|stderr`), truncated
  (`pipe=stdout|stderr`, a captured stream past 1 MiB),
  stderr, guard_start, guard_stop (`raise`), signal, guard_cleanup;
  `loader` file, format, tables, done, reject (`reason`, `pos`); `gc`
  collect (`at=turn|end`); `tls` (10.3) tls_handshake (`socket`, or
  `socket=0` and the `listener` on the server side, `role=client|server`,
  the client's `host`), tls_handshake_done (`protocol`, `cipher`),
  tls_handshake_error (`error`, `detail`), tls_setup_error (`error`, for
  a bad CA file, certificate or key), tls_read_error (`error`) and
  tls_close (`socket`, `why` as for tcp_close, right after the socket's
  tcp_close). A cut line ends
  with `...` after a whole escape or UTF-8 sequence; a cut inside a quoted
  value closes the quote first (`"...`). `make vm TRACE=0` passes
  `-DAGC_TRACE_BUILD=0` and `--version` then says `trace off`.
  `vm/tests/trace_test.c` covers the escaper and the line buffer;
  `tests/vm-trace-test.rkt` the whole runs.
- On Linux, `main` first opens `/dev/null` onto any of descriptors 0, 1
  and 2 that is closed, in the wrong direction (write-only for 0,
  read-only for 1 and 2), so libuv never gets a low descriptor and trips
  its assertion, while reads and writes on that stream still fail with
  `EBADF` as before.
