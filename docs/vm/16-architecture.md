## 16. VM architecture

**Status:** decided by the owner on 2026-10-13, row 7.2.1c of the
[roadmap](../roadmap/README.md). This is the one picture of the threads, the
queues and who owns what. The VM runs one scheduler per logical core by default;
with N = 1 the scheduler and the loop share one thread. §16.9 says what differs,
and this model also serves N = 1.

The model has one loop, one run queue and no home scheduler for a task. A BEAM
style design (one loop, run queue and resource registry per scheduler, a home
scheduler for each task, work stealing first) was rejected. §10.2.3 keeps the
rules per thread (the park and wake protocol, the cancel and stop flags, the
state split, the stream locks, the `--schedulers` flag). §14's five rules hold
in this model; §16.6 maps each to the component that enforces it.

### 16.1 Components

- **Runtime** (`agc_runtime`): the program, the arguments and the settings.
  Shared by every thread and read-only after start-up, except the atomics and
  locks that §10.2.3 lists (`steps_left`, `outcome`, one lock per output stream)
  and the Globals table, which the entry writes before `main` (§16.7).
- **Schedulers:** N threads that run the interpreter. A scheduler takes a ready
  task from the global run queue, runs one turn (§10.2.1), then parks it, ends
  it or puts it back. It never calls libuv (§16.2).
- **Global run queue:** the FIFO of ready tasks. Many producers, N consumers
  (§16.3).
- **I/O thread:** the main thread after start-up. It runs the only libuv loop
  and has an inbox of requests from the schedulers (§16.4).
- **Windows stdin reader:** one VM thread that makes the blocking `_read` of
  stdin and wakes the I/O thread with an async handle (§14.1).
- **libuv thread pool:** bounded blocking work only: regular files and
  directories, DNS, and the TLS setup jobs that load CA, certificate and key
  files (§14.1). Its threads never touch GC memory.
- **Compute pool:** the native calls of `compute def`, which may run without
  bound: at most one thread per scheduler, FIFO, apart from the libuv pool
  (§16.9). Its threads never touch GC memory.
- **Handles and their owner tasks:** a socket, listener, pipe, terminal, process
  or poller is a libuv handle on the I/O loop for its whole life. The task that
  opened it owns it (§14.5). A regular file is not a handle on the loop: pool
  jobs use it as a descriptor.
- **Jobs:** a task's pending operation: `malloc` memory with raw bytes and up to
  three libuv pieces (pool work, the one timer, a wait on the loop), owned by a
  GC resource in the registry (§16.5).
- **GC:** Boehm, built for threads. Every scheduler thread and the I/O thread
  are registered with it.

```text
 +------------------+  request: start, cancel, release...       +--------------------+
 |  schedulers      | ----------------------------------------> |  I/O inbox         |
 |  1 .. N          |        then uv_async_send                 +---------+----------+
 |  (interpreter)   |                                                     |
 +--------^---------+                                                     v
          | pop one task                                         +--------------------+
 +--------+---------+  push, the result is already in the job    |  I/O thread        |
 |  global run      | <----------------------------------------- |  (main thread)     |
 |  queue           |                                            |  the only libuv    |
 +------------------+                                            |  loop              |
                                                                 +----+----------^----+
                                                          uv_queue_work |        | after_work
                                                                        v        |
                                                                 +----------------+---+
                                                                 |  libuv thread pool |
                                                                 +--------------------+
```

### 16.2 Threads

- **One scheduler per logical core.** The default and the flag are in §10.2.3.
- **The main thread starts the VM, then becomes the I/O thread.** Start-up (the
  GC, the environment, the hash keys, the locale, the program load) and the
  start of the scheduler threads come first. Then the main thread runs the only
  libuv loop (timers, sockets, pipes, FIFOs, terminals, pollers). It also owns
  the run's life cycle: the stop signals and the one exit path (§14.4).
- **Only the I/O thread touches libuv.** The one call other threads make is
  `uv_async_send` on the inbox's handle, which libuv allows from any thread.
  Every step that calls libuv is a request to the I/O thread (§16.4). The pool
  runs only the `work` half of a job, on `malloc`'d memory (§10.2.2).
- **The I/O thread moves bytes and builds no GC values.** It reads into and
  writes from `malloc`'d buffers: a job's, and a socket's input buffer
  (`agc_conn.in`), which it owns (§16.11). Stdin is read into a job's buffer (on
  Windows, the reader thread's own buffer) and appended to the shared input by
  the `done` half, on a scheduler. The `done` half of a job, which builds GC
  values from those bytes, runs on the scheduler that resumes the task. TLS
  crypto runs on the I/O thread beside the socket state it reads and writes
  (`vm/tcp.c`), so a slow handshake delays the loop. Moving it to the schedulers
  is a later step (§16.10).
- **No dispatcher thread.** Schedulers pull work; nobody pushes a task at a
  chosen scheduler.

### 16.3 Queues

KISS. Every queue is an intrusive singly linked list with `first` and `last` and
one `uv_mutex_t`, which libuv makes portable to Windows. The `next` link lives
in the task (run queue) or in the request entry (inbox). A task push allocates
nothing; a request push allocates its entry. A push is O(1) at the tail and a
pop is O(1) at the head.

The run queue is `vm/runq.c`: `agc_runq_push`, `agc_runq_wait` (the pop that
waits) and `agc_runq_end`, with a `uv_cond_t`. A push signals the condvar after
the unlock. The inbox (`vm/inbox.c`) has `agc_inbox_post` and `agc_inbox_run`,
which takes the whole list. A solo queue never waits: `agc_runq_wait` returns
NULL when it is empty. After the end, `agc_runq_wait` returns NULL even if tasks
are left: the run is over. The rules:

- **Wake after publish.** The producer prepares the entry outside the lock,
  links it under the lock, unlocks, and only then wakes the recipient. The lock
  publishes everything written before the push (a job's result, a task's state).
  This holds for the push path only. A waker that finds the task still PARKING
  does not push (§10.2.3). There the state CAS from PARKING to WOKEN must be
  `acq_rel`, so the task sees the outcome (§16.5) and what else the waker wrote.
- **Single-consumer queues** (the I/O thread's inbox, and one inbox for each I/O
  thread if there are K of them, §16.10) are taken whole in one lock (`first =
  last = NULL`). The consumer handles the whole list in that turn, outside the
  lock. It keeps no remainder.
- **The global run queue has N consumers**, so a scheduler pops one task under
  the lock, never the whole list and never a batch. Taking more would leave the
  other schedulers idle with work waiting.
- **Idle schedulers wait on the condvar**, with no busy waiting. A push signals
  one. A scheduler checks the queue and waits under the same lock, so a signal
  after the unlock is never lost. The wait is always in a loop that tests its
  condition again (`agc_runq_wait`): a condition wait may return with no signal,
  and Boehm's suspend signals can interrupt it. The flag that ends the wait
  (`ended`, set when the run stops) changes under the same lock, as
  `agc_runq_end` does. Set outside the lock, a stop wake could fall between the
  test and the wait and be lost. The I/O thread's wake is `uv_async_send`.
- **Not lock-free, on purpose.** Atomic `first`, `last` and `next` do not make
  the operation atomic, and node reuse (ABA) and producers suspended halfway
  make it hard to get right. A mutex with light contention is fine. Measure
  contention and latency before changing the algorithm. This is not a temporary
  design.

### 16.4 Two directions

- **To the schedulers: the global run queue.** The I/O thread writes the result
  into the job (raw bytes), sets the outcome and pushes the task (§16.5). The
  push publishes the result (§16.3). Schedulers push too: a spawn, a yield, and
  the wake of an awaiter or of a lock waiter. Whoever wakes a task follows the
  park and wake protocol of §10.2.3, so a wake that arrives while the task is
  still parking is not lost.
- **To the I/O thread: its inbox.** A request is its own small `malloc`'d entry
  (`agc_request`, `vm/core.h`). A job is never linked into the inbox, so one job
  can have several requests in flight. The kinds are: start a job (a read,
  write, close, accept and so on, on handle H), cancel it, stop or extend its
  timer, release it, and the libuv step of a `done`, `expired` or cancel half. A
  scheduler marks its task as parking and posts the start request. The inbox's
  lock publishes what it wrote, the mirror of wake after publish (§16.3). Then
  it calls `uv_async_send` and ends the turn. The I/O thread takes the inbox
  whole and handles every request: for a pool job it calls `uv_queue_work`, and
  for every job with a timeout it arms the job's one timer (§14.2).
- **The pool keeps its own mechanism.** Its `after_work` callback runs on the
  I/O thread, which sets the outcome and pushes the task (§16.5). There is one
  path back from I/O, and it is always the run queue.
- **Invariant: a task is in one place at a time.** It is running, in the run
  queue, or parked with one pending wait. So the task's intrusive link is safe,
  and the run queue holds at most the live tasks. Two cases need care:
  - **The PARKING window.** Between the mark and the final CAS, the task still
    runs on its scheduler while its job may already be started, or done. §10.2.3
    covers it.
  - **A lock wait with a deadline.** The task is in the handle's lock FIFO, and
    its timer is in its scheduler's heap (§16.9). The waker that wins takes the
    task out of the FIFO before it pushes it, so the task is never in the FIFO
    and the run queue at once (§16.6).

Each kind of request is posted at most once per job, so the inbox is bounded by
the live jobs times the number of kinds. The live jobs are those of live tasks,
detached jobs, and consumed jobs with libuv pieces still open. Neither queue
needs backpressure.

### 16.5 Ownership and lifetime

The rules below are invariants (§16.11 lists what is open).

- **A job is `malloc` memory owned by a GC resource.** `start_job` in
  `vm/loop.c` allocates it with its `uv_work_t` and `uv_timer_t`, and registers
  it as a GC `agc_resource`. It holds raw bytes and ids, never a GC pointer. The
  I/O thread follows no pointer from `malloc` memory into the GC heap. It goes
  from the job's resource id (`r->id`; a registry slot moves when
  `agc_unregister` fills a gap) to the resource and to `r->task` through the
  registry (§16.9), and links the task into the run queue.
- **A handle belongs to the I/O loop** for its whole life, as a `malloc`'d libuv
  handle that lives until its `uv_close` callback (§10.2.2). The task that
  opened it owns it (§14.5). Ownership decides who closes the handle, not who
  may use it: any task reaches it through a request, and the handle's lock FIFO
  (§10.2.2) keeps the operations in order. A regular file is no handle: its
  state is used by pool jobs, and its close is a pool job.
- **GC rule.** A queue that links GC objects lives in GC memory or is a
  registered root, as the run queue does for tasks. `malloc`'d structures (jobs,
  requests, handle state) hold ids and raw bytes, never a GC pointer. No GC
  pointer is stored in memory that libuv owns.

The invariants:

1. **Only the I/O thread calls libuv** (except `uv_async_send`, §16.2). Every
   libuv step from a scheduler is a request, with its own entry (§16.4).
