# VM loop, stdin, stdout and files

The libuv loop, the resource registry, stdin, stdout and stderr, and the `File`,
`Dir` and `Path` builtins.

Read first: `references/vm.md` and `references/vm-c.md`.

## Files

- **Path:** `vm/loop.c`
  - **Owns:** The libuv event loop and the resource registry. Details below.

- **Path:** `vm/files.c`
  - **Owns:** The shared `File`, `Dir` and `Path` builtins (Unix and Windows
    regular files). Details below.

- **Path:** `vm/file_io.c`, `vm/file_io.h`
  - **Owns:** Synchronous libuv filesystem adapter: UTF-8 paths, binary
    descriptors, metadata, directory names and canonical paths. Called by
    existing pool jobs; no VM state.

- **Path:** `vm/file_windows.c`
  - **Owns:** Windows UTF-8/native path conversion, drive and UNC resolution,
    and OS error mapping.

- **Path:** `vm/process_os.h`, `vm/process_posix.c`, `vm/process_windows.c`
  - **Owns:** The command search rules of `Process.spawn`: what is a path, the
    PATH list split and quotes, the `.exe`/`.com` allowlist (no PATHEXT) and the
    names that are refused (trailing dot or space, `:` that is not a drive).
    `process.c` keeps the search loop and the file test.

- **Path:** `vm/duplex_os.h`, `vm/duplex_posix.c`, `vm/duplex_windows.c`
  - **Owns:** The ends of a child channel: how the parent makes them (a socket
    pair, or a pipe per direction on Windows), the `AGENTICA_CHANNEL` value
    each system understands and how a child takes the inherited descriptors.
    `duplex.c` keeps the framing, limits, locks and timeouts.

- **Path:** `vm/tree.c`
  - **Owns:** `agc_tree_refused` (the pure test of the names never removed) and
    `agc_remove_tree`, the tree walk of `Path.remove`: `openat` with
    `O_NOFOLLOW`, `unlinkat`, an explicit stack of at most 128 levels, no VM
    state.

- **Path:** `vm/input.c`
  - **Owns:** the only stdin reader (`agc_input_*`, status OK, EOF, WAIT or
    FAILED): one growing buffer in the runtime shared by `gets`, `read`,
    `read_bytes` and `eof?`; on Linux a pipe, FIFO, terminal or socket stdin is
    read on the loop (`watch_stdin`: a pipe or terminal reopened through
    `/proc/self/fd/N` with `O_NONBLOCK` so the inherited description keeps its
    flags, a socket read with `MSG_DONTWAIT`; an `agc_poller` and an `external`
    job), any other stdin by one pool job; the job's `done` half appends the
    bytes and wakes the readers waiting in the input's FIFO, and the builtin
    re-runs (retry) once data or EOF is in; an EOF read bumps `eof_seq` and each
    task gets it once (`input_seen`); a `scanned` offset keeps line search
    linear; U+FFFD decoding of consumed bytes, a pending EOF after a peek;
    Windows uses one blocking `_read` pool job for every stdin kind, including
    the console; it occupies one pool thread until data or EOF, cancellation
    detaches it, and process exit does not wait for it (the explicit exception
    in §14.1)

- **Path:** `vm/output.c`
  - **Owns:** The writer of stdout and stderr, with a buffer and a waiting queue
    per stream. It has no OS branch: `vm/stdio_posix.c` and `vm/stdio_windows.c`
    decide how a descriptor is written (`agc_write_mode`: DISK pool job, POLL on
    Linux and macOS, STREAM a libuv pipe on Windows, THREAD a pool job for a
    Windows console or a handle libuv refuses), whether two descriptors are one
    target, and make the in-memory stream of a notice. A STREAM or THREAD stream
    has no non-blocking try, so a stop signal and the final notices wait for the
    request in one shared 200 ms (`settle`, `agc_runtime.settle_by`); the normal
    end of the run waits within the flush limit.

