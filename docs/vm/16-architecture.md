## 16. VM architecture

**Status:** decided by the owner on 2026-10-13, row 7.2.1c of the [roadmap](../roadmap/README.md) (docs only; nothing here changes the VM yet). This is the one picture of the threads, the queues and who owns what. The VM as built runs one scheduler and the loop on the same thread (N = 1); §16.9 says what differs. Building more than one scheduler stays gated (roadmap step 11), and this model also serves N = 1.

It replaces the first multicore design of §10.2.3 (BEAM style: one loop, one run queue and one resource registry per scheduler, a home scheduler for each task, work stealing first). The new model has one loop, one run queue and no home. §10.2.3 keeps the rules that still hold (the park and wake protocol, the cancel and stop flags, the state split, the stream locks, the `--schedulers` flag). §14's five rules hold in this model; §16.6 maps each to the component that enforces it.

### 16.1 Components

| Component | What it is |
|---|---|
| **Runtime** | `agc_runtime`: the program, the arguments, the settings. Shared by every thread and read-only after start-up, except the atomics and locks that §10.2.3 lists (`steps_left`, `outcome`, one lock per output stream). |
| **Schedulers** | N threads that run the interpreter. A scheduler takes a ready task from the global run queue, runs one turn (§10.2.1), and then parks it, ends it or puts it back. It never calls libuv. |
| **Global run queue** | The FIFO of ready tasks. Many producers, N consumers (§16.3). |
| **I/O thread** | The main thread after start-up. It runs the only libuv loop. It has an inbox of requests from the schedulers (§16.4). |
| **libuv thread pool** | Bounded blocking work only: regular files and directories, DNS, and the TLS setup jobs that load CA, certificate and key files (§14.1). One pool per process, driven by the loop. Its threads never touch GC memory. |
| **Handles and their owner tasks** | A file, socket, listener, process or poller is a libuv handle on the I/O loop for its whole life. The task that opened it owns it (§14.5). |
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
- **Only the I/O thread touches libuv.** The one call other threads make is `uv_async_send` on the inbox's handle, which libuv allows from any thread. The pool runs only the `work` half of a job on `malloc`'d memory (§10.2.2).
- **The I/O thread only moves bytes.** It reads into and writes from buffers in the job. TLS crypto and HTTP parsing run on the scheduler that resumes the task, over OpenSSL memory BIOs (`vm/tls_openssl.c` has them already), so a slow handshake or a big parse never stalls the loop.
- **No dispatcher thread.** Schedulers pull work; nobody pushes a task at a chosen scheduler.

### 16.3 Queues

KISS. Every queue is the same small thing: an intrusive singly linked list with `first` and `last`, and one `pthread_mutex_t`. The `next` link lives in the task or job, so a push allocates nothing. A push is O(1) at the tail and a pop is O(1) at the head.

```c
typedef struct { entry *first, *last; pthread_mutex_t lock; } queue;

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
```

This is a sketch of the rules, not final code. The rules:

- **Wake after publish.** The producer prepares the entry outside the lock, links it under the lock, unlocks, and only then wakes the recipient. The lock publishes everything written before the push (a job's result, a task's state).
- **Single-consumer queues** (the I/O thread's inbox now; per-scheduler inboxes later) are taken whole in one lock (`first = last = NULL`) and processed outside the lock. The consumer may take a bounded number per turn and keep the rest in a local list; it looks at that list on its next turn, with no new wake.
- **The global run queue has N consumers**, so a scheduler pops one task (or a small batch) under the lock, never the whole list. Taking everything would leave the other schedulers idle with work waiting.
- **Idle schedulers wait on a condvar**, with no busy waiting. A push signals one. A scheduler checks the queue and waits under the same lock, so a signal after the unlock is never lost. The I/O thread's wake is `uv_async_send`.
- **Not lock-free, on purpose.** Atomic `first`, `last` and `next` do not make the operation atomic, and node reuse (ABA) and producers that are suspended halfway make it hard to get right. A mutex with light contention is fine. Measure contention and latency before changing the algorithm. This is not a temporary design.

### 16.4 Two directions

- **To the schedulers: the global run queue.** The I/O thread writes the result into the job, then pushes the task; the lock publishes the result. Schedulers push too: a spawn, a yield, and the wake of an awaiter or of a lock waiter. Whoever wakes a task follows the park and wake protocol of §10.2.3, so a wake that arrives while the task is still parking is not lost.
- **To the I/O thread: its inbox.** A request is "start a read, write, close or cancel on handle H for job J". A scheduler marks its task as parking, links the job on the inbox, calls `uv_async_send`, and ends the turn. The I/O thread takes the inbox and starts each request on the loop: for a pool job it calls `uv_queue_work`, and for every job it arms the job's one timer (§14.2).
- **The pool keeps its own mechanism.** Its `after_work` callback runs on the I/O thread, which then pushes the task to the run queue. There is one path back from I/O, and it is always the run queue.
- **Invariant: a task is in exactly one place.** It is running, or in the run queue, or parked with at most one pending request. So the intrusive link is safe (a task or job is in one list at a time), and neither queue needs backpressure: both are bounded by the number of live tasks.

### 16.5 Ownership and lifetime

- **A job belongs to its parked task.** The I/O thread fills in the result and never frees the job. The scheduler that resumes the task takes the result and ends the job (`agc_io_finish` today, §10.2.2). A detached job has no task; who ends it is open (§16.11).
- **A handle belongs to the I/O loop** for its whole life, as a `malloc`'d libuv handle that stays until its `uv_close` callback (§10.2.2). The task that opened it owns it (§14.5). Ownership decides who closes the handle, not who may use it: any task reaches it through a request, and the handle's lock FIFO (§10.2.2) keeps the operations in order.
- **GC rule.** Tasks and jobs are GC memory. A queue head in `malloc` memory that points to them is invisible to Boehm, so each queue lives in GC memory or is registered as a GC root. Thread-pool threads never touch GC memory, and no GC pointer is stored in memory that libuv owns.

### 16.6 Task life cycle and the rules of §14

A task goes ready, then running, then parked on something, then woken by something, then ready again. Each wait kind has one waker, and the woken task always comes back through the run queue.

| Parked on | Woken by | Path back |
|---|---|---|
| A pool job (a regular file, DNS, TLS setup loads) | the I/O thread, in `after_work` | result in the job, push |
| A loop job (socket, pipe, FIFO, terminal, poller, a child's exit) | the I/O thread, in a libuv callback | result in the job, push |
| A timer (`Task.sleep`, a job's timeout, a lock wait's deadline) | the I/O thread, in the timer callback | push |
| A handle's lock FIFO | the scheduler that ends the holder's job | push |
| `Task.await` | the scheduler that ends the target task | push |
| A stdin read that another task already started | the scheduler that ends that read's job | push |
| A channel (`send` or `recv`, 17b) | the scheduler of the task that sends, receives or closes; a deadline is a timer | push |
| `agc_task_cancel` | the scheduler of the task that cancels | the task ends, its waiters are pushed |

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
- **stdout and stderr are locked per stream when N > 1** (§10.2.3, "Output"). The writes stay blocking until they move onto the loop (roadmap row 7.2.1f), so a full pipe blocks the scheduler thread that holds the lock, and the other schedulers that print to that stream wait for it.
- **One lock on the run queue** is shared by every scheduler and the I/O thread. Measure it (§16.3).
- **One I/O thread** may become the limit at a high rate of sockets. That is what §16.10 is for.
- **A wake crosses threads.** An I/O result goes through a push and a condvar signal before a scheduler runs the task. With N = 1 as built there is no hop. Measure the latency.

### 16.9 As built: N = 1

Today there is one scheduler and the loop on the same thread. The model with N = 1 is almost what exists: tasks, turns, jobs with their `agc_io_kind` halves, detached jobs, the handle lock FIFO, the owners and the one exit path are as in §16.1 to §16.6. What differs:

- **One thread plays both roles.** The scheduler calls `uv_run(UV_RUN_NOWAIT)` after each turn and `uv_run(UV_RUN_ONCE)` when the run queue is empty (§10.2.1, §10.2.2). In the model, the I/O thread sits in the loop and the schedulers wait on the condvar.
- **No inbox and no locks.** `agc_io_start` calls libuv directly. libuv callbacks put the job on a ready list, and the scheduler drains it after `uv_run` and queues the tasks. That drain is the push of §16.4. The run queue is a plain list.
- **Services call libuv from their builtins.** `tcp.c`, `process.c`, `files.c` and the others make their own handles through `agc_io_uv` (§15.1) on the scheduler's thread, which today is the loop thread. In the model that code runs on the I/O thread, as the start step of the request (§16.4). This is part of the multicore work too.
- **TLS and HTTP steps run in libuv callbacks.** `advance` and `flush` in `vm/tcp.c`, and `head_step` in `vm/http_server.c` and `vm/http_client.c`, run from connection callbacks on the loop thread. The model moves them into the turn of the resumed task. This is part of the multicore work, not of the earlier PRs.
- **Plain task states.** READY, RUNNING, PARKED and DONE, without PARKING and WOKEN (§10.2.3), and no stream locks.
- **One resource registry on the scheduler** (`vm->registry`), and Boehm built without thread support.
- **`end_run` runs on the scheduler's thread**, which is the main thread.

### 16.10 Later iterations

Only if measurements ask for them. Neither is planned.

- **K I/O threads**, K configurable (for example one per 4 to 8 cores). Each handle is fixed to one loop when it is created. There is one inbox per I/O thread, and a request goes to the loop of its handle. Ready tasks still go to the global run queue.
- **Per-scheduler local queues with work stealing.** Wakes then go to a global inject queue.

### 16.11 Open

- **Detached jobs and cancel requests.** A job whose task was cancelled has no owner (§10.2.2, "Detached jobs"), and a cancel request must not need a second link on a job that may still be in the inbox. Options: the I/O thread ends a detached job, an exception to §16.5 for that case only; or the job goes back through the run queue to a scheduler. For the cancel: a flag on the job plus a wake of the I/O thread, or a small entry of its own.
- **Cancelling a ready task.** A singly linked list cannot unlink a task from the middle in O(1). Options: set the task's cancel flag and let the scheduler that pops it end it instead of running it; or walk the list under the lock.
- **The resource registry.** One registry shared under a lock, or one owned by the I/O thread, with registration done when the request is started.
- **The end of the run.** Whether `end_run` waits for the schedulers to stop (at most one turn, as a stop signal does today, §10.2.2) or starts at once. The first keeps a running task from using a file while the exit path closes it.
- **The form of N = 1 once N > 1 exists.** Keep the single-thread shortcut of §16.9 (a second code path), or use the same threads with N = 1 (two threads, one code path).
