#### 10.2.3 Multicore: threads and the rules per thread

The multicore model (threads, queues and ownership) is in §16
([`16-architecture.md`](16-architecture.md)); this section keeps the rules
that still apply.

- **Schedulers.** `N` defaults to `uv_available_parallelism()` (respects CPU
  affinity); `--schedulers N` or the variable `AGENTICA_SCHEDULERS` sets it,
  capped at 1024, and the flag wins over a valid variable. Invalid values exit
  2, also a bad variable next to a valid flag. As built, both are
  parsed and checked and the default is 1. A count above 1 runs only under the
  test-only switch `AGENTICA_VM_TEST_MULTICORE=1`, and otherwise exits 2 before
  the program loads (§16.9). `--schedulers 1`
  gives the N=1 order, which still depends on timer and pool timing. `--seed`
  does not imply one scheduler; at N>1 only per-task random values repeat
  (7.4). The thread split and shared queue are in §16.2–16.3.
- **Run queue and idle schedulers.** FIFO order, push/pop and condvar rules are
  specified in §16.3. Requeueing a preempted task does not change the packed
  Stall-check word: it remains live.
- **Waking.** State/results are published before enqueueing (§16.3–16.4):
  the I/O thread on job completion, or a scheduler after await/lock completion
  or cancellation. Release/acquire ordering or the per-task lock makes results
  visible to the resumed scheduler. The park and wake protocol below handles
  races while a task is still parking.
- **Cancel and stop flags.** The task's cancel flag and the run's stop flag are
  atomics, checked only on the `STEP` slow path, when the "next stop" counter
  runs out. The fast path still touches no atomic. A cancel or stop takes effect
  within one turn budget. A task that a cancel finds on a turn is ended by its
  own scheduler at the end of the turn, so no signal crosses schedulers (the
  `vm->yield` of the canceller's scheduler is for the canceller's own task).
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
  As built (`vm/task.c`):
  - `agc_task_parking` marks the running task PARKING before the builtin
    registers anything: before it joins a waiter list or the FIFO of a stream,
    posts a request or starts a job (`agc_io_start_then` marks before the job
    exists). `agc_task_unpark` takes the task back to RUNNING, from PARKING or
    WOKEN, when the wait turns out to be unneeded. `agc_task_park` only says
    that the turn ends in a wait.
  - A waker CASes PARKED to READY, not to WOKEN, and pushes: READY means "in the
    run queue", and the scheduler sets READY to RUNNING when it pops the task.
    On PARKING it CASes to WOKEN and queues nothing.
  - The end of the turn is in the scheduler (`agc_task_end_turn`). It traces,
    reads the cancel flag (an atomic) and ends a cancelled task first. Then it
    does the CAS from PARKING to PARKED (`agc_task_commit_park`): from then on a
    waker may queue the task and another scheduler may run it. The one thing it
    does after that is read the cancel flag again (a cancel can fall between the
    first read and the CAS) and claim the task by a CAS from PARKED to READY, to
    end it. A CAS that finds WOKEN queues the task, so the turn yields.
  - A yield after WOKEN does not skip anything the waker prepared. A task that
    parked on a job has `parked` set, and `resume` takes the job's result and
    writes it to `park_reg` when the task runs again, whichever way it got
    there; a retry park (`agc_task_park(vm, true)`) runs the builtin again. So
    for a park that does not retry (the job path) the waker never writes the
    register, and WOKEN needs only the yield.
  - A job's task is recorded before the job is started: `start_job` sets the
    resource's `task` and the task's `parked` before it posts the start request
    (§16.4), so a completion that follows at once finds the task. The outcome
    of the job (§16.5, rule 3) is an atomic that the first writer sets by CAS;
    the resumed task reads it in `agc_io_finish`, and a task that resumes with
    it still pending (woken by a lock hand-on or an awaited task) sets
    EXPIRED itself. The job is freed by its reference count (§16.9).
  - The re-check of the wait condition after the registration belongs to each
    builtin; with one thread it cannot change between the check and the
    registration. Waiter lists and FIFOs that more than one thread touches get
    their locks with those threads (§16.11).