- `vm/loop.c`
  - the event loop and the resource registry (`docs/vm/10-io-scheduler.md`
    §10.2.2), with `vm/stdio_windows.c`, `vm/stream.c`, `vm/process.c`,
    `vm/system.c`, `vm/tcp.c` and `vm/http_client.c` the only files that include
    `uv.h` (`vm/http_server.c` reaches libuv only through `vm/net.h` and jobs)
    - `agc_io_init` (
      - the `UV_USE_IO_URING=0` setenv at start-up
      - returns whether it set it)
    - `agc_io_uv` (
      - the scheduler's `uv_loop_t`, for handle code)
    - `agc_io_ready` (
      - completes an `external` job from a libuv callback)
    - `agc_io_run_for` (
      - runs the loop once for at most N ms with one reusable timer, then hands
        the finished jobs on; the flush wait, the last writes after a stop
        signal and the native close all wait with it)
    - `agc_register`/`agc_unregister` (
      - GC `agc_resource` objects owning `malloc` memory
      - a job keeps its registry slot index, fixed when an entry moves)
    - job outcome and count (`core.h`)
      - `agc_job_settle` sets the outcome once by CAS from PENDING (DONE,
        EXPIRED or CANCELLED), the first writer wins; the count has the owner,
        the wait piece, the ready list and each request in flight as holders;
        the holder that drops the last one puts the job on the loop's dead
        list, and `sweep` (loop's thread only) walks that list and frees after
        the timer closed
      - a START finds `ended` set when the owner ended the job first, and
        starts nothing
      - the libuv steps are requests (START, EXTEND, CLOSE_TIMER, RELEASE):
        inline on the loop's thread, queued in the inbox from any other
    - `agc_io_start` (
      - one `uv_queue_work` job plus an optional timer per blocking call
      - a kind without `work` is a timer only
      - parks the current task through `r->task` and `task->parked`)
    - `agc_io_poll` (
      - `uv_run` NOWAIT or ONCE, then the ready list of finished jobs wakes
        their tasks
      - a non-empty ready list is drained even when the loop has nothing alive,
        and makes the run NOWAIT)
    - `agc_io_finish` (
      - the request's `done` or `expired` half when the parked task runs again
      - it first releases a handle the request held, handing it to the head
        waiter as `next_owner`)
    - `agc_io_detach` (
      - 20b: the job of a cancelled task is detached
      - it ends between turns when the drain meets it, runs `done` and drops the
        result (closing a new handle in it, except a process: `process.c` sets
        `keep_detached` on its resource), never `expired`, so it never closes a
        task's handle
      - a kind's optional `cancel(vm, data, context, deadline)` half, refused on
        pool kinds, may end it early through `drop`, also when its timer fired
        before the cancel
      - a queued job is never swept)
    - `agc_io_detached` (phase 24: a job with no task from the start, for a
      crashed task's file close), `agc_io_extend` (20c: restart a job's own
      timer once, so `read_request`'s deadline counts from the request's first
      byte), handle ownership (24b: `agc_own` records a handle's owner and close
      and puts it on the owner task's list (`owned_prev` and `owned_next` in the
      resource, `owned` in the task), `agc_unregister` takes it off,
      `agc_owned_of` finds the owned resource of a handle value, `agc_hand_over`
      moves it to another task, `agc_close_owned(vm, t)` closes what a task
      still owns when it ends), `close_pending` runs a file's pending close
      after the job that held it
  - `agc_own` sets no owner outside a turn
  - at the end `close_files` starts the same close job for every open file (
    - `agc_resource.pool_close`)
    - and `finish_flushes` waits for all of them with `uv_run` ONCE until the
      flush-limit deadline timer (
      - 30000 ms, `--flush-timeout` or `AGENTICA_FLUSH_TIMEOUT_MS`)
    - setting `rt->flush_expired` for the warning line of `vm/launch.c`),
      `agc_handle_leave` (
      - a cancelled lock waiter leaves the FIFO
      - a cancelled `next_owner` passes the lock on)
    - `agc_handle_wait` (
      - the per-handle FIFO lock: take it as `next_owner` or when free, else
        queue and park with retry on the task's own timer
        (`agc_task_park_until`) at its deadline
      - a `closing` handle lets every caller through, so the builtin returns its
        closed error)
    - the one exit path (
      - `docs/vm/10-io-scheduler.md` §10.2.2 "End of run"
      - `agc_launch_settle` in `vm/launch.c` (then `agc_launch_exit`):
        `agc_processes_stop` kills the children,
        `agc_io_children_stopped` acts on a second signal recorded meanwhile,
        `agc_io_goodbye` calls each resource's `goodbye` hook (TCP: one TLS
        `close_notify` by `uv_try_write`), stdout and stderr flush (retried on
        `EINTR`), `agc_io_flush_files` closes the files and waits for their
        flush jobs until the flush limit under a fresh `setjmp`, then `_exit`,
        or the stop signal raised again with the stop signals blocked for the
        last read
      - nothing else is joined or drained)
    - stop signals (
      - `agc_io_watch_stop`: a `sigaction` handler for
        `SIGINT`/`SIGTERM`/`SIGHUP`, not for one inherited as ignored, and a
        `SIGALRM` backstop, installed and armed only when a second signal is
        recorded
      - the one global `stop`, marked `NOLINT`, holds lock-free atomics (first
        signal, a second one, `held` until the children are stopped), the driver
        pid and an unreferenced `uv_async_t` that wakes the loop
      - `check_stop` in `vm/task.c` ends the run between turns, before a wait
        and before a stall error, through `agc_stop` in `vm/interp.c`, which
        `agc_write` and `agc_flush` also call on `EINTR`
      - a second signal ends the VM at once, except while `held`
      - a driven VM whose driver is gone takes that path on its first signal)
    - `agc_poller_*` (a `malloc`'d `uv_poll_t` that owns a descriptor that can
      wait forever: open (returns the libuv error), wait readable or writable
      with a callback, pause, close, which closes the descriptor),
    - `agc_fs_realpath` (in the `file_io.c` adapter, for `Path.real`:
      `uv_fs_realpath` without a callback, so it
      runs on the calling pool thread; it returns a `malloc`'d string, or NULL
      with errno; `files.c` includes no libuv header), `agc_io_start_then` (a
      pool job's `more` step, run on the loop thread after its work, may keep
      the job waiting on the loop until `agc_io_ready`; the job's `on_loop` flag
      then makes its `expired` and end-of-run paths treat it like an `external`
      job),
    - `agc_io_close` (only for in-process harnesses, the fuzzer and the C tests:
      flush the files, then close handles and timers and free the loop; the
      process guard's release kills children; false while a job is stuck in the
      OS)
  - resources have a `kind` (native or job)
  - non-Linux builds get stubs
  - `drain` counts the jobs that are ready when it starts and pops one at a
    time, so a long jump out of the flush (a `done` half that calls `agc_fail`)
    loses only the job in hand, not the rest of the batch
  - jobs readied while it runs wait for the next drain
