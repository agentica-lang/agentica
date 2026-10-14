## 16. VM architecture

**Status:** decided by the owner on 2026-10-13, row 7.2.1c of the [roadmap](../roadmap/README.md) (docs only; nothing here changes the VM yet). This is the one picture of the threads, the queues and who owns what. The VM as built runs one scheduler and the loop on the same thread (N = 1); §16.9 says what differs. Building more than one scheduler stays gated (roadmap step 11), and this model also serves N = 1.

It replaces the first multicore design of §10.2.3 (BEAM style: one loop, one run queue and one resource registry per scheduler, a home scheduler for each task, work stealing first). The new model has one loop, one run queue and no home. §10.2.3 keeps the rules that still hold (the park and wake protocol, the cancel and stop flags, the state split, the stream locks, the `--schedulers` flag). §14's five rules hold in this model; §16.6 maps each to the component that enforces it.

### 16.1 Components

| Component | What it is |
|---|---|
| **Runtime** | `agc_runtime`: the program, the arguments, the settings. Shared by every thread and read-only after start-up, except the atomics and locks that §10.2.3 lists (`steps_left`, `outcome`, one lock per output stream). |
| **Schedulers** | N threads that run the interpreter. A scheduler takes a ready task from the global run queue, runs one turn (§10.2.1), and then parks it, ends it or puts it back. It never calls libuv, except `uv_async_send` on the inbox's handle. |
| **Global run queue** | The FIFO of ready tasks. Many producers, N consumers (§16.3). |
| **I/O thread** | The main thread after start-up. It runs the only libuv loop. It has an inbox of requests from the schedulers (§16.4). |
| **libuv thread pool** | Bounded blocking work only: regular files and directories, DNS, and the TLS setup jobs that load CA, certificate and key files (§14.1). One pool per process, driven by the loop. Its threads never touch GC memory. |
| **Handles and their owner tasks** | A socket, listener, pipe, terminal, process or poller is a libuv handle on the I/O loop for its whole life. The task that opened it owns it (§14.5). A regular file is not a libuv handle on the loop: it is a descriptor that pool jobs use. |
| **Jobs** | A task's pending operation: `malloc` memory with raw bytes and up to three libuv pieces (pool work, the one timer, a wait on the loop), owned by a GC resource in the registry (§16.5). |
| **GC** | Boehm, built for threads. Every scheduler thread and the I/O thread are registered with it. |

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

- **One scheduler per logical core.** The default is `uv_available_parallelism()`, which respects CPU affinity; `--schedulers N` sets it (the flag rules are in §10.2.3).
- **The main thread starts the VM, then becomes the I/O thread.** The start-up work (`GC_INIT`, thread registration, `setenv`, the SipHash keys, the locale, the program load) and the start of the scheduler threads come first. Then the main thread runs the only libuv loop: timers, sockets, pipes, FIFOs, terminals and pollers. It also owns the life cycle of the run: the stop signals and the one exit path, `end_run` (§14.4).
- **Only the I/O thread touches libuv.** The one call other threads make is `uv_async_send` on the inbox's handle, which libuv allows from any thread. Every step that calls libuv is a request to the I/O thread (§16.5). The pool runs only the `work` half of a job on `malloc`'d memory (§10.2.2).
- **The I/O thread only moves bytes.** It reads into and writes from `malloc`'d buffers: a job's, and a socket's input buffer (`agc_conn.in`; who owns it is open, §16.11). Stdin is read into a job's buffer and appended to the shared input by the `done` half, on a scheduler. The `done` half of a job, which builds GC values from those bytes, runs on the scheduler that resumes the task. TLS crypto and HTTP parsing run on the scheduler that resumes the task, over OpenSSL memory BIOs (`vm/tls_openssl.c` has them already), so a slow handshake or a big parse never stalls the loop.
- **No dispatcher thread.** Schedulers pull work; nobody pushes a task at a chosen scheduler.

### 16.3 Queues

KISS. Every queue is the same small thing: an intrusive singly linked list with `first` and `last`, and one `pthread_mutex_t`. The `next` link lives in the task (run queue) or in the request entry (inbox). A task push allocates nothing; a request push allocates its entry. A push is O(1) at the tail and a pop is O(1) at the head. The run queue has a condvar too.

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

