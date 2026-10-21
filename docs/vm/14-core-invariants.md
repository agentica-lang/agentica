## 14. VM core invariants

The VM core is the scheduler, the loop and the runtime under them (`vm/task.c`,
`vm/loop.c`, `vm/input.c`, `vm/files.c`, `vm/process.c`, `vm/tcp.c`, and the
HTTP and TLS code on top). It must stay small enough for one person to hold in
their head. A blocked `read()` on a thread-pool thread once hung the VM at exit:
the exit path joined the pool, and the pool waited for a FIFO that never wrote.
The rule is **one way for each job**. A reviewer checks every core PR against
14.1 to 14.5 and the entry rule of 14.6. A PR that breaks one either changes the
rule here first, with the reason, or does not merge.

Each rule says what is **as built** today and what is **being built** or is a
**target**. The mechanisms are in §10.2.1 and §10.2.2
([`10-io-scheduler.md`](10-io-scheduler.md)), §10.4
([`10-io-processes.md`](10-io-processes.md)), §10.7.2
([`10-io-http.md`](10-io-http.md)) and [task rules][task-rules].

### 14.1 Waiting

**Rule.** A task waits only by parking: on a job (`agc_io_start`, the task's
`parked`), on a list the scheduler owns (a handle's lock FIFO, a task's
awaiters, the stdin waiters `rt->in.waiters`, the output waiters
`rt->out.waiters` and `rt->err.waiters`), or in its scheduler's timer heap
(`agc_task_park_until`, `vm/timers.c`), alone or next to one of those lists.
Nothing else blocks. The loop thread
never blocks on a descriptor. Every wait has an exit that `agc_task_cancel`
knows (§14.3).

- **Regular files** (and directories) use the libuv thread pool, since a read or
  write on them ends in bounded time. The other bounded pool work is DNS
  (`getaddrinfo`) and the TLS setup jobs that load CA, certificate and key files
  (§10.2.2, pool size). As built.
- **Pipes, FIFOs, terminals, sockets and other character devices that can wait**
  are non-blocking on the loop (`uv_pipe_t`, `uv_tcp_t` or a poll handle,
  `agc_poller` in `vm/loop.c`), never a pool job: a pool thread that waits
  forever cannot be cancelled or joined. As built: sockets (`vm/tcp.c`), process
  pipes (`vm/process.c`), stdin (`vm/input.c`), stdout and stderr
  (`vm/output.c`) and the `File` calls (`vm/files.c`).
- A descriptor picks one of the two by what it is, never by how it was named.
  `vm/files.c` opens with `O_NONBLOCK`, then `fstat` (regular files, block
  devices and directories go to the pool) and an `epoll_ctl` probe. Only `EPERM`
  from the probe means "never waits" (`/dev/null`, `/dev/zero`), and those go to
  the pool and are set blocking. Any other probe error, or a poll handle that
  cannot be made, is the call's error, never a silent fall back to the pool. A
  whole-file call (`read_text`, `write_text`) opens in the pool, then waits on
  the loop (`agc_io_start_then`).

Known exceptions, as built:

- **Windows `File` calls.** `probe` in `vm/files.c` returns `ENOTSUP` for
  anything that is not a regular file, a block device or a directory, and
  `path_string` refuses the `\\.\`, `\\?\` and `//./` spellings. So a named
  pipe or a device is refused at once and its handle closed: no `File` call
  waits on a stream there. The streams that wait reach the VM as sockets,
  process pipes and the standard streams (see #474).
- **Windows stdin.** The Unix poller cannot watch Windows console handles, so
  every stdin kind is read by one blocking `_read` on a thread of the VM's own,
  not in the pool; the task waits on the loop for the read's job, which an async
  handle ends. At most one read is in flight, shared by all readers. Cancelling
  a reader detaches the job rather than interrupting the OS read. This is a
  portability exception, not a pattern for other I/O (§10.2.2, Stdin).
- **Windows stdout and stderr.** A pipe is written by a libuv pipe handle, one
  write request at a time; a console, and a handle that libuv refuses, by a pool
  job, so the loop never waits for the reader (a console is not written by
  `uv_tty_t`, because libuv writes it on the loop thread). A pool job keeps one
  pool thread while the reader is slow. Windows has no non-blocking try on a
  pipe or a console, so a stop signal and the final notices wait for the request
  instead, in one wait of up to 200 ms that the exit shares (§10.2.2). The
  normal end of the run waits only within the flush limit.
- **Fallbacks that still use a pool thread.** stdin stays a pool job with a
  blocking read when it cannot be made non-blocking: the reopen through
  `/proc/self/fd/N` fails (no `/proc`, or `EACCES` after `su` or `sudo -u`), a
  socket's `F_DUPFD` fails, the poller cannot be made, or stdin is write-only. A
  regular file whose read can block (`/proc/kmsg`, some `/sys` files) goes to
  the pool, and that read keeps one pool thread until it returns. A regular file
  that reports size 0 (`/proc`, `/sys`) is read to EOF, at most 1 MiB.
- **stdout and stderr fallbacks.** `puts`, `print`, `IO.inspect` and `IO.warn`
- **stdout and stderr fallbacks.** `puts`, `print`, `IO.inspect` and `IO.warn`
  copy into a buffer and wait in a FIFO on the loop (row 7.2.1f, §10.2.2). A
  pipe, FIFO or terminal is reopened through `/proc/self/fd/N`, a socket is
  duplicated, and both are written when the poller says they are writable; a
  regular file or a device epoll refuses is drained by a pool job. The stderr
  that a child process writes goes through the same buffer
  (`agc_output_forward`, behind the queued notices); past 64 KiB queued, the VM
  stops reading the child's stderr until the queue is back to 32 KiB, so the
  child waits on its pipe, not the loop. A stream keeps the blocking `fwrite` of
  its `FILE *` only when it cannot be put on the loop: the reopen or the `dup`
  fails (no `/proc`, or `EACCES`), the descriptor is not open for writing (a
  closed stdout that `main` refilled with `/dev/null`), it is another
  descriptor type, or the build is not Linux, macOS or Windows. A full pipe then
  stalls every task, a stop signal interrupts the write (`EINTR`, no
  `SA_RESTART`) and ends the run (§14.4), and the final `fflush` is not bounded
  by the flush limit; a child's stderr then takes the same blocking `fwrite`, on
  the I/O thread under the stream's lock. With N > 1 they are locked per stream
  (§16.8).
- **Notices (text the VM writes to stderr by itself).** A task crash diagnostic
  and the unobserved-task summary are queued (at most 1 MiB) and enter the
  stderr buffer ahead of waiting writers as room appears, in pieces if they are
  longer than the buffer, and never in the middle of a print that holds the
  stream, so they are neither lost to a full buffer nor placed inside a print.
  The diagnostic of a failed run is queued the same way (a kept notice, never
  dropped for the queue limit) after the blocking streams are flushed and before
  the end-of-run wait, so the wait and the flush limit cover it. The flush
  warnings and what is only known after the wait (the flush-timeout warning, a
  stdout or stderr write error) are written with non-blocking writes, and what a
  stuck pipe will not take is dropped, so the exit stays bounded and the exit
  code still reports the result (§10.2.2, Notices).
- **Release flush of a file handle.** When a file job is dropped before its
  pool work ran (its timeout, a cancel, or the flush limit at the end of the
  run), or a handle is released at the end of the run (`release_handles`),
  `release_state` in `vm/files.c` writes what the handle still buffers with one
  blocking write on the loop thread. Only a regular file or a device that never
  waits is written so (a polled descriptor is non-blocking), so the write ends in
  bounded time. Its size is bounded too: at most 4 KiB (`WRITE_BUFFER`) for a
  handle of `File.open`, and at most 64 KiB (`CHUNK`) for the handle of
  `Lazy.write_lines`, which batches its lines into one write job.
- **Stdout and stderr on one target.** When both descriptors are the same file
  (`st_dev` and `st_ino`: a terminal, `2>&1`; on Windows `CompareObjectHandles`,
  which matches only the same kernel object), they share one buffer and one
  FIFO, so `puts`, `IO.warn` and `puts` appear in the order of the calls.

### 14.2 Timeouts

**Rule.** Two ways, one per kind of wait.

- **An I/O job's deadline is its job's timer.** A builtin that takes
  `timeout_ms` for work or a wait on the loop passes it to `agc_io_start`, whose
  job owns one `uv_timer_t` (`start_job` in `vm/loop.c`). When it fires, the job
  ends with the timeout error and the task wakes. The timer lives with the job
  because the START request that the job pays anyway starts it, and the job's
  outcome decides between the timeout and the completion.
- **A wait with only a deadline is a task timer.** `Task.sleep`, the timed
  await, a channel deadline, `Task.map`'s oldest deadline and a handle lock's
  deadline arm the task's own timer (`agc_task_park_until`, `vm/timers.c`) in
  the scheduler's heap. Such a wait has no I/O, so it needs no job, no registry
  slot and no request to the I/O thread (§16.9, "Timers").

No builtin starts its own timer for a timeout. As built, a few
timers are not job timeouts and stay: a captured child's grace period (§10.4),
the `HttpClient` pool's idle timer, the end-of-run flush deadline (§14.4), and
the 3-second `alarm` of the stop signals (`STOP_GRACE_SECONDS` in `vm/loop.c`,
§10.2.2, Stop signals). The end-of-run wait for the children (`await_exits` in
`vm/process.c`, §14.4) is a bounded timer of the same kind. A new one needs a
reason here.

### 14.3 Cancelling

**Rule.** One way: `agc_task_cancel` (20b's core, §10.2.1, Cancellation). It
knows every place a task can park (§14.1) and takes the task out of each one. A
new kind of wait adds its case to `agc_task_cancel` and to
`vm/tests/task_cancel_test.c` in the same PR. A crash (cancellation),
`Test.run`'s leftovers (a test's tasks) and the public `Task.cancel` cancel
through it. Nothing else cancels a wait. A timer, a job's completion and a crash
also unlink a task, but they end a wait; they do not cancel one. `unlink_task`
takes a cancelled task out of every wait, its timer included
(`agc_timers_disarm`).

A task cancelled from another scheduler finishes its turn first (§10.2.3), after
the cancel walk over its descendants. A task it spawns in that turn starts
cancelled: the spawn reads the flag of the parent (or of the task that owns the
groups above it) under `rt->sync`, which the walk holds too, and ends the child
before it runs (`spawn_child` in `vm/task.c`, #392). A handle handed to the
child is moved first, so the child's end closes it. Cancel reaches every
descendant. An end hook set after the spawn (`Task.map`'s items,
`HttpWire.spawn`) may not run for such a child, which may have ended already; a
handed file's close can delay that end through `closing`. Its caller is
cancelled too, so nothing waits for the hook. A turn that fails with a
diagnostic that is not fatal in a task already cancelled (such as
`Task.await` of that child) ends the task as cancelled, not as a crash: a flag
set during the turn wins.

A cancelled job is detached (`agc_io_detach`). A loop job is stopped by its
`cancel` half. A wait that has taken nothing yet leaves its queue at once, on
the I/O thread: a `TCP.accept` leaves the listener's queue and a read leaves the
reader slot (`request_cancel` in `vm/tcp.c`, #403), as an HTTP server's waiter
does (`waiter_cancel`). The next connection then goes to a live accept, and the
bytes stay in the input for the next read, whose reader lock the job's end hands
on. A wait that has taken something keeps its result: its `done` half runs and
the result is dropped, so a served accept's socket is closed. A pool job runs to
its end, which §14.1 keeps bounded except for its explicit stdin exceptions. A
pool job that goes on to wait on the loop (`agc_io_start_then`, a whole-file
call on a FIFO) is cancelled only in that loop phase: `cancellable` in
`vm/loop.c` calls the `cancel` half only for a job with no `work`, or one past
it (`on_loop`). A pool kind with a `cancel` half that is started with no `more`
step is `RUNTIME-INTERNAL` when it starts (`start_job`), never later in a
cancel. `vm/tests/task_cancel_test.c` covers both phases. A task parked in the
FIFO of stdout or stderr leaves it (`agc_output_leave`, called from
`unlink_task`), and the next writer is woken if its text now fits; the test
cancels the head of a full buffer's FIFO.

### 14.4 Ending

**Rule.** One exit path. Every step of it is bounded, the file flush included.
The file flush has a limit that is always on, 30 seconds by default, set with
`--flush-timeout MS` or the environment variable `AGENTICA_FLUSH_TIMEOUT_MS`
(the flag wins), with no way to turn it off. The owner decided this on
2026-10-13 (row 7.2.1d, second part, done). At exit, stdout and stderr count as
part of the file flush. **When `main` ends, the program ends.** The steps are:

1. kill child processes (`close_children`, about 2 seconds at most, driving the
   loop for their exit callbacks, §10.4 Close);
2. flush stdout, stderr and open files (the file flush within the flush limit);
3. exit.

Nothing else is joined or drained: no task is awaited, no pool job other than
the file flush is waited for, no socket is read to its end. `System.exit` and a
crash of `main` take the same path. So does the first stop signal (SIGTERM,
SIGINT, SIGHUP), flush included; but after a stop signal the flush of stdout and
stderr is one non-blocking write per stream, because a reader that never reads
would otherwise hold the stopped VM for the whole flush limit. Files keep their
wait. A second stop signal exits at once without flushing, so a stuck flush (a
FIFO nobody reads, or a test child that gets `PR_SET_PDEATHSIG`'s SIGTERM,
`agc_launch_bind` in `vm/launch.c`) need not wait for the flush limit. A second
signal that comes before the children are stopped waits for step 1, so children
are never left behind.

As built (`agc_launch_settle` of `vm/launch.c`, §10.2.2 "End of run" and "Stop
signals"): `main`'s return, `System.exit`, a diagnostic, the step limit and the
first stop signal all reach `agc_launch_settle`. It kills the children, sends
one non-blocking TLS `close_notify` per finished TLS session (sockets and
`HttpClient` connections), flushes the blocking stdout and stderr, queues the
diagnostic of a failed run on stderr, closes the files and waits for their flush
jobs and for the output buffers of stdout and stderr (within the flush limit;
once a stop signal is set, one non-blocking write per stream and no more wait
for stdout and stderr), prints what is only known after the wait without
blocking (the flush-timeout warning, a write-error diagnostic; text that a stuck
stderr pipe will not take is dropped), and ends with `_exit`, or with the stop
signal raised again. A second stop signal before the children are stopped is
recorded and acted on right after, and an `alarm` bounds that at 3 seconds. A
driven VM whose driver is gone takes the immediate path on its first signal.
`agc_io_close` is only for the in-process harnesses and for the single binary,
which closes the front end's loop before it runs the program in a new runtime.
The Windows stdin reader thread (§14.1) is not joined: the close cancels its
read where Windows can, and a read it cannot cancel stays in `_read` and takes
the next input, so no later runtime in the process may read that descriptor.
Children are reaped by libuv's exit callback, never by `waitpid` or a sleep, and
step 1 runs the loop for the exits (§10.4 Close; row 7.2.1d, first part, done).
The streams on the loop drain inside the file flush, so the flush limit bounds
them; the blocking fallbacks of §14.1 are the only unbounded write left.

Known exceptions, outside the exit path: the out-of-memory and GC abort handlers
end with `_Exit(70)` and run none of these steps (§6.3), and `SIGKILL` runs none
either. Both leave children running.

### 14.5 Handles

**Rule (phase 24, 24b).** A handle (file, socket, listener, process, `std/http`
server) belongs to the task that opened it. A `Channel` has no opener: it is
unowned until `Task.spawn_owning` hands it to a task, which then owns it like
any other handle. If that task ends, in any way
(return, crash, cancel), without closing it, the handle is closed. There is one
close path: `finish_task` (`vm/task.c`) ends every task and closes the handles
it still owns through `agc_close_owned`. Handing a handle to another task is
always explicit, through one hand-off form, `Task.spawn_owning`
([handle ownership][task-rules]): it
gives a handle the caller owns to the task it spawns, in the same call.
`HttpWire.spawn` (20c, §10.7.2) is the same hand-off into the server's task
group, through the one port function `agc_task_spawn_owning`; it has no group
registration of its own. Ownership decides who closes a handle, not who may use
it. Other tasks still use a shared handle (handle ownership, "Shared
handles"), and
`HttpClient` stays exempt (handle ownership). Planned (phase 9,
[§13](../future/13-ats.md)): a `Table` is exempt too. It is not an OS resource,
so no task owns it, and a task's end never closes it.

As built, the owner is a field of the resource (`agc_own` in `vm/loop.c`), and
each task keeps the list of the handles it owns, so a task's end costs the
number of its handles, not the size of the registry. `Task.spawn` moves nothing,
and nothing is given back to the parent when a task returns, so a handle opened
in a helper task and returned through `Task.await` is closed when the helper
ends. A cancelled task's handles are closed too, including a task parked in a
stepper (`File.each_line`), a handler that `close_server` cancels, the leftovers
of `Test.run`, and an `HttpServer` whose owner is cancelled, which frees its
port. A closed handle leaves its owner's list (`agc_unregister`). The close of a
regular file is a pool job, and the ending task's awaiters wait for it, so what
a helper wrote to a regular file is on disk when the parent's await returns. A
flush to a FIFO or a pipe, and a close behind any job that holds the file, are
not waited for. When the end of a task is observed (its `Task.await` returns, or
`Task.map` takes its result into a slot), the handles it owned and those of the
descendants that its crash or cancel reached are closed: a socket, listener,
process or server is marked closed under `rt->sync`, and at N > 1 its close step
reaches the I/O thread before any step that the observer posts (#402). A
timed-out item is not observed this way: its slot is written at its deadline,
before it or its descendants close anything. A cancelled descendant that is
still on a turn on another scheduler ends at the end of that turn, and until
then it holds the task that the cancel reached it through (`hold` in
`vm/task.c`, a count in `closing`). One that an earlier cancel holds already
(it moved up when its holder ended) is counted through the top of its holder
chain. A server owns its listener:
`HttpWire.server` takes the listener off its owner's list, so ending the
server's owner closes both and a hand-off moves both. `Task.spawn_owning` fails
with `RUNTIME-HANDLE-NOT-OWNED` when the caller does not own the handle or it is
closed, before it makes a task.

A channel is the one handle that is made unowned. `Channel.new` makes no
registry entry. The first `Task.spawn_owning` of the channel (any task may do
it) registers an entry with no native object, whose close function is the
channel's own close (`vm/channel.c`), and gives it to the new task. When that
task ends, `agc_close_owned` runs it: the channel closes as `Channel.close`
does (parked senders wake with the closed error, readers drain, then get it),
and the entry is dropped. `Channel.close` from any task drops the entry too, so
an owner's later end does nothing, and a closed channel cannot be handed over.
A channel owned by another task is `RUNTIME-HANDLE-NOT-OWNED` for the caller,
as any owned handle. A channel that was never handed over is closed only by
`Channel.close`.

### 14.6 Entry rule for the core

- No new subsystem in `vm/` without a demonstrated use case: a program that
  needs it and cannot be written well without it.
- Prefer Agentica code first (`std/`, the roadmap's "`std/` first" rule), then a
  separate process. C in the core is the last choice.
- Each new core concept replaces something, or justifies itself against §14.1 to
  §14.5: how it waits, times out, is cancelled, ends and owns its handles. If it
  needs a second way for any of them, it does not go in.

Items in the plan to re-check with this rule before they start:

- **Item:** VM metrics (phase 18, §28)
  - **Question:** It adds a metrics thread and hooks in the core. Could a dump
    at exit, or an outside reader of the VM's state, do the job? 18d adds one
    add on the allocation path while nobody asks (§28.12): it must pass the
    overhead check or change rule 4 of §28.2 first.

- **Item:** VM layers (7l in [`07-vm.md`](../roadmap/07-vm.md#7l-vm-layers);
  its first part is row 7.2.1b, §15)
  - **Question:** Does each layer replace code, or only add a boundary? (§15
    answers for the first part.)

- **Item:** JIT (7m, §22)
  - **Question:** Required by the roadmap; it must keep the same five rules and
    add no runtime of its own.

- **Item:** Multicore schedulers (in progress, §16 and §10.2.3)
  - **Question:** Started by the owner's decision of 2026-10-19: schedulers
    that pull from one global run queue, and one I/O thread with the only loop.
    Each rule above must still hold as §16.6 maps it, with one exit path for
    the process (`end_run` on the I/O thread).

- **Item:** K I/O threads, local run queues with work stealing (§16.10)
  - **Question:** Only if measurements ask. Does the model of §16 stop being
    enough, and does the change keep one way to wake a task and one place for
    each handle?

[task-rules]: ../grammar/06c-tasks-and-tests.md#lightweight-tasks