- `vm/files.c`
  - the `File`, `Dir` and `Path` builtins (`agc_file_builtins`, shared with
    Windows;
    `docs/vm/02-reference-behavior.md` §2.8)
    - argument checks in the evaluator's order (
      - for a handle: arguments and timeout, then the lock, then open and mode)
    - host paths (
      - raw `getcwd` bytes read at start-up by `agc_files_init`, `/` when it
        fails, + `/` collapsing)
    - `malloc`'d `op` requests whose `work` half runs in the libuv pool,
      Racket's messages (
      - contract forms cut at 256 characters, `strerror_l` in the message
        locale, the byte string form for invalid UTF-8)
    - `FileHandle` state with its read buffer or its 4096-byte write buffer (
      - Racket's rule: append when it fits, else write pending and new bytes
        together
      - flush, close and the end of run write it)
    - the one waiting rule (
      - `probe`: after an `O_NONBLOCK` open, `fstat` plus an `epoll_ctl` probe
      - regular files, block devices and devices epoll refuses with `EPERM` go
        to the pool, set blocking
      - any other probe error, or a failed `agc_poller_open`, is the call's
        error
      - pipes, FIFOs, terminals and other pollable devices stay non-blocking on
        an `agc_poller`: `start` tries `step` on the loop thread, then parks on
        `poll_io`, an `external` kind, whose poller callback (`ready`) repeats
        `step`
      - whole-file calls get there through `agc_io_start_then`'s `more`
      - `stop` is the `cancel` half, which `cancellable` in `vm/loop.c` calls
        only in the loop phase
      - `ready` repeats the step on a hang-up, so a reader that left gives
        `EPIPE`
      - a timed-out close drops the bytes it already sent
      - a close sends the buffer only for a writable state, so closing a read
        FIFO that still holds read-ahead lines is `ok()`
      - the end-of-run flush of a polled file is a detached `poll_close_io` job
      - `close_file` makes the owner-end close job hold the handle as its
        context, and `closed` stores an error result on the handle, wakes the
        lock waiters and calls `agc_task_close_done` for the ending task, so
        `File.close` on a closing handle waits for the lock and returns that
        result)
    - `private_pipe` refusing, as not a regular file, a path that reopens a pipe
      the VM made (one open in the VM that is not in `rt->inherited`, the pipes
      `agc_files_inherited` found at start-up, before libuv and the trace file;
      reading libuv's signal lock pipe once stole its token and deadlocked the
      next `uv_signal_*` call with every signal blocked)
  - inherited pipes (`bash <(...)`, a piped stdin through `/dev/stdin`, stdout
    and stderr through `/dev/stdout`, `/dev/stderr` and `/proc/self/fd/1` and
    `2`) stay reachable
  - `names_output_fd` (before the open, in `open_for`) refuses only a path that
    is an entry of `/proc/self/fd` or `/proc/thread-self/fd` (same directory
    device and inode; not `/proc/<pid>/task/<tid>/fd`) with the number of the
    descriptor `vm/output.c` reopened for stdout or stderr.
  - A child run with `--allow-run` can still open `/proc/<VM pid>/fd/N`: the
    check covers the program's own file calls only.
  - `agc_each_fd` (the `/proc/self/fd` walk, also used by `vm/process.c`) lives
    here, `owns_st` saying which request frees the state (open, close, or a
    handle request after its timeout), `Path.join` and `Path.resolve` as pure
    string code
  - the owner-only and lock builtins of the BDD driver port
    (`docs/future/18-front-end-language.md`
    §18.4, port step 7a), all pool jobs in `work`:
    - `File.open(path, "create_private")` is `OP_OPEN_CREATE`, which
      `open_for` handles first with `O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW`
      and mode 0600, then goes the way of `write`
    - `File.lstat` is `OP_LSTAT`, sharing `work_stat` with `OP_STAT`, and
      `FileInfo` has `mode`, `user_id` and `group_id` after `modified_seconds`
    - `Dir.mkdir_private` is one `mkdir(0700)` (`OP_MKDIR_PRIVATE`, the
      `FS_MKDIR` error)
    - `File.try_lock` (`OP_TRY_LOCK`) is `flock(LOCK_EX | LOCK_NB)` on the
      handle's `st->fd` after the handle's own lock wait (`blocked`);