This is a sketch of the rules, not final code. The run queue's `push` also calls `pthread_cond_signal` after the unlock. The rules:

- **Wake after publish.** The producer prepares the entry outside the lock, links it under the lock, unlocks, and only then wakes the recipient. The lock publishes everything written before the push (a job's result, a task's state). This holds for the push path only. A waker that finds the task still PARKING does not push (§10.2.3); there the state CAS from PARKING to WOKEN must be `acq_rel`, so the task sees the outcome (§16.5) and what else the waker wrote.
- **Single-consumer queues** (the I/O thread's inbox, and one inbox for each I/O thread if there are K of them, §16.10) are taken whole in one lock (`first = last = NULL`), and the consumer processes all of the list in that turn, outside the lock. It keeps no remainder.
- **The global run queue has N consumers**, so a scheduler pops one task under the lock, never the whole list and never a batch. Taking more than one would leave the other schedulers idle with work waiting.
- **Idle schedulers wait on the condvar**, with no busy waiting. A push signals one. A scheduler checks the queue and waits under the same lock, so a signal after the unlock is never lost. The wait is always in a loop that tests its condition again (`pop_wait`): `pthread_cond_wait` may return with no signal, and Boehm's suspend signals can interrupt it. The flag that ends the wait (`ended`, set when the run stops) changes under the same lock, as `end_waiting` does; set outside the lock, a stop wake could fall between the test and the wait and be lost. The I/O thread's wake is `uv_async_send`.
- **Not lock-free, on purpose.** Atomic `first`, `last` and `next` do not make the operation atomic, and node reuse (ABA) and producers that are suspended halfway make it hard to get right. A mutex with light contention is fine. Measure contention and latency before changing the algorithm. This is not a temporary design.

### 16.4 Two directions

- **To the schedulers: the global run queue.** The I/O thread writes the result into the job (raw bytes), sets the outcome and pushes the task (§16.5); the push publishes the result (§16.3). Schedulers push too: a spawn, a yield, and the wake of an awaiter or of a lock waiter. Whoever wakes a task follows the park and wake protocol of §10.2.3, so a wake that arrives while the task is still parking is not lost.
- **To the I/O thread: its inbox.** A request is its own small `malloc`'d entry `{next, kind, job id}`. A job is never linked into the inbox, so one job can have several requests in flight. The kinds are: start a job (a read, write, close, accept, and so on, on handle H), cancel it, stop or extend its timer, release it, and the libuv step of a `done`, `expired` or cancel half. A scheduler marks its task as parking and posts the start request; the inbox's lock publishes what it wrote, the mirror of wake after publish (§16.3). Then it calls `uv_async_send` and ends the turn. The I/O thread takes the inbox whole and handles every request: for a pool job it calls `uv_queue_work`, and for every job that has a timeout it arms the job's one timer (§14.2).
- **The pool keeps its own mechanism.** Its `after_work` callback runs on the I/O thread, which sets the outcome and pushes the task (§16.5). There is one path back from I/O, and it is always the run queue.
- **Invariant: a task is in one place at a time.** It is running, or in the run queue, or parked with one pending wait. So the intrusive link of a task is safe (it is in one list at a time), and the run queue holds at most the live tasks. Two cases need care:
  - **The PARKING window.** Between the mark and the final CAS, the task still runs on its scheduler while its job may already be started, or done. The protocol of §10.2.3 covers it.
  - **A lock wait with a deadline.** The task is in the handle's lock FIFO, and its timer-only job is on the loop. The waker that wins takes the task out of the FIFO before it pushes it, so the task is never in the FIFO and the run queue at once (§16.6).

  Each kind of request is posted at most once per job, so the inbox is bounded by the live jobs times the number of kinds. The live jobs are those of live tasks, detached jobs, and consumed jobs with libuv pieces still open. Neither queue needs backpressure.

### 16.5 Ownership and lifetime

The rules below are invariants. How each is built is decided when the multicore row is built (§16.11 lists what is open).

- **A job is `malloc` memory owned by a GC resource.** As built, `start_job` in `vm/loop.c` `calloc`s it, with its `uv_work_t` and `uv_timer_t`, and registers it as a GC `agc_resource`. It holds raw bytes and ids, never a GC pointer. The `done` half builds GC values from them, on the scheduler that resumes the task. The pool never touches GC memory. The I/O thread is a registered GC thread, but it builds no GC values and follows no pointer from `malloc` memory into the GC heap: it goes from the job's resource id (`r->id`; a registry slot moves when `agc_unregister` fills a gap) to the resource and to `r->task` through the registry (§16.11), and it links the task into the run queue.
- **A handle belongs to the I/O loop** for its whole life, as a `malloc`'d libuv handle that stays until its `uv_close` callback (§10.2.2). The task that opened it owns it (§14.5). Ownership decides who closes the handle, not who may use it: any task reaches it through a request, and the handle's lock FIFO (§10.2.2) keeps the operations in order. A regular file is no handle: its state is used by pool jobs, and its close is a pool job.
- **GC rule.** A queue that links GC objects lives in GC memory or is a registered root: the run queue, which links tasks. `malloc`'d structures (jobs, requests, handle state) hold ids and raw bytes, never a GC pointer, and no GC pointer is stored in memory that libuv owns.

The invariants:

1. **Only the I/O thread calls libuv** (except `uv_async_send`, §16.2). Every libuv step from a scheduler is a request, with its own entry (§16.4).
2. **A job is freed when its reference count reaches zero.** The count is one atomic (`acq_rel`). Every holder counts: each libuv piece in progress, the task until it has consumed the job, each request in flight, and a waker until it has pushed. The poster takes the reference before it posts, and the request carries it; the I/O thread drops it as its last access after it handles the request, and then frees the request entry. A winning waker drops its reference after its push. Whoever drops the last reference frees the job. If the job has something to drop, the last reference goes to a "release job" request, and nothing touches the job after its handler frees it. `drop` always runs on the I/O thread because it calls libuv, even for drops that only free memory, to keep one rule.
3. **The first to set the job's outcome wins.** The outcome (done, expired or cancelled; not the run's `outcome`) is set once, by CAS from "none". Only the winner takes the task off its wait list and does the state CAS, and it pushes the task once, only if it moved it from PARKED (in the PARKING window it does not push, and the task re-checks). A loser ends only its own piece. A cancel never reaches the job: `agc_task_cancel` sets the cancel flag and does the state CAS only, and the resumed task, which holds its own reference, detaches the job (the "cancelled" outcome, by the same CAS) and posts the cancel request. A wait with no job (`Task.await`, stdin waiters) uses the state CAS only. A parked channel wait always has a deadline, so it has a timer job and uses the outcome CAS (§27.2, "VM design").
4. **Memory order.** The outcome CAS is release and the task's read of it is acquire. The resumed task reads the outcome, never `work_done`.
5. **Completion** is set when the job's last phase ends: `after_work` for a pool job without a `more` step ([§14.1](14-core-invariants.md#141-waiting)), the end of the wait on the loop (`ready`) otherwise, and the timer callback for a timer-only job.

