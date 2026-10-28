## 8. Loader safety

The loader validates the whole file before anything runs. A failure prints
`agentica run: invalid bytecode: <reason>` and exits 2. Types are not checked
statically: run-time tag checks are simpler, and each costs one predictable
branch.

- **Input**: a regular file of at most 256 MiB, read with bounds checks. Every
  count is checked against the bytes left before anything is allocated. Index
  and size sums use `uint64_t`. The loader has a memory budget of 4 times the
  file length plus 1 MiB, and every allocation is charged to it first. A table
  of fixed-size entries (the spans, the instruction words and the span indexes
  of a function) is taken once, since the count check has shown that it fits,
  and decoded without more bounds checks; a rejection and its reason are the
  same as with a check for each field. The collector is held off while a program
  loads (`agc_gc_pause`, and `agc_gc_resume` after a load that succeeded or
  failed), because everything the loader allocates is live until the load ends
  and a collection would only mark it again (the GC-stress build ignores the
  pause).
- **Header**: magic, format version and Agentica version match exactly. The file
  ends right after the entry. The one exception to the exact Agentica version is
  the front end that the single binary loads itself (the carried one, or the
  file of `--front-end`): its Agentica version may differ, and every other check
  applies to it. The format version is the binary's (6) or, until
  `bootstrap/stage0.agcb` is refreshed, the previous one (5, with no prelude
  flag in the functions), which the first binary of the bootstrap still writes.
  See "The single binary" in section 9.
- **Strings**: valid UTF-8 with no surrogates. Character counts are computed.
- **Spans**: the source exists, `start <= end`, and each line is within the
  source's line count and each column within the line's length plus 1.
- **Prelude**: the flag of each function is 0 or 1. A `CALL` of a function with
  the flag has its argument spans in range, and a call of a prelude-only builtin
  (`__fail_arg`) is in a function with the flag (03, 4.7).
- **Tables**: constant kinds 0 to 6 only. Field counts and variant arities are
  at most 65535. The loader does not check builtin records: a builtin finds its
  record by exact name and fields at run time (5.2). Every builtin `(name,
  arity)` pair exists.
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

- `agentica compile` runs the front end and writes bytecode. The user-facing
  flags and their ranges are in `docs/grammar/06b-builtins.md` (the parts on
  running and on the execution budget); this section keeps the VM side.
- `check --stdin FILE`: the front end takes the bytes with
  `FrontEnd.stdin_bytes` (see "The guarded builtins") and wraps
  `Workspace.read_text`, `file_exists` and `real_path`
  (`compiler/io/stdin_buffer.agc`, over `compiler/modules/overlay.agc`), so the
  linker reads the root from the buffer and every other file from the disk.
  Input over 16 MiB exits 2. `check --stdin` with no file or with two,
  `check FILE --stdin` and `compile --stdin` are usage errors (exit 2).
- `run`: C answers the word `run` before any front end starts. The option parser
  is hand written. It stops at the first non-option and honors `--`. Callers
  always pass `--` before the file, so an option after the file is a program
  argument. A repeated option, an unknown switch or a bad value exits
  2. `--ai` and `--json` may both appear, and the last one wins.
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
  buffered output of stdout and stderr (10.2.2, End of run). The environment
  variable `AGENTICA_FLUSH_TIMEOUT_MS` is read by the VM, so `agentica` and
  `agentica run` both honour it; the flag wins. `0` means no wait; values above
  86400000 (24 hours) are rejected. When the wait runs out, the VM prints the
  flush-timeout warning after the flush and after the diagnostic of a failed
  run. The exit code is kept.
- `--version` prints the VM version and the versions of the libraries it links:
  libgc, yyjson, libuv and OpenSSL (the one that runs). OpenSSL is linked
  statically in the release.
- `--schedulers N` (10.2.3) sets the scheduler threads: an integer from 1 to
  1024, without a sign, a space or a trailing letter. The variable
  `AGENTICA_SCHEDULERS` is read before the front end starts, so a bad value
  exits 2 for every command, also `check`. The flag wins over a valid variable;
  a bad flag or a bad variable exits 2 even when the other is valid. The front
  end itself always runs on one scheduler; `check` and `compile` ignore the
  flag. `agentica test` refuses the flag (exit 2), since the VMs it starts would
  not get it; they read the variable.
