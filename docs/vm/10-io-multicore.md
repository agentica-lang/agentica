#### 10.2.3 Multicore: threads and the rules per thread

The design lets the VM use all CPU cores. The model (the threads, the queues and
who owns what) is in §16 ([`16-architecture.md`](16-architecture.md)): N
scheduler threads that pull ready tasks from one global run queue, and one I/O
thread, the main thread, with the only libuv loop. This section keeps the rules
that follow from it. The first design was M:N as in BEAM (a loop, run queue and
registry per scheduler, a home scheduler per task, work stealing). The owner
replaced it with §16 on 2026-10-13. It is gated: the roadmap builds more than
one scheduler only after the server measurement (7j), which decides it (order
step 11, right after step 9 and before the JIT), and only if CPU-bound work
needs it.

- **Schedulers.** N scheduler threads. The default is
  `uv_available_parallelism()`, which respects CPU affinity. `--schedulers N`
  sets it, capped at 1024 (not built yet). 0, negative or non-numeric values
  exit 2, like other bad VM flags. `--schedulers 1` gives the N=1 order, which
  still depends on timer and pool timing. `--seed` does not imply
  `--schedulers 1`: a repeatable run needs it given explicitly. At N>1 only each
  task's random values repeat (7.4). The schedulers share one global run queue
  and have no loop: the only `uv_loop_t` belongs to the I/O thread (§16.2).
  Tasks are green VM stacks, and reductions and turns work as in 10.2.1. The
  thread pool is one per process, driven by that loop, and its size is
  `UV_THREADPOOL_SIZE` (10.2.1).
- **Run queue and idle schedulers.** One global run queue (§16.3). New, yielded
  and woken tasks are pushed at its tail. A scheduler pops one task under the
  queue's lock, never a batch. An idle scheduler waits on the queue's condvar
  and never spins. A push signals one. Requeueing a preempted task does not
  touch the packed word of the Stall check, since the task never stops being
  live.
- **Waking.** Whoever wakes a task pushes it on the global run queue, after
  publishing what the task needs to see (§16.3, wake after publish): the I/O
  thread when a job ends, a scheduler when an await finishes or a lock passes,
  or a cancel. There is no home scheduler and no per-scheduler wake handle. A
  task's results and state changes are published with release/acquire or under a
  small per-task lock, so an awaiting task on another scheduler sees the whole
  result.
- **Cancel and stop flags.** The task's cancel flag and the run's stop flag are
  atomics, checked only on the `STEP` slow path, when the "next stop" counter
  runs out. The fast path still touches no atomic. A cancel or stop takes effect
  within one turn budget.
- **Park and wake protocol.** Each task has an atomic state: RUNNING, PARKING,
  PARKED or WOKEN. To park, the task sets PARKING before it registers its wait
  (before it posts its start request, joins a waiter list, or registers on
  another task's result). It then re-checks its wait condition and its cancel
  flag. If either is satisfied, it unregisters and goes back to RUNNING with one
  CAS that accepts PARKING or WOKEN. A posted request cannot be recalled, so for
  a job "unregisters" means the task detaches it, and the job runs to its end
  (§16.11). If the outcome (§16.5) is already set, the task consumes the job
  instead. Otherwise it CASes PARKING to PARKED. Registering on another task's
  result is done under that task's lock, and fails if the result is already
  published. A waker acts only on PARKING or PARKED. On PARKING it CASes to
  WOKEN and queues nothing, so the task sees WOKEN and re-checks at once. On
  PARKED it CASes to WOKEN and pushes the task on the run queue. A waker that
  finds PARKING undoes its pending-wake increment. A wake that finds RUNNING or
  WOKEN is stale and dropped. The scheduler sets WOKEN to RUNNING when the turn
  starts. A resumed task re-checks its condition, so a wake is only a hint. No
  wake is lost, and a task is queued at most once. Which waker wins is in §16.5.
- **Channel lock (17b).** Each channel has a short lock. `send`, `recv`,
  `close`, a wake, a hand-on and a cancelled waiter that leaves its FIFO take
  it, and it is never held across a park. Ring growth copies the slots under the
  lock: an accepted exception, bounded by the capacity and charged as turn cost.
  The lock orders the write of a value before its read on another scheduler. A
  wake or a hand-on is a scheduler waker that reaches the waiter's timer job:
  under the channel lock it takes the job's reference and sets the outcome by
  the CAS of §16.5 rule 3. If the timer wins instead, the timer side takes the
  channel lock before it pushes the task, and a wake or hand-on that lost passes
  the value or the slot to the next waiter, so nothing is lost. With N=1 the
  lock is not needed, and the VM does not take one. Each task also writes its
  `awaiting` field before it parks, under the target's lock (Park and wake
  protocol), so two tasks that close a cycle at the same time cannot both miss
  it: the second to take the lock sees the first's field.