- **Channel lock (17b).** Each channel has a short lock. `send`, `recv`,
  `close`, a wake, a hand-on and a cancelled waiter that leaves its FIFO take
  it, and it is never held across a park. Ring growth copies the slots under the
  lock: an accepted exception, bounded by the capacity and charged as turn cost.
  The lock orders the write of a value before its read on another scheduler. As
  built, the waiter's deadline is a timer of the task (§16.9, "Timers"),
  not a job: a wake or a hand-on and the fire of the timer are two wakers, the
  state CAS lets one win, and both run under `rt->sync`, so the retry of the
  woken waiter sees either its reservation or the passed deadline, and a value
  or slot it does not take is passed to the next waiter, so nothing is lost.
  With N=1 the lock is not needed, and the VM does not take one. Each task also
  writes its `awaiting` field before it parks, under the target's lock (Park and
  wake protocol), so two tasks that close a cycle at the same time cannot both
  miss it: the second to take the lock sees the first's field.
- **Task.map group lock (17a, planned for N>1; not built).** Each `Task.map`
  group will have a small lock for its running list, its ended list and its
  counters. The step function on the caller's scheduler and the end hook of an
  item, which `finish_task` calls on the item's scheduler, will take it; it is
  never held across a park or a cancel (`agc_task_cancel` takes the locks of the
  tasks it reaches, so the step function copies the item it expires out of the
  list, drops the lock and then cancels). The hook adds the item to the ended
  list under the lock and wakes the caller (a hint, as everywhere). The caller
  alone writes a result slot, from the ended list or when it expires an item, so
  each slot is written once, by whichever of the item's end and its deadline the
  caller sees first; an item that ends after it timed out finds itself off the
  running list and does nothing. With a cancelled caller the hook sees the
  cancel flag of the item and does not wake the caller. An item that still has a
  file close pending is not settled; the hook puts itself back on the task and
  runs again from `agc_task_close_done`, on the scheduler that finishes the
  close (unless the item timed out meanwhile, when it is already settled and the
  hook does nothing). With N=1 the lock is not needed, and the VM does not take
  one (as built).