- `--jit MODE` (`off`, `on`, the default, or `always`; the variable
  `AGENTICA_JIT` too, the flag wins) compiles functions of the user's program to
  machine code (§6.4). A bad flag or variable exits 2.
  `agentica test` refuses the flag, as it refuses `--schedulers`.
- `agentica file.agc [args...]` runs in the same process: the front end compiles
  in memory and hands the bytes to C with `FrontEnd.hand_off`, and C runs them
  in a new runtime (see "The single binary" below). No temporary file and no
  child are involved. `--driver-pid PID` is a hidden flag of `agentica run`.
  Only a driver that hands the VM a private one-shot file may pass it: the BDD
  driver of `agentica test` for the runner and the programs under test, which
  take `--driver-pid` from their own command line.
- On Linux, the VM first resets `SIGTERM` to its default, sets
  `prctl(PR_SET_PDEATHSIG, SIGTERM)` (`SIGTERM`, so the VM kills its children
  before it ends, 10.4) and checks that `getppid()` is `PID`. If not, the driver
  is already gone, and the VM exits 2 without reading the input. Then it opens
  the input with `O_NOFOLLOW` and loads it only if it is a regular file owned by
  the VM's user with one link and no group or other permission bits. The file is
  deleted after loading, but only if the path still names the file it opened
  (same device and inode). The driver also deletes the file when the VM never
  ran, or failed before loading.
- Windows checks the parent PID through libuv. Bytecode reads use binary
  descriptors and UTF-8 paths. A private handoff opens the file without
  following its final reparse point, then requires a regular disk file with one
  link, this process user's owner SID, and a protected DACL granting only that
  user. Only after those checks and the size limit pass does it mark the opened
  handle for deletion on close. A failed check leaves the file intact.
- On a break (`SIGINT`, `SIGTERM` or `SIGHUP` to the process that runs `agentica
  test`), the run ends on the first signal and `agc_launch_settle`
  (`vm/launch.c`) calls `agc_processes_stop` (`vm/process.c`) before anything
  else (14.4). A child that the driver started with `Process.spawn_captured`
  (the runner and the programs under test) gets `SIGTERM`, and `SIGKILL` if it
  is still running after a grace of 1 second (`GRACE_MS`), and then the stop
  waits at most 1 more second (`REAP_MS`) for the exits. A plain child gets
  `SIGKILL` at once. Ctrl-C also reaches the children, which end on that first
  signal without the file flush after they kill their own children; the driver
  sends no second signal of its own, so the flush of the driver is not cut short
  (10.2.2). Last, the process flushes and raises the signal again with its
  default action, so the shell sees it.
- A failed read of the standard input of an `agentica` run is the program's own
  error: it reads the real descriptor (`RUNTIME-INTERNAL`, `cannot read standard
  input`, exit 1). The front end's runtime opens standard input only when it
  calls `FrontEnd.stdin_bytes`.
- Front-end and `LOWER-` diagnostics print as usual (exit 1). `--vm` and
  `--legacy-eval` are unknown switches.
- There is no VM file to find and no `AGENTICA_VM`: nothing reads the variable,
  so a value of it changes no run. The binary is the VM; a program that starts
  `agentica` again (the BDD driver) uses the path in `Settings.self_path`.
- `agentica test` runs in the binary (`docs/bdd.md`). The BDD driver is part of
  the front end (`compiler/bdd/bdd_driver.agc`). It compiles the test files to a
  private run directory and starts the runner with `agentica run
  --driver-pid PID --embedded runner -- CONFIG` (`PID` is its own). The runner
  starts one VM per scenario or test file with the same command. The runner and
  the default step program are carried by the binary, compiled at build time
  (see "The embedded data"). A front end that reads the `std/` sources from a
  folder (`--stdlib`, the tests that fake the binary) compiles both into the run
  directory instead and starts the runner with `-- runner.agcb CONFIG`. The
  configuration names the step program in `steps_bytecode`; an empty name means
  the default one, which the runner starts with `--embedded steps`. The first
  binary of the bootstrap runs the driver of stage0, which compiles both from
  the `std/` sources. A front end that stops with an error (a bug in the driver)
  ends the process with status 2, never the 1 of a failed test run.
