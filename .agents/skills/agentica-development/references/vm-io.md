# VM loop, stdin, stdout and files

Read first: `references/vm.md` and `references/vm-c.md`.

## Event loop and jobs (`vm/loop.c`)

Only the thread that owns the loop calls `uv_run`: the scheduler with N = 1
(through `agc_io_poll` in `vm/task.c`), the I/O thread with N > 1. libuv
callbacks only set flags and queue the task. Only `vm/loop.c`,
`vm/stdio_windows.c`, `vm/stream.c`, `vm/process.c`, `vm/system.c` and
`vm/tcp.c` include `uv.h`. `rg 'agc_io_|agc_loop_' vm/*.h` lists the API. Rules:

- At N > 1 a libuv step goes through `agc_io_call` or `agc_loop_call`, since
  `agc_io_uv` aborts off the I/O thread. A step posted from a hook with no VM
  (`release`, `drop`) uses `agc_loop_call`. `agc_io_here` is true where a posted
  step runs at once (N = 1): the test of a service's fast path.
- `agc_io_init` sets `UV_USE_IO_URING=0`. `agc_io_run_for` runs the loop once
  for at most N ms (one reusable timer). A loop with nothing alive is not run
  (`alive_required`).
- A job's outcome is set once by CAS from PENDING (DONE, EXPIRED or CANCELLED).
  Its holders (owner, wait piece, ready list, each request in flight) are
  counted; the last holder moves it to the loop's dead list, and `sweep` (loop
  thread only) frees it after its timer closed. A START that finds `ended` set
  starts nothing.
- `agc_io_start`: one `uv_queue_work` job plus an optional timer per blocking
  call. A kind needs `work` or `external`; a bare deadline is a task timer.
  `agc_io_poll` runs `uv_run` NOWAIT or ONCE and wakes the ready list. A
  non-empty ready list is drained even when the loop has nothing alive, and
  makes the run NOWAIT. `agc_io_finish` runs `done` or `expired` when the parked
  task runs again, and first hands a held handle to the head waiter
  (`next_owner`).