`open_state`
      is `usable` without the direction check; a handle with a poller (pipe,
      FIFO) is refused at once, and any other kind that `fstat` in the job says
      is not a regular file (a device) is `FS_NOT_LOCKABLE`; `done` returns
      `ok(true)` or `ok(false)`
    - `Path.remove` (`OP_REMOVE`): `unlink` (repeated on `EINTR`), a missing
      path is success, and `EISDIR` calls `agc_remove_tree` (`vm/tree.c`), whose
      negative returns `AGC_TREE_TOO_DEEP` and `AGC_TREE_REFUSED` become
      `FS_TREE_DEEP` and `FS_REFUSED`; a failure inside the tree comes with the
      path of the failed entry (`failed`), which replaces `o->path` in the error
    - `Path.rename` (`OP_RENAME`): Unix uses `renameat2` with
      `RENAME_NOREPLACE` (macOS: `renameatx_np` with `RENAME_EXCL`); Windows
      uses `MoveFileExW` with no flags, which fails if the destination exists;
      there is no cross-volume copy fallback. The second path is `op.to`; the error is
      `FS_RENAME` with both paths
  - `Path.real` (`OP_REAL`: the pool `work` half calls `agc_fs_realpath`, the
    job
    has no deadline (`NO_DEADLINE`, -1), a failure is `FS_RESOLVE`, `filesystem:
    cannot resolve path` with the path and the OS error text, and the result is
    decoded with `lossy`, one U+FFFD per bad byte)
  - `File.each_line` (7.2.1h, `lines_step`, a stepper state machine with phases
    START, OPENED, SCAN, RESUME, CLOSE, CLOSED: it opens the path with
    `OP_OPEN_READ`, reads one `OP_READ_BLOCK` job at a time into a buffer of
    `buffer_bytes + 1` bytes made once, with the pending bytes compacted to the
    front (`compact`) and each read clamped to `buffer_bytes` bytes
    (`read_more`; the spare byte only lets a read tell a last line of exactly
    `buffer_bytes` bytes from a longer one), and `scan_line`, shared with
    `read_line`, finds the next line: a terminator within the first
    `buffer_bytes` bytes of the pending data, one `\r` stripped before the LF,
    the last line without a newline at EOF, and `filesystem: line exceeds
    buffer_bytes` when more than `buffer_bytes` bytes are pending with no
    terminator; text is checked with `agc_utf8_chars`; the handle is owned with
    `agc_own(close_file)` like `File.open`; the buffer range check comes first,
    then the timeout, then the path contract error; a block error is the result
    and the file is closed with `OP_CLOSE` before it is returned)
