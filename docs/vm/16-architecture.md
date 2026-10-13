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
| **Jobs** | A pending request of a parked task: `malloc` memory with raw bytes, the libuv work request and the one timer, owned by a GC resource in the registry (§16.5). |
| **GC** | Boehm, built for threads. Every scheduler thread and the I/O thread are registered with it. |

```text
 +------------------+  request: start / cancel on H for job J   +--------------------+
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

KISS. Every queue is the same small thing: an intrusive singly linked list with `first` and `last`, and one `pthread_mutex_t`. The `next` link lives in the task or job, so a push allocates nothing. A push is O(1) at the tail and a pop is O(1) at the head. The run queue has a condvar too.

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

- **To the schedulers: the global run queue.** The I/O thread writes the result into the job (raw bytes), then pushes the task; the push publishes the result (§16.3). Schedulers push too: a spawn, a yield, and the wake of an awaiter or of a lock waiter. Whoever wakes a task follows the park and wake protocol of §10.2.3, so a wake that arrives while the task is still parking is not lost.
- **To the I/O thread: its inbox.** A request is "start a read, write, close or cancel on handle H for job J". The entries are the `malloc`'d jobs, linked by their own `next`; they hold ids and bytes, never a GC pointer (§16.5). A scheduler marks its task as parking, records the task in the resource (`r->task`) and the resource in the task (`t->parked`), and only then links the job on the inbox; the inbox's lock publishes what it wrote, the mirror of wake after publish (§16.3). Then it calls `uv_async_send` and ends the turn. The I/O thread takes the inbox whole and starts every request in it on the loop: for a pool job it calls `uv_queue_work`, and for every job that has a timeout it arms the job's one timer (§14.2).
- **The pool keeps its own mechanism.** Its `after_work` callback runs on the I/O thread. On completion, when the libuv pieces the job has are done (§16.5 has the timeout and cancel paths), the I/O thread finds the task through the registry and pushes it to the run queue. There is one path back from I/O, and it is always the run queue.
- **Invariant: a task is in one place at a time.** It is running, or in the run queue, or parked with one pending request. So the intrusive link is safe (a task or job is in one list at a time), and the run queue holds at most the live tasks. Three cases need care:
  - **The PARKING window.** Between the mark and the final CAS, the task still runs on its scheduler while its job may already be in the inbox, or done. The protocol of §10.2.3 covers it.
  - **A lock wait with a deadline.** The task is in the handle's lock FIFO, and its timer-only job is in the inbox or armed on the loop. The waker that wins takes the task out of the FIFO before it pushes it, so the task is never in the FIFO and the run queue at once (§16.6).
  - **A detached job.** Its task was cancelled, so the job lives on with no task, in the inbox or on the loop (§16.11).

  So the inbox is bounded by the live tasks plus the detached jobs, and neither queue needs backpressure.

### 16.5 Ownership and lifetime

- **A job is `malloc` memory owned by a GC resource.** As built, `start_job` in `vm/loop.c` `calloc`s the job, with the `uv_work_t` and the `uv_timer_t` inside it, and registers it as a GC `agc_resource` of kind `AGC_RESOURCE_JOB`, which has no `release` function. `sweep` frees the job once it is consumed, its work is done, it is not queued and its timer is closed (§10.2.2). The job holds raw bytes only: paths, buffers, the result, the kind's data. The `done` half builds GC values from them, on the scheduler that resumes the task. The pool never touches GC memory. The I/O thread is a registered GC thread (§16.1), but it builds no GC values and follows no pointer from `malloc` memory into the GC heap. It reads the registry and the task's state, and it links the task into the run queue.
- **The I/O thread reaches the task through the registry.** As built, the job holds its registry slot (`j->slot`), which `agc_unregister` keeps up to date on the one thread. A slot is not stable across threads: `agc_unregister` moves the last entry into the gap, so the job should hold the resource id (`r->id`, from `agc_resource_id`), which never changes, and the slot can be only a hint. The I/O thread goes from the id to the resource and from the resource to `r->task`. It never follows a pointer from `malloc` memory to a task. This needs the registry to be readable from the I/O thread, and a lookup by id, so it depends on the registry decision of §16.11.
- **A job belongs to its parked task.** The I/O thread fills in the result and does not free the job while the task may still read it. The scheduler that resumes the task takes the result and ends the job (`agc_io_finish` today, §10.2.2). A detached job has no task; who ends it is open (§16.11).
- **The I/O thread closes the libuv pieces of a job.** A job has up to two: pool work (a pool job; `after_work` ends it) and a timer (only when it has a timeout, `start_job`). A loop job has no pool work: its libuv callback calls `agc_io_ready`. The I/O thread stops and closes the timer, and it owns the work request until `after_work` returns. The scheduler never frees memory that libuv may still hold, and it never calls `uv_close` (§16.9 says what is different today).
- **When a job is freed.** Only when all of these hold: the libuv pieces it has are done, and its task has consumed it (ran `done` or `expired`) or, for a detached job, it was ended. The pieces are the pool work (if any), the timer's close (if any), and, for a loop job, `ready` was called or the request was cancelled and dropped. A pool-then-loop job (`agc_io_start_then` with a `more` step, §14.1) has both: the pool work, then the wait on the loop. `consumed` must be the task's last access to the job; today `agc_io_finish` sets it first and still reads the job (§16.9). Whoever brings the last condition ends the job. `drop` always runs on the I/O thread, since it calls libuv (it cancels and closes handles and pollers, and may free the connection). So a scheduler that brings the last condition posts a "release job" request to the inbox if the job has something to drop, and frees the job itself only when it has nothing. For example, one atomic count of the open conditions can tell who is last. This keeps `done` and `expired` reading live data: a loop job whose timer closed before the pushed task was popped stays until the task consumed it. `sweep` has this rule today, but it also needs `!queued`, and it runs `drop` before the timer is closed.
- **The first to set the outcome wins.** The outcome of the wait (done, expired or cancelled; not the run's `outcome`) is its own atomic field in the job, set once by CAS from "none". Every waker sets it first. The one that wins then does the state CAS (§10.2.3) and pushes only on the PARKED path; in the PARKING window it does not push, and the task re-checks at once. A loser changes nothing. A plain write before the CAS would let a loser overwrite the winner, and a write after it could be read too early. The resumed task reads the outcome, never `work_done`. A wait with no job (`Task.await`) has only the state CAS, and the task re-checks its condition.
- **Two ways back to the run queue.**
  - **Completion.** The result is in the job. The I/O thread pushes the task after the libuv pieces the job has are done. Both pieces end on the I/O thread, so the last of them pushes.
  - **Timeout, cancel or another waker.** The waker that wins the outcome pushes the task at once, even if a libuv piece is still pending. The resumed task gets no result (`expired`), or a cancel ends it. The job stays registered until the rule above frees it.
  - **What stays off the I/O thread.** Running `done` for a finished job whose task was cancelled, and discarding the result, builds GC values and may close a handle (`end_detached` in `vm/loop.c`). That needs a scheduler, or an explicit exception (§16.11).
- **A handle belongs to the I/O loop** for its whole life, as a `malloc`'d libuv handle that stays until its `uv_close` callback (§10.2.2). The task that opened it owns it (§14.5). Ownership decides who closes the handle, not who may use it: any task reaches it through a request, and the handle's lock FIFO (§10.2.2) keeps the operations in order. A regular file is no handle: its `malloc`'d state (descriptor and read buffer) is used by pool jobs, and its close is a pool job.
- **GC rule.** A queue that links GC objects lives in GC memory or is a registered root: the run queue, which links tasks. `malloc`'d structures (jobs, inbox entries, handle state) hold ids and raw bytes, never a GC pointer, so Boehm has no need to scan them and nothing hides from it. Thread-pool threads never touch GC memory, and no GC pointer is stored in memory that libuv owns.

### 16.6 Task life cycle and the rules of §14

A task goes ready, then running, then parked on something, then woken, then ready again. The woken task always comes back through the run queue. Each wait kind has a usual waker, but a wait can also end by its timeout or by a cancel, so a task can have two wakers at once.

| Parked on | Usual waker | Also ends it | The list it sits in, and its owner |
|---|---|---|---|
| A pool job (a regular file, DNS, TLS setup loads) | the I/O thread, when the last libuv piece is done (push) | the job's timer; a cancel | none; the job is on the loop |
| A loop job (socket, pipe, FIFO, terminal, poller, a child's exit) | the I/O thread, when the last libuv piece is done (push) | the job's timer; a cancel | none; the job is on the loop |
| A timer (`Task.sleep`, a job's timeout) | the I/O thread, when the last libuv piece is done: the timer's close callback (push) | a cancel | none |
| A handle's lock FIFO | the scheduler that ends the holder's job (hand-on, push) | the lock wait's deadline (a timer job); a cancel | the handle's FIFO; open (§16.11) |
| `Task.await` | the scheduler that ends the target task (push) | a cancel of the awaiter | the target task's awaiters list, under that task's lock (§10.2.3) |
| A stdin read that another task already started | the scheduler that ends that read's job (push) | a cancel | the input's FIFO; open (§16.11) |
| A channel (`send` or `recv`, 17b) | the scheduler of the task that sends, receives or closes (push) | the deadline (a timer); a cancel | the channel's waiter lists; decided with 17b |

**The first to set the outcome wins** (§16.5). Two wakers can race, for example a hand-on and a lock deadline, or any wait and a cancel. The winner does the state CAS from PARKED to WOKEN (§10.2.3) and is the only one that pushes the task. The other changes nothing and its wake is stale. A wait can hold two registrations, a place in a list and a timer. The winner takes the task out of the list before it pushes it (a timer that wins does it under the list's lock, or by a request to the list's owner), so the task is never in a list and in the run queue at once. If the timer is still armed, a cancel request goes to the I/O thread (§16.4), and the job is freed by the rule of §16.5. A resumed task still re-checks its wait condition (§10.2.3), so a late wake is only a hint.

`agc_task_cancel` is not a wait kind. It is a waker for every row of the table. It runs on the scheduler of the task that cancels, sets the task's cancel flag, and wakes the task like any other waker, so the first one wins. A ready task is ended without running (§16.11).

The rules of §14 and the component that enforces each:

| Rule | Enforced by |
|---|---|
| §14.1 Waiting: a task only parks, and nothing waits where the loop cannot cancel | The schedulers never wait on a descriptor. The I/O thread never blocks on one: every descriptor that can wait is non-blocking on the loop. The pool takes only bounded work. |
| §14.2 Timeouts: one timer on the job | The I/O thread owns the job's single `uv_timer_t` and arms it when it starts the request. |
| §14.3 Cancelling: `agc_task_cancel` | It runs on the scheduler of the canceller. It takes the task out of every wait list a scheduler owns and sends a cancel request to the I/O thread for a loop job. |
| §14.4 Ending: one exit path | `end_run` runs on the I/O thread, the main thread. |
| §14.5 Handles: owned by the task that opened them | The owner is recorded in the resource. A close is a request to the I/O thread, the only thread that touches handles. |

### 16.7 Sharing

Threads in one VM share immutable values without copying. There are no per-task heaps and no message copies (§10.2.3, "Values are immutable"). Between VMs, the only sharing is by OS processes, and it is explicit: `Process.spawn` and the planned fd 3 channel of 25c, like Erlang nodes talking to each other.

### 16.8 Risks and notes

- **Boehm stops all threads at once.** Every collection stops every scheduler and the I/O thread. This is the main cost of threads against BEAM's per-process heaps. Parallel marking helps, and round 2 of the benchmarks measures it. Boehm stops threads with signals installed with `SA_RESTART`, and the syscall paths retry on `EINTR` (§10.2.3).
- **stdout and stderr are locked per stream when N > 1** (§10.2.3, "Output"). The writes stay blocking until they move onto the loop (roadmap row 7.2.1f), so a full pipe blocks the scheduler thread that holds the lock, and the other schedulers that print to that stream wait for it. Once a write can park, an OS lock cannot be held across the park (§10.2.3). The order of whole prints then needs something else, for example a lock FIFO on the stream as a handle has (§10.2.2); §16.11 lists the options.
- **Two bounded waits block the loop thread until row 7.2.1d.** `reap` in `vm/process.c` polls for at most 1 second, and `close_children` in `end_run` takes about 2 seconds at most (§14.1, §14.4). In the model, that thread is the I/O thread, so every socket and timer would stall meanwhile. Row 7.2.1d removes the first; the second is on the exit path.
- **One lock on the run queue** is shared by every scheduler and the I/O thread. Measure it (§16.3).
- **One I/O thread** may become the limit at a high rate of sockets. That is what §16.10 is for.
- **A wake crosses threads.** An I/O result goes through a push and a condvar signal before a scheduler runs the task. With N = 1 as built there is no hop. Measure the latency.

### 16.9 As built: N = 1

Today there is one scheduler and the loop on the same thread. The model with N = 1 is almost what exists: tasks, turns, jobs with their `agc_io_kind` halves, detached jobs, the handle lock FIFO, the owners and the one exit path are as in §16.1 to §16.6. What differs:

- **One thread plays both roles.** The scheduler calls `uv_run(UV_RUN_NOWAIT)` after each turn and `uv_run(UV_RUN_ONCE)` when the run queue is empty (§10.2.1, §10.2.2). In the model, the I/O thread sits in the loop and the schedulers wait on the condvar.
- **No inbox and no locks.** `agc_io_start` calls libuv directly. libuv callbacks put the job on a ready list, and the scheduler drains it after `uv_run` and queues the tasks, finding each task through the job's slot and `r->task` as in §16.5. That drain is the push of §16.4. The run queue is a plain list.
- **The resuming thread closes the job's timer.** `agc_io_finish` calls `close_timer` on the thread that resumes the task, and `end_detached` does the same for a detached job (`vm/loop.c`). With N = 1 that is the loop thread. In the model the I/O thread closes the timer, and on completion the task is pushed after the close callback (§16.5). This is part of the multicore work.
- **The outcome is read at resume time.** `agc_io_finish` chooses `done` or `expired` from `work_done` (or `timer_fired`) when the task resumes, sets `consumed` first and still reads the job afterwards. In the model the first waker sets the outcome, once, in the job (§16.5), and `consumed` is the task's last access.
- **Done, expired, cancel and drop call libuv on the scheduler.** `accept_done` calls `uv_accept` (`vm/tcp.c`), `request_expired` calls `shut` (`vm/tcp.c`, which cancels requests and drops links), `drop_request` reaches `uv_cancel` and `uv_close` through `release_child` and `shut_one`, and the file `drop` calls `agc_poller_close` (`vm/files.c`). Builtins in `vm/files.c` and `vm/input.c` also call `agc_poller_open`, `agc_poller_wait`, `agc_poller_pause` and `agc_poller_close`. In the model these steps become requests to the I/O thread (§16.5).
- **The task is recorded after the job starts.** `agc_io_start_then` calls `start_job`, which starts the timer and queues the work, and only then sets `r->task` and `t->parked`. With one thread nothing can run in between. In the model both are set before the job is linked on the inbox (§16.4).
- **Two scheduler calls into libuv.** `loop_now` (`uv_update_time` and `uv_now`, used by `agc_handle_wait` for the lock deadline) and `agc_io_extend` (`uv_timer_start`, used by the HTTP server) run on the scheduler. In the model the scheduler needs a clock that does not use the loop, and `extend` becomes a request to the I/O thread.
- **Services call libuv from their builtins.** `tcp.c`, `process.c` and `http_client.c` make their own handles through `agc_io_uv` (§15.1) on the scheduler's thread, which today is the loop thread. In the model that code runs on the I/O thread, as the start step of the request (§16.4). This is part of the multicore work too.
- **TLS and HTTP steps run in libuv callbacks.** `advance` and `flush` in `vm/tcp.c`, and `head_step` in `vm/http_server.c` and `vm/http_client.c`, run from connection callbacks on the loop thread. The model moves them into the turn of the resumed task. This is part of the multicore work, not of the earlier PRs.
- **Plain task states.** READY, RUNNING, PARKED and DONE, without PARKING and WOKEN (§10.2.3), and no stream locks.
- **One resource registry on the scheduler** (`vm->registry`), and Boehm built without thread support.
- **`end_run` runs on the scheduler's thread**, which is the main thread.

### 16.10 Later iterations

Only if measurements ask for them. Neither is planned.

- **K I/O threads**, K configurable (for example one per 4 to 8 cores). Each handle is fixed to one loop when it is created. There is one inbox per I/O thread, and a request goes to the loop of its handle. Ready tasks still go to the global run queue.
- **Per-scheduler local queues with work stealing.** Wakes then go to a global inject queue.

### 16.11 Open

- **Detached jobs and cancel requests.** A job whose task was cancelled has no owner (§10.2.2, "Detached jobs"). A job already linked in the inbox cannot be unlinked from a singly linked list, so a task that gives up its wait detaches the job instead, and the job runs to its end (§10.2.3, "Park and wake protocol"). Who ends a detached job is open. The `drop` half calls libuv, so it runs on the I/O thread (§16.5). For a job that finished, running `done` and discarding the result builds GC values and may close a handle, so the options are: the I/O thread does it, an exception to §16.5 for that case only; or the job goes back through the run queue to a scheduler. A cancel request must not need a second link on a job that may still be in the inbox. Options: a flag on the job plus a wake of the I/O thread, or a small entry of its own.
- **Cancelling a ready task.** `agc_task_cancel` already walks the ready list today (`leave_ready` in `vm/task.c`), on the one thread. With a shared run queue the options are:
  - Walk the queue under its lock. It is O(n), and it misses a task that another scheduler has popped but not yet set to RUNNING, so the cancel flag must be set as well and checked when that task starts.
  - Only set the cancel flag, and let the scheduler that pops the task end it instead of running it. It is O(1), but the end of the task (and the wake of its awaiters and the close of its handles) waits until the task is popped, and the order against other tasks changes.

  Unlinking a task from a waiter list or from the lock FIFO is the same O(n) walk today (`agc_task_remove`). A cancel from another scheduler takes effect within one turn (§10.2.3).
- **The resource registry.** One registry shared under a lock, or one owned by the I/O thread, with registration done when the request is started. The I/O thread needs it to go from a job's id to the task (§16.5). A slot moves when another entry is unregistered (`agc_unregister` moves the last entry into the gap), so a lookup needs the lock, or a stable id with a map. Freeing a job from the I/O thread clears `r->native` and calls `agc_unregister`, a write to the registry that moves the last entry. As built, `sweep` walks the whole registry on every job finish; under a shared lock that is a point of contention.
- **Who owns the wait lists.** The handle's lock FIFO, the stdin waiters and the channel waiters have no decided owner (the awaiters list is under the target task's lock, §10.2.3). Options: a short lock for each list, taken to link or unlink and never held across a park; or the I/O thread owns the FIFOs, and lock enter and leave are requests.
- **Read buffers and request slots.** Socket bytes land in a connection's `agc_conn.in`, a `realloc`'d buffer appended by a libuv read callback (on the I/O thread in the model) and consumed by a builtin on a scheduler. Who owns and locks that buffer, and where the read-ahead goes when no task is parked, is open. Options: the I/O thread appends under a lock of the buffer and the builtin consumes under the same lock; or every read is a request with its own buffer in the job, and there is no read-ahead. The same question holds for a connection's or process's request slots: `drop_request` (`vm/tcp.c`, `vm/process.c`) unlinks the request from them and may free the connection, so once `drop` can run on the I/O thread, who owns the slots needs a rule. Stdin is simpler: its bytes are read into a `calloc`'d `read_request` buffer in the job, and `read_done`, the `done` half on the resuming scheduler, appends them to `rt->in.buf`, which is GC memory. The open point there is how the schedulers lock `rt->in` between them (it is the shared input, with one read in flight and a FIFO of readers).
- **stdout and stderr once they park** (row 7.2.1f). The per-stream lock of §10.2.3 cannot be held across a park. Options: a lock FIFO on each stream, as a handle has, with one whole print served at a time; or a short lock around a queue of whole prints and a single writer on the loop.
- **The end of the run.** Whether `end_run` waits for the schedulers to stop (at most one turn, as a stop signal does today, §10.2.2) or starts at once. The first keeps a running task from using a file while the exit path closes it. A scheduler can also be blocked in a stdout write that holds the stream lock (a full pipe), while the I/O thread's flush of that stream waits for the same lock. The second stop signal is one way out (the write gets `EINTR`, §14.4), but a process signal may not be delivered to that thread. Another is `pthread_kill` on the schedulers. Whether the flush takes the lock with a limit is open.
- **The form of N = 1 once N > 1 exists.** Keep the single-thread shortcut of §16.9 (a second code path), or use the same threads with N = 1 (two threads, one code path).
