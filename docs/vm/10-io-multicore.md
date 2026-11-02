#### 10.2.3 Multicore: threads and the rules per thread

The multicore model (threads, queues and ownership) is in §16
([`16-architecture.md`](16-architecture.md)); this section keeps the rules
that still apply.

- **Schedulers.** `N` defaults to `uv_available_parallelism()` (respects CPU
  affinity); `--schedulers N` or the variable `AGENTICA_SCHEDULERS` sets it (the
  flag rules are in `08-loader-and-cli.md`, the cases that force one scheduler
  in §16.9, "`--schedulers N`"). `--schedulers 1` gives the N=1 order, which
  still depends on timer and pool timing. `--seed` does not imply one scheduler;
  at N>1 only per-task random values repeat (7.4). The thread split and shared
  queue are in §16.2–16.3.
- **Run queue, idle schedulers and waking:** §16.3 and §16.4 (results are
  published before the task is enqueued). The park and wake protocol below
  handles races while a task is still parking.
- **Cancel and stop flags.** The task's cancel flag and the run's stop flag are
  atomics. The scheduler reads them at the end of each turn, never on the `STEP`
  paths (§10.2.1, One counter for both budgets), so the fast path touches no
  atomic. A cancel or stop takes effect within one turn budget. A task that a
  cancel finds on a turn is ended by its own scheduler at the end of the turn,
  so no signal crosses schedulers (the `vm->yield` of the canceller's scheduler
  is for the canceller's own task).
- **Park and wake protocol.** Each task has an atomic state (`agc_task_state`):
  READY (in the run queue), RUNNING, PARKING, PARKED, WOKEN or DONE. To park,
  the task sets PARKING before it registers its wait (before it posts its start
  request, joins a waiter list, or registers on another task's result). It then
  re-checks its wait condition and its cancel flag. If either is satisfied, it
  unregisters and goes back to RUNNING with one CAS that accepts PARKING or
  WOKEN. A posted request cannot be recalled, so for a job "unregisters" means
  the task detaches it, and the job runs to its end (§16.11). If the outcome
  (§16.5) is already set, the task consumes the job instead. Otherwise it CASes
  PARKING to PARKED. Registering on another task's result is done under that
  task's lock, and fails if the result is already published. A waker acts only
  on PARKING or PARKED. On PARKING it CASes to WOKEN and queues nothing, so the
  task sees WOKEN and re-checks at once. On PARKED it CASes to READY and pushes
  the task on the run queue. A wake that finds any other state is stale and
  dropped. A scheduler that finds WOKEN at the end of the turn queues the task
  itself, and `run_task` sets RUNNING when a turn starts. A resumed task
  re-checks its condition, so a wake is only a hint. No wake is lost, and a task
  is queued at most once. Which waker wins is in §16.5.
  In `vm/task.c`, `agc_task_parking` marks the task PARKING before the builtin
  registers anything (`agc_io_start_then` marks before the job exists), and
  `agc_task_unpark` takes it back to RUNNING when the wait turns out to be
  unneeded; `agc_task_park` only says that the turn ends in a wait (the end of
  the turn is in §16.9, "Atomic task states"). A task that parked on a job has
  `parked` set, and `resume` takes the job's result and writes it to `park_reg`
  whichever way the task got there, so for the job path the waker never writes
  the register and WOKEN needs only the yield; a retry park runs the builtin
  again. The re-check of the wait condition belongs to each builtin.
- **Channels (17b).** A channel's waiter lists change under `rt->sync`, the one
  coarse lock (§16.9), never held across a park. Ring growth copies the slots
  under the lock: an accepted exception, bounded by the capacity and charged as
  turn cost. The lock orders the write of a value before its read on another
  scheduler. The waiter's deadline is a timer of the task (§16.9, "Timers"), a
  second waker beside the wake or hand-on: the state CAS lets one win, and what
  the loser leaves is passed on (§10.2.2, Channel waits). Each task also writes
  its `awaiting` field before it parks, under the lock (Park and wake protocol),
  so two tasks that close a cycle at the same time cannot both miss it: the
  second to take the lock sees the first's field.
- **State split.** `agc_runtime` (shared), `struct agc_vm` (the scheduler) and
  `agc_task` hold what §16.9, "The context split", lists. With N=1 there are
  these deviations: the `fail` jmp_buf is per scheduler (the only `setjmp` is
  the scheduler's own), and the stream locks and `rt->sync` are solo (they take
  nothing) until `agc_share`, since one thread runs the VM (§16.9). With N>1 the
  fields go as follows (§16):
  - Runtime, read-only after start-up: `program` (with its constants, except
    the Globals table, which the entry writes before `main`, see "The Globals
    table" below), `args`, `cwd` (raw bytes, read by `agc_files_init`),
    `no_files`, and the config.
    Shared under rules: the atomic `steps_left` (10.2.1, Quotas), `outcome` (set
    once by a CAS, 6.2), `out` and `err` (one lock per stream, see Output) and
    `sync`, the one lock of the task tree, the channels and the other shared
    state (§16.9).
    Stdin (`in`, an `agc_input`) is a handle on the I/O loop (see I/O
    ownership).
  - Shared: the global run queue (§16.3).
  - The `std/logger` registry (`log` in the runtime, built in `vm/logger.c`,
    the grammar's logging section): the global level, the lowest handler
    rank and an array of (name, rank, handler) in the GC heap, reached only by
    the ten `LogRegistry` builtins. It is the language's one piece of global
    mutable state and is a field of the runtime, not a `static`. With N>1 it
    needs a lock: `rt->sync`, the one coarse lock (§16.9), taken
    around each `LogRegistry` builtin that writes or reads the array (its
    rows are marked `shared`). The level, the lowest rank and the floor (the
    higher of the two) are atomics that the writers change under the lock, so
    `level`, `lowest` and `floor` are leaf rows that read one each without it.
    `install_default` is one native call, so the check for level -1 and the
    writes cannot interleave with another task.
  - I/O thread: the loop, the inbox (§16.4) and the resource registry. As
    built, the registry has its own leaf lock for register and unregister
    (§16.9).
  - Per scheduler: the turn counter and the running task's context (`task`,
    `fail`).
  - Per task: the registers and frames, `random` (7.4), the `fail` jmp_buf
    target (armed on the thread that runs the turn), the string cursor cache,
    and `parked`, the request the task waits on, which it sets while PARKING.
  - A runtime diagnostic or `System.exit` on any scheduler ends the run (6.2):
    the schedulers stop and the exit path (§14.4) runs on the I/O thread after
    it has joined them (§16.9, "Threads").
- **I/O ownership.** Handles stay on the I/O loop, and so does the state that a
  socket's callbacks touch, so a socket needs no lock (§16.2, §16.4, §16.9).
  Stdin is a handle like any other: each read stays whole, because the input
  keeps a FIFO of waiting readers and serves one read at a time. No OS mutex or
  spinlock is held across a park.
- **Output.** Streams to one target share a buffer, FIFO and lock, with the
  loop as sole writer. For N>1 a short lock protects each access and is never
  held across a park. Blocking fallbacks (§14.1) hold it across writes, retry
  short writes and `ferror`, then drop writes once the outcome is set. The final
  `vm/launch.c` diagnostic is exempt. Only interleaving order between tasks is
  not repeatable (§16.8).
- **The I/O thread blocks in its loop.** With nothing to do it blocks in
  `uv_run(UV_RUN_ONCE)`. The inbox's `uv_async_t` is ref'd while schedulers run,
  so the loop stays alive with no other handle, and a request calls
  `uv_async_send` on it. At the end of the run it is unref'd, so an in-process
  harness can close the loop. The real binary ends with `_exit` and closes no
  loop (§14.4: the real binary closes none). With N=1 there is no inbox handle,
  and the "no active handles" check of 10.2.1 still holds. `agc_io_share` makes
  the inbox (§16.9, "The inbox"). The stall check (§16.9, "Stall") never uses
  `uv_run`'s return value.
- **GC.** The build flags and the thread registration rules are in §11. The
  schedulers register with `agc_gc_thread_enter` and leave with
  `agc_gc_thread_leave`; the main thread calls `agc_gc_allow_threads` once after
  `agc_init`, which also starts the mark threads (never with N=1). The libuv
  pool threads and the Windows stdin reader stay unregistered on purpose: they
  touch only `malloc` memory. The runtime struct is GC memory (`agc_vm_init`
  allocates it), reached from the `agc_vm` that stays on the main thread's stack
  for the whole run. Where GC pointers may live is in §16.5, "GC rule".
  Collections stop the world; that cost is accepted. Boehm stops threads with
  signals installed with `SA_RESTART`. The VM's syscall paths retry on `EINTR`,
  and libuv signal handling (`uv_signal_t`) must never take Boehm's suspend and
  restart signals.
  On Windows Boehm stops threads with `SuspendThread`, so a stopped thread may
  hold the `malloc` heap lock, and the collecting thread must not `malloc` until
  the world restarts. Its mark phase calls `signal(SIGSEGV, ...)`, and the UCRT
  allocates a thread's signal table at that thread's first `signal` call, so
  every thread calls `signal` once before it registers (`own_signal_table` in
  `vm/value.c`).
- **No mutable global state in `vm/`.** Every mutable `static` or global
  variable goes into the runtime, scheduler or task struct. Lazy one-time init
  uses `pthread_once` or happens at start-up. `make vm-lint` enforces this with
  clang-tidy's `cppcoreguidelines-avoid-non-const-global-variables` on `vm/*.c`
  and `vm/*.h` (`vm/tests/.clang-tidy` turns it off for the C tests). The check
  does not see function-local `static` variables. The exceptions that stay, each
  marked `// NOLINT(cppcoreguidelines-avoid-non-const-global-variables)`:
  - the `AGC_NO_GC` block tracking in `vm/value.c` (fuzz and test builds,
    single-threaded), the fuzz harness static in `vm/fuzz.c`;
  - the stop state of `vm/loop.c` (lock-free atomics, a pid and the wake
    handle; a function-local `static`, so not marked), since a signal handler
    gets no context (10.2.2, Stop signals);
  - the system trust store in `vm/tls_trust.c` (a `CRYPTO_ONCE` and the list
    it fills once, read-only after; 10.3 Trust), which every TLS setup job of
    every runtime shares, so one load serves the process;
  - the native call of the running thread in `vm/ffi.c` (`current_site`, a
    `_Thread_local` pointer to a record on that call's C stack), since a
    callback that C makes gets no context but its own data and must know
    whether this thread is inside a native call that may run it.

  `setenv("UV_USE_IO_URING", "0", 0)` runs once at start-up (`agc_io_init`,
  before any loop exists), since `setenv` is not thread-safe. `agc_io_init`
  returns whether it set the variable, and `vm/launch.c` keeps that in the
  runtime (`drop_uring_env`) for `Process.spawn` (10.4). It runs once per
  process, also in the single binary, whose two runtimes share the result.
- **Values are immutable**, so tasks on different schedulers share them without
  locks or copies (§16.7). Any in-place mutation inside the VM (caches, updates
  in place when a value is known to be unique, the faster lists of roadmap 8d)
  must be proven unshared or made atomic. Future mutable structures must use
  locks and atomics. The `ATS` tables (the grammar's "Shared tables") are
  built so: a table is one atomic pointer to an immutable state of persistent
  trees, and a write builds the next state and installs it with
  compare-and-swap, retrying when another write won (`vm/ats.c`). A table call
  takes no lock and does not yield.
- **The Globals table** (module constants, the grammar's `Module constants`
  section) is the one place a loaded program is written
  (`agc_program.globals`).
  The loader lets only the entry function write it, in code with no backward
  jump, and refuses any call or closure of the entry in a file with slots. So
  each `GLOBAL_SET` runs at most once, in the main task, before it tail-calls
  `main`, and then the table is only read: it needs no lock and no atomic once
  the other schedulers start. The entry of a front-end file runs only pure
  builtins, so it spawns no task. A hand-made entry could spawn a task before
  its last write, so a run with N>1 starts no second scheduler until the entry
  has handed over to `main` (its first `TAIL_CALL` or `RETURN`; §16.9,
  "Threads"). A slot is a 16-byte value, so per-slot ordering would not stop a
  torn read. At N=1 tasks interleave on one thread and
  nothing is racy.
- **Order of work.** The task fixtures run as a stress test with `--schedulers
  4`, under TSan when available (§16.9, "TSan covers the shared code"). ASan and
  TSan, both without GC, cover memory errors and races in the scheduler code.
  The GC-threaded build is covered only by a GC-stress run with `--schedulers
  4`. The parity rule stays black-box (1): with N=1, exit code, stdout, program
  stderr and diagnostic codes match the goldens. The differential, bytecode and
  golden tests, the `--max-steps` sweep and the seeded runs all run with
  `--schedulers 1`.