- `vm/output.c`
  - the writer of stdout and stderr, but not the only one: `vm/process.c`
    forwards a child's stderr to `err.file` with a blocking `fwrite`
    (`agc_write`, `agc_output_waiting`, `agc_drain` for `IO.flush`, `agc_flush`;
    row 7.2.1f, `docs/vm/10-io-scheduler.md` §10.2.2).
  - Per stream an `agc_output` (`vm->rt->out` and `err`) with a 64 KiB ring
    (`AGC_OUTPUT_BUFFER`) and a FIFO of waiting writers
  - a print that fits and has nobody ahead of it is copied and returns,
    otherwise the task keeps a pointer to its text in `task->output` and parks
    (retry; `agc_output_waiting` tells the builtin to pass no text), the head is
    woken when its whole text fits (`wake_head`), a print longer than the ring
    copies in pieces and holds the stream.
  - `agc_output_open` (from `main`, after `agc_input_open`) reopens a pipe, FIFO
    or terminal through `agc_fd_reopen` (`/proc/self/fd/N`, `O_NONBLOCK`), or
    duplicates a socket (`F_DUPFD_CLOEXEC`, `send` with `MSG_DONTWAIT`; on macOS
    every write is first guarded by `poll` and cut to `PIPE_BUF` or
    `SO_SNDLOWAT`), and writes it from an `agc_poller` (one `external` detached
    job per writable event, the request holds the stream index)
  - it drains a regular file, a block device or a device epoll refuses
    (`/dev/null`) by one pool job on the original descriptor
  - and it leaves the others (read-only descriptor, failed reopen or `dup`,
    non-Linux) on the blocking `fwrite` of their `FILE`.
  - When stderr is the same file as stdout (`st_dev`, `st_ino`), `err.base`
    points to the stdout stream and they share one ring and FIFO.
  - A write error sets `failed`, drops the data and the notices, and wakes the
    waiters
  - `agc_output_leave` (from `unlink_task`) takes a cancelled waiter out
  - `agc_output_busy` keeps `flushing()` in `vm/loop.c` waiting while a buffer
    holds data (it pumps queued notices with force and kicks the writer, since
    no task runs any more to finish a cut print), and once a stop signal is set
    it makes one non-blocking write per stream and stops waiting.
  - `advance` always ends with `kick`.
  - The poller's per-event jobs are quiet (`AGC_JOB_QUIET`)
  - the trace has `output_start` and `output_done` lines per run of data.
  - `agc_notice_begin` and `agc_notice_end` (mode `AGC_NOTICE_QUEUED`,
    `AGC_NOTICE_KEPT` or `AGC_NOTICE_FINAL`) write the text of the VM itself:
    queued notices (task crash diagnostics, the unobserved summary) join a queue
    of at most 1 MiB
  - a kept notice (the diagnostic of a failed run) is queued even when the queue
    is at its limit that enters the ring ahead of waiting writers, never inside
    a print that holds the stream
  - the diagnostic of a failed run is queued as a kept notice after the blocking
    streams are flushed and before the end-of-run wait (`announce_outcome` in
    `vm/launch.c`), and final notices (the flush warnings, the flush-timeout
    warning, a write-error diagnostic) are written after it with non-blocking
    writes, and the rest a stuck pipe will not take is dropped

