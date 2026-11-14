### 10.4 Processes

- `--deny-run` is the VM's own flag, checked inside every `Process` start at
  call time, for every task and handler. A denied start is an error `Result`
  that begins with `denied: --deny-run`.
- The VM resolves the executable itself, with the rule of the grammar
  (Processes): a command with `/` resolves against the program's working
  directory, and a bare name is looked up in each `PATH` entry in order. Empty
  entries are skipped, and an explicit relative entry such as `.` resolves
  against the working directory. The VM never adds the working directory itself.
  It passes the absolute path to `uv_spawn`. All three stdio streams are pipes,
  except that an `out` or `err` file of `Process.spawn` goes to the child in
  place of that pipe's write end, which the VM closes, so its read end ends at
  once. `UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS` is never used.
- Every spawn checks `chdir` of `Process.Options` (nonempty, no NUL) after the
  arguments and before the timeout. It must be a directory, else `process:
  directory is unavailable`; `"."` passes no working directory. The command
  still resolves against the program's working directory.
- A child must not get `UV_USE_IO_URING=0` from the VM's own environment
  (§10.2.2), unless the user set it before the VM started.
- Windows: allow only `.exe` and `.com` after resolution, case-insensitively
  (`.exe` is tried first when the name has neither, on purpose: a plain name
  should not be taken by the rarer `.com`). A command with `\`, `/` or a `:` is
  a path and is not searched in `PATH`. `agc_proc_name_ok` checks the command as
  given and rejects a name that ends in a dot or a space, or in `.cmd` or
  `.bat`, any `:` that is not the drive letter of `C:\` or `C:/`, and the
  `\\?\` and `\\.\` prefixes (so `C:foo.exe` and `x.exe:stream` are
  refused). The allowlist applies to the last component of the resolved path.
  `PATHEXT` is not read: `.bat` and `.cmd` need `cmd.exe`, an implicit shell, so
  they never run, and a planted `x.cmd.exe` cannot answer a request for `x.cmd`.
  A program that wants a shell starts `cmd.exe` by name. No device-name check
  (`CON`, `NUL`) is made: such a name is a file that does not run, or an error
  from `uv_spawn`.
- Windows stops: there is no `SIGTERM`. libuv ends a child with
  `TerminateProcess` for `SIGTERM`, `SIGKILL` and `SIGINT` alike, so the grace
  wait of a captured child ends at once. `exited` records 128 plus the signal
  that was asked for: 137 for the `SIGKILL` of a plain child, 143 for the
  `SIGTERM` of a captured one (`tests/test_process_windows.py`); the pair holds
  only when the stop reached a live child, since after an `ESRCH` the real exit
  code is recorded. Unless libuv cannot assign its job object (a Windows version
  without nested jobs), every child it starts is in one job that kills its
  members when the VM that made it ends. That job has
  `JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK`, so only the direct children are in it,
  not their subprocesses: a child that is itself a VM stops its own children the
  same way, and a grandchild that a VM started never reads the end of its
  channel from the death of its parent there: the parent's job ends it first. A
  parent that is no libuv process, or that spawns with `UV_PROCESS_DETACHED`,
  leaves a child that reads it (`vm/tests/process_test.c`). `Process.close` and
  the end of a run still stop only the direct child. Stopping a child that has
  already ended, before its exit callback ran, is not a failure on any system
  (`UV_ESRCH` is read as stopped); on POSIX it means someone else reaped the
  child (`SIGCHLD` set to `SIG_IGN`, or its own reaper), and then
  `Process.close` waits up to `REAP_MS`.
- Windows arguments: libuv quotes each argument with the rules of the C runtime
  (`CommandLineToArgvW`), so every word arrives unchanged. The whole command
  line, counting the quotes that libuv adds, may hold 32767 characters; a longer
  one is an error `Result`. Only the standard streams and the channel reach a
  child: libuv passes a handle list.

**Plain processes.** `vm/process.c` holds the `Process` builtins. Other
systems get none.

- **Values.** A `Process` has a registered state and two lock records, `reader`
  and `writer`. `read_line` and `read_bytes` take the reader lock. `send`,
  `send_bytes` and `close_stdin` take the writer lock. `wait` and `close` take
  neither. A reader parked on a silent child never blocks a writer, and a
  lock-wait timeout leaves the process running.
- **Spawn.** Checks, in order: `--deny-run`; a nonempty command with no NUL;
  the timeout. A path that does not exist, or is a directory, gives
  `process: executable is unavailable`. The pipes are real pipes, not
  socketpairs. The first spawn marks every inherited descriptor above 2
  close-on-exec, so a child sees only 0, 1 and 2. A failed `uv_spawn` (`EACCES`,
  `ENOEXEC`) is an error `Result` with the OS text.
- **Parking.** Operations park only their task, with the call's timeout. Stdout
  is read only while a reader waits, 4 KiB at a time (more when `read_bytes`
  needs more), so the VM reads at most about 4 KiB past what the program asked.
  A child that writes more than the program reads blocks on its pipe. A read
  error after a partial line returns the error, not the partial line. `wait`
  returns when the child has exited and its stderr is at EOF. A timed-out read
  or write closes the process. A timed-out `wait` leaves the child running.
- **Stderr** is read all the time and forwarded to the program's stderr in
  order with `IO.warn`, with the stop and resume bounds of §10.2.2 ("A child's
  stderr"): the child waits on its pipe, and so does `wait`, but nothing else in
  the VM. If the write fails (`/dev/full`, say), the rest is read and dropped,
  and the child is kept.
- **Close.** `Process.close`, a timed-out read or write, the end of the run
  (step 1 of §14.4) and a stop signal share one close: a running child gets
  `SIGKILL`, and libuv's exit callback reaps it (no `waitpid`, no sleep). A
  child started with `pgroup` (POSIX: libuv's `UV_PROCESS_DETACHED`, a
  `setsid` in the child) leads its own group, and each signal of a stop goes to
  the group, so its descendants end too. A captured group's SIGKILL comes when
  the grace ends even if the leader was reaped meanwhile (the grace timer
  outlives the exit; the guard keeps a group in its grace on a second list, and
  the end of the run waits, up to the grace, until those groups are gone),
  since POSIX does not reuse a pid while its group exists. A group whose
  leader exited before any stop is not signalled. Windows does not use it,
  since a detached child leaves libuv's job object. The pipes close at once,
  and a task blocked on the child (reader, writer or
  waiter) wakes with `process: process is closed`. Only the call that parks
  waits: `Process.close` of a running plain child parks its task on a job with a
  1-second timer, which the exit callback ends, and other tasks run meanwhile,
  so those blocked tasks wake before it returns. A second `Process.close`
  returns at once. Owned closes do not wait: a timed-out read or write (its
  timeout error stands), an oversized line, and the close of a task that crashes
  or of a server dropped by `close_server` only send the signal, so a respawn
  right after a read timeout may briefly overlap the old child. The end of the
  run and a stop signal send `SIGKILL` to every child, then run the loop until
  the exit callbacks have run, under a 1-second bound, once per run, inside the
  driver's 2-second grace (`docs/vm/08-loader-and-cli.md` §9). A child that
  cannot be killed (`EPERM`) is not waited for, and one that sleeps
  uninterruptibly is waited for only up to the bound: libuv reaps it later, or
  `init` gets it after `_exit`. A failed kill in `Process.close` ends the run
  with `RUNTIME-PROCESS-CLOSE`. Later operations on a closed process return
  `process: process is closed`.
- **Signals.** A stop signal takes the one exit path (§10.2.2). A VM killed by
  `SIGKILL`, or ended by the out-of-memory exit (70, §6.3), leaves its children
  running; one that has a channel reads the end of input (on Windows the job
  above ends it first). On a break, `agentica` waits 2 seconds, sends
  `SIGTERM`, and kills the VM 2 seconds later
  (`docs/vm/08-loader-and-cli.md`).
- **Sending signals.** `Process.signal` and `signal_group` (`kill(-pid)`) run
  on the I/O thread (a request at several schedulers) and signal only an
  unreaped child, so its pid and its group id cannot name another process.
  `Process.spawn_group` is a `pgroup` child whose stdin, stdout and stderr are
  the VM's descriptors 0 to 2 (no pump task: nothing can stall); its stream
  calls are errors, and its close is a plain child's group `SIGKILL`. The new
  session (`setsid`) leaves it no controlling terminal (`/dev/tty` gives
  `ENXIO`; no terminal job control; `Ctrl-C` reaches it only through the stop
  path). It shares stdin with the VM (a pending `IO.gets` splits the input) and
  the VM's buffered stdout may come after the child's output.
  `System.signal` opens a pidfd (`pidfd_open`, called through `syscall()`:
  glibc 2.28 has no wrapper), checks `/proc/<pid>/comm`, and signals with
  `pidfd_send_signal` on that pidfd, so it never reaches a process that took
  the pid; not `kill()` after the name check. One probe (a pidfd of the VM
  itself) per run turns ENOSYS and EPERM into `signal: pidfd is unavailable`.
  `--deny-run` covers `spawn_group` and `System.signal`.
- **Behavior notes.** libuv resets signals 1 to 31 to their default in the
  child, so a signal the VM inherited as ignored (`nohup`) is not ignored in its
  children; the VM does not patch libuv. `Process.spawn` checks its timeout but
  does not apply it to the lookup and start.

**Captured processes.** `Process.spawn_captured` and
`Process.output` (specified in
`site/content/library/io-and-system/process.md`) share the code above.

- **Spawn.** A non-empty `out` or `err` is refused with `process: out and err
  need Process.spawn`, right after `--deny-run` and before the command and
  argument checks, so `spawn_captured("", [], Process.Options(out: "x"))`
  reports that refusal.
- **Reading.** Both pipes are read from the spawn on and never stopped. Pending
  bytes are capped at 1 MiB. A byte that does not fit marks its stream as cut,
  and later chunks of that stream are read and dropped, so the child never
  blocks. The stdout limit counts unread bytes. Stderr keeps its first 1 MiB.
- **Output.** `Process.output` is a wait that is ready when stdout is at EOF or
  has a read error, and stderr is at EOF. The record is built from the pending
  bytes, with U+FFFD for invalid UTF-8, and nothing is consumed. It charges a
  turn cost by the bytes it copies.
- **Close.** `shut` sends `SIGTERM` to a running captured child and starts a
  1-second grace timer. The pipes close, and the program sees
  `process: process is closed` at once. When the timer fires, `SIGKILL` is sent,
  and libuv reaps the child, so `Process.close` never blocks. At the end of the
  run and on a stop signal, plain children get `SIGKILL`, captured ones get
  `SIGTERM` (if not sent yet), the loop runs until the captured ones have
  exited, under one 1-second bound, and the rest get `SIGKILL` and the loop runs
  until they have exited, under another 1-second bound. `Process.close` of a
  captured child does not park. A child that handles `SIGTERM` ends the cleanup
  in milliseconds. A failed `SIGTERM` in `Process.close` is
  `RUNTIME-PROCESS-CLOSE`.

**The child channel.** Descriptors separate from stdin, stdout
and stderr (two pipes, one per direction) carry the protocol of
`agentica test` and of BDD children, so a test or a step program owns its own
stdin and stdout. The builtins are in `vm/process.c`; the child side and the
shared duplex stream are in `vm/duplex.c`, a service (`docs/vm/15-layers.md`),
with the system part in `vm/duplex_os.h`. The signatures are in
`site/content/library/io-and-system/process.md`, with the user rules (lines,
errors, limits, the half close); this section is the design behind them.

- **A pipe per direction.** `agc_chan_pair` makes two pipes like the ones of
  stdin and stdout (`uv_pipe`; the child's ends blocking, the parent's ends
  non-blocking): the child reads descriptor 3 (the parent's lines) and writes
  descriptor 4 (its own), the stdio count is 5, and the variable is
  `AGENTICA_CHANNEL=3,4`. `channel_close` waits for the queued writes
  (`uv_shutdown`), then closes the parent's write end, and the child reads the
  end of its input; the parent keeps reading the other pipe. The close is the
  end of input that every system delivers; a pipe has no `shutdown(2)`
  (`ENOTSOCK`).
- **Windows.** The CRT of the child rebuilds descriptors 3 and 4 from the
  `lpReserved2` block that libuv builds for each spawn, and libuv passes only
  those handles
  (`PROC_THREAD_ATTRIBUTE_HANDLE_LIST`), so a grandchild gets none of them.
  The child's write end is not overlapped, so libuv queues writes to it on a
  worker thread: a child stuck in a large `parent_send` waits until the parent
  reads or closes the channel, as a child does with a full stdout pipe.
- **Environment.** Every spawn builds the child's environment from the VM's own:
  `AGENTICA_CHANNEL` is always removed, `UV_USE_IO_URING` is removed
  (§10.2.2), and only `spawn_channel` adds `AGENTICA_CHANNEL=3,4`. So a parent
  that spawns without the pipes never passes an inherited marker on, and a
  grandchild sees neither the marker nor descriptors 3 and 4 unless
  its own parent opened a channel for it. `System.env` hides the same entries
  from the program (`own_env` in `vm/process.c` decides for both). The `env` Map
  of a spawn adds to that copy, replacing a variable of the same name (ignoring
  case on Windows, where two names that differ only in case are an error); it
  cannot name an entry the VM owns, which is an error and not a silent drop. The
  natives of each spawn have two arities, with and without `env`: the shorter
  one is for the bytecode of `stage0.agcb`. `AGENTICA_VM_METRICS` and
  `AGENTICA_VM_METRICS_FILE` are also removed from a child's environment
  (`metrics_env`), so a child VM or a BDD runner never fights for the metrics
  port or file; `System.env` still shows them to the program.
- **Child start.** `agc_parent_take` runs from `agc_launch_vm` (`vm/launch.c`)
  before the program does. The variable names the form, and a VM never guesses
  from another one. For `3,4` on POSIX, `fstat` must say FIFO or socket for both
  descriptors and `fcntl(F_GETFL)` must say 3 is open for reading and 4 for
  writing (or either both ways, as node's socket pairs are). POSIX also takes
  `3`: one socket or FIFO open both ways on descriptor 3, duplicated once (a
  parent that is not a VM may pass it). The VM moves the descriptors with
  `F_DUPFD_CLOEXEC`, closes the originals, forgets them in the table of
  inherited files (so no `File` call can reach them), removes the variable from
  its own environment, and keeps the streams until the end of the run. On
  Windows it takes only `3,4`, with descriptor 3 a pipe that grants reading and
  4 one that grants writing. In any other case (a regular file, a character
  device or a pipe the wrong way round) nothing is touched and the child-side
  builtins return `error("process: no parent channel")`; a one-way descriptor in
  the wrong place is refused because it would park `Test.run` forever. The libuv
  handle is attached on first use, so a program that never uses the channel
  never starts a read.
- **Locks and waits.** A parent-side `Process` has two more lock records,
  `channel.reader` and `channel.writer`, so a `channel_read_line` parked on a
  silent child blocks neither `Process.read_line` nor `send` (§14.1); the child
  side has one pair for the VM (`vm->parent_locks`). Every operation is a job on
  the loop with its timeout as the job timer (§14.2): `timeout_ms` must be
  positive on both sides (else the error of the other stream builtins), and it
  includes the lock wait. A second reader (or writer) of the same end waits on
  the lock. `Process.parent_read_line(timeout_ms)` and
  `Process.parent_send(text, timeout_ms)` take a timeout like their parent-side
  twins; there is no untimed form.
- **Timeouts and errors.** A timed-out channel read or send closes the channel
  and only the channel: the process keeps running. A cut of stdout or stderr
  (more than 1 MiB unread, as in Reading) also wakes a pending
  `channel_read_line`, and every later one that finds no complete line fails;
  lines already in the buffer are still delivered first, and the channel stays
  open. So a child that prints for ever, and never sends its record, is found at
  1 MiB and not at the runner's deadline. A reset peer counts as the end of
  input for `channel_read_line`. The error texts are in `vm/process.c` and
  `vm/duplex.c`.
- **Half close.** `channel_close` is the `uv_shutdown` of the first bullet. A
  `uv_shutdown` that fails on the spot (`ENOTCONN` when the peer is gone) is
  ignored, since the write side is closed either way.
- **`read_available`** never waits for more output. Before it answers, it
  drains the stdout pipe with non-blocking reads, at most 2 MiB per call, so
  everything the child wrote to stdout before it wrote a channel line is in the
  text once that line has been read. That is the whole ordering rule between the
  two streams: a child that flushes its stdout before it sends a channel record
  (the VM does, in `Test.run` and in `BDD`) gets that output attributed to that
  record. Bytes that end in the middle of a UTF-8 character (up to three) stay
  in the buffer for the next call, unless the stream has ended or failed.
- **Close.** The channel handle closes with the process (`shut`), after the
  pipes. A pending channel read or write wakes with
  `process: channel is closed`.
- **`Test.run` and the BDD children** use the child side; the protocol is in
  `docs/bdd.md`. `Test.run` checks `main`'s own task with
  `vm->task == vm->rt->main` and the channel with `agc_parent_open`, flushes
  stdout with `agc_drain` before each record, and sends it with
  `agc_parent_send`. The core has no protocol mode: stdout is an
  ordinary stream and stdin is the program's. Nothing keeps a test from calling
  the child-side builtins, which can lose or add a line (accepted, as in the
  grammar's test rules); the only guard is that a second request in a direction
  that already has one pending gets `error("process: the channel is in use")`,
  so two requests never share a buffer.

### 10.5 Limits the C runtime keeps

- 1 MiB: `IO.read_bytes` count (0..1 MiB), Process send, read and line, File
  read, line, text and writes, TCP `send_bytes`, `recv_bytes` and line
  (`TCP.send` of a String has no limit, as in the grammar).
- Byte values 0..255; `List.repeat` count 0..1048576.
- HTTP: start and header line 8192 bytes, header block 65536 bytes, 100 headers,
  15 interim responses accepted (the 16th fails), `max_connections` at most
  65536, body `max_body_bytes` (413). The body is held whole, so the default is
  1 MiB and the cap 64 MiB (10.7).
- Process launch is off with `--deny-run`; Windows programs other than `.exe`
  and `.com` are rejected.

HTTP numbers: `Content-Length` and chunk sizes accumulate with saturation.
Parsing stops once a value exceeds the limit (413), and every comparison is
written `size > limit - total`.
