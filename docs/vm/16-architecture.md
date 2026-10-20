## 16. VM architecture

**Status:** decided by the owner on 2026-10-13, row 7.2.1c of the
[roadmap](../roadmap/README.md) (docs only; nothing here changes the VM yet).
This is the one picture of the threads, the queues and who owns what. The VM as
built runs one scheduler and the loop on the same thread (N = 1); §16.9 says
what differs. More than one scheduler is built in steps (roadmap step 11), and
this model also serves N = 1.

It replaces the first multicore design of §10.2.3 (BEAM style: one loop, one run
queue and one resource registry per scheduler, a home scheduler for each task,
work stealing first). The new model has one loop, one run queue and no home.
§10.2.3 keeps the rules that still hold (the park and wake protocol, the cancel
and stop flags, the state split, the stream locks, the `--schedulers` flag).
§14's five rules hold in this model; §16.6 maps each to the component that
enforces it.

### 16.1 Components

- **Component:** **Runtime**
  - **What it is:** `agc_runtime`: the program, the arguments, the settings.
    Shared by every thread and read-only after start-up, except the atomics and
    locks that §10.2.3 lists (`steps_left`, `outcome`, one lock per output
    stream) and the Globals table of the program, which the entry writes before
    `main` (§16.7).

- **Component:** **Schedulers**
  - **What it is:** N threads that run the interpreter. A scheduler takes a
    ready task from the global run queue, runs one turn (§10.2.1), and then
    parks it, ends it or puts it back. It never calls libuv, except
    `uv_async_send` on the inbox's handle.

- **Component:** **Global run queue**
  - **What it is:** The FIFO of ready tasks. Many producers, N consumers
    (§16.3).

- **Component:** **I/O thread**
  - **What it is:** The main thread after start-up. It runs the only libuv loop.
    It has an inbox of requests from the schedulers (§16.4).

- **Component:** **libuv thread pool**
  - **What it is:** Bounded blocking work only: regular files and directories,
    DNS, and the TLS setup jobs that load CA, certificate and key files (§14.1).
    One pool per process, driven by the loop. Its threads never touch GC memory.

- **Component:** **Handles and their owner tasks**
  - **What it is:** A socket, listener, pipe, terminal, process or poller is a
    libuv handle on the I/O loop for its whole life. The task that opened it
    owns it (§14.5). A regular file is not a libuv handle on the loop: it is a
    descriptor that pool jobs use.

- **Component:** **Jobs**
  - **What it is:** A task's pending operation: `malloc` memory with raw bytes
    and up to three libuv pieces (pool work, the one timer, a wait on the loop),
    owned by a GC resource in the registry (§16.5).

- **Component:** **GC**
  - **What it is:** Boehm, built for threads. Every scheduler thread and the I/O
    thread are registered with it.

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

- **One scheduler per logical core.** The default is
  `uv_available_parallelism()`, which respects CPU affinity; `--schedulers N`
  sets it (the flag rules are in §10.2.3).
- **The main thread starts the VM, then becomes the I/O thread.** The start-up
  work (`GC_INIT`, thread registration, `setenv`, the SipHash keys, the locale,
  the program load) and the start of the scheduler threads come first. Then the
  main thread runs the only libuv loop: timers, sockets, pipes, FIFOs, terminals
  and pollers. It also owns the life cycle of the run: the stop signals and the
  one exit path, `end_run` (§14.4).
- **Only the I/O thread touches libuv.** The one call other threads make is
  `uv_async_send` on the inbox's handle, which libuv allows from any thread.
  Every step that calls libuv is a request to the I/O thread (§16.5). The pool
  runs only the `work` half of a job on `malloc`'d memory (§10.2.2).
- **The I/O thread moves bytes and builds no GC values.** It reads into and
  writes from `malloc`'d buffers: a job's, and a socket's input buffer
  (`agc_conn.in`), which it owns (§16.11). Stdin is read into a job's buffer
  and appended to the shared input by the `done` half, on a scheduler. The
  `done` half of a job, which builds GC values from those bytes, runs on the
  scheduler that resumes the task. TLS crypto runs on the I/O thread, beside
  the socket state it reads and writes (`vm/tcp.c`), so a slow handshake
  delays the loop; moving it to the schedulers is a later step (§16.10).
- **No dispatcher thread.** Schedulers pull work; nobody pushes a task at a
  chosen scheduler.

### 16.3 Queues

KISS. Every queue is the same small thing: an intrusive singly linked list with
`first` and `last`, and one `pthread_mutex_t`. The `next` link lives in the task
(run queue) or in the request entry (inbox). A task push allocates nothing; a
request push allocates its entry. A push is O(1) at the tail and a pop is O(1)
at the head. The run queue has a condvar too.

```c
typedef struct { entry *first, *last; bool ended; pthread_mutex_t lock; pthread_cond_t wake; } queue;

void push(queue *q, entry *e) {
  e->next = NULL;
  pthread_mutex_lock(&q->lock);
  if (q->last) q->last->next = e; else q->first = e;
  q->last = e;
  pthread_mutex_unlock(&q->lock);
}

entry *take_all(queue *q) {
  pthread_mutex_lock(&q->lock);
  entry *list = q->first;
  q->first = q->last = NULL;
  pthread_mutex_unlock(&q->lock);
  return list;
}

entry *pop_wait(queue *q) {
  pthread_mutex_lock(&q->lock);
  while (!q->first && !q->ended)
    pthread_cond_wait(&q->wake, &q->lock);
  entry *e = q->first;
  if (e && !(q->first = e->next)) q->last = NULL;
  pthread_mutex_unlock(&q->lock);
  return e;
}

void end_waiting(queue *q) {
  pthread_mutex_lock(&q->lock);
  q->ended = true;
  pthread_mutex_unlock(&q->lock);
  pthread_cond_broadcast(&q->wake);
}
```