- `agc_io_detach`: a cancelled task's job runs `done` between turns and drops
  the result (a process keeps its handle: `keep_detached`). It never runs
  `expired`, so it never closes a task's handle. A kind's optional
  `cancel(vm, data, context, deadline)` half, refused on pool kinds, may end it
  early through `drop`. A queued job is never swept. `agc_io_detached` is a job
  with no task (a crashed task's file close).
- `drain` pops the jobs ready at its start one at a time. A long jump out of the
  flush (a `done` half that calls `agc_fail`) loses only the job in hand.
- `agc_poller_*` owns a descriptor that can wait forever (`uv_poll_t`; close
  closes the descriptor). A pool job's `more` step (`agc_io_start_then`), run on
  the loop thread, may keep the job waiting until `agc_io_ready`; its `on_loop`
  flag makes its `expired` and end-of-run paths treat it like an `external` job.
- `agc_io_close` is for in-process harnesses, the fuzzer and C tests only; it
  runs `uv_run` NOWAIT so callbacks still fire.

## Handles and ownership

- `agc_own` records a handle's owner and close, and puts it on the owner task's
  list; it sets no owner outside a turn. `agc_hand_over` moves it to another
  task. `agc_close_owned(vm, t)` closes what a task still owns when it ends.
- `agc_handle_wait` is the per-handle FIFO lock. A caller takes it as
  `next_owner` or when free, else queues and parks with retry on its own task
  timer. A cancelled waiter leaves the FIFO; a cancelled `next_owner` passes the
  lock on. A `closing` handle lets every caller through, so the builtin returns
  its closed error.
- Handles and requests are `malloc`'d and stay owned until their `uv_close`
  callback. Either the GC resource stays in the registry until then, or the
  native state counts its pending close callbacks and users and frees itself
  when both reach zero. With that count, `close` may unregister at once (as
  `Process.close` and `TCP.close` do). Request buffers stay owned by the request
  until its callback. Handles and descriptors are non-inheritable.

## Stop, flush and exit

- The one exit path (`docs/vm/10-io-scheduler.md` §10.2.2, "End of run";
  `agc_launch_settle` then `agc_launch_exit`): `agc_processes_stop` kills the
  children; `agc_io_children_stopped` acts on a second signal; `agc_io_goodbye`
  calls each resource's `goodbye` hook (TCP sends TLS `close_notify`); stdout
  and stderr flush; `agc_io_flush_files` closes the files and waits for their
  flush jobs under a fresh `setjmp`; then `_exit`. Nothing else is joined or
  drained. The flush wait is `uv_run` ONCE until the flush-limit timer (30000
  ms, `--flush-timeout` or `AGENTICA_FLUSH_TIMEOUT_MS`), which sets
  `rt->flush_expired` for the warning line.
- Stop signals: `agc_io_watch_stop` handles `SIGINT`, `SIGTERM` and `SIGHUP`
  (not one inherited as ignored), with a `SIGALRM` backstop armed only after a
  second signal. The global `stop` (`NOLINT`) holds lock-free atomics: first
  signal, second, and `held` until the children are stopped. `check_stop` in
  `vm/task.c` ends the run between turns, before a wait and before a stall
  error, through `agc_stop` in `vm/interp.c`; `agc_write` and `agc_flush` also
  call it on `EINTR`. A second signal ends the VM at once, except while `held`.
  A driven VM whose driver is gone takes that path on its first signal.

## Files (`vm/files.c` and its adapters)

- `vm/process_os.h`, `vm/process_posix.c`, `vm/process_windows.c`: the command
  search rules of `Process.spawn`: what counts as a path, the PATH split and
  quotes, the `.exe`/`.com` allowlist (no PATHEXT), and the names refused (a
  trailing dot or space, or a `:` that is not a drive). The read of a child's
  stdout beside libuv for `Process.read_available` is POSIX only.
- `vm/duplex_os.h`, `vm/duplex_posix.c`, `vm/duplex_windows.c`: the ends of a
  child channel (how the parent makes them, the `AGENTICA_CHANNEL` value each
  system understands, how a child takes the inherited descriptors). `duplex.c`
  keeps framing, limits, locks and timeouts.
- `vm/files.c`: the `File`, `Dir` and `Path` builtins (`agc_file_builtins`,
  shared with Windows; `docs/vm/02-reference-behavior.md` §2.8). `vm/file_io.c`
  is the synchronous libuv filesystem adapter, with no VM state, run in pool
  jobs. `vm/file_windows.c` converts Windows paths and maps OS errors.
  `vm/tree.c` is the no-follow tree walk behind `Path.remove`.
- Argument checks run in a fixed order: for a handle, the arguments and timeout,
  then the lock, then the open and mode. Each request is a `malloc`'d `op`; its
  `work` half runs in the libuv pool.
- A handle has a read buffer or a 4096-byte write buffer. An append goes in when
  it fits; otherwise the write stays pending with the new bytes. Flush, close
  and the end of run write it.
- The waiting rule. `probe` runs after an `O_NONBLOCK` open (`fstat` plus an
  `epoll_ctl` probe). Regular files, block devices, and devices epoll refuses
  with `EPERM` go to the pool, set blocking. Other probe errors, or a failed
  `agc_poller_open`, are the call's error. Pipes, FIFOs, terminals and other
  pollable devices stay non-blocking on an `agc_poller`: `start` tries `step` on
  the loop, then parks on `poll_io` (an `external` kind), whose `ready` repeats
  `step`. `ready` repeats the step on a hang-up, so a reader that left gets
  `EPIPE`. Whole-file calls reach this through `agc_io_start_then`'s `more`.
  `stop` is the `cancel` half, called only in the loop phase.
- A timed-out close drops the bytes it already sent. A close sends the buffer
  only for a writable state, so closing a read FIFO that holds read-ahead lines
  is `ok()`. `close_file` holds the handle as the close job's context. `closed`
  stores an error result, wakes the lock waiters and calls
  `agc_task_close_done`, so `File.close` on a closing handle waits for the lock
  and returns that result. The end-of-run flush of a polled file is a detached
  `poll_close_io` job.
- `private_pipe` refuses, as not a regular file, a path that reopens a pipe the
  VM made (one not in `rt->inherited`, the pipes found at start-up before libuv
  and the trace file). Reading libuv's signal lock pipe once stole its token and
  deadlocked the next `uv_signal_*` call with every signal blocked.
- Inherited pipes (`bash <(...)`, `/dev/stdin`, `/dev/stdout`,
  `/proc/self/fd/1`, ...) stay reachable. `names_output_fd` refuses only the
  descriptor `vm/output.c` reopened for stdout or stderr, found through
  `/proc/self/fd` or `/proc/thread-self/fd` by device and inode. A child can
  still open `/proc/<VM pid>/fd/N`: the check covers the program's own file
  calls only. `owns_st` marks the request that frees the file state.
- BDD driver builtins (pool jobs):
    - `File.open(path, "create_private")` (`OP_OPEN_CREATE`) opens with
    `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW` and mode 0600, then takes the
    write path.
    - `File.try_lock` (`OP_TRY_LOCK`) is `flock(LOCK_EX | LOCK_NB)` after the
    handle's own lock wait. A poller handle (pipe, FIFO) is refused at once; a
    device that `fstat` reports as not a regular file is `FS_NOT_LOCKABLE`.
    Results are `ok(true)` or `ok(false)`.
    - `Path.remove` (`OP_REMOVE`) unlinks, repeating on `EINTR`; a missing path
    is success. `EISDIR` calls `agc_remove_tree`, whose refusals map to
    `FS_TREE_DEEP` and `FS_REFUSED`. A failure inside the tree reports that
    entry's path.
    - `Path.rename` (`OP_RENAME`) never replaces: `renameat2` with
    `RENAME_NOREPLACE` (macOS `renameatx_np` with `RENAME_EXCL`), `MoveFileExW`
    with no flags on Windows. There is no cross-volume copy fallback. The error
    is `FS_RENAME` with both paths.
    - `Path.real` (`OP_REAL`) calls `agc_fs_realpath` on the pool thread, with
    no deadline. A failure is `FS_RESOLVE`; the result decodes lossily (one
    U+FFFD per bad byte).
    - `File.lstat` shares `work_stat` with `OP_STAT`; `Dir.mkdir_private` is one
    `mkdir(0700)`.
- `File.each_line` and `File.foreach` share `agc_line_reader` (`agc_lines_new`,
  `agc_lines_next`, `agc_lines_stop` in `services.h`), a state machine that a
  stepper drives one line at a time (`lines_step`; for `foreach`, the terminal
  of `vm/lazy.c`, which takes `rt->sync` only around `agc_lines_next`). It reads
  one `OP_READ_BLOCK` at a time into a buffer of `buffer_bytes + 1` bytes, made
  once; each read is clamped to `buffer_bytes`, and the spare byte tells a last
  line of exactly `buffer_bytes` from a longer one. `scan_line` (shared with
  `read_line`) finds a terminator within the first `buffer_bytes` pending bytes
  and strips one `\r`. A last line without a newline is returned at EOF. More
  than `buffer_bytes` pending with no terminator fails with
  `filesystem: line exceeds buffer_bytes`. Text is checked with
  `agc_utf8_chars`. Check order: buffer range, then timeout, then the path
  contract. A block error is the result, and the file closes with `OP_CLOSE`
  first; every path that opened the file passes CLOSE before END.
- The io trace logs `file_open handle=N` on open and `file_close handle=N` when
  the registry forgets a handle (at `File.close`, at the owner's end, or on a
  timed-out job). A timed-out close can log twice; a handle still open at run
  end logs no close. `tests/test_vm_lazy_io.py` checks these on every platform.
- `Lazy.write_lines` writes through `agc_line_writer`: `OP_OPEN_WRITE`, then
  each line and its LF into a handle buffer of `CHUNK` (64 KiB, not
  `WRITE_BUFFER`), a full buffer going out as one `OP_WRITE`, then
  `close_handle`. A line over `LIMIT` is an error. The handle is private, so no
  handle lock is taken.

## Input (`vm/input.c`)

- The only stdin reader. Statuses are OK, EOF, WAIT and FAILED. One growing
  runtime buffer serves `gets`, `read`, `read_bytes` and `eof?`. An EOF read
  bumps `eof_seq`, and each task sees it once (`input_seen`). A `scanned` offset
  keeps line search linear.
- Linux: a pipe, FIFO, terminal or socket stdin is read on the loop
  (`watch_stdin`). A pipe or terminal is reopened through `/proc/self/fd/N` with
  `O_NONBLOCK`, so the inherited description keeps its flags; a socket uses
  `MSG_DONTWAIT`. Other stdin is read by one pool job. Its `done` half appends
  the bytes and wakes the readers, which re-run (retry).
- Windows reads every stdin kind, console included, with one blocking `_read` on
  a reader thread of its own (`agc_stdin_*` in `vm/stdio_windows.c`), never in
  the pool. It is an `external` job that an async handle ends; cancellation
  detaches it, and the end of the run does not wait for it (§14.1).
- Only `vm/input.c` reads fd 0. `agc_vm_init` leaves input closed (`fd = -1`,
  always EOF) and `System.args` empty; `agc_launch_vm` opens fd 0 (not for the
  front end) and fills the args, so C tests and the fuzzer never block on stdin.
  The driver copies a non-file stdin into the VM with a thread it kills when the
  VM exits.
- Stdin decodes each invalid byte to U+FFFD. Arguments decode each invalid byte
  to `?`, and an incomplete sequence at the end to one `?` (`LC_ALL=C.UTF-8` in
  the diff test).

## Output (`vm/output.c`)

- The only writer of stdout and stderr: `agc_write`, `agc_output_waiting`,
  `agc_drain` (for `IO.flush`) and `agc_flush` (`docs/vm/10-io-scheduler.md`
  §10.2.2). `output.c` has no OS branch: `vm/stdio_posix.c` and
  `vm/stdio_windows.c` pick the write mode (`agc_write_mode`: DISK, POLL, STREAM
  or THREAD), whether two descriptors are one target, and the in-memory stream
  of a notice.
- Per stream, `agc_output` (`vm->rt->out`, `err`) has a 64 KiB ring
  (`AGC_OUTPUT_BUFFER`) and a FIFO of waiting writers. A print with nobody ahead
  of it is copied and returns. Otherwise the task keeps a pointer to its text in
  `task->output` and parks (retry; `agc_output_waiting` tells the builtin to
  pass no text), and the head is woken when its whole text fits. A print longer
  than the ring copies in pieces and holds the stream.
- `agc_output_open` (from `main`, after `agc_input_open`) reopens a pipe, FIFO
  or terminal through `agc_fd_reopen`, or duplicates a socket, and writes from
  an `agc_poller`. On macOS each write is guarded by `poll` and cut to
  `PIPE_BUF` or `SO_SNDLOWAT`. A regular file, a block device, or a device epoll
  refuses (`/dev/null`) drains by a pool job. Any other descriptor stays on the
  blocking `fwrite` of its `FILE`.
- When stderr is the same file as stdout (`st_dev`, `st_ino`), both share one
  ring and FIFO. A write error sets `failed`, drops the data and the notices,
  and wakes the waiters.
- `agc_output_forward` takes a child's stderr on the I/O thread into the notice
  queue. It uses only the room the FIFO head does not need (`spare`), so a
  waiting print goes first. Past `AGC_FORWARD_BOUND` queued it waits
  (`agc_forward_wait`) until the queue drops to `AGC_FORWARD_RESUME` or the
  stream closes. `sent` and `own_end` are stream positions: a failure that lost
  only forwarded bytes does not fail the run.
- `agc_output_busy` keeps `flushing()` waiting while a buffer holds data: it
  pumps queued notices with force and kicks the writer, since no task will
  finish a cut print. After a stop signal it makes one non-blocking write per
  stream and stops waiting. The trace has `output_start` and `output_done` per
  run of data.
- VM notices go through `agc_notice_begin` and `agc_notice_end`, in one of three
  modes: `AGC_NOTICE_QUEUED` (crash diagnostics and the unobserved summary; a
  queue of at most 1 MiB), `AGC_NOTICE_KEPT` (the failed run's diagnostic;
  queued even at the limit, but never inside a print that holds the stream, and
  before the end-of-run wait), and `AGC_NOTICE_FINAL` (flush warnings;
  non-blocking writes, and what a stuck pipe refuses is dropped).

## Gotchas

- Never `fwrite` to `vm->rt->out.file` or `err.file` from builtin code. Use
  `agc_write`, which parks the task and runs the builtin again. So the builtin
  works out its text first (passing none when `agc_output_waiting` says it
  already waits) and touches no state the second run would repeat. `agc_vm_init`
  leaves both streams on the blocking `FILE *` it was given (`base` is null), so
  C tests and the fuzzer never depend on the loop. `vm/process.c` hands a
  child's stderr to `agc_output_forward` and stops reading the pipe while that
  queue is full.
- A builtin whose work grows with its input sets a turn cost
  (`docs/vm/10-io-scheduler.md` §10.2.1), taken from the turn only, never from
  `steps_left`, so `--max-steps` stops a program at the same place.
- No new mutable `static` or global in `vm/` (rule and exceptions:
  `references/vm-c.md`). State goes in the runtime, scheduler or task struct;
  lazy init uses `pthread_once` or runs at start-up.
- Limits: the 1 MiB per-call reads, the HTTP framing limits and the other caps
  in `docs/vm/10-io-processes.md` stay as documented.

## Native Windows files

- `files.c` shares validation, buffers, task ownership and pool deadlines with
  Unix. Do not put `uv.h` or Win32 headers in the driver to reach these
  operations. Regular files use binary descriptors and UTF-8 paths;
  `Path.resolve` keeps drive and UNC roots.
- Windows locks use non-blocking `LockFileEx` over the whole file, so other
  handles cannot read or write the locked range either (unlike advisory
  `flock`). `file_state.locked` makes repeat calls on the same handle succeed.
  Only `ERROR_LOCK_VIOLATION` becomes `EAGAIN`; access denied and other failures
  stay errors.
- Windows `Path.remove` traverses by handle with no-follow, and validates the
  raw path before normalizing it. Destructive tests need the scratch harness.
  Windows special file streams remain separate work.
- Private creates and directories use a protected owner-only DACL. A private
  handoff checks the owner, DACL, regular type and single link on the opened
  handle before it marks that handle for deletion; a failed check preserves the
  file. The native handoff deletion tests run only when `CI` is set, in
  test-owned directories.
- Filesystem adapter files and headers go in the explicit lists of
  `vm/tools/check-layers.sh`. `file_io.h` stays forbidden to core files,
  adapters stay independent of VM values, and `make vm-layers` (with its
  planted-violation self-tests) runs before pushing changes to these boundaries.
- `System.env` and `System.pid` live in `vm/system.c`, apart from process
  spawning. Environment lookup keeps empty values, rejects NUL and `=`, and
  hides the private channel marker (case-insensitively on Windows).
  `vm/tests/system_test.c` runs on all hosts.
- Bytecode file reads are opened by `file_io.c` and consumed in `launch.c`;
  `agentica.c` has no native file APIs.
