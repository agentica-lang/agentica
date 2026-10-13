## 14. VM core invariants

The VM core is the scheduler, the loop and the runtime under them (`vm/task.c`, `vm/loop.c`, `vm/input.c`, `vm/files.c`, `vm/process.c`, `vm/tcp.c` and the HTTP and TLS code on top). It must stay small enough that one person can hold it in their head. A blocked `read()` on a thread-pool thread once made the VM hang at exit: the exit path joined the pool, and the pool waited for a FIFO that never wrote. This section is the answer: **one way for each job**. A reviewer checks every core PR against these rules. A PR that breaks one either changes the rule here first, with the reason, or does not merge.

Each rule says what is **as built** today and what is **being built** or is a **target**. The details stay in §10.2.1 and §10.2.2 ([`10-io-scheduler.md`](10-io-scheduler.md)), §10.4 ([`10-io-tls-processes-http.md`](10-io-tls-processes-http.md)), §30.6 and §37.

### 14.1 Waiting

**Rule.** A task waits only by parking: on a job (`agc_io_start`, the task's `parked`), or on a list the scheduler owns (a handle's lock FIFO, a task's awaiters, the stdin waiters `rt->in.waiters`). Nothing else blocks. The loop thread never blocks on a descriptor, and we only wait where the loop can cancel: every wait has an exit that `agc_task_cancel` knows (§14.3).

- **Regular files** (and directories) use the libuv thread pool. A read or write on a regular file ends in bounded time, so a pool thread is safe there. The other bounded pool work allowed is DNS (`getaddrinfo`) and the TLS setup jobs that load CA, certificate and key files (§10.2.2, pool size). As built.
- **Pipes, FIFOs, character devices (a terminal, `/dev/zero`) and sockets** are non-blocking on the loop (`uv_pipe_t`, `uv_tcp_t`, `uv_tty_t` or a poll handle), never a pool job, because a read on them can wait forever, and a pool thread that waits forever cannot be cancelled or joined. As built: sockets (`vm/tcp.c`) and process pipes (`vm/process.c`). **Being built** (a separate fix PR: stdin, FIFOs and character devices read non-blocking on the loop; row 7.2.1a of the [roadmap](../roadmap/README.md)): stdin (`vm/input.c` reads it in a pool job today, with a blocking `poll`) and `File.open` on a FIFO or a character device (`vm/files.c` clears `O_NONBLOCK` and reads in the pool today).
- A new kind of descriptor picks one of the two by what it is (`fstat` after open), never by how it was named.

Known exceptions, as built:

- **stdout and stderr writes block.** `puts`, `print`, `IO.inspect` and `IO.warn` write through `agc_write` to a blocking `FILE *` (`vm/interp.c`), so a full stdout pipe stalls every task. Decided: kept for now, as the simplest form. A stop signal interrupts such a write (`EINTR`, no `SA_RESTART`) and ends the run (§14.4).
- **Reaping a process blocks the loop thread.** `Process.close` and an owned process's close (`close_proc` → `shut` → `reap` in `vm/process.c`), and `outlast` at the end of the run, poll with `nanosleep` for at most `REAP_SECONDS` (1 s). It is bounded, but it is neither a park nor a job timer (§14.2).

### 14.2 Timeouts

**Rule.** One way: a timer on the job. A builtin that takes `timeout_ms` passes it to `agc_io_start`, whose job owns one `uv_timer_t` (`start_job` in `vm/loop.c`). When it fires, the job ends with the timeout error and the task wakes. No builtin starts its own timer for a timeout.

`Task.sleep` is the same thing: a job with no work and a timer. As built, a few timers are not job timeouts and stay: a captured child's grace period (§31.9), the `HttpClient` pool's timer, and the end-of-run flush deadline (§14.4). The reap's `nanosleep` deadline (§14.1) is a bounded wait of the same kind, not a loop timer. A new one needs a reason here.

### 14.3 Cancelling

**Rule.** One way: `agc_task_cancel` (20b's core, §30.6 and §10.2.1). It knows every place a task can park (§14.1) and takes the task out of each one. A new kind of wait adds its case to `agc_task_cancel` and to `vm/tests/task_cancel_test.c` in the same PR. A crash (§37.6) and `Test.run`'s leftovers (§36.6) cancel through it; nothing else cancels a wait (a timer, a job's completion and a crash also unlink a task, but they end a wait, they do not cancel one).

A job that is cancelled is detached (`agc_io_detach`): a loop job is stopped by its `cancel` half; a pool job runs to its end, which §14.1 keeps bounded.

### 14.4 Ending

**Rule.** One exit path. Every step of it is bounded, except the file flush, which waits until it is done unless `--flush-timeout` sets a limit (the owner's choice in phase 24, as Erlang's `flush_timeout`: no limit by default). At exit, stdout and stderr count as part of the file flush: unbounded by default, bounded by `--flush-timeout`. **When `main` ends, the program ends.** The steps are:

1. kill child processes;
2. flush stdout, stderr and open files (the file flush with no limit by default, or within `--flush-timeout`);
3. exit.

Nothing else is joined or drained: no task is awaited, no pool job other than the file flush is waited for, no socket is read to its end. `System.exit` and a crash of `main` take the same path. So does the first stop signal (SIGTERM, SIGINT, SIGHUP), flush included; a second stop signal exits at once without flushing, so a flush that cannot end (a FIFO nobody reads, or a test child that gets `PR_SET_PDEATHSIG`'s SIGTERM, `vm/main.c`) never makes the VM unkillable. A second signal that comes before the children are stopped waits for step 1, so children are never left behind.

As built (`end_run` in `vm/main.c`, §10.2.2 "End of run" and "Stop signals"): `main`'s return, `System.exit`, a diagnostic, the step limit and the first stop signal (`check_stop` in `vm/task.c`, or `EINTR` on a stdout write) all reach `end_run`, which kills the children (`agc_processes_stop` → `close_children` in `vm/process.c`, about 2 seconds at most), sends one non-blocking TLS `close_notify` per finished TCP session (`agc_io_goodbye`), flushes stdout and stderr, closes the files and waits for their flush jobs (`agc_io_flush_files`), prints the diagnostic or summary and ends with `_exit`, or by the stop signal raised again, so libuv's destructor never joins the pool. A second stop signal before `agc_processes_stop` returns is recorded and acted on right after it (an `alarm` bounds that at 3 seconds); later, it ends the VM at once. A driven VM whose driver is gone takes that immediate path on its first signal. `agc_io_close` (close every resource, free the loop) is only for the in-process harnesses. Where this differs from the rule (targets):

- The `fflush` of stdout and stderr is not bounded by `--flush-timeout`.
- HTTP client TLS connections get no `close_notify` at the end of the run (only `TCP` sockets do); 20c can give its connections the same `goodbye` hook.

Known exceptions, outside the exit path: the out-of-memory and GC abort handlers end with `_Exit(70)` and run none of these steps (§6.3), and `SIGKILL` runs none either; both leave children running.

### 14.5 Handles

**Target rule.** A handle (file, socket, listener, process) belongs to the task that opened it. If that task ends, in any way (return, crash, cancel), without closing it, the handle is closed. Handing it to another task is always explicit, through one hand-off form; `HttpWire.spawn`'s group registration (20c, §30.6) is one use of that form, not a second mechanism. Ownership decides who closes a handle, not who may use it: other tasks still use a shared handle (§37.5 "Shared handles"), and `HttpClient` stays exempt (§37.5).

As built (phase 24, §37.5 and §10.2.1 "Owners"), two more rules: a handle passed directly as the `Task.spawn` argument moves to the new task when the caller owns it (`builtin_spawn` in `vm/task.c`), and when a task ends normally, the handles it still owns go to its parent (`agc_give_owned`); only a crash closes them (`agc_close_owned`). A cancelled task's handles are neither given back nor closed (`end_cancelled` in `vm/task.c`; `drop_handles` is set only on a crash), so they stay open until the end of the run. Planned in 20c (§30.6), not built yet, a third way: `HttpWire.spawn` registers each connection's socket with the server's group, which closes it when the connection task ends or at `close_server`. Replacing all of these with the target rule is planned after HTTP 20c ([phase 24, 24b](../roadmap/24-task-crash-isolation.md)); closing on cancel is a behavior change too (`Test.run`'s leftovers, cancelled handlers).

### 14.6 Entry rule for the core

- No new subsystem in `vm/` without a demonstrated use case: a program that needs it and cannot be written well without it.
- Prefer Agentica code first (`std/`, the roadmap's "`std/` first" rule), then a separate process. C in the core is the last choice.
- Each new core concept replaces something, or justifies itself against §14.1 to §14.5: how it waits, times out, is cancelled, ends and owns its handles. If it needs a second way for any of them, it does not go in.

Items in the plan to re-check with this rule before they start:

| Item | Question |
|---|---|
| VM metrics (phase 18, §28) | It adds a metrics thread and hooks in the core. Could a dump at exit, or an outside reader of the VM's state, do the job? |
| VM layers (7l, §21; its first part is row 7.2.1b, §15) | Does each layer replace code, or only add a boundary? (§15 answers for the first part.) |
| JIT (7m, §22) | Required by the roadmap; it must keep the same five rules and add no runtime of its own. |
| Multicore schedulers (gated, §10.2.3) | Gated on the numbers of steps 9 and 10. If built, each rule above must still hold per scheduler, with one exit path for the process. |