2. **A job is freed when its reference count reaches zero.** The count is one
   atomic (`acq_rel`). Every holder counts: each libuv piece in progress, the
   task until it has consumed the job, each request in flight, and a waker until
   it has pushed. The poster takes the reference before it posts, and the
   request carries it. The I/O thread drops it as its last access after it
   handles the request, and then frees the request entry. A winning waker drops
   its reference after its push. A scheduler gives its references back by a
   RELEASE request, so the last drop is always on the I/O thread. That holder
   puts the job on the dead list, and the sweep that follows frees it (§16.9).
   Nothing touches the job after its handler frees it. `drop` runs on the I/O
   thread even for drops that only free memory, to keep one rule.
3. **The first to set the job's outcome wins.** The outcome (done, expired or
   cancelled; not the run's `outcome`) is set once, by CAS from "none". Only the
   winner takes the task off its wait list and does the state CAS. It pushes the
   task once, and only if it moved the task from PARKED. In the PARKING window
   it does not push, and the task re-checks. A loser ends only its own piece. A
   cancel never reaches the job: `agc_task_cancel` sets the cancel flag and does
   the state CAS only. The resumed task, which holds its own reference, detaches
   the job (the "cancelled" outcome, by the same CAS) and posts the cancel
   request. A wait with no job (`Task.await`, stdin waiters) uses the state CAS
   only. A parked channel wait always has a deadline, a timer of the task
   (§16.9, "Timers"), not a job, so it too uses the state CAS only.
4. **Memory order.** The outcome CAS is release and the task's read of it is
   acquire. The resumed task reads the outcome.
