#### 10.2.3 Multicore: M:N schedulers

The design lets the VM use all CPU cores (parallelism), not only run tasks
concurrently. It follows BEAM. It is gated: the roadmap builds it only after
the server measurement (7j) and the evaluation round (6c), and only if that
measurement shows CPU-bound work that one scheduler cannot serve.

- **Schedulers.** N scheduler threads. The default is
  `uv_available_parallelism()`, which respects CPU affinity; `--schedulers
  N` sets it, capped at 1024, and 0, negative or non-numeric values exit 2
  like other bad VM flags. `--schedulers 1` gives the N=1 order (which still
  depends on timer and pool timing).
  `--seed` does not imply `--schedulers 1`: a repeatable run needs
  `--schedulers 1` given explicitly; at N>1 only each task's random values
  repeat (7.4).
  Each scheduler has its own run queue, its own `uv_loop_t` (libuv loops are
  per thread) and its own resource registry. The loop and the wake
  `uv_async_t` are `malloc`'d, pointed to by the scheduler struct, and freed
  after `uv_loop_close` at shutdown: pool threads and other schedulers write
  to them, so they are never GC memory. Tasks are green VM stacks, as
  in 10.2.1, and reductions and turns stay as they are there. The libuv
  thread pool is one per process, shared by every scheduler's loop; its
  size is still `UV_THREADPOOL_SIZE` (10.2.1).
- **Work stealing.** A scheduler whose queue is empty steals from the queues
  of others. It takes only ready tasks; a parked task stays with the
  scheduler that owns what it waits on. A steal makes the thief the task's
  home. A spawned or preempted task stays on its own scheduler's queue, for
  locality. As in BEAM, when a scheduler pushes onto its queue while the
  idle count is above 0 and its queue holds more than one task, it sends
  `uv_async_send` to one idle scheduler, which then tries to steal. It
  picks that scheduler from an atomic idle bitmask (one bit per scheduler,
  set while idle). Requeueing a preempted task onto the same queue does not
  touch the shared packed word (Stall check), since the task never stops
  being live.
- **Home scheduler and waking.** Every task has a home scheduler: the one
  whose queue it was last put on. Waking a task (an await finishing, an I/O
  reply, cancellation) pushes it onto its home scheduler's MPSC wake queue
  and calls `uv_async_send` on that scheduler's wake handle. A task's result
  and state changes are published with release/acquire, or under a small
  per-task lock, so an awaiting task on another scheduler sees the whole
  result. Cancellation sets the task's cancel flag, plus a wake if it is
  parked.
- **Cancel and stop flags.** The task's cancel flag and the run's stop flag
  are atomics, checked only on the `STEP` slow path, when the "next stop"
  counter runs out. The fast path still touches no atomic. A cancel or stop
  takes effect within one turn budget.
