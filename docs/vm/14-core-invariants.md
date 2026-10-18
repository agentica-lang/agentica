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
([`10-io-http.md`](10-io-http.md)) and §37.

### 14.1 Waiting

**Rule.** A task waits only by parking: on a job (`agc_io_start`, the task's
`parked`), or on a list the scheduler owns (a handle's lock FIFO, a task's
awaiters, the stdin waiters `rt->in.waiters`, the output waiters
`rt->out.waiters` and `rt->err.waiters`). Nothing else blocks. The loop thread
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

- **Windows stdin.** Every stdin kind uses one blocking `_read` in the pool
  because the Unix poller setup cannot watch Windows console handles. At most
  one read is in flight, shared by all readers; it can occupy one pool thread
  indefinitely. Timers and stop signals still run on the loop. Cancelling a
  reader detaches the job rather than interrupting the OS read. Process exit
  does not wait for it, but an in-process harness must supply data or EOF before
  it can close the loop. This is a portability exception, not a pattern for
  other I/O (§10.2.2, Stdin). With `UV_THREADPOOL_SIZE=1`, a pending stdin read
  leaves no worker for file I/O; keep spare pool capacity when stdin may wait.
- **Fallbacks that still use a pool thread.** stdin stays a pool job with a
  blocking read when it cannot be made non-blocking: the reopen through
  `/proc/self/fd/N` fails (no `/proc`, or `EACCES` after `su` or `sudo -u`), a
  socket's `F_DUPFD` fails, the poller cannot be made, or stdin is write-only. A
  regular file whose read can block (`/proc/kmsg`, some `/sys` files) goes to
  the pool, and that read keeps one pool thread until it returns. A regular file
  that reports size 0 (`/proc`, `/sys`) is read to EOF, at most 1 MiB.
- **stdout and stderr fallbacks.** `puts`, `print`, `IO.inspect` and `IO.warn`
  copy into a buffer and wait in a FIFO on the loop (row 7.2.1f, §10.2.2). A
  pipe, FIFO or terminal is reopened through `/proc/self/fd/N`, a socket is
  duplicated, and both are written when the poller says they are writable; a
  regular file or a device epoll refuses is drained by a pool job. A stream
  keeps the blocking `fwrite` of its `FILE *` only when it cannot be put on the
  loop: the reopen or the `dup` fails (no `/proc`, or `EACCES`), the descriptor
  is not open for writing (a closed stdout that `main` refilled with
  `/dev/null`), it is another descriptor type, or the build is not Linux. A full
  pipe then stalls every task, a stop signal interrupts the write (`EINTR`, no
  `SA_RESTART`) and ends the run (§14.4), and the final `fflush` is not bounded
  by the flush limit. The stderr that a child process writes is forwarded by a
  blocking `fwrite` too (`vm/process.c`), not through the buffer: the one write
  outside `vm/output.c`, and it can block the loop on a stuck stderr. With N > 1
  they are locked per stream (§16.8).
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
- **Stdout and stderr on one target.** When both descriptors are the same file
  (`st_dev` and `st_ino`: a terminal, `2>&1`), they share one buffer and one
  FIFO, so `puts`, `IO.warn` and `puts` appear in the order of the calls.

### 14.2 Timeouts

**Rule.** One way: a timer on the job. A builtin that takes `timeout_ms` passes
it to `agc_io_start`, whose job owns one `uv_timer_t` (`start_job` in
`vm/loop.c`). When it fires, the job ends with the timeout error and the task
wakes. No builtin starts its own timer for a timeout.

`Task.sleep` is a job with no work and a timer. `agc_io_extend` (20c) restarts a
job's own timer once, so `HttpWire.read_request`'s deadline runs from the
request's first byte. It is the same timer, not a second one. As built, a few
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
`vm/tests/task_cancel_test.c` in the same PR. A crash (§37.6) and `Test.run`'s
leftovers (§36.6) cancel through it. Nothing else cancels a wait. A timer, a
job's completion and a crash also unlink a task, but they end a wait; they do
not cancel one.

A cancelled job is detached (`agc_io_detach`). A loop job is stopped by its
`cancel` half. A pool job runs to its end, which §14.1 keeps bounded except for
its explicit stdin exceptions. A pool job that goes on to wait on the loop
(`agc_io_start_then`, a whole-file call on a
FIFO) is cancelled only in that loop phase: `cancellable` in `vm/loop.c` calls
the `cancel` half only for a job with no `work`, or one past it (`on_loop`). A
pool kind with a `cancel` half that is started with no `more` step is
`RUNTIME-INTERNAL` when it starts (`start_job`), never later in a cancel.
`vm/tests/task_cancel_test.c` covers both phases. A task parked in the FIFO of
stdout or stderr leaves it (`agc_output_leave`, called from `unlink_task`), and
the next writer is woken if its text now fits; the test cancels the head of a
full buffer's FIFO.

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
always explicit, through one hand-off form, `Task.spawn_owning` (§37.5): it
gives a handle the caller owns to the task it spawns, in the same call.
`HttpWire.spawn` (20c, §10.7.2) is the same hand-off into the server's task
group, through the one port function `agc_task_spawn_owning`; it has no group
registration of its own. Ownership decides who closes a handle, not who may use
it. Other tasks still use a shared handle (§37.5, "Shared handles"), and
`HttpClient` stays exempt (§37.5). Planned (phase 9,
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
not waited for. A server owns its listener: `HttpWire.server` takes the listener
off its owner's list, so ending the server's owner closes both and a hand-off
moves both. `Task.spawn_owning` fails with `RUNTIME-HANDLE-NOT-OWNED` when the
caller does not own the handle or it is closed, before it makes a task.

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

- **Item:** Multicore schedulers (gated, §16 and §10.2.3)
  - **Question:** Gated on the numbers of step 9 (and the 6c pilot of step
    7.2.2). If built: schedulers that pull from one global run queue, and one
    I/O thread with the only loop. Each rule above must still hold as §16.6 maps
    it, with one exit path for the process (`end_run` on the I/O thread).

- **Item:** K I/O threads, local run queues with work stealing (§16.10)
  - **Question:** Only if measurements ask. Does the model of §16 stop being
    enough, and does the change keep one way to wake a task and one place for
    each handle?