- Parent death: on Windows, unless libuv cannot assign its job object (10.4),
  the VM and every child it starts are in one job that kills its members when
  the VM ends, so a child that is a VM stops its own (`PR_SET_PDEATHSIG` has no
  counterpart there). On macOS there is no parent-death signal: a driven VM
  polls `getppid()` every 250 ms and takes a stop (like `SIGTERM`) when the
  driver is gone. Windows also waits on the driver's process handle
  (`vm/loop.c`). All three systems check the parent PID at start.
  `tests/test_process_lifecycle.py` kills a driver and checks that its VM and
  that VM's child end, on all three. The `O_NOFOLLOW`, privacy and inode checks
  run on every non-Windows system.
- `PR_SET_PDEATHSIG` follows the OS thread that forked the VM, so the driver
  must call `subprocess` from the main thread.
- On Linux, `main` first ignores `SIGPIPE`, so a closed pipe on the standard
  output ends a write with an error and not the process (before the early
  `--version` answer too), and opens `/dev/null` onto any of descriptors 0, 1
  and 2 that is closed or in the wrong direction. So libuv never gets a low
  descriptor and trips its assertion, and reads and writes on that stream still
  fail with `EBADF`.

**The single binary.** `make` links
`dist/agentica`: the VM objects, `vm/agentica.c` as its `main`, and the front
end with the `std/` sources as data (`vm/embedded.h`, written by
`vm/tools/gen-embedded.sh`). It is the only program of the product
(docs/future/18-front-end-language.md, §18.2 and §18.8). `make` links a first
copy with `bootstrap/stage0.agcb` in place of the front end
(build/vm/<mode>/bootstrap/agentica, never shipped) to compile the stages.

- **`agentica run`.** When the first word is `run`, `vm/agentica.c` parses the
  VM options (`agc_launch_parse`, messages named `agentica run`), reads the file
  (a regular file of at most 256 MiB; with `--driver-pid`, only a private one,
  which it deletes after the load), loads it with the full version check and
  runs it in one runtime. No front end is loaded. `agentica run --version`
  prints the long line (`agentica VERSION (libgc ..., yyjson ..., libuv ...,
  OpenSSL ...)`); `agentica --version` prints the version alone. `--embedded
  NAME` (hidden, like `--driver-pid`; once) runs a program that the binary
  carries in place of the file: `runner` or `steps`, the two programs of
  `agentica test`. The words after `--` are all the program's arguments. A name
  that is not one of them, or a binary that carries none (the first binary of
  the bootstrap: `agentica run: this binary carries no embedded program
  runner`), is exit 2, and the front end may not pass the option on in a
  hand-off.

