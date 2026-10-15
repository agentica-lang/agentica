## 8. Loader safety

The loader validates the whole file before anything runs. A failure prints
`agentica-vm: invalid bytecode: <reason>` and exits 2. Types are not checked
statically: run-time tag checks are simpler, and each costs one predictable
branch.

- **Input**: a regular file of at most 256 MiB, read with bounds checks. Every
  count is checked against the bytes left before anything is allocated. Index
  and size sums use `uint64_t`. The loader has a memory budget of 4 times the
  file length plus 1 MiB, and every allocation is charged to it first.
- **Header**: magic, format version and Agentica version match exactly. The file
  ends right after the entry. The one exception to the exact Agentica version
  is the front end that the single binary loads itself (the carried one, or
  the file of `--front-end`): its Agentica version may differ, and every other
  check applies to it. See "The single binary" in section 9.
- **Strings**: valid UTF-8 with no surrogates. Character counts are computed.
- **Spans**: the source exists, `start <= end`, and each line is within the
  source's line count and each column within the line's length plus 1.
- **Tables**: constant kinds 0 to 6 only. Field counts and variant arities are
  at most 65535. The loader does not check builtin records: a builtin finds its
  record by exact name and fields at run time (5.2). Every builtin
  `(name, arity)` pair exists.
- **Types**: at most 65535 types with known kinds. A List or Map entry names an
  earlier type and nests at most 1024 levels (the writer gives `BYTECODE-LIMIT`
  past that). A Struct entry names a struct in range that has a decodable
  record. Records name structs in increasing order with distinct names, have one
  field type per field, and every index is in range. So cycles only go through
  named structs.
- **Updates**: at most as many entries as fit in the file. Each names a struct
  in range and lists 1 to that struct's field count of field indexes, strictly
  increasing (so distinct) and below the field count. `STRUCT_WITH` then names
  an entry in range, with the window `b..b+k` (the receiver and the `k` values)
  below `registers`. The loader does not know the type of a register, so the
  receiver's struct type and field count are checked when the instruction runs
  (5.2).
- **Globals**: the slot count is at most 65,535. Nothing else is read for the
  section (a slot has no bytes, so the count cannot be checked against the bytes
  left), and the array of slots is allocated through `load_alloc`, so the load
  budget charges it. The slots start as zeroed memory, which means "never set"
  (`GLOBAL` of one is `RUNTIME-INTERNAL`, 4.2).
- **Functions**: `1 <= registers <= 65535` and `params + captures <= registers`.
  At least one instruction, and the last is `RETURN` or `JUMP`. Every opcode is
  known. Every register operand is below `registers`, including each window:
  `LIST` `b..b+c-1`, `MAP` `b..b+2c-1` (with `c <= 255`), `STRUCT` and `ENUM` by
  their sizes, `CALL` and `TAIL_CALL` by the callee's parameter count,
  `CALL_VALUE` `a..a+b`, `CALL_BUILTIN` by its arity, `CLOSURE` by its captures.
  Constant, function, builtin, type, struct, field, variant and span indexes are
  in range, including the extra spans of `STEP` and `CALL_BUILTIN`. Jump targets
  are inside the function, and a `STEP` count is at least 1. `RANGE` checks `a`,
  the window `b..b+1` and that `c <= 1`; `RANGE_BOUNDS` checks `b` and the
  window `a..a+2`.
- **Termination**: every backward jump targets a `STEP`. Every function starts
  with a `STEP`, unless it has at most 2 instructions and no call (an empty
  body). The lowering (3.3) always meets these rules. Together they mean every
  unbounded repetition charges a step, so `--max-steps` holds even for hostile
  files. The budget bounds instructions to about steps times code size. It does
  not bound bytes: `CONCAT` and `INSPECT` cost time and memory in proportion to
  their strings (§1). `LIST` and `TAIL_CALL` copy up to 65534 values in one
  instruction. `MAP` hashes at most 255 pairs per instruction, and longer
  literals are extended with `Map.put`.