5. **Completion** is set when the job's last phase ends: `after_work` for a pool
   job without a `more` step ([§14.1](14-core-invariants.md#141-waiting)), and
   the end of the wait on the loop (`ready`) otherwise. Every job has pool work
   or a wait. `start_job` refuses a kind with neither, since a bare deadline is
   a timer of the task (§16.9).

### 16.6 Task life cycle and the rules of §14

A task goes ready, then running, then parked on something, then woken, then
ready again. The woken task always comes back through the run queue. Each wait
kind has a usual waker, but a wait can also end by its timeout or by a cancel,
so a task can have two wakers at once.

- **Pool job** (a regular file, DNS, TLS setup loads): woken by the I/O thread
  in `after_work` (outcome, push). Also ended by the job's timer or a cancel.
  The job is on the loop, and the task sits in no list.
- **Loop job** (socket, pipe, FIFO, terminal, poller, a child's exit): woken by
  the I/O thread when it calls `ready` (outcome, push). Also ended by the job's
  timer or a cancel. No list.
- **Timer** (`Task.sleep`, a deadline): woken by the owner scheduler in
  `agc_timers_run`. Also ended by a cancel. No list.
- **Handle lock FIFO:** woken by the scheduler that ends the holder's job
  (hand-on, push). Also ended by the lock wait's deadline (a timer of the task,
  §16.9) or by a cancel. The list is the handle's FIFO, under `rt->sync`
  (§16.9).
- **`Task.await`:** woken by the scheduler that ends the target task (push).
  Also ended by a cancel of the awaiter. The list is the target's awaiters,
  under that task's lock (§10.2.3).
- **Stdin read that another task already started:** woken by the scheduler that
  ends that read's job (push). Also ended by a cancel. The list is the input's
  FIFO, under `rt->sync`.
- **Channel** (`send` or `recv`, 17b): woken by the scheduler of the task that
  sends, receives or closes (push). Also ended by the deadline (a timer) or by a
  cancel. The list is the channel's waiter lists, under `rt->sync`.

**The first to set the outcome wins** (§16.5). Two wakers can race, for example
a hand-on and a lock deadline; the loser's wake is stale. A wait can hold two
registrations, a place in a list and a timer. The winner takes the task out of
the list before it pushes it. A timer that wins does so under the list's lock,
or by a request to the list's owner. So the task is never in a list and in the
run queue at once. If the timer of a job is still armed, the resumed task posts
a request to stop it (§16.4), and the job is freed by its reference count
(§16.5). A timer of the task (§16.9, "Timers") is disarmed by `resume` under
`rt->sync`. A resumed task still re-checks its wait condition (§10.2.3), so a
late wake is only a hint.

`agc_task_cancel` is not a wait kind. It is a waker for every row above, and it
never touches the job (§16.5, rule 3). A ready task is ended without running
(§16.11).

The rules of §14 and the component that enforces each:

- **Rule:** §14.1 Waiting: a task only parks, and nothing waits where the loop
  cannot cancel.
  - **Enforced by:** The schedulers never wait on a descriptor. The I/O thread
    never blocks on one: every descriptor that can wait is non-blocking on the
    loop. The pool takes only bounded work.
- **Rule:** §14.2 Timeouts: one timer on the job.
  - **Enforced by:** The I/O thread owns the job's single `uv_timer_t` and arms
    it when it starts the request.
- **Rule:** §14.3 Cancelling: `agc_task_cancel`.
  - **Enforced by:** It runs on the canceller's scheduler. It sets the cancel
    flag, takes the task out of the wait lists a scheduler owns, and does the
    state CAS. It never touches the job. The resumed task detaches the job and
    posts the cancel request to the I/O thread.
- **Rule:** §14.4 Ending: one exit path.
  - **Enforced by:** `agc_launch_end` in `vm/launch.c` runs on the main thread,
    which is the I/O thread.
- **Rule:** §14.5 Handles: owned by the task that opened them.
  - **Enforced by:** The owner is recorded in the resource. A close is a request
    to the I/O thread, the only thread that touches handles.

### 16.7 Sharing

Threads in one VM share immutable values without copying. There are no per-task
heaps and no message copies (§10.2.3). The one table a run writes into the
loaded program is the Globals table of the module constants (§10.2.3, "The
Globals table"). Between VMs, the only sharing is by OS processes, and it is
explicit: `Process.spawn` and the planned fd 3 channel of 25c, like Erlang nodes
talking to each other.

### 16.8 Risks and notes

- **Boehm stops all threads at once.** Every collection stops every scheduler
  and the I/O thread. This is the main cost of threads against BEAM's
  per-process heaps. Parallel marking helps. The signals it stops threads with
  are in §10.2.3, GC.
- **stdout and stderr are locked per stream when N > 1** (§10.2.3, Output). A
  print is a copy into the stream's buffer, or a wait in its FIFO, and the loop
  writes it (§10.2.2). So only the blocking fallbacks (§14.1) can block a
  scheduler thread that holds a lock. Why the lock is short and never held
  across a park is in §16.11. At N = 1 nothing is locked.
- **One bounded wait on the exit path.** `close_children` (§14.4, step 1) does
  not block the loop thread: it runs the loop (`await_exits` in
  `vm/process.c`, `uv_run` under a timer) until libuv's exit callbacks have
  reaped the children. `Process.close` does not wait on the loop thread. It
  parks its task on a job with a timer.
- **One lock on the run queue** is shared by every scheduler and the I/O thread.
  Measure it (§16.3).
- **One I/O thread** may become the limit at a high rate of sockets. §16.10 is
  the next step.
- **A wake crosses threads.** An I/O result goes through a push and a condvar
  signal before a scheduler runs the task. With `--schedulers 1` there is no
  hop. Measure the latency.

### 16.9 As built

At N = 1 the model is almost what exists: tasks, turns, jobs with their
`agc_io_kind` halves, detached jobs, the handle lock FIFO, the owners and the
one exit path are as in §16.1 to §16.6. What differs:

- **One thread plays both roles at N = 1.** The scheduler calls
  `uv_run(UV_RUN_NOWAIT)` after each turn and `uv_run(UV_RUN_ONCE)` when the run
  queue is empty (§10.2.1, §10.2.2). A separate I/O thread beside one scheduler
  thread at N = 1 is not used: the libuv code of the services would also run
  beside the interpreter, which §16.11 leaves open, and every deadline wait (a
  channel wait, a timed await, `Task.sleep`) would pay a timer job. A prototype
  ran the task-switch benchmark several times slower. The request code is the
  same at any N. What differs is where the loop runs: a request posted on the
  loop's thread runs at once, and one posted from another thread is queued and
  wakes the loop.
- **The inbox** (`vm/inbox.c`) is a locked queue of `malloc`'d `agc_request`
  entries, taken whole by the loop's thread and woken by a `uv_async_t`. The
  poster sends after it unlocks (§16.3). It does not exist at N = 1: no handle,
  no descriptor. `agc_io_share` makes it and gives the loop to the calling
  thread. A run with N > 1 and the C tests call it, as they call
  `agc_runq_share`. The run queue (`agc_runtime.runq`, in GC memory) is solo in
  the same way: while one thread uses it, it takes no lock, and `agc_runq_share`
  turns the lock on for push, pop and remove. It must run before a second thread
  touches the queue.
- **The libuv steps of a job are requests** (`vm/loop.c`): START (the timer and
  the pool work of `start_job`), CLOSE_TIMER, RELEASE (a reference given back; a
  scheduler posts it, so the count reaches zero on the loop's thread), DETACH
  (the cancel half and the ready list, which only the loop's thread touches),
  EXPIRE_CANCEL (the cancel at a detached job's deadline), WAIT_DONE and CALL (a
  libuv step with no job). `post` runs one at once on the loop's thread, with no
  entry. libuv callbacks put the job on a ready list. The scheduler drains it
  after `uv_run` and queues the tasks. That drain is the push of §16.4, and it
  keeps a woken task behind the one whose turn just ended.
- **Compute pool** (`vm/compute.c`). `agc_io_compute` starts a job whose `work`
  is a native call; its START gives the work to the compute pool instead of the
  libuv pool. The pool is made at the first such START, on the loop's thread,
  with N threads at most, started when an item finds none free, with the stop
  signals blocked. The arguments are copied on the scheduler and the result is
  built by the `done` half on the scheduler that resumes the task. An item that
  ends goes back to the loop's thread through the pool's own inbox, which exists
  at N = 1 too and keeps the loop alive only while items run, and ends the job
  as libuv's `after_work` does. So a compute job is a pool job: no deadline, no
  cancel half, and a cancel detaches it. A detached item still in the queue
  skips its `work`; a running one drops the result once the call returns. The
  end of the run does not wait for it; `agc_io_close` (harnesses, the front
  end) joins the idle threads and leaves a busy one to end by itself.
- **Services.** Service code makes its handles through `agc_loop_uv` (§15.1).
  The libuv part of its `done`, `expired`, cancel and `drop` halves, and the
  poller calls of builtins, run where the half runs. At N > 1 the steps of the
  standard streams and of polled files (stdin, FIFOs) are requests: the start of
  a stream write, a poller wait with no deadline, and every poller pause and
  close go through `agc_io_call`. The stdin poller is opened before the
  schedulers start, and a polled file's poller in its job's `more` step. Both
  run on the I/O thread (`agc_poller_open` aborts elsewhere). So at N > 1 stdin
  is watched from the start of the run, where N = 1 watches it at the first
  read. A default above 1 changes that for every program. A wait with a deadline
  starts in the job's START, before its timer is armed. The kind's `pause` stops
  it on the I/O thread before EXPIRED is published, so `expired` never runs
  beside one of its callbacks. TCP and TLS are requests at every N: the I/O
  thread owns each connection (`net` in `vm/tcp.c`: its TLS session, buffers,
  request slots and counts). A builtin posts its step as the START's `more` step
  (`agc_io_start_then`) and parks. A close and a resource's release are posted
  with `agc_loop_call`. `finish` fills the request on the I/O thread, and the
  `done` half reads only the request and then posts its `drop`. A socket's
  `cancel` and `pause` touch only the request and the connection, never a
  resource or a task. The builtins post under `rt->sync`, so their steps reach
  the inbox in the order of the calls. At N = 1 the steps run inline, and a read
  of buffered bytes or a send that goes out at once returns without a park
  (`agc_io_here`). The HTTP server keeps its state on the I/O thread the same
  way (§10.7.2). Processes and the child channel are requests too. The I/O
  thread owns each child's handles, buffers and request slots, and a posted
  request carries its result, which the `done` half reads. At N > 1 a spawn, a
  close and `Process.read_available` park too. The parent channel of a child run
  (`Test.run`) opens at the start of the run (`agc_parent_take`). `agc_io_uv`
  aborts off the I/O thread.
- **An outcome and a count, not flags.** A job has an atomic outcome (PENDING,
  DONE, EXPIRED or CANCELLED), set once by CAS (`agc_job_settle`, release;
  `agc_io_finish` reads it with acquire). It also has an atomic reference count.
  The holders are the owner (the task until `agc_io_finish`, or the detached
  ending), the wait piece (while the pool work or the loop wait runs; the atomic
  `busy`), the ready list, and each request in flight. The timer is no holder:
  it never touches `data`, and `sweep` waits for its close. Only the holder that
  clears `busy` gives back the wait piece's count, so a late end of an abandoned
  wait changes nothing. A pool or loop completion sets DONE, the timer sets
  EXPIRED, a detach sets CANCELLED, and a task that resumes with the outcome
  still PENDING (a lock hand-on or an awaited task woke it) sets EXPIRED itself.
  So the first outcome stands. The holder that brings the count to zero puts the
  job on the loop's dead list. `sweep` walks that list only, so its cost is the
  jobs that ended, not the jobs alive. `drop` takes `data` when the count is
  zero, and the job is freed once the timer has closed. Only the loop's thread
  sweeps. A START that the inbox still holds when the owner ended the job starts
  nothing. `ended` is set before CLOSE_TIMER and RELEASE are posted, and the
  START gives back the wait piece's count.
- **The detached ending runs on a scheduler once threads exist.** `drain` calls
  `end_detached` itself while one thread plays both roles. When the loop is
  shared (`agc_io_share`), the drain only queues the detached job on
  `loop->service` (it keeps the ready list's count on it) and nudges the run
  queue (`agc_runq_nudge`). `done` builds GC values and may close a handle, so
  it never runs on the I/O thread (§16.5). A scheduler calls `agc_io_service`
  when `agc_runq_nudged` is set at its turn boundary. It also does so when
  `agc_runq_wait` returned NULL with a nudge pending and `agc_runq_take_nudge`
  says it is the one to run it. The wait predicate tests the flag under the
  queue's lock, so a nudge is never lost. The service runs each ending with
  `rt->sync` held and a scratch task current, and gives the count back by a
  RELEASE request. The owner's count goes back before `done` runs, so a `done`
  that raises does not leak the job.
- **The context split.** `agc_runtime` (`vm/port.h`) holds the state that every
  scheduler and the I/O role share: among others `main`, `registry`, `loop`,
  `process_guard`, the crash and quiet lists with their counters, and the atomic
  `tasks_done`. `agc_vm` keeps the scheduler's own context: the current task,
  the turn and stop counters, `yield`, `in_turn`, `sync_depth`, the profile and
  the two jmp_bufs. The registry has its own leaf lock (solo until `agc_share`):
  `agc_register`, `agc_unregister` and `agc_resource_id` take it. A job points
  to its resource (`res`), so the I/O role never looks a job up by slot, since
  `agc_unregister` moves slots (swap-with-last). The walks of the whole registry
  (`release_handles`, `agc_io_goodbye`, `close_files`, `close_all`, `flushing`)
  copy it under the lock first (`registry_snapshot`). They skip an entry
  unregistered since, and run at the end of the run on the loop's thread.
- **Timers.** A task that waits for a deadline (`Task.sleep`, a timed await, a
  channel timeout, a `Task.map` timeout, a handle lock timeout) arms its own
  entry (`agc_timer` in `agc_task`). The entry goes in the min-heap of the
  scheduler that runs the task (`vm->timers`, `vm/timers.c`, ordered by deadline
  and then by arming order), and the task parks (`agc_task_park_until`). There
  is no job, no registry slot and no count, so no START, CLOSE_TIMER or RELEASE.
  A channel wait parks with `agc_task_park_within` instead, which reads no
  clock: the entry waits in the scheduler's one `pending` slot, and the
  scheduler starts its clock at the end of its next turn, at its next such
  park, or before it sleeps. A task woken before then drops the entry, so a
  wait that the peer ends in its next turn never reads the clock (a system
  call on a host with an HPET clock source). Its timeout can then be late
  by at most one more turn than that of another timer, which also waits for a
  turn boundary to fire.
  The scheduler fires its due timers at its turn boundary and when its run queue
  is empty (`agc_timers_run`), by waking the task like any waker. Every change
  to a heap is made with `rt->sync` held. So any scheduler can remove the entry
  at once: the task leaves the heap when it resumes (`resume`) or is cancelled
  (`unlink_task`), under the lock the fire takes. A fire never wakes a task that
  has left the wait. When `rt->sync` is split, a removal from a scheduler that
  is not the owner becomes lazy. The CAS of an outcome decides, the owner drops
  the dead entry when it pops it, and the heap is rebuilt when the dead entries
  are twice the live ones. A due timer fires at the owner's next turn boundary
  or idle step, so it is late by at most the rest of the current turn and one
  poll of the loop. At N = 1 an idle scheduler runs the loop once, bounded by
  the nearest deadline (`agc_io_run_for`). An armed timer counts as work for the
  stall check (`vm->timers.next_due`). At N > 1 an idle scheduler waits on the
  run queue until its nearest deadline (`agc_runq_wait_until`), and the stall
  check reads the armed-timer count of every heap (`rt->timers_armed`). A
  service task's timer (the idle wait of an HTTP client worker,
  `agc_task_service`) is counted in `rt->timers_weak` too. Both checks wait only
  for the other timers (`agc_timers_strong`), so at N = 1 the bounded run needs
  a live loop, else the run has stalled. No other task waits on such a timer, so
  it cannot be the work that ends a stall. Deadlines of real I/O jobs (a work or
  external job) stay on a libuv timer, started by the START request that the job
  pays anyway.
- **A post after the loop closed is loud.** `agc_io_share` marks the loop shared
  for good, so `on_io_thread` keeps comparing thread ids after `agc_io_close`
  clears the inbox. A post from another thread after close writes a message and
  aborts (`post_after_close`). It guards against a bug, not a program:
  `vm/tests/job_test.c` runs this case in a child.
- **TSan covers the shared code.** `make vm-tsan` builds the VM without libgc
  (`TSAN=1`, `AGC_NO_GC`; TSan and Boehm's stop-the-world do not mix). It runs
  the C tests that use more than one thread: the inbox, the set-once outcome and
  count, the run queue, wake and cancel against park, jobs, `rt->sync`, the
  output locks, timers, and whole runs on four schedulers in
  `vm/tests/threads_test.c`. `make vm-tsan-run` runs
  `tests/test_vm_multicore.py` on the same build, with the release front end.
- **The task is recorded before the job starts.** `start_job` sets `r->task` and
  `t->parked` before it posts START, so a completion that follows at once finds
  the task.
- **Atomic task states.** The states (`agc_task_state` in `vm/port.h`) are in an
  `_Atomic` field, and the protocol is in §10.2.3, "Park and wake protocol". The
  end of the turn is in the scheduler. It decides the trace and the cancel flag
  first. The CAS from PARKING to PARKED is its last access to the task, apart
  from one more read of the cancel flag (a cancel can fall between the first
  read and the CAS). If the CAS finds WOKEN, the scheduler queues the task, so
  the task is queued once and its next turn takes up the wait again.
- **`--schedulers N`.** `vm/launch.c` reads the flag and `AGENTICA_SCHEDULERS`
  (§10.2.3). The default is at most 1024. The profile trace and
  `AGENTICA_VM_TEST_BLOCKING_OUTPUT=1` need one scheduler. The default count
  then drops to 1, and a count above 1 chosen by the flag or the variable exits
  2 with a message before the program loads. The front end always runs on one
  scheduler, so its output does not depend on the machine.
- **Threads.** `agc_vm_run` with N > 1 (`run_threads` in `vm/task.c`) shares the
  locks and the loop, lets threads register with the GC, makes one scheduler
  context (`agc_vm`) per thread, and starts scheduler 0. The calling thread
  becomes the I/O thread (`agc_io_serve`). Scheduler 0 runs alone until main
  leaves the entry function, which sets the module constants (at once when there
  are none). Then the others start, so no other task can read a constant before
  it is set. Each scheduler pops tasks from the global queue, runs detached
  endings and its due timers between turns, and waits on the queue when it is
  empty. A fatal diagnostic, `System.exit` or the end of main on any scheduler
  records the outcome once (`agc_run_over`, a CAS on `rt->over`) in that
  scheduler's own record. It copies the outcome to `rt->outcome`, ends the run
  queue and wakes the I/O thread. The I/O thread then joins every scheduler
  thread. Only then does it run the detached endings that are left, the report
  of unobserved crashes and the exit path, as at N = 1. So the exit waits for
  the schedulers to stop (at most one turn, as a stop signal does, §10.2.2), and
  no running task uses a file while the exit path closes it. `--max-steps` is
  approximate at N > 1. Each scheduler takes steps from the shared budget in
  batches of up to `AGC_TURN_STEPS`, so the limit can trip while other
  schedulers still hold unused steps of their batch.
- **Stall.** At N > 1 the I/O thread runs the check when it has nothing to do
  (not from `uv_run`'s return value). Every scheduler waits on an empty queue
  (`agc_runq_quiet`, with an epoch that any wake moves). The inbox and the ready
  list are empty, no timer is armed, and the loop has no live handle except the
  inbox's own handle, which is unref'd. The I/O thread then reads the epoch
  again (`agc_runq_still_quiet`). Only the I/O thread makes work in that state,
  so the run has stalled. It ends with the `RUNTIME-INTERNAL` of N = 1. The last
  scheduler to go idle wakes the I/O thread for the check (`agc_runq_on_idle`).
- **Wakes between schedulers.** The run queue stays one global FIFO, with no
  local queues, no stealing and no thread affinity. Three things keep a wake
  cheap (`vm/task.c`, `vm/runq.c`):
  - Each scheduler thread has one runnext slot (`agc_vm.runnext`). A task that a
    scheduler wakes (`agc_task_wake`: a channel, an await, a timer, a lock
    hand-on, a detached ending) goes into that slot when it is free, and to the
    global queue when it is full. The slot keeps its task. A spawn, a yield and
    every wake by the I/O thread go to the queue. The slot is off at N = 1.
    `agc_task_next` takes the slot first, at most `RUNNEXT_LIMIT` (3) times in a
    row. It then pops the queue once and resets the count. With the queue empty
    it takes the slot after all. So two tasks that wake each other run on one
    core, taking the queue's lock only every fourth pick, with no futex wake.
    Only the owner thread touches the slot, and another scheduler never takes
    its task. A task in a slot is READY like a queued one. It counts as pending,
    so the owner never waits while its slot is full, and the stall check never
    sees it idle. A cancel by the owner takes it out of the slot and ends it. A
    cancel from another thread leaves it to the owner's `agc_task_next`, as for
    a popped task. At the end of the run it is left like the queued tasks.
  - An idle scheduler spins before it waits on the condvar (`agc_runq_spin`). It
    polls the queue's atomic `work` flag, not the lock, with CPU pauses whose
    runs double up to 32 (`SPIN_PAUSES_MAX`), for `SPIN_BUDGET_US` (10 µs). It
    never sleeps. At most half the schedulers (at least one) spin at once, and
    none spin at N = 1. A push reads the count of spinners under the queue's
    lock and skips the condvar signal while one spins. No wake is lost. A
    spinner leaves the count before it takes the lock for its wait, so it either
    sees `work`, finds the task in that wait, or left before the push read the
    count, which then signals. A spinner may see several pushes that sent no
    signal, so the wake is chained: a scheduler that leaves a spin or a wait
    with a task, while more tasks are queued, signals one more waiter. Spinners
    do not count as idle for the stall check. Only the condvar wait does.
  - A task whose turn ends ready (a yield, or a wake during its own turn) goes
    back to the queue with `agc_runq_push_own` when its scheduler's slot is
    empty, so that scheduler pops next. If the queue was empty, the push sends
    no signal and does not set `work`: the task is the first one its scheduler
    pops, so it stays on that core. A queue that holds tasks signals as usual.
    With a plain push, one CPU-bound task would wake an idle scheduler at
    every turn and move between cores. A timer or a service end at
    that turn boundary may fill the slot after the push, and the slot's task
    may hold the thread for long (a long builtin, a native call). So the
    scheduler marks the push (`agc_vm.own_pending`), and when its next pick
    takes the slot while the mark is set, it sends the skipped wake
    (`agc_runq_kick`: while the queue holds a task, it sets `work`, and it
    signals when no scheduler spins).
- **A cancel is a claim.** `cancel_one` (`vm/task.c`) sets the target's atomic
  cancel flag, and then the state says who ends the task. Exactly one party
  does. A task on a turn (RUNNING, PARKING or WOKEN) is left to its scheduler,
  which reads the flag at the end of the turn and again after it publishes
  PARKED (`agc_task_end_turn`). Only the canceller's own task gets `vm->yield`.
  Another scheduler's task stops within one turn, as §10.2.3 says. A READY task
  is taken out of the queue and ended. If it is not in the queue (a waker set
  READY and has not pushed, or a scheduler has popped it), `agc_task_next` ends
  it when it pops it. A PARKED task is claimed by a CAS from PARKED to READY
  (`agc_task_claim`), the same race as a waker's, and the winner ends it. The
  ending (`end_cancelled`) walks the task's lists with `rt->sync` held.
- **One coarse lock, not per-channel locks.** The plan of §16.1 to §16.8 puts a
  lock on each channel, waiter list and task. As built there is one mutex,
  `rt->sync` (`vm/sync.c`, an `agc_lock`). It covers the task tree (parent,
  children, waiters, awaiting), the channels, the `Task.map` groups, the logger
  table, the stdin buffer, and the FIFOs of the handles and of the jobs. Why one
  lock: the code that touches these structures calls into each other. A cancel
  ends a task, which wakes its awaiters, which ends a `Task.map` item, which
  cancels its siblings. Many small locks would need one fixed order across the
  whole task code and would still be taken in long chains. The coarse lock is
  held for a short stretch of pointer work and never across a park or a turn. So
  the long work (the Agentica code of the turns, strings, numbers, JSON, lists
  and maps) runs in parallel. It is held across the libuv calls that a locked
  path makes inline at N = 1 (a job start, a close). At N > 1 those are requests
  to the I/O thread, and the lock is not held while the scheduler waits for one.
  It is cheap to split later, when a measurement shows the contention (the
  `prints`, `ping-pong` and `files` benchmarks, with the locks on). The pieces:
  - What takes the lock is marked per builtin: `agc_builtin.shared`, a flag in
    each row of the builtin tables, so a new row must say `true` or `false`.
    `call_builtin` (`vm/interp.c`) takes `rt->sync` around a row marked shared.
    The rows of the pure libraries (strings, numbers, lists, maps, JSON, `Path`)
    are not marked. A builtin that touches the task tree, a channel, the logger
    table, a handle's FIFO or stdin is marked, and so is every `IO` row that
    reads stdin. `Task.spawn_owning` is the exception: it walks its argument
    unlocked and takes `rt->sync` itself to claim and hand over the handles. The interpreter takes the lock around the steps of a stepper,
    and `run_half` (`vm/loop.c`) around the halves of a job whose kind says
    `locked` (`agc_io_kind.locked`). The end of a task takes it in
    `agc_task_end_turn` and `agc_task_next`. The output builtins are not marked:
    a stream has its own lock, taken inside `vm/output.c`.
  - The lock nests. A scheduler counts its depth (`vm->sync_depth`) and takes
    and drops the mutex at the outer level, so a cancel that wakes a task that
    ends a `Task.map` item does not lock itself. `agc_sync_reset` drops it after
    an `agc_fail` jumped out of a locked builtin (`run_turn`, `agc_vm_run`).
  - Each stream has a lock (the base's, when two streams share one buffer). A
    print takes it for the copy into the ring or the join of the FIFO, and drops
    it before it returns, parks or fails. `agc_sync_reset` also drops a stream
    lock that a failure left. The lock order is `rt->sync`, then a stream's
    lock, then the I/O inbox's and the run queue's. No lock is held across a
    park.
  - Both are solo until `agc_share`, which runs before a second thread exists.
    `rt->shared` is false, and `agc_sync_take` tests that one flag and locks
    nothing. `agc_share` runs when the VM starts N > 1 schedulers (`vm/task.c`).
    It also runs for the C tests and for `AGENTICA_VM_TEST_SHARED=1`, a
    test-only switch that runs a program on one scheduler with every lock on.
    `make test-shared` runs the binary test modules that way. In that mode the
    lock placement is checked, not only exercised. `agc_lock_drop` aborts when
    the caller is not the owner. `agc_sync_assert` fails the run with
    `RUNTIME-INTERNAL` when a mutator of a shared list runs without the lock.
    `rg agc_sync_assert vm/` lists them: the task tree, a channel's waiter
    queues, the logger table, a handle's waiters, holder and `next_owner`, the
    stdin waiters and the timer heaps. `agc_task_next` fails when a turn ended
    with the lock held. `vm/tests/sync_test.c` checks the marks of the tables,
    and `tests/test_vm_shared.py` holds the programs for the paths the other
    modules do not reach. Not yet under the lock: the profiling counters. A
    socket or a child needs no lock, since the I/O thread owns it. The owner of
    a stream's lock is the calling thread's context, not the stream's own `vm`.
- **GC threads.** Boehm's thread support, the helpers in `vm/value.c` and who
  registers are in §10.2.3, GC.
- **The exit path runs on the I/O thread.** `agc_launch_end` (`vm/launch.c`)
  calls `agc_launch_settle`, then the output end, then `agc_launch_exit`.

### 16.10 Later iterations

Only if measurements ask for them. Wakes with the single global run queue
already use a runnext slot and a short spin (§16.9, "Wakes between schedulers").

- **K I/O threads**, K configurable (for example one per 4 to 8 cores). Each
  handle is fixed to one loop when it is created. There is one inbox per I/O
  thread, and a request goes to the loop of its handle. Ready tasks still go to
  the global run queue.
- **Per-scheduler local queues with work stealing.** Wakes then go to a global
  inject queue.
- **TLS crypto on the schedulers.** As built it runs on the I/O thread with the
  socket state (§16.2), so a TLS-heavy server can make the loop its limit.

### 16.11 Open

- **Detached jobs** (decided, built; §16.9). A job whose task was cancelled has
  no owner (§10.2.2). A cancelled outcome counts as detached: the task gives up
  the wait, and the job runs to its end (§10.2.3). A scheduler ends a detached
  job through `agc_io_service`.
- **Cancel against PARKING and a ready task** (decided, built; §16.9). A READY
  task is taken out of the queue by the canceller, an O(n) walk under the
  queue's lock. A task the canceller cannot find is ended by the scheduler that
  pops it. Unlinking a task from a waiter list or from the lock FIFO is the same
  O(n) walk (`agc_task_remove`), under `rt->sync`.
- **The resource registry and the wait lists** (decided, built; §16.9). One
  registry is shared under its own leaf lock, and the I/O thread goes from a
  job's id to the task through it (§16.5). The alternative, a registry owned by
  the I/O thread, would make every free by a scheduler a request too. Freeing a
  job calls `agc_unregister`, a registry write that moves the last entry. The
  handle's lock FIFO, the stdin waiters and the awaiters list are all under
  `rt->sync`. The alternatives were a short lock for each list, or FIFOs owned
  by the I/O thread with lock enter and leave as requests. `rt->sync` covers the
  channels' waiter lists too. A lock hand-on and a channel wake race the
  waiter's deadline, a timer of the task (§16.9). Both wakers run under
  `rt->sync`, and the state CAS picks one. A losing lock hand-on must offer the
  lock to the next waiter. A losing channel wake passes the value or slot on
  (§10.2.2).
- **Read buffers and request slots** (decided, built for sockets; §16.9). The
  I/O thread owns a connection's `agc_conn.in` and its request slots (a
  process's too). The read callback appends to the buffer, read-ahead stays
  there, and a read request gets its line or bytes as a `malloc`'d copy cut on
  the I/O thread. Open: at N > 1 a read of bytes that are already buffered still
  posts a request. A lock on the buffer that lets a scheduler take them at once
  is not built. On the polled file path, `expired` moves `o->st->buf` while the
  I/O thread may still run `ready`, `step` and `send_rest`, so the poller pause
  must complete first. Stdin is read into a job's buffer (on Windows, the
  reader's buffer), and `read_end` appends it to `rt->in.buf` (GC memory) on a
  scheduler. How the schedulers lock `rt->in` between them is open.
- **A libuv step whose result a half needs** (decided, for sockets). `serve`
  (`vm/tcp.c`) calls `uv_accept` on the I/O thread. A TLS child finishes its
  handshake there, and the request hands the child to `accept_done`.
- **stdout and stderr on the loop** (decided, built; §10.2.2). An OS lock
  cannot be held across a park, so each stream has a short lock around its
  buffer and FIFO and a single writer on the loop (§16.8).
- **The blocking fallback at the end of the run** (open). The end of the run
  waits for the schedulers (built; §16.9, "Threads"). What stays open is the
  blocking fallback (one scheduler only, §16.9, "`--schedulers N`"). A scheduler
  can be blocked in a stdout write that holds the stream lock (a full pipe),
  while the I/O thread's flush of that stream waits for the same lock. The
  second stop signal is one way out (the write gets `EINTR`, §14.4), but a
  process signal may not be delivered to that thread. Another is `pthread_kill`
  on the schedulers. Whether the flush takes the lock with a limit is open.
  Streams on the loop do not have this problem: no scheduler blocks in a stdout
  write for them (§10.2.2).
