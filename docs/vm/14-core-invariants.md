## 14. VM core invariants

The VM core is the scheduler, the loop and the runtime under them (`vm/task.c`, `vm/loop.c`, `vm/input.c`, `vm/files.c`, `vm/process.c`, `vm/tcp.c`, and the HTTP and TLS code on top). It must stay small enough for one person to hold in their head. A blocked `read()` on a thread-pool thread once hung the VM at exit: the exit path joined the pool, and the pool waited for a FIFO that never wrote. The rule is **one way for each job**. A reviewer checks every core PR against 14.1 to 14.5 and the entry rule of 14.6. A PR that breaks one either changes the rule here first, with the reason, or does not merge.

Each rule says what is **as built** today and what is **being built** or is a **target**. The mechanisms are in §10.2.1 and §10.2.2 ([`10-io-scheduler.md`](10-io-scheduler.md)), §10.4 ([`10-io-processes.md`](10-io-processes.md)), §10.7.2 ([`10-io-http.md`](10-io-http.md)) and §37.

### 14.1 Waiting

**Rule.** A task waits only by parking: on a job (`agc_io_start`, the task's `parked`), or on a list the scheduler owns (a handle's lock FIFO, a task's awaiters, the stdin waiters `rt->in.waiters`). Nothing else blocks. The loop thread never blocks on a descriptor. Every wait has an exit that `agc_task_cancel` knows (§14.3).

- **Regular files** (and directories) use the libuv thread pool, since a read or write on them ends in bounded time. The other bounded pool work is DNS (`getaddrinfo`) and the TLS setup jobs that load CA, certificate and key files (§10.2.2, pool size). As built.
- **Pipes, FIFOs, terminals, sockets and other character devices that can wait** are non-blocking on the loop (`uv_pipe_t`, `uv_tcp_t` or a poll handle, `agc_poller` in `vm/loop.c`), never a pool job: a pool thread that waits forever cannot be cancelled or joined. As built: sockets (`vm/tcp.c`), process pipes (`vm/process.c`), stdin (`vm/input.c`) and the `File` calls (`vm/files.c`).
- A descriptor picks one of the two by what it is, never by how it was named. `vm/files.c` opens with `O_NONBLOCK`, then `fstat` (regular files, block devices and directories go to the pool) and an `epoll_ctl` probe. Only `EPERM` from the probe means "never waits" (`/dev/null`, `/dev/zero`), and those go to the pool and are set blocking. Any other probe error, or a poll handle that cannot be made, is the call's error, never a silent fall back to the pool. A whole-file call (`read_text`, `write_text`) opens in the pool, then waits on the loop (`agc_io_start_then`).

Known exceptions, as built:

- **Fallbacks that still use a pool thread.** stdin stays a pool job with a blocking read when it cannot be made non-blocking: the reopen through `/proc/self/fd/N` fails (no `/proc`, or `EACCES` after `su` or `sudo -u`), a socket's `F_DUPFD` fails, the poller cannot be made, or stdin is write-only. A regular file whose read can block (`/proc/kmsg`, some `/sys` files) goes to the pool, and that read keeps one pool thread until it returns. A regular file that reports size 0 (`/proc`, `/sys`) is read to EOF, at most 1 MiB.
- **stdout and stderr writes block.** `puts`, `print`, `IO.inspect` and `IO.warn` write through `agc_write` to a blocking `FILE *` (`vm/interp.c`), so a full stdout pipe stalls every task. Decided by the owner on 2026-10-13: they move onto the loop later, on top of the parking mechanism of channels (17b), as roadmap row 7.2.1f. A stop signal interrupts such a write (`EINTR`, no `SA_RESTART`) and ends the run (§14.4). With N > 1 they are locked per stream (§16.8).

### 14.2 Timeouts

**Rule.** One way: a timer on the job. A builtin that takes `timeout_ms` passes it to `agc_io_start`, whose job owns one `uv_timer_t` (`start_job` in `vm/loop.c`). When it fires, the job ends with the timeout error and the task wakes. No builtin starts its own timer for a timeout.

`Task.sleep` is a job with no work and a timer. `agc_io_extend` (20c) restarts a job's own timer once, so `HttpWire.read_request`'s deadline runs from the request's first byte. It is the same timer, not a second one. As built, a few timers are not job timeouts and stay: a captured child's grace period (§10.4), the `HttpClient` pool's idle timer, the end-of-run flush deadline (§14.4), and the 3-second `alarm` of the stop signals (`STOP_GRACE_SECONDS` in `vm/loop.c`, §10.2.2, Stop signals). The end-of-run wait for the children (`await_exits` in `vm/process.c`, §14.4) is a bounded timer of the same kind. A new one needs a reason here.

### 14.3 Cancelling

**Rule.** One way: `agc_task_cancel` (20b's core, §10.2.1, Cancellation). It knows every place a task can park (§14.1) and takes the task out of each one. A new kind of wait adds its case to `agc_task_cancel` and to `vm/tests/task_cancel_test.c` in the same PR. A crash (§37.6) and `Test.run`'s leftovers (§36.6) cancel through it. Nothing else cancels a wait. A timer, a job's completion and a crash also unlink a task, but they end a wait; they do not cancel one.

A cancelled job is detached (`agc_io_detach`). A loop job is stopped by its `cancel` half. A pool job runs to its end, which §14.1 keeps bounded. A pool job that goes on to wait on the loop (`agc_io_start_then`, a whole-file call on a FIFO) is cancelled only in that loop phase: `cancellable` in `vm/loop.c` calls the `cancel` half only for a job with no `work`, or one past it (`on_loop`). A pool kind with a `cancel` half that is started with no `more` step is `RUNTIME-INTERNAL` when it starts (`start_job`), never later in a cancel. `vm/tests/task_cancel_test.c` covers both phases.

### 14.4 Ending

**Rule.** One exit path. Every step of it is bounded, the file flush included. Target (row 7.2.1d, second part): the file flush has a limit that is always on, 30 seconds by default, set with `--flush-timeout MS` or an environment variable (for example `AGENTICA_FLUSH_TIMEOUT_MS`), with no way to turn it off. The owner decided this on 2026-10-13. At exit, stdout and stderr count as part of the file flush. **When `main` ends, the program ends.** The steps are:

1. kill child processes (`close_children`, about 2 seconds at most, driving the loop for their exit callbacks, §10.4 Close);
2. flush stdout, stderr and open files (the file flush within the flush limit);
3. exit.

Nothing else is joined or drained: no task is awaited, no pool job other than the file flush is waited for, no socket is read to its end. `System.exit` and a crash of `main` take the same path. So does the first stop signal (SIGTERM, SIGINT, SIGHUP), flush included. A second stop signal exits at once without flushing, so a flush that cannot end (a FIFO nobody reads, or a test child that gets `PR_SET_PDEATHSIG`'s SIGTERM, `vm/main.c`) never makes the VM unkillable. A second signal that comes before the children are stopped waits for step 1, so children are never left behind.

As built (`end_run` in `vm/main.c`, §10.2.2 "End of run" and "Stop signals"): `main`'s return, `System.exit`, a diagnostic, the step limit and the first stop signal all reach `end_run`. It kills the children, sends one non-blocking TLS `close_notify` per finished TLS session (sockets and `HttpClient` connections), flushes stdout and stderr, closes the files and waits for their flush jobs, prints the diagnostic or summary, and ends with `_exit`, or with the stop signal raised again. A second stop signal before the children are stopped is recorded and acted on right after, and an `alarm` bounds that at 3 seconds. A driven VM whose driver is gone takes the immediate path on its first signal. `agc_io_close` is only for the in-process harnesses. Children are reaped by libuv's exit callback, never by `waitpid` or a sleep, and step 1 runs the loop for the exits (§10.4 Close; row 7.2.1d, first part, done). Where this differs from the rule (targets):

- The file flush has no limit unless `--flush-timeout` is given. The target is the always-on limit above (row 7.2.1d, second part).
- The `fflush` of stdout and stderr is not bounded by the flush limit.

Known exceptions, outside the exit path: the out-of-memory and GC abort handlers end with `_Exit(70)` and run none of these steps (§6.3), and `SIGKILL` runs none either. Both leave children running.

### 14.5 Handles

**Target rule.** A handle (file, socket, listener, process) belongs to the task that opened it. If that task ends, in any way (return, crash, cancel), without closing it, the handle is closed. Handing it to another task is always explicit, through one hand-off form. `HttpWire.spawn`'s group registration (20c, §10.7.2) is one use of that form, not a second mechanism. Ownership decides who closes a handle, not who may use it. Other tasks still use a shared handle (§37.5, "Shared handles"), and `HttpClient` stays exempt (§37.5).

As built (phase 24, §37.5 and §10.2.1 "Owners"), three more rules apply. A handle passed directly as the `Task.spawn` argument moves to the new task when the caller owns it (`builtin_spawn` in `vm/task.c`). When a task ends normally, the handles it still owns go to its parent (`agc_give_owned`), and only a crash closes them (`agc_close_owned`). A cancelled task's handles are neither given back nor closed (`end_cancelled` in `vm/task.c`), so they stay open until the end of the run, except under `close_server`. `HttpWire.spawn` (20c) moves each connection's socket to its connection task, whose end hook closes it when that task ends in any way, and `close_server` drops the group, which closes every handle the group's subtree owns. A server whose owner is cancelled rather than crashed stays open, its port bound, until the run ends. 24b's close on cancel fixes that. Replacing all of these with the target rule is planned after HTTP 20c ([phase 24, 24b](../roadmap/24-task-crash-isolation.md)). Closing on cancel is a behavior change too (`Test.run`'s leftovers, cancelled handlers).

### 14.6 Entry rule for the core

- No new subsystem in `vm/` without a demonstrated use case: a program that needs it and cannot be written well without it.
- Prefer Agentica code first (`std/`, the roadmap's "`std/` first" rule), then a separate process. C in the core is the last choice.
- Each new core concept replaces something, or justifies itself against §14.1 to §14.5: how it waits, times out, is cancelled, ends and owns its handles. If it needs a second way for any of them, it does not go in.

Items in the plan to re-check with this rule before they start:

| Item | Question |
|---|---|
| VM metrics (phase 18, §28) | It adds a metrics thread and hooks in the core. Could a dump at exit, or an outside reader of the VM's state, do the job? 18d adds one add on the allocation path while nobody asks (§28.12): it must pass the overhead check or change rule 4 of §28.2 first. |
| VM layers (7l, §21; its first part is row 7.2.1b, §15) | Does each layer replace code, or only add a boundary? (§15 answers for the first part.) |
| JIT (7m, §22) | Required by the roadmap; it must keep the same five rules and add no runtime of its own. |
| Multicore schedulers (gated, §16 and §10.2.3) | Gated on the numbers of steps 9 and 10. If built: schedulers that pull from one global run queue, and one I/O thread with the only loop. Each rule above must still hold as §16.6 maps it, with one exit path for the process (`end_run` on the I/O thread). |
| K I/O threads, local run queues with work stealing (§16.10) | Only if measurements ask. Does the model of §16 stop being enough, and does the change keep one way to wake a task and one place for each handle? |