## Design notes

- **libuv (7h, in: loop, files and tasks)**
  - `docs/vm/10-io-scheduler.md` §10.2.2 describes the loop with its run queue
  - only the scheduler (`vm/task.c`, through `agc_io_poll`) calls `uv_run`, and
    libuv callbacks only set flags (tasks will also queue the task).
  - N=1 today
  - the design target (`docs/vm/16-architecture.md` §16, rules per thread in
    `docs/vm/10-io-multicore.md` §10.2.3, gated in the roadmap order on the
    server measurement, decided right after it) is N scheduler threads that pull
    from one global run queue and one I/O thread, the main thread, with the only
    libuv loop, built on split structures (read-only runtime; global run queue;
    the loop and its inbox on the I/O thread, and the registry there or shared
    under a lock, which is open in §16.11; per-scheduler turn counter; per-task
    stack, registers and frame).
  - Once tasks land, a builtin or opcode whose work grows with its input sets a
    turn cost (`docs/vm/10-io-scheduler.md` §10.2.1, Builtins)
  - it is taken from the turn only, never from `steps_left`, so it never changes
    how `--max-steps` stops a program.
  - Only the thread that owns the loop calls `uv_run` on it (the scheduler with
    N=1, the I/O thread with N>1).
  - New code adds no mutable `static` or global variable in `vm/` (the
    exceptions are listed in `docs/vm/10-io-multicore.md` §10.2.3)
  - state goes in the runtime, scheduler or task struct, and lazy init uses
    `pthread_once` or runs at start-up.
  - Handles and requests are `malloc`'d and must stay owned until their
    `uv_close` callback: either the GC object that owns one stays in its
    scheduler's resource registry until then, or the `malloc`'d native state
    counts its pending close callbacks (and its users) and frees itself only
    when both reach zero.
  - With such a count, `close` may unregister the resource at once, as
    `Process.close` and `TCP.close` do: the native state outlives the handle.
  - The VM's own exit path frees nothing (`_exit`)
  - `agc_io_close`, for the in-process harnesses, runs `uv_run` NOWAIT so the
    callbacks still fire there.
  - Request buffers stay owned by the request until its callback.
  - All handles and descriptors are non-inheritable.
- **Limits**: the 1 MiB per-call reads, HTTP framing limits and the other
  caps in the `docs/vm/10-io-processes.md` limits table stay as documented.

## Gotchas