This is a sketch of the rules, not final code. The run queue's `push` also calls
`pthread_cond_signal` after the unlock. As built, the run queue is `vm/runq.c`,
with libuv's `uv_mutex_t` and `uv_cond_t` (portable to Windows). `agc_runq_wait`
is `pop_wait` and `agc_runq_end` is `end_waiting`; no scheduler thread calls
them yet. A solo queue never waits: `agc_runq_wait` returns NULL when it is
empty. After the end, `agc_runq_wait` returns NULL even if tasks are left (the
sketch returns them): the run is over. The rules:

- **Wake after publish.** The producer prepares the entry outside the lock,
  links it under the lock, unlocks, and only then wakes the recipient. The lock
  publishes everything written before the push (a job's result, a task's state).
  This holds for the push path only. A waker that finds the task still PARKING
  does not push (§10.2.3); there the state CAS from PARKING to WOKEN must be
  `acq_rel`, so the task sees the outcome (§16.5) and what else the waker wrote.
- **Single-consumer queues** (the I/O thread's inbox, and one inbox for each I/O
  thread if there are K of them, §16.10) are taken whole in one lock
  (`first = last = NULL`), and the consumer processes all of the list in that
  turn, outside the lock. It keeps no remainder.
- **The global run queue has N consumers**, so a scheduler pops one task under
  the lock, never the whole list and never a batch. Taking more than one would
  leave the other schedulers idle with work waiting.
- **Idle schedulers wait on the condvar**, with no busy waiting. A push signals
  one. A scheduler checks the queue and waits under the same lock, so a signal
  after the unlock is never lost. The wait is always in a loop that tests its
  condition again (`pop_wait`): `pthread_cond_wait` may return with no signal,
  and Boehm's suspend signals can interrupt it. The flag that ends the wait
  (`ended`, set when the run stops) changes under the same lock, as
  `end_waiting` does; set outside the lock, a stop wake could fall between the
  test and the wait and be lost. The I/O thread's wake is `uv_async_send`.
- **Not lock-free, on purpose.** Atomic `first`, `last` and `next` do not make
  the operation atomic, and node reuse (ABA) and producers that are suspended
  halfway make it hard to get right. A mutex with light contention is fine.
  Measure contention and latency before changing the algorithm. This is not a
  temporary design.

### 16.4 Two directions

- **To the schedulers: the global run queue.** The I/O thread writes the result
  into the job (raw bytes), sets the outcome and pushes the task (§16.5); the
  push publishes the result (§16.3). Schedulers push too: a spawn, a yield, and
  the wake of an awaiter or of a lock waiter. Whoever wakes a task follows the
  park and wake protocol of §10.2.3, so a wake that arrives while the task is
  still parking is not lost.
- **To the I/O thread: its inbox.** A request is its own small `malloc`'d entry
  `{next, kind, job id}`. A job is never linked into the inbox, so one job can
  have several requests in flight. The kinds are: start a job (a read, write,
  close, accept, and so on, on handle H), cancel it, stop or extend its timer,
  release it, and the libuv step of a `done`, `expired` or cancel half. A
  scheduler marks its task as parking and posts the start request; the inbox's
  lock publishes what it wrote, the mirror of wake after publish (§16.3). Then
  it calls `uv_async_send` and ends the turn. The I/O thread takes the inbox
  whole and handles every request: for a pool job it calls `uv_queue_work`, and
  for every job that has a timeout it arms the job's one timer (§14.2).
- **The pool keeps its own mechanism.** Its `after_work` callback runs on the
  I/O thread, which sets the outcome and pushes the task (§16.5). There is one
  path back from I/O, and it is always the run queue.
- **Invariant: a task is in one place at a time.** It is running, or in the run
  queue, or parked with one pending wait. So the intrusive link of a task is
  safe (it is in one list at a time), and the run queue holds at most the live
  tasks. Two cases need care:
  - **The PARKING window.** Between the mark and the final CAS, the task still
    runs on its scheduler while its job may already be started, or done. The
    protocol of §10.2.3 covers it.
  - **A lock wait with a deadline.** The task is in the handle's lock FIFO, and
    its timer is in its scheduler's heap (§16.9). The waker that wins takes the
    task out of the FIFO before it pushes it, so the task is never in the FIFO
    and the run queue at once (§16.6).

  Each kind of request is posted at most once per job, so the inbox is bounded
  by the live jobs times the number of kinds. The live jobs are those of live
  tasks, detached jobs, and consumed jobs with libuv pieces still open. Neither
  queue needs backpressure.

### 16.5 Ownership and lifetime

The rules below are invariants. How each is built is decided when the multicore
row is built (§16.11 lists what is open).

- **A job is `malloc` memory owned by a GC resource.** As built, `start_job` in
  `vm/loop.c` `calloc`s it, with its `uv_work_t` and `uv_timer_t`, and registers
  it as a GC `agc_resource`. It holds raw bytes and ids, never a GC pointer. The
  `done` half builds GC values from them, on the scheduler that resumes the
  task. The pool never touches GC memory. The I/O thread is a registered GC
  thread, but it builds no GC values and follows no pointer from `malloc` memory
  into the GC heap: it goes from the job's resource id (`r->id`; a registry slot
  moves when `agc_unregister` fills a gap) to the resource and to `r->task`
  through the registry (§16.11), and it links the task into the run queue.
- **A handle belongs to the I/O loop** for its whole life, as a `malloc`'d libuv
  handle that stays until its `uv_close` callback (§10.2.2). The task that
  opened it owns it (§14.5). Ownership decides who closes the handle, not who
  may use it: any task reaches it through a request, and the handle's lock FIFO
  (§10.2.2) keeps the operations in order. A regular file is no handle: its
  state is used by pool jobs, and its close is a pool job.
- **GC rule.** A queue that links GC objects lives in GC memory or is a
  registered root: the run queue, which links tasks. `malloc`'d structures
  (jobs, requests, handle state) hold ids and raw bytes, never a GC pointer, and
  no GC pointer is stored in memory that libuv owns.

The invariants:

1. **Only the I/O thread calls libuv** (except `uv_async_send`, §16.2). Every
   libuv step from a scheduler is a request, with its own entry (§16.4).
