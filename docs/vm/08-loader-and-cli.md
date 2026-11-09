## 8. Loader safety

The loader validates the whole file before anything runs. A failure prints
`agentica run: invalid bytecode: <reason>` and exits 2. Types are not checked
statically: run-time tag checks are simpler, and each costs one predictable
branch.

- **Input**: a regular file of at most 256 MiB, read with bounds checks. Every
  count is checked against the bytes left before anything is allocated. Index
  and size sums use `uint64_t`. The loader has a memory budget of 4 times the
  file length plus 1 MiB, and every allocation is charged to it first. A table
  of fixed-size entries is taken once, since the count check has shown that it
  fits, and decoded without more bounds checks. The collector is held off while
  a program loads (`agc_gc_pause`; the GC-stress build ignores it), because
  everything the loader allocates is live until the load ends.
- **Header**: magic, format version and Agentica version match exactly, and the
  file ends right after the entry. The exception is the front end that the
  single binary loads itself (the carried one, or the file of `--front-end`):
  its Agentica version may differ, and every other check applies to it. The
  format version is the binary's (6) or, until `bootstrap/stage0.agcb` is
  refreshed, the previous one (5, with no prelude flag), which the first binary
  of the bootstrap still writes.
- **Strings**: valid UTF-8 with no surrogates. Character counts are computed.
- **Spans**: the source exists, `start <= end`, and each line is within the
  source's line count and each column within the line's length plus 1.
- **Prelude**: the flag of each function is 0 or 1. A `CALL` of a function with
  the flag has its argument spans in range, and a call of a prelude-only builtin
  (`__fail_arg`) is in a function with the flag (4.7).
- **Tables**: constant kinds 0 to 7 only. A String constant is valid UTF-8; a
  Bytes constant is any bytes, at most what is left of the file. Field counts
  and variant arities are at most 65535. Every builtin `(name, arity)` pair
  exists. The loader does not check builtin records: a builtin finds its record
  by exact name and fields at run time (5.2).
- **Types**: at most 65535 types with known kinds. A List or Map entry names an
  earlier type and nests at most 1024 levels (the writer gives `BYTECODE-LIMIT`
  past that). A Struct entry names a struct in range that has a decodable
  record. Records name structs in increasing order with distinct names, have one
  field type per field, and every index is in range. So cycles only go through
  named structs.
- **Updates**: each entry names a struct in range and lists 1 to that struct's
  field count of field indexes, strictly increasing and below the field count.
  `STRUCT_WITH` names an entry in range, with its window below `registers`. The
  receiver's struct type and field count are checked when the instruction runs
  (5.2), since the loader does not know the type of a register.
- **Globals**: the slot count is at most 65,535. The array of slots is allocated
  through `load_alloc`, so the load budget charges it. The slots start as zeroed
  memory, which means "never set" (4.2).
- **Functions**: `1 <= registers <= 65535` and `params + captures <= registers`.
  At least one instruction, and the last is `RETURN` or `JUMP`. Every opcode is
  known. Every register operand is below `registers`, including each window
  (`LIST`, `MAP` with `c <= 255`, `STRUCT`, `ENUM`, `CALL`, `TAIL_CALL`,
  `CALL_VALUE`, `CALL_BUILTIN`, `CLOSURE`, `RANGE`, `RANGE_BOUNDS`). Constant,
  function, builtin, type, struct, field, variant and span indexes are in range,
  including the extra spans of `STEP` and `CALL_BUILTIN`. Jump targets are
  inside the function, and a `STEP` count is at least 1.
- **Termination**: every backward jump targets a `STEP`. Every function starts
  with a `STEP`, unless it has at most 2 instructions and no call (an empty
  body). The lowering (3.3) always meets these rules. Together they mean every
  unbounded repetition charges a step, so `--max-steps` holds even for hostile
  files. The budget bounds instructions to about steps times code size. It does
  not bound bytes: `CONCAT` and `INSPECT` cost time and memory in proportion to
  their strings (§1). `LIST` and `TAIL_CALL` copy up to 65534 values in one
  instruction, and `MAP` hashes at most 255 pairs.