- **Park and wake protocol.** Each task has an atomic state: RUNNING,
  PARKING, PARKED or WOKEN. To park, the task sets RUNNING to PARKING
  before it registers its wait. Then it re-checks its wait condition and
  its cancel flag; if either is satisfied, it unregisters and goes back to
  RUNNING with one CAS that accepts PARKING or WOKEN. Otherwise it CASes PARKING to PARKED. Registering on another
  task's result is done under that task's lock and fails if the result is
  already published. A waker acts only on PARKING (CAS to WOKEN, no queue:
  the task's CAS fails, so it sets WOKEN to RUNNING and re-checks at once)
  and on PARKED (CAS to WOKEN, then queue the task). A waker that finds
  PARKING, and so does not queue, undoes its pending-wake increment. A wake
  that finds
  RUNNING or WOKEN is stale and dropped. The scheduler sets
  WOKEN to RUNNING when the task's turn starts. A resumed task re-checks
  its wait condition, so a wake is only a hint. No wake is lost, and a task
  is queued at most once.
- **State split.** As built (`vm/agc.h`): `agc_runtime` (shared),
  `struct agc_vm` (the scheduler: the context every builtin gets, with
  `rt`, the current `task`, the run queue, `loop`, `registry`, the turn
  counters and the `fail` jmp_buf) and `agc_task`. Deviations, with N=1:
  the runtime is GC-allocated by `agc_vm_init` and reachable from the
  scheduler, not a struct on the main thread's stack (both are roots for
  Boehm); the `fail` jmp_buf is per scheduler, not per task, because the
  only `setjmp` is the scheduler's own, armed once on its thread, and any
  failure ends the run; the task state is a plain READY, RUNNING, PARKED,
  DONE enum without the PARKING and WOKEN steps, which only matter when
  another thread can wake a task; and there are no stream locks, since
  one thread writes. Every field of the old `struct agc_vm` has a place:
  - Runtime, read-only after start-up: `program` (with its constants),
    `args`, `cwd` (raw bytes, read at start-up by `agc_files_init`),
    `no_files`, and the config. Also in the runtime but shared under rules: the
    atomic `steps_left` (10.2.1, Quotas), `outcome` (set once by a CAS on the outcome kind, 6.2), `out`
    and `err` (one lock per stream, see Output). Stdin (`in`, an
    `agc_input`) is a handle owned by scheduler 0 (see I/O ownership).
  - Per scheduler: the loop (`loop`), the run queue, the resource registry
    (`registry`) and the turn counter.
  - Per task: the registers and frames (`regs`, `reg_capacity`, `frames`,
    `frame_capacity`, `frame_count`, `depth`), `random` (7.4), the `fail`
    jmp_buf target (armed on the thread that runs the task's turn), the
    string cursor cache (`cursor`, `cursor_index`, `cursor_offset`), and
    `parked`, the request the task waits on, which it sets while PARKING
    (see Park and wake protocol).
  - A runtime diagnostic or `System.exit` on any scheduler ends the run
    (6.2): that scheduler records the outcome once and sends
    `uv_async_send` to every other scheduler; they stop at their next
    `STEP` slow path or loop wake-up, then cleanup runs.
- **I/O ownership.** A libuv handle belongs to the loop that created it. A
  task parked on I/O wakes on the scheduler that owns that loop. If a task
  that was stolen to another scheduler uses a handle owned elsewhere, the
  operation is sent to the owner loop (an MPSC queue plus `uv_async_send`),
  and the task parks until the reply. The reply wakes it on the scheduler
  that owns the loop: that one becomes its home. A stolen task that keeps
  using a handle owned elsewhere moves back to the owner on each
  operation; this is intended, for locality. Thread-pool threads still
  never touch GC memory (10.2).
- **Stdin.** Stdin is a handle owned by scheduler 0. Reads from other
  schedulers go through the same hand-off. Each read stays whole because
  the owner keeps a FIFO of waiting reader tasks and serves one read at a
  time. No OS mutex or spinlock is ever held across a park.
- **Output.** Each print to stdout or stderr is written whole under one lock
  per stream, so lines from different tasks never mix mid-line. These
  writes never park, so the lock is never held across a park. Under the
  lock, a write checks for short writes and `ferror` and retries. Once the
  outcome is set, writes are dropped; the check is made under the stream
  lock. The final diagnostic that `vm/main.c` prints is exempt. Only the order in which output from different tasks interleaves is
  not repeatable.
- **Idle schedulers park, not spin.** An idle scheduler (empty queue,
  nothing to steal) raises the idle count, re-checks the queues once (a
  read only; it leaves idle before it pops or steals), then refs its wake `uv_async_t` and blocks in
  `uv_run(UV_RUN_ONCE)`, so its loop stays alive even with no other handle.
  A wake or new work for it calls `uv_async_send`. When the run ends, each
  scheduler unrefs its wake handle so its loop can close. With N=1 the wake
  handle is never ref'd, so the plain "no active handles" check of 10.2.1
  still holds.
- **Stall check.** For N>1 it uses only atomic counters, never `uv_run`'s
  return value. One 64-bit atomic word packs the idle scheduler count and
  the live count (handles, parked I/O and timer waiters, pending wakes,
  pending I/O hand-offs, and ready tasks in run queues), so the check reads
  one snapshot. The per-scheduler wake `uv_async_t` is not counted. A
  pending wake or hand-off counts as live: the sender increments the count
  before the push, and the receiving scheduler decrements it when it drains
  the item. Every hand-on of liveness (waiter, then pending wake, then
  ready task) increments the new item before it decrements the old one, or
  does both in one CAS on the packed word. A libuv callback that readies a
  task on an idle scheduler leaves idle in that same CAS. A scheduler
  leaves idle before it touches a queue or drains a wake.
  The check runs on every change of the word that makes idle == N and
  live == 0: the idle increment and every live decrement. The thread that
  makes that change, if tasks are still parked, fails the run with
  `RUNTIME-INTERNAL` and wakes the other schedulers (10.2.1, Fairness).
- **Main thread.** It does the start-up-only work (`GC_INIT`,
  `GC_allow_register_threads`, the `setenv`, the SipHash keys, the messages
  locale), starts schedulers 1..N-1, runs scheduler 0 itself, and joins the
  others after its own loop ends.
- **Shutdown.** Each scheduler closes its own registry's handles and runs
  its own loop to completion on its own thread before the main thread
  joins it.
- **GC.** Boehm is built with `GC_THREADS`, `PARALLEL_MARK` and
  `THREAD_LOCAL_ALLOC`. The main thread calls `GC_allow_register_threads()`
  first. Scheduler threads are created with `GC_pthread_create` or register
  with `GC_register_my_thread`; the libuv pool threads stay unregistered on
  purpose, since they never touch GC memory. The runtime struct stays on
  the main thread's stack, which Boehm scans, for the whole run. MPSC wake
  and hand-off queue nodes, and the run-queue and steal-deque storage, are
  GC-allocated; if one is not, the task or payload it carries is also
  rooted in the owner's registry until it is drained. Collections
  stop the world; that cost is accepted and measured (round 2 benchmarks,
  which also measure contention on the packed word of the Stall check).
  Boehm stops threads with signals, installed with `SA_RESTART`, and the
  VM's syscall paths retry on
  `EINTR`, and libuv signal handling (`uv_signal_t`) must never take
  Boehm's suspend and restart signals.
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
  without locks. Any in-place mutation inside the VM (caches, updates in
  place when a value is known to be unique, the faster lists of roadmap 8d)
  must be proven unshared or made atomic. Future mutable structures (for example mutable vectors)
  and the shared tables of `docs/future/13-ats.md` §13 must use an owner scheduler or
  locks and atomics. A table call does not yield, so it is atomic with N=1;
  once N>1, each table call needs a lock, an owner scheduler, or a
  persistent structure installed with compare-and-swap (as the evaluator
  does with `box-cas!`).
- **Order of work.** First the tasks PR on these split structures with N=1;
  then, if the gate above opens, the multicore schedulers item (N>1, work
  stealing, Boehm threads, the I/O hand-off, and a stress test of the task
  fixtures with
  `--schedulers 4`, under TSan when available; TSan does not get along with
  Boehm's stop-the-world, so that run uses an `AGC_NO_GC`-style build with
  `-fsanitize=thread` that never calls `agc_set_alloc_limit`, so the
  `AGC_NO_GC` block tracking stays off. ASan and TSan, both without GC,
  cover memory errors and data races in the scheduler code; the
  GC-threaded build is covered only by a GC-stress run with
  `--schedulers 4`); then round 2 of the benchmarks covers multicore
  (roadmap phase 12) if it landed. Multicore did not block 7i. The parity rule stays
  black-box (1): with N=1, exit code, stdout, program stderr and diagnostic
  codes match the goldens. The differential, bytecode and golden tests, the `--max-steps`
  sweep and the seeded runs all run the VM with `--schedulers 1`.