### 16.6 Task life cycle and the rules of §14

A task goes ready, then running, then parked on something, then woken, then ready again. The woken task always comes back through the run queue. Each wait kind has a usual waker, but a wait can also end by its timeout or by a cancel, so a task can have two wakers at once.

| Parked on | Usual waker | Also ends it | The list it sits in, and its owner |
|---|---|---|---|
| A pool job (a regular file, DNS, TLS setup loads) | the I/O thread, in `after_work` (outcome, push) | the job's timer; a cancel | none; the job is on the loop |
| A loop job (socket, pipe, FIFO, terminal, poller, a child's exit) | the I/O thread, when it calls `ready` (outcome, push) | the job's timer; a cancel | none; the job is on the loop |
| A timer (`Task.sleep`, a timer-only job) | the I/O thread, in the timer callback (outcome, push) | a cancel | none |
| A handle's lock FIFO | the scheduler that ends the holder's job (hand-on, push) | the lock wait's deadline (a timer job); a cancel | the handle's FIFO; open (§16.11) |
| `Task.await` | the scheduler that ends the target task (push) | a cancel of the awaiter | the target task's awaiters list, under that task's lock (§10.2.3) |
| A stdin read that another task already started | the scheduler that ends that read's job (push) | a cancel | the input's FIFO; open (§16.11) |
| A channel (`send` or `recv`, 17b) | the scheduler of the task that sends, receives or closes (push) | the deadline (a timer); a cancel | the channel's waiter lists; under the channel's short lock (§27.2) |

**The first to set the outcome wins** (§16.5). Two wakers can race, for example a hand-on and a lock deadline. The winner does the state CAS from PARKED to WOKEN (§10.2.3) and is the only one that pushes the task. The other changes nothing and its wake is stale. A wait can hold two registrations, a place in a list and a timer. The winner takes the task out of the list before it pushes it (a timer that wins does it under the list's lock, or by a request to the list's owner), so the task is never in a list and in the run queue at once. If the timer is still armed, the resumed task posts a request to stop it (§16.4), and the job is freed by its reference count (§16.5). A resumed task still re-checks its wait condition (§10.2.3), so a late wake is only a hint.

`agc_task_cancel` is not a wait kind. It is a waker for every row of the table, and it never touches the job. It runs on the scheduler of the task that cancels, sets the task's cancel flag and does the state CAS (§10.2.3). The resumed task holds its own reference, sees the flag, detaches the job and posts the cancel request (§16.5). A ready task is ended without running (§16.11).

The rules of §14 and the component that enforces each:

| Rule | Enforced by |
|---|---|
| §14.1 Waiting: a task only parks, and nothing waits where the loop cannot cancel | The schedulers never wait on a descriptor. The I/O thread never blocks on one: every descriptor that can wait is non-blocking on the loop. The pool takes only bounded work. |
| §14.2 Timeouts: one timer on the job | The I/O thread owns the job's single `uv_timer_t` and arms it when it starts the request. |
| §14.3 Cancelling: `agc_task_cancel` | It runs on the scheduler of the canceller. It sets the cancel flag, takes the task out of the wait lists a scheduler owns and does the state CAS; it never touches the job. The resumed task detaches the job and posts the cancel request to the I/O thread. |
| §14.4 Ending: one exit path | `end_run` runs on the I/O thread, the main thread. |
| §14.5 Handles: owned by the task that opened them | The owner is recorded in the resource. A close is a request to the I/O thread, the only thread that touches handles. |

### 16.7 Sharing

Threads in one VM share immutable values without copying. There are no per-task heaps and no message copies (§10.2.3, "Values are immutable"). Between VMs, the only sharing is by OS processes, and it is explicit: `Process.spawn` and the planned fd 3 channel of 25c, like Erlang nodes talking to each other.

### 16.8 Risks and notes

- **Boehm stops all threads at once.** Every collection stops every scheduler and the I/O thread. This is the main cost of threads against BEAM's per-process heaps. Parallel marking helps, and round 2 of the benchmarks measures it. Boehm stops threads with signals installed with `SA_RESTART`, and the syscall paths retry on `EINTR` (§10.2.3).
- **stdout and stderr are locked per stream when N > 1** (§10.2.3, "Output"). Since row 7.2.1f a print is a copy into the stream's buffer, or a wait in its FIFO, and the loop writes it (§10.2.2), so only the blocking fallbacks (§14.1) can block the scheduler thread that holds a lock. An OS lock cannot be held across a park (§10.2.3), so the order of whole prints at N > 1 needs a short lock around the buffer and the FIFO, and §16.11 decides it. At N = 1 nothing is locked yet.
- **One bounded wait on the exit path.** `close_children` in `end_run` takes about 2 seconds at most (§14.4). It does not block the loop thread: it runs the loop (`await_exits` in `vm/process.c`, `uv_run` under a timer) until libuv's exit callbacks have reaped the children. `Process.close` no longer waits on the loop thread; it parks its task on a job with a timer (row 7.2.1d, first part).
- **One lock on the run queue** is shared by every scheduler and the I/O thread. Measure it (§16.3).
- **One I/O thread** may become the limit at a high rate of sockets. That is what §16.10 is for.
- **A wake crosses threads.** An I/O result goes through a push and a condvar signal before a scheduler runs the task. With N = 1 as built there is no hop. Measure the latency.

### 16.9 As built: N = 1

Today there is one scheduler and the loop on the same thread. The model with N = 1 is almost what exists: tasks, turns, jobs with their `agc_io_kind` halves, detached jobs, the handle lock FIFO, the owners and the one exit path are as in §16.1 to §16.6. What differs:

- **One thread plays both roles.** The scheduler calls `uv_run(UV_RUN_NOWAIT)` after each turn and `uv_run(UV_RUN_ONCE)` when the run queue is empty (§10.2.1, §10.2.2). In the model, the I/O thread sits in the loop and the schedulers wait on the condvar.
- **No inbox and no locks.** `agc_io_start` calls libuv directly. libuv callbacks put the job on a ready list, and the scheduler drains it after `uv_run` and queues the tasks. That drain is the push of §16.4. The run queue is a plain list.
- **Libuv steps run on the scheduler.** The timer close in `agc_io_finish` and `end_detached`; the libuv part of `done`, `expired`, cancel and `drop` (for example `accept_done` in `vm/tcp.c`, `request_expired` in `vm/process.c`, the file `drop` in `vm/files.c`); the poller calls of builtins; the timer and `uv_queue_work` of `start_job`; and `loop_now` and `agc_io_extend` (`vm/loop.c`). In the model they are requests to the I/O thread, and the scheduler needs a clock that does not use the loop.
- **Services make their own handles** through `agc_io_uv` (§15.1), for example in `vm/tcp.c`, `vm/process.c` and `vm/http_client.c`. In the model that code is the start step of a request.
- **Flags, not an outcome and a count.** `agc_io_finish` picks `done` or `expired` from `work_done` when the task resumes, sets `consumed` first and still reads the job; `sweep` frees by flags. In the model: the outcome CAS and the reference count (§16.5).
- **The task is recorded after the job starts.** `agc_io_start_then` sets `r->task` and `t->parked` after `start_job` (§16.11).
- **TLS and HTTP steps run in libuv callbacks.** For example `advance` and `flush` in `vm/tcp.c` and `head_step` in `vm/http_server.c`. The model moves them into the turn of the resumed task.
- **Plain task states.** READY, RUNNING, PARKED and DONE, without PARKING and WOKEN (§10.2.3), and no stream locks.
- **One resource registry on the scheduler** (`vm->registry`), and Boehm built without thread support.
- **`end_run` runs on the scheduler's thread**, which is the main thread.

### 16.10 Later iterations

Only if measurements ask for them. Neither is planned.

- **K I/O threads**, K configurable (for example one per 4 to 8 cores). Each handle is fixed to one loop when it is created. There is one inbox per I/O thread, and a request goes to the loop of its handle. Ready tasks still go to the global run queue.
- **Per-scheduler local queues with work stealing.** Wakes then go to a global inject queue.

### 16.11 Open

- **Detached jobs.** A job whose task was cancelled has no owner (§10.2.2, "Detached jobs"). A cancelled outcome counts as detached: the task gives up the wait and the job runs to its end (§10.2.3, "Park and wake protocol"). Who ends a detached job is open. For a job that finished, running `done` and discarding the result builds GC values and may close a handle (`end_detached`), so the options are: the I/O thread does it, an exception to §16.5 for this case; or the job goes back through the run queue to a scheduler.
- **Cancelling a ready task.** `agc_task_cancel` already walks the ready list today (`leave_ready` in `vm/task.c`), on the one thread. With a shared run queue the options are:
  - Walk the queue under its lock. It is O(n), and it misses a task that another scheduler has popped but not yet set to RUNNING, so the cancel flag must be set as well and checked when that task starts.
  - Only set the cancel flag, and let the scheduler that pops the task end it instead of running it. It is O(1), but the end of the task (and the wake of its awaiters and the close of its handles) waits until the task is popped, and the order against other tasks changes.

  Unlinking a task from a waiter list or from the lock FIFO is the same O(n) walk today (`agc_task_remove`). A cancel from another scheduler takes effect within one turn (§10.2.3).
- **The resource registry.** One registry shared under a lock, or one owned by the I/O thread, with registration done when the request is started. The I/O thread needs it to go from a job's id to the task (§16.5), so a lookup needs the lock, or a stable id with a map. Freeing a job clears `r->native` and calls `agc_unregister`, a registry write that moves the last entry; with a registry owned by the I/O thread, a free by a scheduler must be a request too. As built, `sweep` walks the whole registry on every job finish, a point of contention under a shared lock.
- **Who owns the wait lists.** The handle's lock FIFO and the stdin waiters have no decided owner (the awaiters list is under the target task's lock, §10.2.3). For channels this is decided: a short lock for each channel (§27.2, "VM design"). Options: a short lock for each list, taken to link or unlink and never held across a park; or the I/O thread owns the FIFOs, and lock enter and leave are requests. A lock hand-on and a channel wake are the scheduler wakers that reach a job (the waiter's timer job): each takes its reference and sets the outcome under the list's lock, and the timer winner takes that lock before it pushes (§16.5). A losing lock hand-on must offer the lock to the next waiter; a losing channel wake passes the value or slot on (§27.2).
- **Read buffers and request slots.** Socket bytes land in a connection's `agc_conn.in`, a `realloc`'d buffer appended by a libuv read callback (on the I/O thread in the model) and consumed by a builtin on a scheduler. Who owns and locks it, and where the read-ahead goes when no task is parked, is open. Options: the I/O thread appends under a lock of the buffer and the builtin consumes under it; or every read is a request with its own buffer in the job, and there is no read-ahead. The same question holds for a connection's or process's request slots, which `drop_request` unlinks (`vm/tcp.c`, `vm/process.c`) once `drop` runs on the I/O thread. On the polled file path, `expired` (`vm/files.c`) moves `o->st->buf` while the I/O thread may still run `ready`, `step` and `send_rest`: the poller pause must complete first. Stdin is read into a job's buffer and `read_done` appends it to `rt->in.buf` (GC memory) on a scheduler; how the schedulers lock `rt->in` between them is open.
- **A libuv step whose result a half needs.** `accept_done` needs the result of `uv_accept` (`vm/tcp.c`). The step runs on the I/O thread, so the half gets the result another way: a second request and park, or the step done earlier on the I/O thread.
- **Which port function posts each request** (§15.2).
- **The order of `r->task` and `t->parked` in the PARKING window.** Both must be written before the start request is posted; the inbox lock publishes them.
- **stdout and stderr once they park** (row 7.2.1f, decided; built for N = 1). The per-stream lock of §10.2.3 cannot be held across a park, so the second option is taken: a short lock around each stream's buffer and FIFO, never held across a park, and a single writer on the loop (the I/O thread), as §10.2.2 ("stdout and stderr (row 7.2.1f)") specifies and builds. At N = 1 the scheduler and the loop share a thread, so the lock arrives with N > 1. No scheduler blocks in a stdout write for a stream on the loop, so only the blocking fallback keeps a lock across a write.
- **The end of the run.** Whether `end_run` waits for the schedulers to stop (at most one turn, as a stop signal does today, §10.2.2) or starts at once. The first keeps a running task from using a file while the exit path closes it. A scheduler can also be blocked in a stdout write that holds the stream lock (a full pipe), while the I/O thread's flush of that stream waits for the same lock. The second stop signal is one way out (the write gets `EINTR`, §14.4), but a process signal may not be delivered to that thread. Another is `pthread_kill` on the schedulers. Whether the flush takes the lock with a limit is open. For streams on the loop this worry goes away: no scheduler blocks in a stdout write, so no stream lock is held across one (§10.2.2); it stays for the blocking fallback.
- **The form of N = 1 once N > 1 exists.** Keep the single-thread shortcut of §16.9 (a second code path), or use the same threads with N = 1 (two threads, one code path).