- **Entry**: exists, with no parameters or captures.
- **Globals in code**: the slot of every `GLOBAL` and `GLOBAL_SET` is below the
  count, so a count of 0 allows neither. When the count is above zero, only the
  entry function may hold a `GLOBAL_SET`, a function with a `GLOBAL_SET` has no
  backward jump (a jump whose target is not after it), and no `CALL`,
  `TAIL_CALL` or `CLOSURE` names the entry, so nothing can run the entry again
  and write a slot after `main` started. With a count of 0 these three rules do
  not apply: the entry is `main`, which a program may call. The writes happen
  once, before `main`, and the table is read-only after that, which keeps the
  tasks of a future multicore scheduler free of races on it (§10.2.3 of
  `10-io-multicore.md`, §16.7 of `16-architecture.md`).
- **Closures**: `CALL_VALUE` checks its window. `CLOSURE` checks the function
  index and the window of its captures. `CALL` and `TAIL_CALL` may not name a
  function with captures, since only `CALL_VALUE` fills them. A `CALL_VALUE`
  counts as a call for the termination rules.
- **Run time**: parameter and capture counts of `CALL_VALUE` and callbacks, tags
  (5.2), list, map and string bounds, and the register cap (6.1).

`vm/tests/loader_test.c` checks each rule by its reason, and truncation at every
byte of a file with a type table, an Updates section or Globals.

## 9. CLI and packaging

- `agentica compile file.agc -o file.agcb` runs the front end and writes
  bytecode.
- `agentica-vm [--version] [--max-steps N] [--seed N] [--flush-timeout MS] [--allow-run] [--ai|--json] [--source-root DIR] -- file.agcb [args...]`.
  The option parser is hand written. It stops at the first non-option and honors
  `--`. Callers always pass `--` before the file, so an option after the file is
  a program argument. Option errors (a repeated option, an unknown switch, a
  missing or bad value, a bad `AGENTICA_FLUSH_TIMEOUT_MS`) exit 2. `--ai` and
  `--json` may both appear, and the last one wins.
- `--source-root DIR` (once; DIR must be valid UTF-8 and not `--`, and "" does
  nothing; a bad DIR exits 2) puts `DIR/` before every source name of the
  program that is relative and does not start with `std/`, once, right after
  the load (`agc_program_set_source_root`), so diagnostics, stack traces, task
  crash lines and test reports all print the joined name (the 256-byte cut of
  stack lines applies to it). No `/` is added when DIR already ends in one. A
  name that starts with `std/` is a standard module; the front end writes a
  user file under a `std/` folder as `./std/NAME.agc`, which is joined. A
  leading `./` is dropped from every name that is joined, not only from that
  one: with DIR `r`, `./x.agc` prints as `r/x.agc`. An absolute name is left
  as it is. The bytes added over all names are capped at 64 MiB; past it the
  VM exits 2 with `--source-root is too long for this program`. The `.agcb`
  stores names relative to the folder of the entry file (4.6); `agentica`
  passes that folder as the user would type it, relative to the working
  directory, unless the entry is in it. Without the option the stored name
  prints. DIR is not normalized: an imported file above the root prints as
  `DIR/../shared/x.agc`.
- `--flush-timeout MS` sets the end-of-run wait for file close jobs and for the
  buffered output of stdout and stderr (10.2.2, End of run). The wait is always
  bounded: 30000 ms by default, and the environment variable
  `AGENTICA_FLUSH_TIMEOUT_MS` (an integer from 0 to 86400000, read by the VM, so
  `agentica` and `agentica-vm` both honour it) sets it when the flag is absent;
  the flag wins. `0` means no wait, and there is no way to turn the limit off:
  values above 86400000 (24 hours) are rejected. A bad flag or variable value
  exits 2. When it runs out, the VM prints
  `agentica: file data may not be written: the flush took longer than MS ms`
  (with `--json`, a JSON object with the same warning), after the flush and
  after the diagnostic of a failed run, which is queued before the wait so that
  the limit covers it. The exit code is kept.
