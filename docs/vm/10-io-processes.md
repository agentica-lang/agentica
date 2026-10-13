### 10.4 Processes

- `--allow-run` is the VM's own flag, checked inside `Process.spawn` at call
  time for every task and handler.
- The VM resolves the executable itself, with the rule written in
  the grammar (Processes): a command that contains `/`
  resolves against the program's working directory; a bare name is looked
  up in each `PATH` entry in order. The VM never adds the working
  directory itself: empty entries are skipped, and an explicit relative
  entry such as `.` or `bin` resolves against the working directory, as in
  the shell. It passes the absolute path to `uv_spawn`.
  All three stdio streams are pipes.
  `UV_PROCESS_WINDOWS_VERBATIM_ARGUMENTS` is never used.
- The file loop sets `UV_USE_IO_URING=0` in the VM's own environment
  (10.2.2). The processes PR must not pass it on: it removes it from the
  child's environment unless the user had set it before the VM started.
- Windows: after resolution, allow only `.exe` and `.com`, case-insensitively,
  and reject names with a trailing dot or space or any `:`. The allowlist applies
  to the last component of the resolved path. The VM must apply it when its
  process code is ported to Windows, and must not search the current
  directory before `PATH` there.

**As built (processes PR, Linux).** `vm/process.c` holds the eight
`Process` builtins; only it and `vm/loop.c` include `uv.h`. Other systems
get an empty table, so the lowerer's keys fail at load as unknown imports.

- **Values.** A `Process` value (`AGC_T_PROCESS`, printed `<Process>`) is
  a GC `agc_process` with three `agc_resource` pointers: `state`, the
  registered resource whose `native` is the `malloc`'d process state, and
  two lock records, `reader` and `writer`, that are never registered and
  only carry the lock fields of 10.2.2. `read_line` and `read_bytes` take
  the reader lock, `send`, `send_bytes` and `close_stdin` the writer lock,
  through `agc_handle_wait`; `wait` and `close` take neither. So a reader parked on a silent child never blocks
  a writer, and a lock-wait timeout leaves the process running.
