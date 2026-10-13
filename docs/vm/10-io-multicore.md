#### 10.2.3 Multicore: threads and the rules per thread

The design lets the VM use all CPU cores (parallelism), not only run tasks
concurrently. The model (the threads, the queues and who owns what) is in
§16 ([`16-architecture.md`](16-architecture.md)): N scheduler threads that
pull ready tasks from one global run queue, and one I/O thread, the main
thread, with the only libuv loop. This section keeps the rules that follow
from it. The first design here was M:N as in BEAM: a loop, a run queue and a
resource registry for each scheduler, a home scheduler for each task, and
work stealing. The owner replaced it with §16 on 2026-10-13. It is gated:
the roadmap builds more than one scheduler only after the server measurement
(7j) and the evaluation round (6c), and only if that measurement shows
CPU-bound work that one scheduler cannot serve.

- **Schedulers.** N scheduler threads. The default is
  `uv_available_parallelism()`, which respects CPU affinity; `--schedulers
  N` sets it, capped at 1024, and 0, negative or non-numeric values exit 2
  like other bad VM flags. `--schedulers 1` gives the N=1 order (which still
  depends on timer and pool timing). `--seed` does not imply `--schedulers
  1`: a repeatable run needs `--schedulers 1` given explicitly; at N>1 only
  each task's random values repeat (7.4). The schedulers share one global
  run queue and have no loop of their own: the only `uv_loop_t` belongs to
  the I/O thread (§16.2). Tasks are green VM stacks, as in 10.2.1, and
  reductions and turns stay as they are there. The libuv thread pool is one
  per process, driven by that loop; its size is still `UV_THREADPOOL_SIZE`
  (10.2.1).
- **Run queue and idle schedulers.** One global run queue (§16.3). A new
  task, a task whose turn ended and a woken task are pushed at its tail. A
  scheduler pops one task under the queue's lock, never the whole list and
  never a batch. An idle scheduler waits on the queue's condvar and never
  spins; a push signals one. Requeueing a preempted task does not touch the
  shared packed word (Stall check), since the task never stops being live.
- **Waking.** Whoever wakes a task pushes it on the global run queue, after
  it has published what the task needs to see (§16.3, wake after publish):
  the I/O thread when a job ends, a scheduler when an await finishes or a
  lock passes, a cancellation. There is no home scheduler and no wake handle
  per scheduler. A task's result and state changes are published with
  release/acquire, or under a small per-task lock, so an awaiting task on
  another scheduler sees the whole result; the queue's lock publishes what
  was written before the push. Cancellation sets the task's cancel flag,
  plus a wake if it is parked.
- **Cancel and stop flags.** The task's cancel flag and the run's stop flag
  are atomics, checked only on the `STEP` slow path, when the "next stop"
  counter runs out. The fast path still touches no atomic. A cancel or stop
  takes effect within one turn budget.