- **Entry**: exists, with no parameters or captures.
- **Globals in code**: the slot of every `GLOBAL` and `GLOBAL_SET` is below the
  count, so a count of 0 allows neither. When the count is above zero, only the
  entry function may hold a `GLOBAL_SET`, a function with a `GLOBAL_SET` has no
  backward jump, and no `CALL`, `TAIL_CALL` or `CLOSURE` names the entry, so
  nothing can run the entry again and write a slot after `main` started. With a
  count of 0 these rules do not apply: the entry is `main`, which a program may
  call. The writes happen once, before `main`, and the table is read-only after
  that, which keeps tasks on other schedulers free of races on it (§10.2.3 of
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

The user-facing flags and ranges are in `site/content/cli.md` and
`docs/grammar/06b-builtins.md`; this section keeps the VM side. The option
parser is `agc_launch_parse` (`vm/launch.c`).

- `check --stdin FILE`: the front end takes the bytes with
  `FrontEnd.stdin_bytes` and wraps `Workspace.read_text`, `file_exists` and
  `real_path` (`compiler/io/stdin_buffer.agc`), so the linker reads the root
  from the buffer and every other file from the disk. Input over 16 MiB exits
  2. Other `--stdin` forms are usage errors (exit 2).
- `run`: C answers the word `run` before any front end starts. The option parser
  is hand written, stops at the first non-option and honors `--`. Callers
  always pass `--` before the file, so an option after the file is a program
  argument. A repeated option, an unknown switch or a bad value exits 2.
- `--source-root DIR` puts `DIR/` before every source name of the program that
  is relative and does not start with `std/`, once, right after the load
  (`agc_program_set_source_root`), so diagnostics, stack traces, task crash
  lines and test reports all print the joined name. The front end writes a user
  file under a `std/` folder as `./std/NAME.agc`, which is joined. A leading
  `./` is dropped, an absolute name is left as it is, and the bytes added over
  all names are capped at 64 MiB (past it, exit 2). The `.agcb` stores names
  relative to the folder of the entry file (4.6). DIR is not normalized: an
  imported file above the root prints as `DIR/../shared/x.agc`.
- `--coverage FILE` counts, for each span of the program, the STEPs that ran
  it (`vm/cover.c`). Every scheduler gets a profile that writes no report
  (`agc_profile.cover`), so the run is interpreted by the profiling copy of
  the turn loop (the JIT is off), where every STEP takes `step_slow`, and its
  `profile_steps` hook adds one to the counter of each span of the STEP
  before the frame's pc. The other copies and the hot path are unchanged: a
  copy of the loop of its own changed the register allocation of
  `plain_turn`. The steps that builtins and native loops count are not
  counted. A build without trace points (`make TRACE=0`) refuses the flag. At the end
  (`agc_launch_settle`, after the files) the counts go to a new file beside
  FILE, which then replaces it, as LCOV: for each source that the loader did
  not mark `library` (`std/`, the prelude, a fetched package
  `pkg/NAME@VERSION/`, judged by the stored name before `--source-root`
  joins it), `FN`/`FNDA` from each function's span and its first STEP, and
  `DA` for each line that starts a span of a STEP, with the highest count of
  its spans. An old FILE is removed when the run starts. A file that cannot be
  written is `RUNTIME-INTERNAL` (exit 1), or a notice after the failure of a
  run that failed. The front end's own run is never counted.
- `--flush-timeout MS` (or `AGENTICA_FLUSH_TIMEOUT_MS`, read by the VM; the flag
  wins) sets the end-of-run wait for file close jobs and buffered output
  (10.2.2). `0` means no wait; above 86400000 is rejected. When the wait runs
  out, the VM prints the flush-timeout warning after the flush and after the
  diagnostic of a failed run. The exit code is kept.
- `--schedulers N` (10.2.3, 1 to 1024) and `AGENTICA_SCHEDULERS` are read before
  the front end starts, so a bad value exits 2 for every command. The flag wins
  over a valid variable; a bad flag or variable exits 2 even when the other is
  valid. The front end itself always runs on one scheduler. `agentica test`
  refuses `--schedulers` and `--jit` (exit 2), since the VMs it starts would not
  get them; they read the variables.
- `--jit MODE` and `AGENTICA_JIT` (§6.4): a bad flag or variable exits 2.
- `agentica file.agc [args...]` runs in one process: the front end compiles in
  memory and hands the bytes to C with `FrontEnd.hand_off`, and C runs them in a
  new runtime ("The single binary"). No temporary file and no child.
- There is no VM file to find and no `AGENTICA_VM`. A program that starts
  `agentica` again (the BDD driver) uses the path in `Settings.self_path`.
- A failed read of the standard input of an `agentica` run is the program's own
  error (`RUNTIME-INTERNAL`, `cannot read standard input`, exit 1). The front
  end's runtime opens standard input only when it calls `FrontEnd.stdin_bytes`.
- On Linux, `main` first ignores `SIGPIPE` (before the early `--version`
  answer too), and opens `/dev/null` onto any of descriptors 0, 1 and 2 that is
  closed or in the wrong direction, so libuv never gets a low descriptor and
  trips its assertion, and reads and writes on that stream still fail with
  `EBADF`.

**The driver handoff.** `--driver-pid PID` is a hidden flag of `agentica run`.
Only a driver that hands the VM a private one-shot file may pass it: the BDD
driver of `agentica test`, for the runner and the programs under test.

- Linux: the VM resets `SIGTERM` to its default, sets
  `prctl(PR_SET_PDEATHSIG, SIGTERM)` (so the VM kills its children before it
  ends, 10.4) and checks that `getppid()` is `PID`; if not, the driver is
  already gone and the VM exits 2 without reading the input. It opens the input
  with `O_NOFOLLOW` and loads it only if it is a regular file owned by the VM's
  user with one link and no group or other permission bits. It deletes the file
  after loading, only if the path still names the file it opened (same device
  and inode). The driver also deletes the file when the VM never ran.
  `PR_SET_PDEATHSIG` follows the OS thread that forked the VM, so the driver
  must call `subprocess` from the main thread.
- Windows checks the parent PID through libuv. A private handoff opens the file
  without following its final reparse point, then requires a regular disk file
  with one link, this process user's owner SID, and a protected DACL granting
  only that user. Only then does it mark the handle for deletion on close.
- Parent death: on Windows, unless libuv cannot assign its job object (10.4),
  the VM and every child it starts are in one job that kills its members when
  the VM ends. On macOS there is no parent-death signal: a driven VM polls
  `getppid()` every 250 ms and takes a stop (like `SIGTERM`) when the driver is
  gone; Windows also waits on the driver's process handle (`vm/loop.c`).
  `tests/test_process_lifecycle.py` kills a driver and checks that its VM and
  that VM's child end, on all three.
- On a break (`SIGINT`, `SIGTERM` or `SIGHUP` to the process that runs
  `agentica test`), `agc_launch_settle` calls `agc_processes_stop`
  (`vm/process.c`) before anything else (14.4). A child that the driver started
  with `Process.spawn_captured` gets `SIGTERM`, and `SIGKILL` if it is still
  running after a grace of 1 second (`GRACE_MS`); the stop then waits at most 1
  more second (`REAP_MS`). A plain child gets `SIGKILL` at once. Ctrl-C also
  reaches the children, which end on that first signal without the file flush;
  the driver sends no second signal of its own, so its flush is not cut short
  (10.2.2). Last, the process flushes and raises the signal again with its
  default action, so the shell sees it.
- `agentica test` (`docs/bdd.md`): the BDD driver
  (`compiler/bdd/bdd_driver.agc`) compiles the test files to a private run
  directory and starts the runner with `agentica run --driver-pid PID --embedded
  runner -- CONFIG`, and the runner starts one VM per scenario or test file the
  same way. A front end that reads the `std/` sources from a folder (`--stdlib`,
  the first binary of the bootstrap) compiles the runner and the step program
  into the run directory instead. A front end that stops with an error (a bug in
  the driver) ends the process with status 2, never the 1 of a failed test run.

**The single binary.** `make` links `dist/agentica`: the VM objects,
`vm/agentica.c` as its `main`, and the front end with the `std/` sources as data
(`vm/embedded.h`, written by `vm/tools/gen-embedded.sh`). It is the only program
of the product (the development skill's `references/ci.md` has the bootstrap
rules). `make` first links a copy with `bootstrap/stage0.agcb` in place of the
front end (`build/vm/<mode>/bootstrap/agentica`, never shipped) to compile the
stages.

- **`agentica run`.** `vm/agentica.c` parses the VM options, reads the file (a
  regular file of at most 256 MiB; with `--driver-pid`, only a private one),
  loads it with the full version check and runs it in one runtime. No front end
  is loaded. `agentica run --version` prints the long line with the library
  versions; `agentica --version` the version alone. `--embedded NAME` (hidden,
  once) runs a program that the binary carries in place of the file: `runner` or
  `steps`, the two programs of `agentica test`. A name that is not one of them,
  or a binary that carries none, is exit 2, and the front end may not pass the
  option on in a hand-off.
- **Two runs in one process.** `agentica [--front-end FILE.agcb] WORDS...` loads
  the front end (the carried one, or `FILE`; `--front-end` must be the first
  word and is in no help) and runs it in a first runtime with the arguments
  `--version V --self PATH [--embedded-bdd] -- WORDS...`. A lone
  `agentica --version` is answered by C before anything else is opened. The
  front end has no step limit, no channel to a parent process, and no standard
  input stream until `FrontEnd.stdin_bytes` opens it (before that `IO.gets`
  gives EOF, so the program keeps the real one). The user's `--deny-*` flags do
  not reach it (the user's program never runs in that runtime); they reach the
  test and step VMs. If it calls `FrontEnd.hand_off` and its run ends with
  status 0, C retires that runtime (`agc_launch_settle`: children stopped,
  output and files flushed), closes the event loop and collects the heap once.
  Any other end of the front end is the end of the process, with the status the
  front end gave, except for a crash (a runtime error in the front end), which
  is status 2. The program is then loaded from the bytes it handed over, with
  the full version check, and runs in a new runtime with the options it was
  given. The stop signal handlers and the wake handle of the loop are set again
  for the second runtime (`unwatch_stop` in `vm/loop.c`). If the event loop of
  the front end cannot be closed (an operation is still running), the run ends
  with status 1 and `agentica: internal error: the front end left an operation
  running`, because the program must not share a process with anything of the
  compiler.
- **What a front end may hand over, and trust.** The front end that C loads is
  fully trusted: it runs with the user's rights and, through the options it
  hands over, can drop the user's `--deny-*` flags. That is why `--front-end
  FILE` is for the build and the tests only and has the same standing as the
  binary itself. The options it may pass are exactly `--ai`, `--json`, the
  `--deny-*` flags, `--sandbox`, `--max-steps N`, `--seed N`,
  `--flush-timeout MS`, `--schedulers N`, `--jit MODE`, `--source-root DIR`
  and `--coverage FILE`, each once; no positional word, no `--version`.
  `--driver-pid` and `--embedded` are refused (exit 2): only the process that
  started this one can say so, and only `agentica run` starts an embedded
  program. The hand-off takes
  at most 64 option words and 1,048,576 argument words
  (`AGC_FRONT_END_MAX_OPTIONS`, `AGC_FRONT_END_MAX_ARGUMENTS`). The file of
  `--front-end` is opened with `O_NONBLOCK` and must be a regular file of at
  most 256 MiB, so a named pipe is refused at once.
- **Shared by the two runs.** `vm/launch.c` holds the option parser, seeds, the
  trace file, the creation of a runtime, the `SIGPIPE` setting and the one exit
  path (`agc_launch_settle`, `agc_launch_exit`). `agc_io_init` runs once per
  process, so its result is kept in `agc_launch` for both runtimes.
- **The guarded builtins.** `FrontEnd.hand_off`, `FrontEnd.std_source` and
  `FrontEnd.stdin_bytes` (`vm/front_end.c`). The driver sets `rt->front_end`
  only for the front end it loads itself; without it, in a user program or in a
  front end run by `agentica run`, all three fail with `RUNTIME-FRONT-END-ONLY`
  at the call. `hand_off` records a pointer into the program's `Bytes` block (at
  most 256 MiB; not a copy), copies the words into GC memory, and ends the run
  with `agc_exit(vm, 0)`. After the run only the `agc_front_end` keeps those
  blocks alive, so it must stay where the collector scans it: the driver keeps
  it on `main()`'s stack, and `agc_init` turns interior pointers on, so a
  pointer into the `Bytes` block holds the whole block. `std_source` (and
  `Std.source` for any program) returns the text of the embedded `stdlib/` file;
  the table is built once and never written after the start, so the call takes
  no lock at any number of schedulers. `stdin_bytes` reads standard input to its
  end through the one stdin reader (`agc_input_whole`, `vm/input.c`) and parks
  the task while a read is in flight. It keeps at most 16 MiB and one byte (one
  byte more is an error); a later call reads on from where the last stopped.
  Nothing reads standard input before the call, so a command that does not call
  it (`agentica FILE.agc`) leaves it to the program.
- **The loader.** `agc_load_front_end` is `agc_load_traced` without the check of
  the Agentica version in the header. Only `vm/agentica.c` calls it; the program
  that the front end hands over goes through `agc_load_traced`.
- **The embedded data.** `agc_embedded_data` holds the front end, the BDD runner
  and the default step program of `agentica test`, then each `std/` source's
  NUL-terminated path and text (layout in `vm/embedded.h`). It is `.rodata`
  built from `.incbin` and label differences, so there are no relocations. The
  runner and the step program (`compiler/embedded/runner.agc`, `steps.agc`) are
  compiled by the first binary with `stage2` as its front end, against the
  `std/` sources of the same build; `make fixed-point` checks that
  `dist/agentica` compiles the same bytes. The first binary of the bootstrap is
  linked without them (length 0), because it has no `stage2` yet; its front end
  is stage0, whose driver compiles them from the `std/` sources on every
  `agentica test`.

**VM tracing.**

- `AGENTICA_VM_TRACE` lists the categories to trace: `sched`, `io`, `proc`,
  `tls`, `loader`, `gc` and `jit`. Trace lines go to stderr, or to
  `AGENTICA_VM_TRACE_FILE` when set (an `unknown category` warning follows them
  there; if the file cannot be opened, tracing is off). Each `{pid}` of the
  file name is replaced by the process id (`trace_file_name` in
  `vm/launch.c`), so the processes of a test run, which share one
  environment, write one file each; a name of 4096 bytes or more after that
  cannot be opened (4095 is the most that fits). The file is opened in append
  mode, so a reused pid appends to the old file. `make TRACE=0` compiles
  the trace points out, and `--version` then says `trace off`.
- The trace file is opened with `O_NONBLOCK` and `O_NOFOLLOW`, and only a
  regular file owned by the VM's user is taken, so start-up never blocks on a
  FIFO or a device.
- Every line is valid UTF-8. A text value with a byte that is not part of a
  valid sequence is quoted, and each such byte is written as `\u00XX`. A cut
  line ends with `...` after a whole escape or sequence.
- Events by category: the `AGC_TRACE` points in `vm/` name them (`rg
  'AGC_TRACE\(' vm`). What the code does not show: `cancel` has `at=call` on the
  task that `Task.cancel` names and `at=spawn` on a child that a cancelled task
  spawned; `cancel_deferred` is a cancelled READY task that is not in the queue,
  which its popper ends. A regular file as stdout or stderr shows as
  `kind=output` jobs; a pipe, FIFO, terminal or socket as one `output_start`
  line and one `output_done` line per run of data. Sleeps, channel waits, timed
  awaits and `Task.map` timers are not jobs and print no `io` line; `sched`
  prints `timer_arm` and `timer_fire` for them (a channel wait arms only once
  its clock starts, §16.9 "Timers").
- `profile` is the odd category: it is not part of `all`, and it counts instead
  of tracing events, to find where a program spends its steps. The loop of
  `interp.c` is built twice, with and without the hooks, so a run without the
  category costs nothing; with it, every `STEP` takes the slow path of the
  budget counter, every instruction is counted and every builtin call is
  timed, so the run is about 1.1 to 1.7 times slower on loops and calls and up
  to about 15 times on a loop of cheap builtin calls. `vm/profile.c` writes the
  report when each runtime ends (the front end hands its program over in a
  second one, so `gc_ms` and `collections`, which count the whole process, in
  the second report include the front end's). The step of each pass of a range
  `each`, `times`, `upto`, `downto` or `File.each_line` loop is `<native>`,
  while `List.map` and `List.each` add no step beyond their callbacks. A
  builtin is timed for the call itself, so one that parks is timed until it
  does. A fused `STEP` or `CONST` counts as itself and the instruction after it
  (§4.2). `Profile.measure` sections are inclusive, and a label inside itself
  in one task counts each call but its numbers once; a run keeps 4096 labels
  and later ones share `[overflow]`. With the profile off, `Profile.measure`
  only has its block called in its place (one step, no native frame).
  `Profile.steps` is the task's steps, the same with the profile on or off. The
  profile runs on one scheduler, so its counters need no lock. The report's
  fields are in `vm/profile.c`.
- `AGENTICA_PROFILE_FORMAT=folded` (with `profile`) writes folded stacks to the
  trace output instead of the report: a line per distinct stack, frames
  outermost first joined by `;`, a space and the weight in steps. Each `STEP`
  takes a sample of the running task's frames every `AGENTICA_PROFILE_SAMPLE`
  steps (1 to 1000000000, default 1000). No timer or signal is involved, so the
  output is the same on every run and every system. A stack deeper than 512
  frames keeps the outer and inner halves around `...`, and `;`, `%` and control
  bytes in a name are written as `%XX`. At most 1,048,576 stacks and 256 MiB of
  frames are kept; the weight of a later new stack goes to one last
  `[truncated]` line (`AGENTICA_VM_TEST_PROFILE_STACKS=N` lowers the limit for
  tests). The front end of `agentica FILE.agc` writes no stacks once it has
  handed its program over, so the output is the program's.