- `--version` prints the VM version and the versions of the libraries it links:
  libgc, yyjson, libuv and OpenSSL (the one that runs). OpenSSL is linked
  statically in the release.
- The planned `--schedulers N` (10.2.3) is not in the VM yet.
- Windows: arguments come from `wmain` and are converted to UTF-8. The input
  opens with `_wopen` on the original UTF-16 name, so a lone surrogate never
  maps to another file. The size comes from `_fstat64`, and a file above the 256
  MiB limit is refused. There is no long-path handling: `vm/main.c` passes the
  path as given, with no `\\?\` prefix and no long-path manifest.
- `agentica file.agc [args...]` runs on the VM. `src/main.rkt` runs the front
  end and `lower`, then writes the bytecode to `agentica-<32 hex>.agcb` in
  `TMPDIR`. The file is created exclusively with mode 0600. The driver runs
  `agentica-vm [options] --driver-pid PID -- file [args...]`. `--driver-pid` is
  a hidden flag. Only a driver that hands the VM a private one-shot file may
  pass it: the normal run and the BDD runner of `agentica test`.
- On Linux, the VM first resets `SIGTERM` to its default, sets
  `prctl(PR_SET_PDEATHSIG, SIGTERM)` (`SIGTERM`, so the VM kills its children
  before it ends, 10.4) and checks that `getppid()` is `PID`. If not, the driver
  is already gone, and the VM exits 2 without reading the input. Then it opens
  the input with `O_NOFOLLOW` and loads it only if it is a regular file owned by
  the VM's user with one link and no group or other permission bits. The file is
  deleted after loading, but only if the path still names the file it opened
  (same device and inode). The driver also deletes the file when the VM never
  ran, or failed before loading.
- On a break (`SIGINT`, `SIGTERM` or `SIGHUP` to the driver), the driver waits
  up to 2 seconds, since Ctrl-C also reaches the VM and a second `SIGTERM` would
  skip the file flush (10.2.2). Then it sends `SIGTERM`, waits up to 2 more
  seconds, and only then sends `SIGKILL`. On another way out (a failed stdin
  read) it sends `SIGTERM` at once. A VM whose driver died ends on its first
  stop signal, without the file flush, after it kills its children.
- When the driver's output is not a file (captured output), it copies that
  stream through a pipe. A non-file stdin is copied into the VM's stdin by a
  thread that stops when the VM exits, so the driver may read ahead of what the
  program consumes. A special (non-byte) value on the port ends the input like
  EOF. If reading the driver's stdin fails, the VM is stopped and the driver
  reports `RUNTIME-INTERNAL` (exit 1).
- Front-end and `LOWER-` diagnostics print as usual (exit 1). `--vm` and
  `--legacy-eval` are unknown switches.
- The VM is found and never looked up in the current directory:
  `AGENTICA_VM=path` wins. Under `racket src/main.rkt` it is `dist/agentica-vm`
  of the checkout. In a `raco exe` build it is `agentica-vm` next to the
  executable, with symlinks resolved. The release archive has it in `bin/`. A
  missing or non-executable VM prints
  `agentica: cannot find the VM at PATH; run make vm or set AGENTICA_VM` and
  exits 2, after the front end and the lowering, so a program diagnostic wins.
  The lookup does not use `define-runtime-path`, since `raco distribute` would
  copy the VM into `lib/`.
- `agentica test` runs on the VM (`docs/bdd.md`). `src/bdd-driver.rkt` starts
  the BDD driver (`compiler/bdd.agc`, compiled by `make` into
  `dist/agentica-bdd-driver.agcb`) with `--driver-pid`, as a private copy that
  the VM deletes after the load. The driver compiles the step program and the
  runner, starts the runner with `--driver-pid` too, and the runner starts one
  VM per scenario.
- `make vm` builds `dist/agentica-vm` (`.exe` on Windows). `make exe` and
  `make test` build it first. The release builds it against glibc 2.28 (11).
- Planned: on Windows a kill-on-close job object instead of `PR_SET_PDEATHSIG`.
  On macOS there is no parent-death signal, so the closest safe thing is the
  delete-after-load flag alone, or a pipe the VM watches. On macOS the flag
  skips only the parent check. The `O_NOFOLLOW`, privacy and inode checks run on
  every non-Windows system. The VM driver is tested on Linux only.
- `PR_SET_PDEATHSIG` follows the OS thread that forked the VM, so the driver
  must call `subprocess` from the main thread.
- On Linux, `main` first opens `/dev/null` onto any of descriptors 0, 1 and 2
  that is closed or in the wrong direction. So libuv never gets a low descriptor
  and trips its assertion, and reads and writes on that stream still fail with
  `EBADF`.

**The single binary (as built in 8b).** `make agentica-next` links
`dist/agentica-next`: the VM objects, `vm/agentica.c` as its `main`, and the
front end with the `std/` sources as data (`vm/embedded.h`, written by
`vm/tools/gen-embedded.sh`). It sits beside `agentica-vm`, which is unchanged,
and is not the default (docs/future/35-self-hosting.md, 35.3 and 35.6).

- **Two runs in one process.** `agentica [--front-end FILE.agcb] WORDS...`
  loads the front end (the carried one, or `FILE`; `--front-end` must be the
  first word and is not in any help) and runs it in a first runtime with the
  arguments `--version V --self PATH -- WORDS...`, where `V` is `AGC_VERSION`
  and `PATH` is the target of `/proc/self/exe` (`argv[0]` without it). A lone
  `agentica --version` is answered by C before anything else is opened, so it
  starts no front end and creates no trace file. `AGENTICA_FLUSH_TIMEOUT_MS`
  is checked before the front end runs, as `agentica-vm` checks it at its start.
  The front end
  has no step limit, no `--allow-run`, no standard input (a read gives EOF, so
  the program keeps the real one) and no channel to a parent process. If it
  calls `FrontEnd.hand_off` and its run ends with status 0, C retires that
  runtime: the same steps as the end of any run (`agc_launch_settle`: children
  stopped, output and files flushed), then the event loop is closed and the
  heap is collected once. Any other end of the front end (a usage error, a
  problem in the user's file, a crash, a stop signal) is the end of the
  process, with the status the front end gave. The program is then loaded from
  the bytes it handed over, with the full version check, and runs in a new
  runtime with the options it was given. A bad option or bytecode is exit 2
  with `agentica: ...`. The stop signal handlers and the wake handle of the
  loop are set again for the second runtime (`unwatch_stop` in `vm/loop.c`
  releases the first one). If the event loop of the front end cannot be closed
  (an operation of its is still running), the run ends with status 1 and
  `agentica: internal error: the front end left an operation running`, because
  the program must not share a process with anything of the compiler.
- **What a front end may hand over, and trust.** The front end that C loads is
  fully trusted: it runs with the user's rights, can read files and, through
  the options it hands over, give the program `--allow-run`. That is why
  `--front-end FILE` is for the build and the tests only, is not in the help,
  and has the same standing as the binary itself. The options it may pass are
  exactly `--ai`, `--json`, `--allow-run`, `--max-steps N`, `--seed N`,
  `--flush-timeout MS` and `--source-root DIR`, each once, and nothing else; no
  positional word, no `--version`. `--driver-pid` is refused (exit 2): it says
  which process started this one, and only that process can say so. The hand-off
  takes at most 64 option words and 1,048,576 argument words
  (`AGC_FRONT_END_MAX_OPTIONS`, `AGC_FRONT_END_MAX_ARGUMENTS`), so the counts
  fit an `int`. The file of `--front-end` is opened with `O_NONBLOCK` and must
  be a regular file of at most 256 MiB, so a named pipe is refused at once.
- **Shared with `agentica-vm`.** `vm/launch.c` holds what both programs do:
  the option parser (`agc_launch_parse`; its messages start with the
  program name), seeds, the trace file, the creation of a runtime, and the one
  exit path (`agc_launch_settle`, `agc_launch_exit`). `vm/main.c` keeps its
  Windows input handling and its usage text. `agc_io_init` runs once per
  process, so its result is kept in `agc_launch` for both runtimes.
- **The guarded builtins.** `FrontEnd.hand_off(program: List[Int], options:
  List[String], arguments: List[String]) -> Result[Void]` and
  `FrontEnd.std_source(path: String) -> Result[String]` (`vm/front_end.c`, in
  the table list after `Test`). The driver sets `rt->front_end` (an
  `agc_front_end`) only for the front end it loads itself. Without it, in a user
  program or in a front end run by `agentica-vm`, both fail with
  `RUNTIME-FRONT-END-ONLY` at the call. `hand_off` copies the bytes (at most
  256 MiB, each 0 to 255) and the words (no character 0) into GC memory,
  records them in the `agc_front_end`, and ends the run with `agc_exit(vm, 0)`;
  it returns an error for a bad byte or word and never for an option, which the
  driver reads after the run. `std_source` returns the text of the embedded
  file at that path in `stdlib/` (`queue.agc`, `bdd/gherkin.agc`), or an error.
- **The loader.** `agc_load_front_end` is `agc_load_traced` without the check of
  the Agentica version in the header (the format version and every other check
  stay). Only `vm/agentica.c` calls it, for the front end; the program that the
  front end hands over goes through `agc_load_traced`, so it is checked like a
  file given to `agentica-vm`.
- **The embedded data.** `agc_embedded_data` holds the front end, then for each
  `std/` source its NUL-terminated path and its text. `agc_embedded_index` has
  `[offset, length]` of the front end, the count `N`, and `N` triples
  `[path offset, text offset, text length]`. Both are `.rodata`, built from
  `.incbin` and label differences, so there are no relocations.

**VM tracing (as built).** The rules are in `docs/future/24-logging.md` §24.4.
This note lists what the code chose.

- `AGENTICA_VM_TRACE` lists the categories to trace: `sched`, `io`, `proc`,
  `tls`, `loader` and `gc`. Trace lines go to stderr. When
  `AGENTICA_VM_TRACE_FILE` is also set, they go to that file instead, and the
  `unknown category` warning follows them there. If the file cannot be opened,
  the `cannot open` line goes to stderr and tracing is off. `make vm TRACE=0`
  compiles the trace points out, and `--version` then says `trace off`.
- The trace file is opened with `O_NONBLOCK` and `O_NOFOLLOW`, and only a
  regular file owned by the VM's user is taken, so start-up never blocks on a
  FIFO or a device.
- Every line is valid UTF-8. A text value with a byte that is not part of a
  valid UTF-8 sequence is quoted, and each such byte is written as `\u00XX`. A
  cut line ends with `...` after a whole escape or sequence.
- Events by category: `sched` (spawn, turn, wake, cancel, stall, fail, stop,
  exit); `io` (start, done, timeout, lock wait and handoff, stdin, poll, end; a
  regular file as stdout or stderr shows as `kind=output` jobs, and a pipe,
  FIFO, terminal or socket as one `output_start stream=stdout|stderr` line and
  one `output_done` line per run of data; channel waits appear as `kind=lock` in
  `start` and `detach`, and have no `done` or `timeout` line); `proc` (spawn,
  spawn_failed, exit, close, term, kill, eof, truncated, stderr, guard_cleanup,
  and `reap pid=N alive=1` when a child is still alive after its bound);
  `loader` (file, format, tables, done, reject); `gc`
  (`collect at=turn|end count= heap= free= since=`, from `trace_gc` in
  `vm/task.c`); `tls` (handshake and its errors, read error, close;
  `tls_handshake_done` carries `protocol` and `cipher`, `vm/tcp.c`); and the TCP
  events of 10.3.1 (`tcp_connect`, `tcp_listen`, `tcp_accept`, `tcp_eof`,
  `tcp_close`, and their error forms). Field names are in `vm/trace.c` and
  `vm/loop.c`.