- **Two runs in one process.** `agentica [--front-end FILE.agcb] WORDS...` loads
  the front end (the carried one, or `FILE`; `--front-end` must be the first
  word and is not in any help) and runs it in a first runtime with the arguments
  `--version V --self PATH [--embedded-bdd] -- WORDS...`, where `V` is
  `AGC_VERSION`, `PATH` is the target of `/proc/self/exe` (`argv[0]` without
  it), and `--embedded-bdd` is passed to the carried front end only when the
  binary carries both compiled programs used by `agentica test`. A replacement
  front end supplied with `--front-end` gets the original arguments, for
  compatibility with older front ends. The standard-library sources can be
  embedded without those programs, as in the first bootstrap binary. A lone
  `agentica --version` is answered by C before anything else is opened, so it
  starts no front end and creates no trace file. `AGENTICA_FLUSH_TIMEOUT_MS` and
  `AGENTICA_SCHEDULERS` are checked before the front end runs, as `agentica run`
  checks them at its start. The front end has no step limit, no standard input
  stream until `FrontEnd.stdin_bytes` opens it (before that `IO.gets` gives EOF,
  so the program keeps the real one) and no channel to a parent process; the
  user's `--deny-*` flags do not reach it, because `agentica test` starts the
  runner (the user's program never runs in that runtime); they reach the test
  and step VMs. If it calls
  `FrontEnd.hand_off` and its run ends with status 0, C retires that runtime:
  the same steps as the end of any run (`agc_launch_settle`: children stopped,
  output and files flushed), then the event loop is closed and the heap is
  collected once. Any other end of the front end (a usage error, a problem in
  the user's file, a crash, a stop signal) is the end of the process, with the
  status the front end gave, except for a crash (a runtime error in the front
  end), which is status 2. The program is then loaded from the bytes it handed
  over, with the full version check, and runs in a new runtime with the options
  it was given. A bad option or bytecode is exit 2 with `agentica: ...`. The
  stop signal handlers and the wake handle of the loop are set again for the
  second runtime (`unwatch_stop` in `vm/loop.c` releases the first one). If the
  event loop of the front end cannot be closed (an operation of its is still
  running), the run ends with status 1 and `agentica: internal error: the front
  end left an operation running`, because the program must not share a process
  with anything of the compiler.
- **What a front end may hand over, and trust.** The front end that C loads is
  fully trusted: it runs with the user's rights, can read files and, through the
  options it hands over, drop the user's `--deny-*` flags. That is why
  `--front-end FILE` is for the build and the tests only, is not in the help,
  and has the same standing as the binary itself. The options it may pass are
  exactly `--ai`, `--json`, `--deny-run`, `--deny-net`, `--deny-fs`,
  `--deny-env`, `--deny-native`, `--sandbox`, `--max-steps N`, `--seed N`,
  `--flush-timeout MS`, `--schedulers N`, `--jit MODE` and `--source-root DIR`,
  each once, and nothing else; no positional word, no `--version`.
  `--driver-pid` is refused (exit 2): it says which process started this one,
  and only that process can say so. So is `--embedded` (exit 2): only
  `agentica run` starts an embedded program. The hand-off takes at most 64
  option words and 1,048,576 argument words (`AGC_FRONT_END_MAX_OPTIONS`,
  `AGC_FRONT_END_MAX_ARGUMENTS`), so the counts fit an `int`. The file of
  `--front-end` is opened with `O_NONBLOCK` and must be a regular file of at
  most 256 MiB, so a named pipe is refused at once.
- **Shared by the two runs.** `vm/launch.c` holds what both do: the option
  parser (`agc_launch_parse`; its messages start with the program name,
  `agentica` or `agentica run`), seeds, the trace file, the creation of a
  runtime, the `SIGPIPE` setting (`agc_launch_ignore_sigpipe`) and the one exit
  path (`agc_launch_settle`, `agc_launch_exit`). `agc_io_init` runs once per
  process, so its result is kept in `agc_launch` for both runtimes.
- **The guarded builtins.** `FrontEnd.hand_off`, `FrontEnd.std_source` and
  `FrontEnd.stdin_bytes` (`vm/front_end.c`; signatures in
  `compiler/catalog/builtins_data.agc`). The driver sets `rt->front_end` (an
  `agc_front_end`) only for the front end it loads itself. Without it, in a user
  program or in a front end run by `agentica run`, all three fail with
  `RUNTIME-FRONT-END-ONLY` at the call. `hand_off` copies the bytes (at most 256
  MiB, each 0 to 255) and the words (no character 0) into GC memory, records
  them in the `agc_front_end`, and ends the run with `agc_exit(vm, 0)`; it
  returns an error for a bad byte or word and never for an option, which the
  driver reads after the run. `std_source` returns the text of the embedded file
  at that path in `stdlib/` (`queue.agc`, `bdd/gherkin.agc`), or an error.
  `Std.source` (`agc_std_builtins`, same file) does the same for any program.
  The driver builds the table of std sources once and every runtime gets it
  (`rt->std`, through `agc_launch`); it is never written after the start, so the
  call takes no lock at any number of schedulers. `stdin_bytes` is the only way
  the front end gets standard input. It opens the runtime's input stream at the
  first call and reads it to its end through the one stdin reader
  (`agc_input_whole`, `vm/input.c`): the task parks while a read is in flight,
  so the loop does not block and a stop signal ends the run as usual. It keeps
  at most 16 MiB and one byte; one byte more is an error, with no list built. A
  later call reads on from where the last one stopped. Nothing reads standard
  input before the call, so a command that does not call it (`agentica
  FILE.agc`) leaves it to the program.
- **The loader.** `agc_load_front_end` is `agc_load_traced` without the check of
  the Agentica version in the header (the format version and every other check
  stay). Only `vm/agentica.c` calls it, for the front end; the program that the
  front end hands over goes through `agc_load_traced`, so it is checked like a
  file given to `agentica run`.
- **The embedded data.** `agc_embedded_data` holds the front end, the BDD runner
  and the default step program of `agentica test`, then for each `std/` source
  its NUL-terminated path and its text (`agc_embedded_index` holds the offsets;
  layout in `vm/embedded.h`). Both are `.rodata`, built from `.incbin` and label
  differences, so there are no relocations. The runner and the step program are
  `compiler/embedded/runner.agc` and `steps.agc` compiled by the first binary
  with `stage2` as its front end (`build/stage/runner.agcb`, `steps.agcb`),
  against the `std/` sources of the same build; `make fixed-point` checks that
  `dist/agentica` compiles the same bytes. The first binary of the bootstrap is
  linked without them (length 0), because it has no `stage2` yet to compile them
  with; its front end is stage0, whose driver compiles them from the `std/`
  sources on every `agentica test`.

**VM tracing.**

- `AGENTICA_VM_TRACE` lists the categories to trace: `sched`, `io`, `proc`,
  `tls`, `loader`, `gc` and `jit`. Trace lines go to stderr. When
  `AGENTICA_VM_TRACE_FILE` is also set, they go to that file instead, and the
  `unknown category` warning follows them there. If the file cannot be opened,
  the `cannot open` line goes to stderr and tracing is off. `make TRACE=0`
  compiles the trace points out, and `--version` then says `trace off`.
- The trace file is opened with `O_NONBLOCK` and `O_NOFOLLOW`, and only a
  regular file owned by the VM's user is taken, so start-up never blocks on a
  FIFO or a device.
- Every line is valid UTF-8. A text value with a byte that is not part of a
  valid UTF-8 sequence is quoted, and each such byte is written as `\u00XX`. A
  cut line ends with `...` after a whole escape or sequence.
- Events by category: the `AGC_TRACE` points in `vm/` name them (`rg
  'AGC_TRACE\(' vm`), and the field names are in `vm/trace.c` and `vm/loop.c`.
  What the code does not show: `cancel` has `at=call` on the task that
  `Task.cancel` names and `at=spawn` on a child that a cancelled task spawned;
  `cancel_deferred` is a cancelled READY task that is not in the queue, which
  its popper ends. A regular file as stdout or stderr shows as `kind=output`
  jobs; a pipe, FIFO, terminal or socket as one `output_start
  stream=stdout|stderr` line and one `output_done` line per run of data. A lock
  wait of a handle has its own `lock_wait` line. Sleeps, channel waits, timed
  awaits and `Task.map` timers are not jobs and print no `io` line; `sched`
  prints `timer_arm task=N in_ms=M` and `timer_fire task=N late_ms=M` for them
  (a channel wait arms only once its clock starts, §16.9 "Timers").
  `proc` prints `reap pid=N alive=1` when a child is still alive after its
  bound. `gc` lines (`collect at=turn|end count= heap= free= since=`) come from
  `trace_gc` in `vm/task.c`; `tls_handshake_done` carries `protocol` and
  `cipher`.
- `profile` is the odd category: it is not part of `all`, and it counts instead
  of tracing events. It is for finding where a program spends its steps. With it
  on, each function counts its calls and the steps it ran (a step is the VM's
  unit of budget: a `STEP` instruction adds the steps of its block), and each
  builtin counts its calls and its time. The loop of `interp.c` is built twice,
  with and without the hooks, so a run without the category costs nothing; with
  it, every `STEP` takes the slow path of the budget counter, every instruction
  is counted and every builtin call is timed, so the run is about 1.1 to 1.7
  times slower on loops and calls and up to about 15 times on a loop of cheap
  builtin calls. When the run ends (once for each runtime: the front end hands
  its program over in a second one) `vm/profile.c` writes a `total` line (fields
  in that file), then the 30 functions with the most steps (the step of each
  pass of a range `each`, `times`, `upto`, `downto` or `File.each_line` loop is
  `<native>`, while `List.map` and `List.each` add no step beyond their
  callbacks), the 12 source files with the most steps and the 30 builtins that
  took the most time. A builtin is timed for the call itself, so one that parks
  is timed until it does. `gc_ms` is Boehm's own clock of its collections, and
  `gc_ms` and `collections` count the whole process so far: the second report of
  `agentica FILE.agc` includes the collections of the front end. Then come up to
  30 `section` rows, one for each label of `Profile.measure`, the most steps
  first, then the most calls. A run keeps 4096 labels; later ones share one
  `[overflow]` section (frame `measure[overflow]`), which the label index does
  not hold. A section counts the steps of its task, the wall time and Boehm's
  clock from the start of the block to its end; sections are inclusive, and a
  label inside itself in one task counts each call but its numbers once (the
  outermost call). With the profile off, `Profile.measure` only has its block
  called in its place (`agc_task_call_block`): one step, no native frame; with
  it on, it is a stepper whose native frame names the label. `Profile.steps` is
  the task's steps (`agc_task_steps`: its finished turns plus the running one),
  the same with the profile on or off. The report ends with what the loop of
  `interp.c` ran: one `events` line (`instructions`, `reloads` of the top
  frame's state, the start of each turn included, and the `CALL_BUILTIN` calls
  that took the leaf path, `builtin_leaf`, the generic tail, `builtin_tail`, or
  started a native frame, `builtin_native`), then one `op` row for each opcode
  that ran (`count`, `share` of the instructions in percent, `name` as
  `--dump-ir` spells it; a fused `STEP` or `CONST` counts as itself and the
  instruction after it, `docs/vm/03-ir-and-bytecode.md` §4.2), the most first,
  and the 20 `pair` rows with the most runs of opcode `first` followed by
  `then` in one frame (the first instruction after a reload starts no pair).
  These counters live in `agc_profile`, like the others, and the profile runs
  on one scheduler, so they need no lock.
- `AGENTICA_PROFILE_FORMAT=folded` (with `profile`; `report` or unset keeps the
  report, another value is one `agc-trace unknown profile format` line) writes
  folded stacks instead of the report, to the trace output: a line per distinct
  stack, frames outermost first joined by `;`, a space and the weight in steps,
  in the order the stacks were first seen. Each `STEP` already goes through the
  profile hook, which takes a sample of the running task's frames every
  `AGENTICA_PROFILE_SAMPLE` steps of the run (1 to 1000000000, default 1000; a
  bad value is one warning line and the default), weighted by the steps it
  stands for. No timer or signal is involved, so the output is the same on every
  run and every system. Frames are `name@FILE:LINE`, `block@FILE:LINE:COL`, the
  builtin of a native frame (`Int.times`, `List.map`) and `measure:LABEL`; a
  stack deeper than 512 frames keeps the outer and inner halves around `...`,
  and `;`, `%` and control bytes in a name are written as `%XX`, so no two
  stacks print the same line. At most 1,048,576 stacks and 256 MiB of frames are
  kept; the weight of a later new stack goes to one last `[truncated]` line,
  followed by one `agc-trace folded profile full` warning
  (`AGENTICA_VM_TEST_PROFILE_STACKS=N` lowers the stack limit for tests). The
  front end of `agentica FILE.agc` writes no stacks once it has handed its
  program over, so the output is the program's.
