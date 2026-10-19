### 10.4 Processes

- `--allow-run` is the VM's own flag, checked inside `Process.spawn` at call
  time, for every task and handler.
- The VM resolves the executable itself, with the rule of the grammar
  (Processes): a command with `/` resolves against the program's working
  directory, and a bare name is looked up in each `PATH` entry in order. Empty
  entries are skipped, and an explicit relative entry such as `.` resolves
  against the working directory. The VM never adds the working directory itself.
  It passes the absolute path to `uv_spawn`. All three stdio streams are pipes.
  `UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS` is never used.
- A child must not get `UV_USE_IO_URING=0` from the VM's own environment
  (§10.2.2), unless the user set it before the VM started.
- Windows: allow only `.exe` and `.com` after resolution, case-insensitively
  (`.exe` is tried first when the name has neither). A command with `\`, `/` or
  a `:` is a path and is not searched in `PATH`. Reject a name that ends in a
  dot or a space, or in `.cmd` or `.bat`, and any `:` that is not the drive
  letter of `C:\` or `C:/` (so `C:foo.exe`, `x.exe:stream` and `\\?\C:\x.exe`
  are refused). The checks are on the command as given (`agc_proc_name_ok`).
  The allowlist applies to the last component of the resolved path. The port
  does not search the current directory before `PATH`, but a relative `PATH`
  entry such as `.` resolves against it, as on POSIX. `PATHEXT` is not read:
  `.bat` and `.cmd` need `cmd.exe`, an implicit shell, so they never run, and a
  planted `x.cmd.exe` cannot answer a request for `x.cmd`. A program that
  wants a shell starts `cmd.exe` by name. A quoted `PATH` entry that holds `;`
  is split inside the quotes, and no device-name check (`CON`, `NUL`) is made:
  such a name is a file that does not run, or an error from `uv_spawn`.
- Windows stops: there is no `SIGTERM`. libuv ends a child with
  `TerminateProcess` for `SIGTERM`, `SIGKILL` and `SIGINT` alike, so the grace
  wait of a captured child ends at once. libuv reports the raw exit code 1 and
  the signal that was asked for, and `exited` records 128 plus that signal: 137
  for the `SIGKILL` of a plain child, 143 for the `SIGTERM` of a captured one
  (`tests/test_process_windows.py` reads the pair from the `proc` trace). The
  program cannot read that status, because the handle is closed by then.
  When libuv can assign its job object (an outer job that forbids breakaway
  prevents it), every child it starts is in one job that kills its members when
  the VM that made it ends: a child that is a VM ends its own children, and a
  VM that is killed takes its children and their descendants with it.
  `Process.close` and the end of a run still stop only the direct child.
  Stopping a child that has already ended, before its exit callback ran, is not
  a failure on any system (`UV_ESRCH` is read as stopped).

**As built (processes PR, Linux).** `vm/process.c` holds the eight `Process`
builtins. Other systems get none.

- **Values.** A `Process` has a registered state and two lock records, `reader`
  and `writer`. `read_line` and `read_bytes` take the reader lock. `send`,
  `send_bytes` and `close_stdin` take the writer lock. `wait` and `close` take
  neither. A reader parked on a silent child never blocks a writer, and a
  lock-wait timeout leaves the process running.
- **Spawn.** Checks, in order: `--allow-run`; a nonempty command with no NUL;
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
- **Stderr** is read all the time, and each chunk goes to the program's stderr
  at once, so it keeps its order with `IO.warn`. If that write fails
  (`/dev/full`, say), the rest is read and dropped, and the child is kept.
- **Close.** `Process.close`, a timed-out read or write, the end of the run
  (step 1 of §14.4) and a stop signal share one close: a running child gets
  `SIGKILL`, and libuv's exit callback reaps it (no `waitpid`, no sleep). The
  pipes close at once, and a task blocked on the child (reader, writer or
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
- **Signals.** A stop signal takes the one exit path (§10.2.2): children are
  killed and reaped, files are flushed, and the signal is raised again. Children
  are killed before the file flush. A VM killed by `SIGKILL`, or ended by the
  out-of-memory exit (70, §6.3), leaves its children running. On a break,
  `agentica` waits 2 seconds, sends `SIGTERM`, and kills the VM 2 seconds later
  (`docs/vm/08-loader-and-cli.md`).
- **Behavior notes.**
  - A file that exists but cannot be executed (no execute permission, a bad
    format) is an error `Result` from `Process.spawn`.
  - A `read_line` or `read_bytes` pending in another task when the process is
    closed returns `process: process is closed`.
  - libuv resets signals 1 to 31 to their default in the child, so a signal the
    VM inherited as ignored (`nohup`) is not ignored in its children. The VM
    does not patch libuv.
  - `Process.spawn` checks its timeout but does not apply it to the lookup and
    start.

**As built (21a, captured processes, Linux).** `Process.spawn_captured` and
`Process.output` (specified in `docs/grammar/06d-io-and-network.md`) share the
code above.

- **Spawn.** The checks keep the order above, with `dir` (nonempty, no NUL)
  checked after the arguments and before the timeout. `dir` must be a directory,
  else `process: directory is unavailable`. `"."` passes no working directory.
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

**As built (25c, the child channel).** A second descriptor, a socket
pair separate from stdin, stdout and stderr, carries the protocol of
`agentica test` and of BDD children, so a test or a step program owns its own
stdin and stdout. `Process.spawn_channel`, `channel_read_line`, `channel_send`,
`channel_close` and `read_available` are in `vm/process.c`;
`Process.parent_read_line` and `Process.parent_send` (the child side) and the
shared duplex stream are in `vm/duplex.c`, a service (`docs/vm/15-layers.md`).
The signatures are in `docs/grammar/06d-io-and-network.md`. Linux and macOS
use a socket pair; Windows has a pipe path (`agc_fs_take_channel`) that the
platform tests do not cover yet.

- **The socket pair.** One `uv_socketpair` (`SOCK_STREAM`) per child. The parent
  keeps one end as a libuv pipe handle, and the child gets the other as
  descriptor 3 (`stdio[3]`, so `stdio_count` is 4) and the variable
  `AGENTICA_CHANNEL=3`. A socket and not a FIFO, so the child cannot reopen it
  through `/proc/self/fd/3` with a different mode, and one object carries both
  directions. The stream is text lines in both directions, as in the other
  `Process` streams: `\n` ends a line, a trailing `\r` is removed, a last line
  without `\n` is a line, and invalid UTF-8 is an error.
- **Environment.** Every spawn builds the child's environment from the VM's own:
  `AGENTICA_CHANNEL` is always removed, `UV_USE_IO_URING` is removed as before
  (§10.2.2), and only `spawn_channel` adds `AGENTICA_CHANNEL=3`. So a parent
  that spawns without the pipe never passes an inherited marker on, and a
  grandchild sees neither the marker nor descriptor 3 unless its own parent
  opened a channel for it. `System.env` hides the same entries from the
  program (`own_env` in `vm/process.c` decides for both). `AGENTICA_VM_METRICS`
  and `AGENTICA_VM_METRICS_FILE` are also removed from a child's environment
  (`metrics_env`, matched with their `=`), so a child VM or a BDD runner never
  fights for the metrics port or file (`docs/future/28-vm-metrics.md` §28.5);
  `System.env` still shows them to the program.
- **Child start.** `agc_parent_take` runs in `agentica.c` before the program
  does. If `AGENTICA_CHANNEL` is `3` and `fstat(3)` says socket or FIFO and
  `fcntl(F_GETFL)` says it is open for both reading and writing (an anonymous
  pipe end never is), the VM moves the descriptor with `F_DUPFD_CLOEXEC`, closes
  3, forgets it in the table of inherited files (so no `File` call can reach
  it), removes the variable from its own environment, and keeps the stream until
  the end of the run. In any other case, such as a regular file, a character
  device or a FIFO open for only one direction on descriptor 3, nothing is
  touched (the descriptor stays as it was) and the child-side builtins return
  `error("process: no parent channel")`. The libuv handle is attached on first
  use, so a program that never uses the channel never starts a read.
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
- **Timeouts and errors.** A timed-out `channel_read_line` or `channel_send`
  closes the channel and only the channel: the process keeps running, so the
  parent can still call `read_available`, `output`, `wait` and `close`. Later
  channel calls return `error("process: channel is closed")`. The same holds for
  the child side. `channel_read_line` at the end of the child's output returns
  `error("process: end of input")` (a reset peer counts as the end); a line over
  1 MiB is `error("process: line exceeds 1048576 bytes")` and closes the
  channel; `channel_send` takes at most 1048576 bytes
  (`process: send exceeds 1048576 bytes`) and a write that finds the peer gone
  is the OS error text (`error writing to stream port`, with the system error).
  A cut of stdout or stderr (more than 1 MiB unread, as in Reading) also wakes a
  pending `channel_read_line`, and makes every later one that finds no complete
  line, with `error("process: output exceeds 1048576 bytes")`; lines already in
  the buffer are still delivered first, and the channel stays open. So a child
  that prints for ever, and never sends its record, is found at 1 MiB and not at
  the runner's deadline. On a process made by `spawn` or `spawn_captured`, the
  three parent-side channel calls return
  `error("process: the child has no channel")`; on a closed process they return
  `error("process: process is closed")`.
- **Half close.** `channel_close(p, timeout_ms)` shuts the write side only
  (`uv_shutdown`): the child reads the end of its input, and the parent can
  still read what the child sends. It is idempotent, also after the peer has
  exited: a `uv_shutdown` that fails on the spot (it gives `ENOTCONN` when the
  peer is gone) is ignored, since the write side is closed either way.
- **`read_available`.** Returns, as a `String`, the stdout the VM has captured
  since the last call and consumes it. It never waits for more output:
  `timeout_ms` bounds only the wait for the reader lock. Before it answers, it
  drains the stdout pipe with non-blocking reads, at most 2 MiB per call, so
  everything the child wrote to stdout before it wrote a channel line is in the
  text once that line has been read. That is the whole ordering rule between the
  two streams: a child that flushes its stdout before it sends a channel record
  (the VM does, in `Test.run` and in `BDD`) gets that output attributed to that
  record. It returns `error("process: output exceeds 1048576 bytes")` once
  stdout or stderr was cut (more than 1 MiB unread, as above), and
  `error("process: output is not captured")` on a `spawn` handle. A cut that
  happens between two calls is how the runner finds a test that printed more
  than 1 MiB. Bytes that end in the middle of a UTF-8 character (up to three)
  stay in the buffer for the next call, unless the stream has ended or failed,
  so a character is never split between two calls.
- **Close.** The channel handle closes with the process (`shut`), after the
  pipes. A pending channel read or write wakes with
  `process: channel is closed`.
- **`Test.run` and the BDD children** use the child side. `Test.run` must be
  called from `main`'s own task (`vm->task == vm->main`): a call from a test or
  any other task is `RUNTIME-TEST-RUN`, "call Test.run from main, outside every
  test". After the name checks, a call with no channel under
  `--agentica-test list|run` (`agc_parent_open`) is `RUNTIME-TEST-RUN` too. In
  run mode, an index line that is not a plain index naming a test, or that
  cannot be read as a UTF-8 line (`AGC_INPUT_FAILED`), is a `RUNTIME-BDD-INFRA`
  fail record ("invalid test index") and exit 1. It flushes stdout (`agc_drain`)
  before each record, then sends the record as one JSON line with
  `agc_parent_send`. The core has no protocol mode: stdout is an ordinary stream
  and stdin is the program's. The two child-side builtins are for runner code.
  Nothing keeps a test from calling them, which can lose or add a line
  (accepted, as in the grammar's test rules); the only guard is that
  a second request in a direction that already has one pending gets
  `error("process: the channel is in use")`, so two requests never share a
  buffer.

### 10.5 Limits the C runtime keeps

- **Limit:** `IO.read_bytes` count
  - **Value:** 0..1 MiB

- **Limit:** Process send, read, line
  - **Value:** 1 MiB

- **Limit:** File read, line, text, writes
  - **Value:** 1 MiB

- **Limit:** TCP `send_bytes`, `recv_bytes`, line (`TCP.send` of a String has no
  limit, as in the grammar)
  - **Value:** 1 MiB

- **Limit:** Byte values
  - **Value:** 0..255

- **Limit:** `List.repeat` count
  - **Value:** 0..1048576

- **Limit:** HTTP start and header line
  - **Value:** 8192 bytes

- **Limit:** HTTP header block
  - **Value:** 65536 bytes

- **Limit:** HTTP headers
  - **Value:** 100

- **Limit:** HTTP interim responses
  - **Value:** 15 accepted, the 16th fails

- **Limit:** `max_connections`
  - **Value:** at most 65536

- **Limit:** HTTP body
  - **Value:** `max_body_bytes`, 413. The body is held whole, so the default is
    1 MiB and the cap 64 MiB (10.7)

- **Limit:** Process launch
  - **Value:** `--allow-run`

- **Limit:** Windows programs other than `.exe`, `.com`
  - **Value:** rejected

HTTP numbers: `Content-Length` and chunk sizes accumulate with saturation.
Parsing stops once a value exceeds the limit (413), and every comparison is
written `size > limit - total`.