- **Spawn.** Checks in this order (`--allow-run` before any
  work on the arguments, then a nonempty command and no NUL, then the
  timeout), resolution as above (a path that does not exist or is a
  directory is "executable is unavailable"), then three real pipes made
  with `uv_pipe` and given to the child with `UV_INHERIT_FD` (libuv's
  `UV_CREATE_PIPE` makes socketpairs, which some programs treat
  differently), and the parent's ends opened with `uv_pipe_open`. The
  first spawn of a run also marks every descriptor the VM inherited above
  2 close-on-exec (a walk over `/proc/self/fd` with `fcntl`;
  `close_range` is not declared under the VM's `_POSIX_C_SOURCE` build),
  and the VM opens its own descriptors close-on-exec, so a child sees only
  0, 1 and 2. `argv[0]` is the resolved path. The
  child's environment is the VM's, without `UV_USE_IO_URING` when
  `drop_uring_env` says the VM set it. A failed `uv_spawn` (`EACCES`,
  `ENOEXEC`) is an error `Result` with the OS text (`agc_system_error`).
  `Process.spawn` charges a turn cost by the size of its arguments
  (`AGC_COST_SIZE`, 10.2.1); `send`, `send_bytes`, `read_line` and
  `read_bytes` charge by the size they write or return, also when they
  park (10.3.1).
- **State.** The `malloc`'d `proc` holds the `uv_process_t`, the three
  `uv_pipe_t`, one `uv_write_t`, the stdout buffer, and the pending
  requests (one reader, one writer, a list of waits). Callbacks find it with
  `offsetof`. It is freed when its resource was released, every request
  that points to it was dropped, and the close callback of each of its
  libuv handles ran (a user count and a handle count), so no callback ever
  sees freed memory.
- **Operations park only their task** on external jobs (10.2.2) with the
  call's timeout on the job's timer. Reads start `uv_read_start` on stdout
  only while a reader waits and stop as soon as its line or bytes are
  buffered (or at EOF or an error). Each read asks for 4 KiB, or for what
  a `read_bytes` still needs when that is more, so the VM reads at most
  about 4 KiB past what the program asked for, and a child that writes much
  more than the program reads blocks on its pipe. The stdout buffer is the one TCP
  uses (`vm/stream.c`, 10.3.1), so a read error after a partial line
  returns the error, not the partial line. A write first tries
  `uv_try_write`; the rest is copied and sent with `uv_write`, and the
  task parks until its callback. `wait` returns at once when the child has
  exited and its stderr reached EOF; otherwise it parks on a job that
  `exit_cb` or the stderr EOF readies. A timed-out read or write closes
  the process; a timed-out `wait` leaves the child
  running.
- **Stderr** is read all the time and each chunk is written and flushed to
  the program's stderr in the read callback, so it reaches the user in
  order with `IO.warn` output and without waiting for a builtin. If that
  write fails, the rest is read and dropped.
- **Close.** `Process.close`, a timed-out read or write, and the end of
  the run (`agc_processes_stop`, the first step of the one exit path of
  10.2.2, also after `System.exit`, a runtime error, the step limit or a
  stop signal) all go through one close. If the child still runs, it sends `SIGKILL` and polls `waitpid`
  with `WNOHANG` every 0.1 ms until a `CLOCK_MONOTONIC` deadline 1 second
  away; a child normally dies within the first polls. `Process.close` and
  a stream timeout give their one child its own deadline. A cleanup of all
  children (the end of the run, or a stop signal, below) sends `SIGKILL`
  to every running child first and then reaps them under one shared
  deadline, so the whole cleanup stays within about 1 second, inside the
  driver's 2-second grace (9). A child in uninterruptible sleep (a hung
  network file system, say) can outlast that bound: then, and when the
  kill fails (`EPERM`, for example a child that became another user
  through `sudo`), the VM does not wait. It keeps the `uv_process_t` open
  so that libuv reaps the child when it ends and `exit_cb` closes the
  handle. A failed kill in `Process.close` ends the run with
  `RUNTIME-PROCESS-CLOSE`; inside
  a timed-out read or write the timeout error stands. If such a child is
  still there at the end of the run, the VM ends with `_exit` anyway
  (10.2.2), leaving that child to `init`. Otherwise the pipes
  are closed at once; libuv's own reap later finds no child and does
  nothing. The waiting reader, writer and waits are readied and see
  "process is closed". A second `close` does nothing, and any other
  operation after it returns "process is closed". So
  no child outlives a run that ends normally and no zombie or pipe stays
  behind.
- **Signals.** A stop signal (`SIGINT`, `SIGTERM`, `SIGHUP`) takes the
  one exit path of 10.2.2 ("Stop signals"): the run ends, the children are
  killed and reaped as above, the files are flushed, and the VM raises the
  signal again, so it ends by that signal as it would without children. The
  process guard has no signal watchers of its own: it only lists the
  running children for that cleanup. The children are killed before the
  file flush, so a flush with no limit never delays their cleanup, and a
  second stop signal that comes before they are killed waits for that
  (10.2.2). A VM killed by `SIGKILL`, or ended by the out-of-memory exit
  (70, 6.3), leaves its children running (they get EOF or `EPIPE` when
  they next touch a pipe). On a break `agentica` waits 2 seconds, then
  sends `SIGTERM`, and kills the VM only 2 seconds after that (8), so a
  cleanup that takes longer leaves the rest of the children running.
- **Behavior notes.**
  - A file that exists but cannot be executed (no execute permission, a
    bad format) is an error `Result` from `Process.spawn`.
  - After a read or write timeout closes a process, a later read or write
    returns "process: process is closed" at once.
  - A `read_line` or `read_bytes` pending in another task when the
    process is closed (by `Process.close`, or by a send that timed out)
    returns "process: process is closed".
  - When forwarding the child's stderr fails (the program's stderr is
    `/dev/full`, say), the VM drops the rest of that stderr and keeps the
    child.
  - libuv resets signals 1 to 31 to their default action in the child, so
    a signal the VM inherited as ignored (`nohup`) is not ignored in its
    children. The VM does not patch libuv for this.
  - `Process.spawn` checks its timeout but does not apply it to the
    lookup and start, which run without a timer.
  - Error texts of failed system calls follow `agc_system_error`.