- **Park and wake protocol.** Each task has an atomic state: RUNNING,
  PARKING, PARKED or WOKEN. To park, the task sets RUNNING to PARKING before
  it registers its wait (before it links its job on the I/O inbox, joins a
  waiter list or registers on another task's result). Then it re-checks its
  wait condition and its cancel flag; if either is satisfied, it unregisters
  and goes back to RUNNING with one CAS that accepts PARKING or WOKEN. A job
  already linked on the inbox cannot be unlinked, so for a job "unregisters"
  means the task detaches it, when the cancel flag ended the wait, and the
  job runs to its end (§16.11). If the outcome (§16.5) is already set, the
  task consumes the job instead.
  Otherwise it CASes PARKING to PARKED. Registering on another task's result
  is done under that task's lock and fails if the result is already
  published. A waker acts only on PARKING (CAS to WOKEN, no queue: the
  task's CAS fails, so it sets WOKEN to RUNNING and re-checks at once) and
  on PARKED (CAS to WOKEN, then push the task on the run queue). A waker
  that finds PARKING, and so does not queue, undoes its pending-wake
  increment. A wake that finds RUNNING or WOKEN is stale and dropped. The
  scheduler sets WOKEN to RUNNING when the task's turn starts. A resumed
  task re-checks its wait condition, so a wake is only a hint. No wake is
  lost, and a task is queued at most once. Which waker wins, and what it
  does, is in §16.5.
- **State split.** As built (`vm/agc.h`): `agc_runtime` (shared), `struct
  agc_vm` (the scheduler: the context every builtin gets, with `rt`, the
  current `task`, the run queue, `loop`, `registry`, the turn counters and
  the `fail` jmp_buf) and `agc_task`. Deviations, with N=1: the runtime is
  GC-allocated by `agc_vm_init` and reachable from the scheduler, not a
  struct on the main thread's stack (both are roots for Boehm); the `fail`
  jmp_buf is per scheduler, not per task, because the only `setjmp` is the
  scheduler's own, armed once on its thread, and any failure ends the run;
  the task state is a plain READY, RUNNING, PARKED, DONE enum without the
  PARKING and WOKEN steps, which only matter when another thread can wake a
  task; and there are no stream locks, since one thread writes. With N>1
  the main fields go as follows (§16):
  - Runtime, read-only after start-up: `program` (with its constants),
    `args`, `cwd` (raw bytes, read at start-up by `agc_files_init`),
    `no_files`, and the config. Also in the runtime but shared under rules:
    the atomic `steps_left` (10.2.1, Quotas), `outcome` (set once by a CAS
    on the outcome kind, 6.2), `out` and `err` (one lock per stream, see
    Output). Stdin (`in`, an `agc_input`) is a handle on the I/O loop (see
    I/O ownership).
  - Shared: the global run queue (§16.3).
  - In the I/O thread: the loop (`loop`), the inbox (§16.4) and the resource
    registry (`registry`). Whether the registry belongs to the I/O thread or
    is shared under a lock is open (§16.11).
  - Per scheduler: the turn counter and the context of the running task
    (`task`, `fail`).
  - Per task: the registers and frames (`regs`, `reg_capacity`, `frames`,
    `frame_capacity`, `frame_count`, `depth`), `random` (7.4), the `fail`
    jmp_buf target (armed on the thread that runs the task's turn), the
    string cursor cache (`cursor`, `cursor_index`, `cursor_offset`), and
    `parked`, the request the task waits on, which it sets while PARKING
    (see Park and wake protocol).
  - A runtime diagnostic or `System.exit` on any scheduler ends the run
    (6.2): that scheduler records the outcome once and wakes the I/O thread
    and the idle schedulers (the flag they wait on changes under the run
    queue's lock, §16.3); the other schedulers stop at their next `STEP`
    slow path or when they wake, and the exit path (§14.4) runs on the I/O
    thread. Whether it first waits for the schedulers to stop is open
    (§16.11).
- **I/O ownership.** Every libuv handle belongs to the one loop, on the I/O
  thread, for its whole life. A task on any scheduler reaches a handle by
  posting a request to the I/O inbox and parking (§16.4); the result wakes
  it through the run queue, on any scheduler. There is no hand-off between
  loops and no task moves to the scheduler that owns a handle. Thread-pool
  threads still never touch GC memory (10.2).
- **Stdin.** Stdin is a handle on the I/O loop like any other. Reads from
  any scheduler are requests. Each read stays whole because the input keeps
  a FIFO of waiting reader tasks and serves one read at a time. No OS mutex
  or spinlock is ever held across a park.
- **Output.** Each print to stdout or stderr is written whole under one lock
  per stream, so lines from different tasks never mix mid-line. These writes
  never park, so the lock is never held across a park. Under the lock, a
  write checks for short writes and `ferror` and retries. Once the outcome
  is set, writes are dropped; the check is made under the stream lock. The
  final diagnostic that `vm/main.c` prints is exempt. Until stdout and
  stderr move onto the loop (roadmap row 7.2.1f, §14.1), a write blocks the
  scheduler thread that does it. Once a write can park, this lock cannot be
  held across the park; what replaces it is open (§16.11). Only the order
  in which output from different tasks interleaves is not repeatable.
- **The I/O thread blocks in its loop.** With nothing to do it blocks in
  `uv_run(UV_RUN_ONCE)`. The inbox's `uv_async_t` is ref'd while schedulers
  run, so the loop stays alive with no other handle; a request calls
  `uv_async_send` on it. When the run ends, the I/O thread unrefs it so the
  loop can close; this is for in-process harnesses only, since the real
  binary ends with `_exit` and closes no loop (Shutdown, below). With N=1
  as built there is no inbox handle, and the plain "no active handles"
  check of 10.2.1 still holds.
- **Stall check.** For N>1 it uses only atomic counters, never `uv_run`'s
  return value. One 64-bit atomic word packs the idle scheduler count
  (schedulers waiting on the run queue's condvar) and the live count (jobs
  and timers started on the loop or the pool, requests in the inbox, wakes
  not yet taken, and ready tasks in the run queue), so the check reads one
  snapshot. The inbox's `uv_async_t` is not counted. A pending request or
  wake counts as live: the sender increments the count before the push, and
  the receiver decrements it when it takes the item. Every hand-on of
  liveness (waiter, then pending request or wake, then ready task)
  increments the new item before it decrements the old one, or does both in
  one CAS on the packed word. A scheduler leaves idle before it pops a task.
  The check runs on every change of the word that makes idle == N and live
  == 0: the idle increment and every live decrement. The thread that makes
  that change, if tasks are still parked, fails the run with
  `RUNTIME-INTERNAL` and wakes the other schedulers (10.2.1, Fairness).
- **Main thread.** It does the start-up-only work (`GC_INIT`,
  `GC_allow_register_threads`, the `setenv`, the SipHash keys, the messages
  locale), starts the N scheduler threads, and then becomes the I/O thread
  (§16.2): it runs the loop and, when the run ends, the one exit path
  (§14.4). It joins no scheduler: the exit path ends with `_exit`.
- **Shutdown.** The run ends through the exit path of §14.4, on the I/O
  thread. It does not close the handles one by one and does not free the
  loop (10.2.2, End of run).
- **GC.** Boehm is built with `GC_THREADS`, `PARALLEL_MARK` and
  `THREAD_LOCAL_ALLOC`. The main thread calls `GC_allow_register_threads()`
  first. Scheduler threads are created with `GC_pthread_create` or register
  with `GC_register_my_thread`; the libuv pool threads stay unregistered on
  purpose, since they never touch GC memory. The main thread, which becomes
  the I/O thread, is registered too. The runtime struct stays on the main
  thread's stack, which Boehm scans, for the whole run. The run queue
  lives in GC memory or is registered as a root, so a head in `malloc`
  memory never hides a task from the collector. Jobs and the inbox are
  `malloc` memory and hold no GC pointer; a GC resource owns each job
  (§16.5).
  Collections stop the world; that cost is accepted and measured (round 2
  benchmarks, which also measure contention on the packed word of the Stall
  check and on the run queue's lock). Boehm stops threads with signals,
  installed with `SA_RESTART`, and the VM's syscall paths retry on `EINTR`,
  and libuv signal handling (`uv_signal_t`) must never take Boehm's suspend
  and restart signals.
- **No mutable global state in `vm/`.** Every mutable `static` or global
  variable goes into the runtime, scheduler or task struct. Lazy one-time
  init uses `pthread_once` or happens at start-up. `make vm-lint` enforces
  this with clang-tidy's `cppcoreguidelines-avoid-non-const-global-variables`
  on `vm/*.c` and `vm/agc.h` (`vm/tests/.clang-tidy` turns it off for the C
  tests); the check does not see function-local `static` variables. What
  `vm/` has today:
  - Exceptions that stay, each with
    `// NOLINT(cppcoreguidelines-avoid-non-const-global-variables)`: the
    `AGC_NO_GC` block tracking in `vm/value.c` (fuzz and test builds only,
    single-threaded); the fuzz harness statics in `vm/fuzz.c` and
    `vm/fuzz_main.c`; `wide_args` in `vm/main.c` (Windows), set once before
    any scheduler starts; the block-scope `extern char **environ` in
    `vm/process.c`, read (never written) when `Process.spawn` builds a
    child's environment; the stop state `stop` in `vm/loop.c` (lock-free
    atomics, a pid and the wake handle), since a signal handler gets no
    context (10.2.2, Stop signals).
  - `agc_init` (`vm/value.c`) asks Boehm (`GC_is_init_called`) instead of
    keeping a `ready` flag.
  - The GC-stress counter in `vm/value.c` (`AGC_GC_STRESS`, a test build
    only) is `_Atomic`.
  - `Result.message` of an `Ok` and `String.join` of an empty list make a
    fresh empty string; the shared `empty_string` and `empty_text` are gone.
  - The SipHash keys are `hash_key` in `agc_vm`, set by `agc_vm_init` and,
    from OS entropy, by `vm/main.c` before the run.
  - The locale for OS error text (`vm/files.c`) is `messages_locale` in
    `agc_vm`, made on first use and never freed. The tasks PR made it
    once at start-up (`agc_files_init`), read-only in the shared runtime,
    and freed on exit (`agc_files_close`).
  - `setenv("UV_USE_IO_URING", "0", 0)` in `vm/loop.c` runs when the first
    loop is made; `setenv` is not thread-safe, so the tasks PR moved it to
    start-up (`agc_io_init`, called by `vm/main.c` before any loop exists).
    `agc_io_init` returns whether it set the variable; `vm/main.c` keeps
    that in the shared runtime (`drop_uring_env`) for `Process.spawn`
    (10.4).
    The tasks PR also moved the `agc_vm` fields above to the shared
    runtime or the scheduler.
- **Values are immutable**, so tasks on different schedulers share them
  without locks or copies (§16.7). Any in-place mutation inside the VM
  (caches, updates in place when a value is known to be unique, the faster
  lists of roadmap 8d) must be proven unshared or made atomic. Future
  mutable structures (for example mutable vectors) and the shared tables of
  `docs/future/13-ats.md` §13 must use locks and atomics. A table call does
  not yield, so it is atomic with N=1; once N>1, each table call needs a
  lock, or a persistent structure installed with compare-and-swap (as the
  evaluator does with `box-cas!`).
- **Order of work.** First the tasks PR on these split structures with N=1;
  then, if the gate above opens, the multicore schedulers item (N>1: the I/O
  thread with its inbox, the global run queue, Boehm threads, the TLS and
  HTTP steps moved into the turn of the resumed task (§16.9), and a stress
  test of the task fixtures with `--schedulers 4`, under TSan when
  available; TSan does not get along with Boehm's stop-the-world, so that
  run uses an `AGC_NO_GC`-style build with `-fsanitize=thread` that never
  calls `agc_set_alloc_limit`, so the `AGC_NO_GC` block tracking stays off.
  ASan and TSan, both without GC, cover memory errors and data races in the
  scheduler code; the GC-threaded build is covered only by a GC-stress run
  with `--schedulers 4`); then round 2 of the benchmarks covers multicore
  (roadmap phase 12) if it landed. Multicore did not block 7i. The parity
  rule stays black-box (1): with N=1, exit code, stdout, program stderr and
  diagnostic codes match the goldens. The differential, bytecode and golden
  tests, the `--max-steps` sweep and the seeded runs all run the VM with
  `--schedulers 1`.