- **State split.** As built (`vm/port.h`): `agc_runtime` (shared),
  `struct agc_vm` (the scheduler: the context every builtin gets, with `rt`, the
  current `task`, the turn counters and the `fail` jmp_buf), and `agc_task`.
  The loop, the registry, the main task and the crash lists are fields of the
  runtime (§16.9, "The context split"). The run queue is a field of the runtime
  (`agc_runtime.runq`, `vm/runq.c`). With N=1 there are these deviations: the
  runtime is GC-allocated by `agc_vm_init` (both are roots for Boehm), the
  `fail` jmp_buf is per scheduler (the only `setjmp` is the scheduler's own),
  and the stream locks and `rt->sync` are solo (they take nothing) until
  `agc_share`, since one thread runs the VM (§16.9). The task state is an
  atomic enum with PARKING and WOKEN (see "Park and wake protocol"). With N>1
  the fields go as follows (§16):
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
    needs a lock; as built it is `rt->sync`, the one coarse lock (§16.9), taken
    around each `LogRegistry` builtin (its rows are marked `shared`).
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
  - A runtime diagnostic or `System.exit` on any scheduler ends the run (6.2).
    That scheduler records the outcome once and wakes the I/O thread and the
    idle schedulers. The others stop at their next `STEP` slow path or when they
    wake. The exit path (§14.4) runs on the I/O thread, after it has joined
    every scheduler thread (§16.9, "Threads").
- **I/O ownership.** Handles stay on the I/O loop. Schedulers request
  operations through its inbox and tasks resume via the global queue, not a
  handle-owning scheduler (§16.2, §16.4). The I/O thread also owns the state
  that a socket's callbacks touch (buffers, TLS session, request slots), so a
  socket needs no lock (§16.9).
- **Stdin.** A handle on the I/O loop like any other. Reads from any scheduler
  are requests. Each read stays whole, because the input keeps a FIFO of waiting
  readers and serves one read at a time. No OS mutex or spinlock is held across
  a park.
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
  loop (Shutdown). With N=1 there is no inbox handle, and the "no active
  handles" check of 10.2.1 still holds. As built, `agc_io_share` makes the
  inbox (`vm/inbox.c`) and gives the loop to the thread that calls it; until it
  runs, every request executes on the thread that posts it.
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
  other schedulers (10.2.1, Stall check). As built the check is not this word:
  the I/O thread runs it when it has nothing to do (§16.9, "Stall").
- **Shutdown.** `end_run` runs on the I/O thread; it does not close each handle
  or free the loop (§14.4; §10.2.2, "End of run").
- **GC.** Boehm is built with `GC_THREADS`, `PARALLEL_MARK` and
  `THREAD_LOCAL_ALLOC`; as built, this holds for the vendored `gc.o` and the
  distro's libgc, and `vm/value.c` defines `GC_THREADS` before it includes
  `gc.h`. The threads libuv starts (the schedulers) register with
  `agc_gc_thread_enter` (`GC_register_my_thread`) and leave with
  `agc_gc_thread_leave`; the main thread calls `agc_gc_allow_threads` once
  after `agc_init`, which also starts the mark threads. The libuv pool threads
  stay unregistered on purpose, since they never touch GC memory; so does the
  Windows stdin reader thread, which touches only `malloc` memory. With N=1 no
  one calls `agc_gc_allow_threads`, so no mark thread exists. The runtime
  struct is GC memory (`agc_vm_init` allocates it), reached from the `agc_vm`
  that stays on the main thread's stack for the whole run. The run queue lives
  in GC memory, so a head in `malloc` memory never hides a task from the
  collector. Jobs and the inbox are `malloc` memory with no GC pointer, and a GC
  resource owns each job (§16.5). Collections stop the world.
  That cost is accepted. Boehm stops
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
    `vm/fuzz_main.c`;
  - the stop state of `vm/loop.c` (lock-free atomics, a pid and the wake
    handle; a function-local `static`, so not marked), since a signal handler
    gets no context (10.2.2, Stop signals);
  - the system trust store in `vm/tls_trust.c` (a `CRYPTO_ONCE` and the list
    it fills once, read-only after; 10.3 Trust), which every TLS setup job of
    every runtime shares, so one load serves the process.

  `setenv("UV_USE_IO_URING", "0", 0)` runs once at start-up (`agc_io_init`,
  before any loop exists), since `setenv` is not thread-safe. `agc_io_init`
  returns whether it set the variable, and `vm/launch.c` keeps that in the
  runtime (`drop_uring_env`) for `Process.spawn` (10.4). It runs once per
  process, also in the single binary, whose two runtimes share the result.
- **Values are immutable**, so tasks on different schedulers share them without
  locks or copies (§16.7). Any in-place mutation inside the VM (caches, updates
  in place when a value is known to be unique, the faster lists of roadmap 8d)
  must be proven unshared or made atomic. Future mutable structures, and the
  shared tables of `docs/future/13-ats.md` §13, must use locks and atomics. A
  table call does not yield, so it is atomic with N=1. Once N>1, each table call
  needs a lock, or a persistent structure installed with compare-and-swap.
- **The Globals table** (module constants, the grammar's `Module constants`
  section) is the one place a loaded program is written
  (`agc_program.globals`).
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
- **Order of work.** The task fixtures run as a stress test with
  `--schedulers 4`, under TSan when available (`make vm-tsan` runs the C tests
  of the shared code, §16.9). TSan does not work with Boehm's stop-the-world,
  so that run uses an `AGC_NO_GC`-style build with `-fsanitize=thread` that
  never calls `agc_set_alloc_limit`. ASan and TSan, both without GC, cover
  memory errors and races in the scheduler code. The GC-threaded build is
  covered only by a GC-stress run with `--schedulers 4`. The parity rule stays
  black-box (1): with N=1, exit code, stdout, program stderr and diagnostic
  codes match the goldens. The differential, bytecode and golden tests, the
  `--max-steps` sweep and the seeded runs all run with `--schedulers 1`.