- Stdout and stderr: `vm/output.c` writes them, with one exception:
  `vm/process.c` forwards the stderr of a child process (`Process.spawn`) to
  `err.file` with a blocking `fwrite` in its read callback. That text is not in
  the buffer or in the order of the calls, and it can block the loop when stderr
  is stuck. `agc_vm_init` leaves
  both on the blocking `FILE *` it was given (`base` is null), so the C tests
and
  the fuzzer never depend on the loop; `agc_launch_vm` (`vm/launch.c`) calls
`agc_output_open`
  after `agc_input_open`. Never `fwrite` to `vm->rt->out.file` or
  `err.file` from builtin code: use `agc_write`, which parks the task and
  expects to be run again, so a builtin must work out its text before the
  call (and pass no text when `agc_output_waiting` says its text already waits)
  and not touch state after it that a second run would repeat. Text the
  VM itself prints goes through `agc_notice_begin` and `agc_notice_end`.
- Stdin and arguments: only `vm/input.c` reads fd 0; `agc_vm_init` leaves
  the input closed (`fd = -1`, always EOF) and `System.args` empty, and
  `agc_launch_vm` opens fd 0 (not for the front end of the single binary, which
reads nothing) and fills `vm->rt->args`, so the C tests and the
  fuzzer never block on stdin. Stdin text decodes each invalid byte to
  U+FFFD (Racket ports); arguments decode each invalid byte to `?` and an
  incomplete sequence at the end to one `?` (Racket in a UTF-8 locale,
  through glibc `iconv`); the diff test checks this with `LC_ALL=C.UTF-8`.
  The driver copies a non-file stdin into the VM with a thread that
  it kills once the VM exits.

## Native Windows files

`files.c` shares validation, buffers, task ownership and pool deadlines with
Unix. `file_io.c` owns the synchronous libuv calls and `file_windows.c` owns
native path conversion. Do not put `uv.h` or Win32 headers in the driver to
reach these operations. Regular files use binary descriptors and UTF-8 paths;
`Path.resolve` preserves drive and UNC roots and normalizes separators.

Windows locks use non-blocking `LockFileEx` over the whole file: unlike Unix
advisory `flock`, this also prevents other handles from reading or writing the
locked range. `file_state.locked` makes repeat calls on the same handle succeed
without locking the range again. Only `ERROR_LOCK_VIOLATION` becomes `EAGAIN`
(contention); access denied and other failures remain errors. The C builtin
tests and portable bootstrap smoke cover read-handle locking, repeat calls,
contention and close/reacquire.

Windows `Path.remove` uses handle-relative no-follow traversal; raw path
validation precedes normalization. Destructive tests require the scratch
harness. `Path.rename` uses `MoveFileExW` with no replace/copy flags.
Windows special file streams remain separate work.

`vm/tests/files_test.c` exercises real builtin calls without needing a
self-hosted compiler: text and all-byte round trips, append/flush/close,
Unicode paths, invalid writes that leave data intact, Windows path roots and
Windows lock exclusion. All native `vm-test` jobs run it.

New filesystem adapter files and headers belong in the explicit lists of
`vm/tools/check-layers.sh`. Keep `file_io.h` forbidden to core files, keep
adapters independent of VM values, and run `make vm-layers` including its
planted-violation self-tests before pushing changes to these boundaries.

`System.env` and `System.pid` live in `vm/system.c`, independent of process
spawning. Environment lookup uses libuv's native UTF-8 implementation, keeps
empty values, rejects NUL and `=`, and hides the private channel marker
(case-insensitively on Windows). `vm/tests/system_test.c` runs on all hosts.

Bytecode file reads are opened by `file_io.c` and consumed in `launch.c`;
`agentica.c` contains no native file APIs. Windows private creates and
directories use a protected owner-only DACL. Private handoff checks the owner,
DACL, regular type and single link on the opened handle before marking that
same handle for deletion. Failed checks preserve the file. Native Windows
handoff deletion tests run only when `CI` is set, in test-owned directories.