**As built (21a, captured processes, Linux).** `Process.spawn_captured`
and `Process.output` (specified in `docs/grammar/06d-io-and-network.md`) live in
`vm/process.c` beside the eight builtins above and share their code; a
`proc` has a `captured` flag.

- **Spawn.** `spawn_child` serves both spawns. The checks keep the order
  above, with `dir` (nonempty, no NUL) after the arguments and before the
  timeout. The command resolves first, against the VM's working directory;
  then `dir` becomes a host path like a file path (raw `getcwd` bytes for a
  relative one) and must be a directory (`stat`), else "directory is
  unavailable" (trace `spawn_failed reason=dir`). It goes to
  `uv_process_options_t.cwd`; `"."` passes no `cwd` at all.
- **Reading.** Both pipes are read from the spawn on, never stopped, into
  two `agc_inbuf`s: `out_buf` (the one `read_line` and `read_bytes` use)
  and `err_kept`. A chunk is read straight into the buffer while 4 KiB
  more still fits under 1 MiB of pending bytes; nearer the limit it is
  read into the 4 KiB scratch buffer and only what fits is copied
  (`keep_scratch`), so a buffer's capacity never passes 1 MiB. A byte
  that does not fit marks the stream (`out_cut`, `err_cut`), and its later
  chunks are read into the scratch buffer and dropped, so the child never
  blocks. For stdout the
  limit counts unread bytes, so reading makes room again until the first
  cut; stderr is never consumed. A cut readies the waiting reader, and
  `read_ready` and `take` check the two marks before the buffer, so a
  zero-byte `read_bytes` returns the error without parking.
- **Output.** `Process.output` is a wait like `Process.wait` (same list,
  no lock, the same `await_child` path); its condition is stdout at EOF or
  a read error and stderr at EOF. The record is built from the pending
  bytes with U+FFFD for invalid UTF-8 (`agc_utf8_decode`), nothing is
  consumed, and the call charges a turn cost by the bytes it copies. The
  lowerer appends `ProcessOutput` to the struct table as it does
  `FileInfo`; the C side finds it with `agc_builtin_struct`.
- **Close.** `shut` sends `SIGTERM` to a running captured child and starts
  a 1-second `uv_timer_t` (`grace`); the pipes close and the program sees
  "process is closed" at once. The timer sends `SIGKILL`; libuv's exit
  callback reaps the child and closes the process handle and the timer
  (`retire`), so `Process.close` and a stream timeout never block. The
  end of the run (and a stop signal) first sends `SIGKILL` to plain
  children and `SIGTERM` to captured ones that have not had it, polls the
  captured ones under one 1-second deadline (`outlast`), then sends
  `SIGKILL` to those left and reaps everything under a second 1-second
  deadline. A captured child that handles `SIGTERM` quickly ends the
  cleanup in milliseconds; one that ignores it holds the run about one
  second, and only a child stuck in the kernel can make it two. A failed
  `SIGTERM` in `Process.close` is `RUNTIME-PROCESS-CLOSE`, as a failed
  kill is.


### 10.5 Limits the C runtime keeps

| Limit | Value |
|---|---|
| `IO.read_bytes` count | 0..1 MiB |
| Process send, read, line | 1 MiB |
| File read, line, text, writes | 1 MiB |
| TCP `send_bytes`, `recv_bytes`, line (`TCP.send` of a String has no limit, as in the grammar) | 1 MiB |
| Byte values | 0..255 |
| `List.repeat` count | 0..1048576 |
| HTTP start and header line | 8192 bytes |
| HTTP header block | 65536 bytes |
| HTTP headers | 100 |
| HTTP interim responses | 15 accepted, the 16th fails |
| `max_connections` | at most 65536 |
| HTTP body | `max_body_bytes`, 413; the body is held whole, so the default is 1 MiB and the cap 64 MiB (10.7) |
| Process launch | `--allow-run` |
| Windows programs other than `.exe`, `.com` | rejected |

HTTP numbers: `Content-Length` and chunk sizes accumulate with saturation:
parsing stops once a value exceeds the limit (413), and every comparison is
written `size > limit - total`. A hermetic test sends over-long values.