2. **A job is freed when its reference count reaches zero.** The count is one
   atomic (`acq_rel`). Every holder counts: each libuv piece in progress, the
   task until it has consumed the job, each request in flight, and a waker until
   it has pushed. The poster takes the reference before it posts, and the
   request carries it; the I/O thread drops it as its last access after it
   handles the request, and then frees the request entry. A winning waker drops
   its reference after its push. A scheduler gives its references back by a
   RELEASE request, so the last drop is always on the I/O thread: that holder
   puts the job on the dead list, and the sweep that follows frees it (as built,
   §16.9). Nothing touches the job after its handler frees it. `drop` always
   runs on the I/O thread because it calls libuv, even for drops that only free
   memory, to keep one rule.
3. **The first to set the job's outcome wins.** The outcome (done, expired or
   cancelled; not the run's `outcome`) is set once, by CAS from "none". Only the
   winner takes the task off its wait list and does the state CAS, and it pushes
   the task once, only if it moved it from PARKED (in the PARKING window it does
   not push, and the task re-checks). A loser ends only its own piece. A cancel
   never reaches the job: `agc_task_cancel` sets the cancel flag and does the
   state CAS only, and the resumed task, which holds its own reference, detaches
   the job (the "cancelled" outcome, by the same CAS) and posts the cancel
   request. A wait with no job (`Task.await`, stdin waiters) uses the state CAS
   only. A parked channel wait always has a deadline; as built it is a timer of
   the task (§16.9, "Timers"), not a job, so it too uses the state CAS only.
4. **Memory order.** The outcome CAS is release and the task's read of it is
   acquire. The resumed task reads the outcome, never `work_done`.