- **State split.** As built (`vm/port.h`): `agc_runtime` (shared),
  `struct agc_vm` (the scheduler: the context every builtin gets, with `rt`, the
  current `task`, the run queue, `loop`, `registry`, the turn counters and the
  `fail` jmp_buf), and `agc_task`. With N=1 there are these deviations: the
  runtime is GC-allocated by `agc_vm_init` (both are roots for Boehm), the
  `fail` jmp_buf is per scheduler (the only `setjmp` is the scheduler's own),
  the task state is a plain READY, RUNNING, PARKED, DONE enum (no PARKING or
  WOKEN, which only matter to a thread that can wake a task), and there are no
  stream locks, since one thread writes. With N>1 the fields go as follows
  (§16):
  - Runtime, read-only after start-up: `program` (with its constants, except
    the Globals table, which the entry writes before `main`, see "The Globals
    table" below), `args`, `cwd` (raw bytes, read by `agc_files_init`),
    `no_files`, and the config.
    Shared under rules: the atomic `steps_left` (10.2.1, Quotas), `outcome` (set
    once by a CAS, 6.2), and `out` and `err` (one lock per stream, see Output).
    Stdin (`in`, an `agc_input`) is a handle on the I/O loop (see I/O
    ownership).
  - Shared: the global run queue (§16.3).
  - The `std/logger` registry (`log` in the runtime, built in `vm/logger.c`,
    `docs/future/24-logging.md` §24.2): the global level, the lowest handler
    rank and an array of (name, rank, handler) in the GC heap, reached only by
    the ten `LogRegistry` builtins. It is the language's one piece of global
    mutable state and is a field of the runtime, not a `static`. With N>1 it
    needs a lock, the same lock as the stderr buffer; the multicore PR owns that
    change. `install_default` is one native call, so the check for level -1 and
    the writes cannot interleave with another task.
  - I/O thread: the loop, the inbox (§16.4) and the resource registry. Whether
    the registry is owned by the I/O thread or shared under a lock is open
    (§16.11).
  - Per scheduler: the turn counter and the running task's context (`task`,
    `fail`).
  - Per task: the registers and frames, `random` (7.4), the `fail` jmp_buf
    target (armed on the thread that runs the turn), the string cursor cache,
    and `parked`, the request the task waits on, which it sets while PARKING.
  - A runtime diagnostic or `System.exit` on any scheduler ends the run (6.2).
    That scheduler records the outcome once and wakes the I/O thread and the
    idle schedulers. The others stop at their next `STEP` slow path or when they
    wake. The exit path (§14.4) runs on the I/O thread. Whether it waits for the
    schedulers first is open (§16.11).
- **I/O ownership.** Every libuv handle belongs to the one loop, on the I/O
  thread, for its whole life. A task on any scheduler reaches a handle by
  posting a request to the I/O inbox and parking (§16.4). The result wakes it
  through the run queue. No task moves to the scheduler that owns a handle.
  Thread-pool threads never touch GC memory (10.2).
- **Stdin.** A handle on the I/O loop like any other. Reads from any scheduler
  are requests. Each read stays whole, because the input keeps a FIFO of waiting
  readers and serves one read at a time. No OS mutex or spinlock is held across
  a park.
- **Output.** Each print to stdout or stderr is copied whole into the stream's
  buffer, or waits whole in the stream's FIFO, so lines from different tasks
  never mix mid-line (§10.2.2, "stdout and stderr (row 7.2.1f)", built for N=1
  without a lock). A stream on the loop is written only by the loop. Stdout and
  stderr on one target share one buffer and one FIFO, so they share the lock
  too. With N>1 the buffer and the FIFO get a short lock around each access,
  never held across a park, since an OS lock held for the whole write could not
  survive a park. The blocking fallbacks (§14.1) keep a lock across the write:
  under it, a short write or `ferror` is retried, and once the outcome is set,
  writes are dropped (checked under the stream lock). The final diagnostic of
  `vm/main.c` is exempt. Only the order in which output from different tasks
  interleaves is not repeatable.
- **The I/O thread blocks in its loop.** With nothing to do it blocks in
  `uv_run(UV_RUN_ONCE)`. The inbox's `uv_async_t` is ref'd while schedulers run,
  so the loop stays alive with no other handle, and a request calls
  `uv_async_send` on it. At the end of the run it is unref'd, so an in-process
  harness can close the loop. The real binary ends with `_exit` and closes no
  loop (Shutdown). With N=1 there is no inbox handle, and the "no active
  handles" check of 10.2.1 still holds.
- **Stall check.** For N>1 it uses only atomic counters, never `uv_run`'s return
  value. One 64-bit atomic word packs the idle scheduler count and the live
  count (jobs and timers started on the loop or the pool, requests in the inbox,
  wakes not yet taken, and ready tasks in the run queue), so the check reads one
  snapshot. The inbox's `uv_async_t` is not counted. A pending request or wake
  counts as live: the sender increments before it pushes, and the receiver
  decrements when it takes the item. Every hand-on of liveness increments the
  new item before it decrements the old one, or does both in one CAS on the
  word. A scheduler leaves idle before it pops a task. The check runs on every
  change that makes idle == N and live == 0. The thread that makes that change,
  if tasks are still parked, fails the run with `RUNTIME-INTERNAL` and wakes the
  other schedulers (10.2.1, Stall check).
- **Main thread.** It does the start-up work (`GC_INIT`,
  `GC_allow_register_threads`, the `setenv`, the SipHash keys, the messages
  locale), starts the N scheduler threads, and then becomes the I/O thread
  (§16.2). It runs the loop and the one exit path (§14.4). It joins no
  scheduler.
- **Shutdown.** The run ends through the exit path of §14.4, on the I/O thread.
  It does not close the handles one by one, and does not free the loop (10.2.2,
  End of run).
- **GC.** Boehm is built with `GC_THREADS`, `PARALLEL_MARK` and
  `THREAD_LOCAL_ALLOC`. Scheduler threads are created with `GC_pthread_create`
  or register with `GC_register_my_thread`. The libuv pool threads stay
  unregistered on purpose, since they never touch GC memory. The runtime struct
  stays on the main thread's stack for the whole run. The run queue lives in GC
  memory or is a registered root, so a head in `malloc` memory never hides a
  task from the collector. Jobs and the inbox are `malloc` memory with no GC
  pointer, and a GC resource owns each job (§16.5). Collections stop the world.
  That cost is accepted and measured in round 2 of the benchmarks, which also
  measures contention on the packed word and the run queue's lock. Boehm stops
  threads with signals installed with `SA_RESTART`. The VM's syscall paths retry
  on `EINTR`, and libuv signal handling (`uv_signal_t`) must never take Boehm's
  suspend and restart signals.
- **No mutable global state in `vm/`.** Every mutable `static` or global
  variable goes into the runtime, scheduler or task struct. Lazy one-time init
  uses `pthread_once` or happens at start-up. `make vm-lint` enforces this with
  clang-tidy's `cppcoreguidelines-avoid-non-const-global-variables` on `vm/*.c`
  and `vm/*.h` (`vm/tests/.clang-tidy` turns it off for the C tests). The check
  does not see function-local `static` variables. The exceptions that stay, each
  marked `// NOLINT(cppcoreguidelines-avoid-non-const-global-variables)`:
  - the `AGC_NO_GC` block tracking in `vm/value.c` (fuzz and test builds,
    single-threaded), the fuzz harness statics in `vm/fuzz.c` and
    `vm/fuzz_main.c`, and `wide_args` in `vm/main.c` (Windows, set once before
    any scheduler starts);
  - the block-scope `extern char **environ` in `host_env` of `vm/process.c`,
    read but never written (the child's environment and `System.env` read it);
  - the stop state `stop` in `vm/loop.c` (lock-free atomics, a pid and the wake
    handle), since a signal handler gets no context (10.2.2, Stop signals).
    Already moved out of globals: the `ready` flag of `agc_init` (Boehm's
    `GC_is_init_called` answers instead); the GC-stress counter (`_Atomic`); the
    SipHash keys (`hash_key` in `agc_vm`, set from OS entropy by `vm/main.c`
    before the run); the OS error locale (`messages_locale` in `agc_vm`, made
    once at start-up and freed on exit); and
    `setenv("UV_USE_IO_URING", "0", 0)`, which moved to start-up (`agc_io_init`,
    before any loop exists) because `setenv` is not thread-safe. `agc_io_init`
    returns whether it set the variable, and `vm/main.c` keeps that in the
    runtime (`drop_uring_env`) for `Process.spawn` (10.4).
- **Values are immutable**, so tasks on different schedulers share them without
  locks or copies (§16.7). Any in-place mutation inside the VM (caches, updates
  in place when a value is known to be unique, the faster lists of roadmap 8d)
  must be proven unshared or made atomic. Future mutable structures, and the
  shared tables of `docs/future/13-ats.md` §13, must use locks and atomics. A
  table call does not yield, so it is atomic with N=1. Once N>1, each table call
  needs a lock, or a persistent structure installed with compare-and-swap.
- **The Globals table** (module constants, `docs/future/44-module-constants.md`
  §44.8) is the one place a loaded program is written (`agc_program.globals`).
  The loader lets only the entry function write it, in code with no backward
  jump, and refuses any call or closure of the entry in a file with slots. So
  each `GLOBAL_SET` runs at most once, in the main task, before it tail-calls
  `main`, and then the table is only read: it needs no lock and no atomic once
  the other schedulers start. The entry of a front-end file runs only pure
  builtins, so it spawns no task. A hand-made entry could spawn a task before
  its last write, so the multicore build must not run a second task on another
  scheduler until the entry has handed over to `main` (its first `TAIL_CALL` or
  `RETURN`), or publish the table with one release store of a flag that
  `GLOBAL` reads with acquire (a slot is a 16-byte value, so per-slot ordering
  would not stop a torn read). At N=1 tasks interleave on one thread and
  nothing is racy.
- **Order of work.** First the tasks PR, on these split structures, with N=1.
  Then, if the gate opens, the multicore schedulers item: N>1 with the I/O
  thread and its inbox, the global run queue, Boehm threads, the TLS and HTTP
  steps moved into the resumed task's turn (§16.9), and a stress test of the
  task fixtures with `--schedulers 4`, under TSan when available. TSan does not
  work with Boehm's stop-the-world, so that run uses an `AGC_NO_GC`-style build
  with `-fsanitize=thread` that never calls `agc_set_alloc_limit`. ASan and
  TSan, both without GC, cover memory errors and races in the scheduler code.
  The GC-threaded build is covered only by a GC-stress run with
  `--schedulers 4`. Round 2 of the benchmarks (roadmap phase 12) then covers
  multicore. The parity rule stays black-box (1): with N=1, exit code, stdout,
  program stderr and diagnostic codes match the goldens. The differential,
  bytecode and golden tests, the `--max-steps` sweep and the seeded runs all run
  with `--schedulers 1`.