5. **Completion** is set when the job's last phase ends: `after_work` for a pool
   job without a `more` step ([§14.1](14-core-invariants.md#141-waiting)), and
   the end of the wait on the loop (`ready`) otherwise. Every job has pool work
   or a wait; `start_job` refuses a kind with neither, since a bare deadline is
   a timer of the task (§16.9).

### 16.6 Task life cycle and the rules of §14

A task goes ready, then running, then parked on something, then woken, then
ready again. The woken task always comes back through the run queue. Each wait
kind has a usual waker, but a wait can also end by its timeout or by a cancel,
so a task can have two wakers at once.

- **Parked on:** A pool job (a regular file, DNS, TLS setup loads)
  - **Usual waker:** the I/O thread, in `after_work` (outcome, push)
  - **Also ends it:** the job's timer; a cancel
  - **The list it sits in, and its owner:** none; the job is on the loop

- **Parked on:** A loop job (socket, pipe, FIFO, terminal, poller, a child's
  exit)
  - **Usual waker:** the I/O thread, when it calls `ready` (outcome, push)
  - **Also ends it:** the job's timer; a cancel
  - **The list it sits in, and its owner:** none; the job is on the loop

- **Parked on:** A timer (`Task.sleep`, a deadline)
  - **Usual waker:** the owner scheduler, in `agc_timers_run` (a wake)
  - **Also ends it:** a cancel
  - **The list it sits in, and its owner:** none

- **Parked on:** A handle's lock FIFO
  - **Usual waker:** the scheduler that ends the holder's job (hand-on, push)
  - **Also ends it:** the lock wait's deadline (a timer of the task, §16.9); a
    cancel
  - **The list it sits in, and its owner:** the handle's FIFO; open (§16.11)

- **Parked on:** `Task.await`
  - **Usual waker:** the scheduler that ends the target task (push)
  - **Also ends it:** a cancel of the awaiter
  - **The list it sits in, and its owner:** the target task's awaiters list,
    under that task's lock (§10.2.3)

- **Parked on:** A stdin read that another task already started
  - **Usual waker:** the scheduler that ends that read's job (push)
  - **Also ends it:** a cancel
  - **The list it sits in, and its owner:** the input's FIFO; open (§16.11)

- **Parked on:** A channel (`send` or `recv`, 17b)
  - **Usual waker:** the scheduler of the task that sends, receives or closes
    (push)
  - **Also ends it:** the deadline (a timer); a cancel
  - **The list it sits in, and its owner:** the channel's waiter lists; under
    the channel's short lock (§27.2)

**The first to set the outcome wins** (§16.5). Two wakers can race, for example
a hand-on and a lock deadline. The winner does the state CAS from PARKED to
WOKEN (§10.2.3) and is the only one that pushes the task. The other changes
nothing and its wake is stale. A wait can hold two registrations, a place in a
list and a timer. The winner takes the task out of the list before it pushes it
(a timer that wins does it under the list's lock, or by a request to the list's
owner), so the task is never in a list and in the run queue at once. If the
timer of a job is still armed, the resumed task posts a request to stop it
(§16.4), and the job is freed by its reference count (§16.5); a timer of the
task (§16.9, "Timers") is disarmed by `resume` under `rt->sync`. A resumed task
still re-checks its wait condition (§10.2.3), so a late wake is only a hint.

`agc_task_cancel` is not a wait kind. It is a waker for every row of the table,
and it never touches the job. It runs on the scheduler of the task that cancels,
sets the task's cancel flag and does the state CAS (§10.2.3). The resumed task
holds its own reference, sees the flag, detaches the job and posts the cancel
request (§16.5). A ready task is ended without running (§16.11).

The rules of §14 and the component that enforces each:

- **Rule:** §14.1 Waiting: a task only parks, and nothing waits where the loop
  cannot cancel
  - **Enforced by:** The schedulers never wait on a descriptor. The I/O thread
    never blocks on one: every descriptor that can wait is non-blocking on the
    loop. The pool takes only bounded work.

- **Rule:** §14.2 Timeouts: one timer on the job
  - **Enforced by:** The I/O thread owns the job's single `uv_timer_t` and arms
    it when it starts the request.

- **Rule:** §14.3 Cancelling: `agc_task_cancel`
  - **Enforced by:** It runs on the scheduler of the canceller. It sets the
    cancel flag, takes the task out of the wait lists a scheduler owns and does
    the state CAS; it never touches the job. The resumed task detaches the job
    and posts the cancel request to the I/O thread.

- **Rule:** §14.4 Ending: one exit path
  - **Enforced by:** `end_run` runs on the I/O thread, the main thread.

- **Rule:** §14.5 Handles: owned by the task that opened them
  - **Enforced by:** The owner is recorded in the resource. A close is a request
    to the I/O thread, the only thread that touches handles.

### 16.7 Sharing

Threads in one VM share immutable values without copying. There are no per-task
heaps and no message copies (§10.2.3, "Values are immutable"). The one table a
run writes into the loaded program is the Globals table of the module
constants: the entry writes it once, before `main`, and after that it is
read-only, so schedulers read it without a lock (§10.2.3, "The Globals table",
which also says what the multicore build must keep). Between VMs, the only
sharing is by OS processes, and it is explicit: `Process.spawn` and the planned
fd 3 channel of 25c, like Erlang nodes talking to each other.

### 16.8 Risks and notes

- **Boehm stops all threads at once.** Every collection stops every scheduler
  and the I/O thread. This is the main cost of threads against BEAM's
  per-process heaps. Parallel marking helps, and round 2 of the benchmarks
  measures it. Boehm stops threads with signals installed with `SA_RESTART`, and
  the syscall paths retry on `EINTR` (§10.2.3).
- **stdout and stderr are locked per stream when N > 1** (§10.2.3, "Output").
  Since row 7.2.1f a print is a copy into the stream's buffer, or a wait in its
  FIFO, and the loop writes it (§10.2.2), so only the blocking fallbacks (§14.1)
  can block the scheduler thread that holds a lock. An OS lock cannot be held
  across a park (§10.2.3), so the order of whole prints at N > 1 needs a short
  lock around the buffer and the FIFO, and §16.11 decides it. At N = 1 nothing
  is locked yet.
- **One bounded wait on the exit path.** `close_children` in `end_run` takes
  about 2 seconds at most (§14.4). It does not block the loop thread: it runs
  the loop (`await_exits` in `vm/process.c`, `uv_run` under a timer) until
  libuv's exit callbacks have reaped the children. `Process.close` no longer
  waits on the loop thread; it parks its task on a job with a timer (row 7.2.1d,
  first part).
- **One lock on the run queue** is shared by every scheduler and the I/O thread.
  Measure it (§16.3).
- **One I/O thread** may become the limit at a high rate of sockets. That is
  what §16.10 is for.
- **A wake crosses threads.** An I/O result goes through a push and a condvar
  signal before a scheduler runs the task. With N = 1 as built there is no hop.
  Measure the latency.

### 16.9 As built: N = 1

By default there is one scheduler and the loop on the same thread; N > 1 runs
only under a test-only switch ("Threads" below). The model with N = 1 is almost
what exists: tasks, turns, jobs with their `agc_io_kind` halves, detached jobs,
the handle lock FIFO, the owners and the one exit path are as in §16.1 to
§16.6. What differs:

- **One thread plays both roles, and stays one thread at N = 1.** The scheduler
  calls `uv_run(UV_RUN_NOWAIT)` after each turn and `uv_run(UV_RUN_ONCE)` when
  the run queue is empty (§10.2.1, §10.2.2). In the model, the I/O thread sits
  in the loop and the schedulers wait on the condvar. A real I/O thread beside
  one scheduler thread at N = 1 was built as a prototype, measured and not
  taken. A request to another thread costs about 18 µs for the round trip (the
  post, `uv_async_send`, the wake of the loop and the answer), and a call costs
  nothing. Every park with a deadline (a channel wait, a timed `Task.await`,
  `Task.sleep`) started a timer job in that prototype, so each one would pay it:
  the task-switch benchmark, which parks on channels with deadlines, ran several
  times slower in the prototype (one run, not kept in the tree). And the libuv
  code of the services would run beside the interpreter, which §16.11 leaves
  open. The request code is the same at any N; what differs is where the loop
  runs. A request posted on the loop's thread runs at once, and one posted from
  another thread is queued and wakes the loop.
- **The inbox** (`vm/inbox.c`) is a locked queue of malloc'd entries
  `{next, kind, subject, arg}`, taken whole by the loop's thread, with the
  `uv_async_t` that wakes it; the poster sends after it unlocks (§16.3). It
  does not exist at N = 1: no handle, no descriptor. `agc_io_share` makes it
  and gives the loop to the calling thread; a run with N > 1 and the C tests
  call it, as they do `agc_runq_share`. The run queue is the locked queue of
  §16.3 (`vm/runq.c`, reached by `agc_runtime.runq`, in GC memory), in its
  solo mode: while one thread uses the queue it takes no lock, and
  `agc_runq_share` turns the lock on for push, pop and remove. It must run
  before a second thread touches the queue (the threaded C tests call it
  first).
- **The libuv steps of a job are requests** (`vm/loop.c`): START (the timer and
  the pool work of `start_job`), CLOSE_TIMER (in `agc_io_finish`,
  `end_detached`), RELEASE (a reference given back; a scheduler posts it, so the count reaches
  zero on the loop's thread), DETACH (`agc_io_detach`: the cancel half and the
  ready list, which only the loop's thread touches), EXPIRE_CANCEL (the cancel
  at a detached job's deadline), WAIT_DONE (`agc_io_ready` from a scheduler)
  and CALL (`agc_io_call`, a libuv step with no job). `post` runs one at once
  on the loop's thread, with no entry. libuv callbacks put the job on a
  ready list, and the scheduler drains it after `uv_run` and queues the tasks:
  that drain is the push of §16.4, and it keeps a woken task behind the one
  whose turn just ended.
- **Services make their own libuv calls**, on the loop's thread. They make
  handles through `agc_io_uv` (§15.1), for example in `vm/process.c`; the
  libuv part of their `done`, `expired`, cancel and
  `drop` halves (for example `request_expired` in `vm/process.c`, the file
  `drop` in `vm/files.c`) and the poller calls of
  builtins run where the half runs. In the model that code is the start step of
  a request. At N > 1 the steps of the standard streams and of polled files
  (stdin, FIFOs) are requests: the start of a stream write, a poller wait with
  no deadline (stdin, the close of a polled file) and every poller pause and
  close go through `agc_io_call`. The poller of a polled file is opened in the
  job's `more` step and the stdin poller before the schedulers start, both on
  the I/O thread (`agc_poller_open` aborts on another thread). So at N > 1 stdin
  is watched at the start of the run, where N = 1 watches it at the first read;
  a default above 1 changes that for every program. A wait with a deadline
  starts in the job's START, before its timer is armed (the `more` step of a
  wait on the loop), so the timer always finds it started, and the kind's
  `pause` stops it on the I/O thread before EXPIRED is published: `expired`
  never runs beside one of its callbacks. TCP and TLS are requests at every N:
  the I/O thread owns each connection (`net` in `vm/tcp.c`: its TLS session,
  buffers, request slots and counts). A builtin posts its step as the START's
  `more` step (`agc_io_start_then`) and parks; a close and a resource's release
  are posted with `agc_loop_call`. `finish` fills the request on the I/O thread
  (a read cuts its line or bytes out of the buffer), and the `done` half reads
  only the request and then posts its `drop`. A socket's `cancel` and `pause`
  touch only the request and the connection, never a resource or a task. The
  builtins post under `rt->sync`, so their steps reach the inbox in the order
  of the calls. At N = 1 the steps run inline, and a read of buffered bytes or
  a send that goes out at once returns without a park (`agc_io_here`).
  `agc_io_uv` aborts off the I/O thread, and the builtins of HTTP, `Process`,
  `Duplex` and `Test.run` fail with `RUNTIME-INTERNAL` at N > 1
  (`agc_program_for_threads`).
- **An outcome and a count, not flags.** A job has an atomic outcome (PENDING,
  DONE, EXPIRED or CANCELLED) that the first writer sets by CAS
  (`agc_job_settle`, release; `agc_io_finish` reads it with acquire), and an
  atomic reference count. The holders are the owner (the task until
  `agc_io_finish`, or the detached ending), the wait piece (while the pool work
  or the wait on the loop runs, the atomic `busy`), the ready list and each
  request in flight. The timer is no holder: it never touches `data`, and
  `sweep` waits for its close. Only the holder that clears `busy` gives back
  the wait piece's count, so a late end of a wait that was abandoned changes
  nothing. A pool or loop completion sets DONE, the timer sets EXPIRED, a
  detach sets CANCELLED, and a task that resumes with the outcome still PENDING
  (a lock hand-on or an awaited task woke it) sets EXPIRED itself. So the first
  outcome stands: when a timeout and a completion fall in the same pass of the
  loop, the task sees the one that came first, where it used to see the
  completion if it had arrived by the time the task ran. The holder that brings the count to zero puts the job
  on the loop's dead list, and `sweep` walks that list only (the cost is the
  jobs that ended, not the jobs alive): `drop` takes `data` when the count is
  zero, and the job is freed once the timer has closed. Only the loop's thread
  sweeps, since a scheduler gives its references back by RELEASE; at N = 1 that
  is the one thread. `consumed` and `work_done` are gone. A START that the
  inbox still holds when the owner ended the job (a task woken by something
  else, the end of the run) starts nothing: `ended` is set before the
  CLOSE_TIMER and RELEASE are posted, and the START gives back the wait
  piece's count.
- **The detached ending runs on a scheduler once threads exist.** `drain` calls
  `end_detached` itself while one thread plays both roles (no inbox). When the
  loop is shared (`agc_io_share`), the drain only queues the detached job on
  `loop->service` (it keeps the ready list's count on it) and nudges the run
  queue (`agc_runq_nudge`): `done`, which builds GC values and may close a
  handle, never runs on the I/O thread (§16.5). A scheduler calls
  `agc_io_service` when `agc_runq_nudged` is set at its turn boundary, or when
  `agc_runq_wait` returned NULL with a nudge pending and `agc_runq_take_nudge`
  says it is the one to run it (the wait predicate tests the flag under the
  queue's lock, so a nudge is never lost). The service runs each ending with
  `rt->sync` held and a scratch task current, and gives the count back by a
  RELEASE request. The owner's count goes back before `done` runs, so a `done`
  that raises does not leak the job.
- **The context split.** The state that every scheduler and the I/O role share
  is in `agc_runtime`: `main`, `registry`, `loop`, `process_guard`, `parent`
  and `parent_locks`, the crash and quiet lists with their counters, and
  `tasks_done` (atomic). `agc_vm` keeps the scheduler's own context: `task`,
  the turn and stop counters, `yield`, `in_turn`, `sync_depth`, `gc_seen`, the
  profile and the two jmp_bufs. The registry has its own leaf lock (solo until
  `agc_share`): `agc_register`, `agc_unregister` and `agc_resource_id` take
  it. A job points to its resource (`res`), so the I/O role never looks a job
  up by slot, which `agc_unregister` moves (the slots are swap-with-last). The
  walks of the whole registry (`release_handles`, `agc_io_goodbye`,
  `close_files`, `close_all`, `flushing`) copy it under the lock first
  (`registry_snapshot`) and skip an entry that was unregistered since; they
  run at the end of the run, on the loop's thread.
- **Timers are per scheduler and live in the task.** A task that waits for a
  deadline (`Task.sleep`, a timed await, a channel timeout, a `Task.map`
  timeout, a handle lock timeout) arms its own entry (`agc_timer` in `agc_task`)
  in the min-heap of the scheduler that runs it (`vm->timers`, `vm/timers.c`,
  ordered by deadline and then by the order of arming), and parks
  (`agc_task_park_until`). There is no job, no registry slot and no count, and
  so no START, CLOSE_TIMER or RELEASE request. The scheduler fires its due
  timers at its turn boundary and when its run queue is empty
  (`agc_timers_run`), by waking the task like any waker. Every change to a heap
  is made with `rt->sync` held. That is why the entry can be removed at once by
  any scheduler: the task leaves the heap when it resumes (`resume`) or is
  cancelled (`unlink_task`), under the lock that the fire takes, so a fire never
  wakes a task that has left the wait. When `rt->sync` is split, a removal from
  a scheduler that is not the owner becomes lazy: the CAS of an outcome decides,
  the owner drops the dead entry when it pops it and rebuilds the heap when the
  dead ones are twice the live ones. A due timer fires at the owner's next turn
  boundary or idle step, so it is late by at most the rest of the current turn
  and one poll of the loop. At N = 1 an idle scheduler runs the loop once
  bounded by the nearest deadline (`agc_io_run_for`), and an armed timer is work
  for the stall check (its heap's `next_due`). At N > 1 an idle scheduler waits
  on the run queue until its nearest deadline (`agc_runq_wait_until`), and the
  stall check reads the count of armed timers of every heap
  (`rt->timers_armed`). A service task's timer (the idle wait of an HTTP client
  worker, `agc_task_service`) is counted in `rt->timers_weak` too, and both
  checks wait only for the other timers (`agc_timers_strong`): at N = 1 the
  bounded run then needs a live loop, else the run has stalled. No other task
  waits on such a timer, so it cannot be the work that ends a stall.
  The `io` trace has no line for these waits; `sched` prints `timer_arm task=N
  in_ms=M` and `timer_fire task=N late_ms=M`. Deadlines of real I/O jobs (a work
  or external job) stay on a libuv timer, started by the START request that the
  job pays anyway.
- **A post after the loop closed is loud.** `agc_io_share` marks the loop
  shared for good, so `on_io_thread` keeps comparing thread ids after
  `agc_io_close` clears the inbox; `closed` is set there, and a post from
  another thread after it writes a message and aborts (`post_after_close`).
  It guards against a bug, not a program: `job_test.c` runs this case in a
  child.
- **TSan covers the shared code.** `make vm-tsan` builds the VM without libgc
  (`TSAN=1`, `AGC_NO_GC`; TSan and Boehm's stop-the-world do not mix) and runs
  the C tests that use more than one thread: the inbox, the set-once outcome
  and the count, the run queue, the wake and the cancel against the park, a job
  on the loop with a request from another thread, `rt->sync`, the output
  locks, the timers and whole runs on four schedulers (`threads_test.c`).
  `make vm-tsan-run` links the same build with the front end of the release
  build and runs `tests/test_vm_multicore.py` on it.
- **The task is recorded before the job starts.** `start_job` sets `r->task` and
  `t->parked` before it posts START, so a completion that follows at once
  finds the task.
- **TLS and HTTP steps run in libuv callbacks.** For example `advance` and
  `flush` in `vm/tcp.c`. TLS runs on the I/O thread with the socket state it
  touches (§16.2).
- **Atomic task states, and a different READY.** The states are READY, RUNNING,
  PARKING, PARKED, WOKEN and DONE (`agc_task_state` in `vm/port.h`), in an
  `_Atomic` field. READY means "in the run queue", so a waker CASes PARKED to
  READY and pushes; the model's PARKED to WOKEN (§10.2.3) is not used. A waker
  that finds PARKING CASes it to WOKEN and queues nothing, as in the model. The
  task is marked PARKING before it registers its wait (`agc_task_parking`, as
  the model says), and the end of the turn is in the scheduler: it decides the
  trace and the cancel flag first, and the CAS from PARKING to PARKED is its
  last access to the task, but for one more read of the cancel flag (a cancel
  can fall between the first read and the CAS), which is claimed by a CAS. When
  the CAS finds WOKEN it queues the task, so the task is queued once and its
  next turn takes up the wait again.
- **`--schedulers N` is parsed and checked, and N > 1 is test-only.**
  `vm/launch.c` reads the flag and `AGENTICA_SCHEDULERS` (1 to 1024, the flag
  wins). A count above 1 runs only with `AGENTICA_VM_TEST_MULTICORE=1`;
  otherwise, and with the profile trace or
  `AGENTICA_VM_TEST_BLOCKING_OUTPUT=1`, it exits 2 with a message before the
  program loads, so N > 1 never runs as 1. The front end always runs on one
  scheduler. The default is 1, not `uv_available_parallelism()`.
- **Threads.** `agc_vm_run` with N > 1 (`run_threads` in `vm/task.c`) shares the
  locks and the loop, lets threads register with the GC, makes one scheduler
  context (`agc_vm`) per thread and starts scheduler 0; the calling thread
  becomes the I/O thread (`agc_io_serve`). Scheduler 0 runs alone until main
  leaves the entry function, which sets the module constants (at once when there
  are none), and then starts the others: no other task can read a constant
  before it is set. Each scheduler pops tasks from the global queue, runs
  detached endings and its due timers between turns, and waits on the queue when
  it is empty. A fatal diagnostic, `System.exit` or the end of main on any
  scheduler records the outcome once (`agc_run_over`, a CAS on `rt->over`) in
  that scheduler's own record, copies it to `rt->outcome`, ends the run queue
  and wakes the I/O thread. The I/O thread then joins every scheduler thread and
  only then runs the detached endings that are left, the report of unobserved
  crashes and the exit path, as at N = 1. So `end_run` waits for the schedulers
  to stop (at most one turn, as a stop signal does, §10.2.2), and no running
  task uses a file while the exit path closes it. `--max-steps` is approximate
  at N > 1: each scheduler takes steps from the shared budget in batches of up
  to `AGC_TURN_STEPS`, so the limit can trip while other schedulers still hold
  unused steps of their batch.
- **Stall.** At N > 1 the I/O thread runs the check when it has nothing to do,
  not the packed word of §10.2.3: every scheduler waits on an empty queue
  (`agc_runq_quiet`, with an epoch that any wake moves), the inbox and the
  ready list are empty, no timer is armed and the loop has no live handle with
  the inbox's own handle unref'd; then it reads the epoch again
  (`agc_runq_still_quiet`). Only the I/O thread makes work in that state, so
  the run has stalled, and it ends with the `RUNTIME-INTERNAL` of N = 1. The
  last scheduler to go idle wakes the I/O thread for the check
  (`agc_runq_on_idle`).
- **A cancel is a claim.** `cancel_one` (`vm/task.c`) sets the target's atomic
  cancel flag, and then the state says who ends the task, and exactly one party
  does. A task on a turn (RUNNING, PARKING or WOKEN) is left to its scheduler,
  which reads the flag at the end of the turn and again after it publishes
  PARKED (`agc_task_end_turn`); only the canceller's own task gets `vm->yield`,
  and another scheduler's task stops within one turn, as §10.2.3 says. A READY
  task is taken out of the queue and ended; if it is not in the queue (a waker
  set READY and has not pushed, or a scheduler has popped it) `agc_task_next`
  ends it when it pops it. A PARKED task is claimed by a CAS from PARKED to
  READY (`agc_task_claim`), the same race as a waker's, and the winner ends
  it. The ending (`end_cancelled`) walks the lists of the task with `rt->sync`
  held (the next item).
- **One coarse lock, not per-channel locks.** The plan of §16.1 to §16.8 puts a
  lock on each channel, waiter list and task. As built there is one mutex,
  `rt->sync` (`vm/sync.c`, an `agc_lock`), for the task tree (parent, children,
  waiters, awaiting), the channels, the `Task.map` groups, the logger table, the
  stdin buffer and the FIFOs of the handles and of the jobs. Why: the code that
  touches these structures calls into each other (a cancel ends a task, which
  wakes its awaiters, which ends a `Task.map` item, which cancels its siblings),
  so many small locks need one fixed order across the whole task code and would
  still be taken in long chains; the coarse lock is held for a short stretch of
  pointer work and never across a park or a turn, so the work that takes long
  (the Agentica code of the turns, strings, numbers, JSON, lists and maps) runs
  in parallel. It is held across the libuv calls that a locked path makes inline
  at N = 1 (a job start, a close); with the services of 3c those become
  requests to the I/O thread, and the lock is not held while the scheduler
  waits for one. It is cheap to split later, when a measurement shows the
  contention: 3c measures it (the benchmarks `prints`, `ping-pong` and `files`
  with the locks on) before the split is chosen. The pieces:
  - What takes the lock is marked per builtin: `agc_builtin.shared` (a flag in
    each row of the builtin tables, so a new row must say `true` or `false`).
    `call_builtin` (`vm/interp.c`) takes `rt->sync` around a row marked shared;
    the rows of the pure libraries (strings, numbers, lists, maps, JSON,
    `Path`) are not marked. A builtin that touches the task tree, a channel,
    the logger table, a handle's FIFO or stdin is marked, and so is every
    `IO` row that reads stdin. The same interpreter takes the lock around the
    steps of a stepper, and `run_half` (`vm/loop.c`) around the halves of a
    job whose kind says `locked` (`agc_io_kind.locked`); the ending of a task
    takes it in `agc_task_end_turn` and `agc_task_next`. The output builtins are not
    marked: a stream has its own lock, taken inside `vm/output.c`.
  - The lock nests. A scheduler counts its depth (`vm->sync_depth`) and takes
    and drops the mutex at the outer level, so a cancel that wakes a task that
    ends a `Task.map` item does not lock itself. `agc_sync_reset` drops it after
    an `agc_fail` jumped out of a locked builtin (`run_turn`, `agc_vm_run`).
  - Each stream has a lock (the base's, when two streams share one buffer). A
    print takes it for the copy into the ring or the join of the FIFO, and drops
    it before it returns, parks or fails (`agc_sync_reset` also drops the stream
    lock a failure left). The lock order is `rt->sync`, then a stream's lock,
    then the I/O inbox's and the run queue's. No lock is held across a park.
  - Both are solo until `agc_share`, which runs before a second thread exists:
    `rt->shared` is false, `agc_sync_take` tests that one flag and nothing is
    locked. Only the C tests and `AGENTICA_VM_TEST_SHARED=1` call `agc_share`
    today. That switch is test-only: it runs a program on one scheduler with
    every lock on. `make test-shared` (a step of CI) runs the binary test
    modules that way, and in that mode the lock placement is checked, not
    only exercised: `agc_lock_drop` aborts when the caller is not the owner,
    `agc_sync_assert` fails the run with `RUNTIME-INTERNAL` when one of these
    runs without the lock: `finish_task`, `agc_task_wake_all`,
    `agc_task_cancel`, the end of a cancelled task, the link of a task to its
    parent (`adopt`, so every spawn), a channel's waiter queues (the enqueue,
    the pop and the leave), the writers of the logger table (`set_level`,
    `install_default`, `attach`, `detach`), a handle's waiters, holder and
    `next_owner` (the hand-on, the wait, a job start on a handle, the closes of
    files), the stdin waiters, and the timer heaps (`arm`,
    `agc_timers_disarm`). `agc_task_next` fails when a turn ended with
    the lock held. `vm/tests/sync_test.c` checks the marks: every row of the
    task, `Task.map`, channel, logger, process, duplex, TCP and HTTP tables is
    marked, no row of the String, number and JSON tables is, and the core and
    `File` tables are checked by row. `tests/test_vm_shared.py` holds the
    programs for the paths the other modules do not reach.
    Not yet under the lock: the profiling counters, the I/O thread's side of the
    handles that N > 1 refuses. A socket needs no lock: the I/O thread owns it
    ("Services" above). The owner of a stream's
    lock is the calling thread's context (`agc_notice_end`, `settle` and the
    start of a write take it), not the stream's own `vm`.
- **The order of PR 3 of issue #345.** 3a (the blocking pop, the cancel by
  claim and these locks), 3b (the context split of the scheduler and
  per-scheduler timers), 3c (threads, pollers and the standard streams, then
  net in its own PR; real parallelism, behind the test-only
  `AGENTICA_VM_TEST_MULTICORE`), 3d
  (process and duplex, the end of the refusal of N > 1, the default of one
  scheduler per logical core).
- **One resource registry on the runtime** (`rt->registry`). Boehm is built
  with thread support (§10.2.3, "GC"): `agc_gc_allow_threads`,
  `agc_gc_thread_enter` and `agc_gc_thread_leave` (`vm/value.c`) are the
  helpers, and each scheduler thread registers at its start. N = 1 starts no
  marker thread.
- **`end_run` runs on the loop's thread**, which is the main thread. It is
  `agc_launch_settle` and `agc_io_close`, called by the driver; the main thread
  is the I/O thread once N > 1 as well (§16.2).

### 16.10 Later iterations

Only if measurements ask for them. The cost of the single global run queue
for wake-heavy programs is measured in §16.11 ("Wakes between schedulers").

- **K I/O threads**, K configurable (for example one per 4 to 8 cores). Each
  handle is fixed to one loop when it is created. There is one inbox per I/O
  thread, and a request goes to the loop of its handle. Ready tasks still go to
  the global run queue.
- **Per-scheduler local queues with work stealing.** Wakes then go to a global
  inject queue.
- **TLS crypto on the schedulers.** As built it runs on the I/O thread with the
  socket state (§16.2), so a TLS-heavy server can make the loop its limit.

### 16.11 Open

- **Detached jobs.** A job whose task was cancelled has no owner (§10.2.2,
  "Detached jobs"). A cancelled outcome counts as detached: the task gives up
  the wait and the job runs to its end (§10.2.3, "Park and wake protocol"). Who
  ends a detached job is decided and built (§16.9): in 3c a scheduler does,
  through `agc_io_service`.
- **Cancel against PARKING and a ready task (decided, built; §16.9).** The
  scheduler re-reads `cancelled` after the commit CAS and claims the task if it
  is set, so a cancel that fell between the first look and the commit does not
  leave a cancelled task PARKED. A READY task is taken out of the queue by the
  canceller (O(n) under the queue's lock), and one it cannot find is ended by
  the scheduler that pops it. `vm->yield` is used only for the canceller's own
  task. Unlinking a task from a waiter list or from the lock FIFO is the same
  O(n) walk (`agc_task_remove`), and it needs the lock of the list (open, "Who
  owns the wait lists").
- **The resource registry.** One registry shared under a lock, or one owned by
  the I/O thread, with registration done when the request is started. The I/O
  thread needs it to go from a job's id to the task (§16.5), so a lookup needs
  the lock, or a stable id with a map. Freeing a job clears `r->native` and
  calls `agc_unregister`, a registry write that moves the last entry; with a
  registry owned by the I/O thread, a free by a scheduler must be a request too.
  As built, only the loop's thread sweeps (it walks the dead list, not the
  registry), but a scheduler still registers a job in `start_job`, so the
  registry needs its lock or its owner before PR 3 runs two threads.
- **Who owns the wait lists.** The handle's lock FIFO and the stdin waiters have
  no decided owner (the awaiters list is under the target task's lock, §10.2.3).
  For channels this is decided: a short lock for each channel (§27.2, "VM
  design"). Options: a short lock for each list, taken to link or unlink and
  never held across a park; or the I/O thread owns the FIFOs, and lock enter and
  leave are requests. A lock hand-on and a channel wake race the waiter's
  deadline, which as built is a timer of the task (§16.9, "Timers"): both wakers
  run under `rt->sync` and the state CAS picks one. A losing lock hand-on must
  offer the lock to the next waiter; a losing channel wake passes the value or
  slot on (§27.2).
- **Read buffers and request slots.** Decided and built for sockets (§16.9,
  "Services"): the I/O thread owns a connection's `agc_conn.in` and its request
  slots. The read callback appends to the buffer, read-ahead stays there, and a
  read request gets its line or bytes as a `malloc`'d copy cut on the I/O
  thread. At N > 1 a read of bytes that are already buffered still posts a
  request; a lock on the buffer that lets a scheduler take them at once is not
  built. A process's request slots, which `drop_request` unlinks
  (`vm/process.c`) once `drop` runs on the I/O thread, are open. On the polled
  file path, `expired` (`vm/files.c`) moves `o->st->buf` while the I/O thread
  may still run `ready`, `step` and `send_rest`: the poller pause must complete
  first. Stdin is read into a job's buffer and `read_done` appends it to
  `rt->in.buf` (GC memory) on a scheduler; how the schedulers lock `rt->in`
  between them is open.
- **A libuv step whose result a half needs.** Decided for sockets: `serve`
  (`vm/tcp.c`) calls `uv_accept` on the I/O thread, a TLS child finishes its
  handshake there, and the request hands the child to `accept_done`.
- **Which port function posts each service request** (§15.2). The job
  requests are posted by `agc_io_start` and the finish and detach paths of
  `vm/loop.c`. The steps of TCP and TLS go through the START's `more` step and
  `agc_loop_call` (§16.9); those of `Process` and `Duplex` have no request yet.
- **stdout and stderr once they park** (row 7.2.1f, decided; built for N = 1).
  The per-stream lock of §10.2.3 cannot be held across a park, so the second
  option is taken: a short lock around each stream's buffer and FIFO, never held
  across a park, and a single writer on the loop (the I/O thread), as §10.2.2
  ("stdout and stderr (row 7.2.1f)") specifies and builds. At N = 1 the
  scheduler and the loop share a thread, so the lock arrives with N > 1. No
  scheduler blocks in a stdout write for a stream on the loop, so only the
  blocking fallback keeps a lock across a write.
- **The blocking fallback at the end of the run.** The end of the run waits for
  the schedulers (decided, built; §16.9, "Threads"). What stays open is the
  blocking fallback (refused at N > 1 today). A scheduler can be blocked in a
  stdout write that holds the stream lock (a full pipe), while the I/O thread's
  flush of that stream waits for the same lock. The second stop signal is one
  way out (the write gets `EINTR`, §14.4), but a process signal may not be
  delivered to that thread. Another is `pthread_kill` on the schedulers. Whether
  the flush takes the lock with a limit is open. Streams on the loop do not have
  this problem: no scheduler blocks in a stdout write for them (§10.2.2).
- **Wakes between schedulers (measured; an optimization for later).** One global
  run queue keeps the schedulers simple, and CPU work scales with the cores. A
  program where every step wakes another task pays for it: each wake takes the
  queue's lock, signals its condvar (a futex wake) and moves the task to another
  core, so wake-heavy programs are several times slower at N > 1 (roughly 4 to 9
  times for the channel ping-pong benchmarks); the I/O thread is not the cost.
  Per-scheduler queues or a LIFO ("runnext") slot for the waker's own scheduler
  would cut it (§16.10). They are a later optimization, not a condition for 3d
  or for the default number of schedulers.
