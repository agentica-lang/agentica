### 10.2 Rules for 7h

The core rules (waiting, timeouts, cancelling, ending, handles) are in §14. This
section says how the scheduler and the loop keep them.

- **Target.** N scheduler threads run the interpreter and pull ready tasks from
  one global run queue. One I/O thread, the main thread, runs the only libuv
  loop (10.2.3, §16). By default there is one scheduler per logical core. With
  `--schedulers 1` the scheduler and the loop share one thread.
- **Tasks are VM stacks.** A blocking builtin starts a libuv request, parks its
  task, and the scheduler runs another (10.2.1). Only the loop's thread calls
  `uv_run`. libuv callbacks only copy results and mark tasks ready. With N>1,
  TLS and HTTP parsing run on the scheduler that resumes the task (§16.2).
  Output order across tasks is not defined.
- **Output on the loop, blocking files.** Stdout and stderr are written by the
  loop (10.2.2), and so is the forwarded stderr of a child process. Only the
  fallbacks of §14.1 keep a blocking write. The VM never sets the thread pool
  size (10.2.2, Pool size).
- **Thread-pool threads never touch GC memory.** Requests and handles are
  `malloc`'d, and file buffers are `malloc`'d copies. The GC object that owns a
  handle stays registered until its `uv_close` callback. `handle->data` and
  `SSL_set_app_data` point to GC objects only while registered.
  `CRYPTO_set_mem_functions` is never routed to the GC.
- **Descriptors are non-inheritable.** All VM file descriptors and handles are
  `O_CLOEXEC`.

#### 10.2.1 Scheduler

- **Run queue.** One FIFO of ready tasks, ordered by the scheduler alone: libuv
  never picks the next task. New tasks, tasks whose turn ended, and tasks woken
  by a libuv callback go to the back. It is the global run queue (`vm/runq.c`),
  locked as §16.3 and 10.2.3 say.
- **Reductions.** Each turn has a budget of 2000 steps (`AGC_TURN_STEPS`),
  counted as `--max-steps` counts them (`STEP n` counts n). A `STEP` that spends
  the budget sends the task to the back of the queue. A merged `STEP n` that
  crosses the budget charges all n and yields at the next instruction; the
  excess is not carried over. Crossing `--max-steps` fails the task with
  `RUNTIME-STEP-LIMIT` at the span of 4.2. The scheduler switches only at a
  `STEP`, at a safe point, or right after a builtin or opcode whose turn cost
  spent the budget (Builtins). Every loop passes a `STEP`, and every function
  that calls starts with one (8). A task also leaves its turn when it blocks.
- **One counter for both budgets.** `STEP` counts down one "next stop" counter,
  set to `min(turn_left, batch)` at the start of a turn and after each sync. The
  batch is the part of `steps_left` that the scheduler holds (Quotas). Turn
  costs never touch the counter, so the fast path is one compare and one
  subtraction. Neither the `STEP` slow path nor the turn-cost path reads the
  cancel or stop flags. The scheduler reads them after each turn (`vm/task.c`).
- **Builtins.** No builtin's C code is stopped halfway. The resumable builtins
  of 4.3 switch out only between their callbacks, and so does `File.each_line`
  (a stepper, 4.3), which also parks while a read or the close runs. Each block
  call costs one step and the turn cost of the bytes read for that line. Any
  other builtin finishes its turn, so one whose work grows with its input
  charges a **turn cost**: one unit per item (a sort counts n·⌈log2 n⌉) and one
  per 64 bytes it copies or scans. Constant work charges nothing. Some opcodes
  charge the same way: string concatenation, interpolation, `to_s`, `inspect`,
  string equality (the checker allows `==` only on scalars, strings and ranges),
  and map access with String keys. The turn cost comes from the turn only, never
  from `--max-steps` (`steps_left`). The task yields at the next instruction if
  its turn is spent. File builtins charge nothing: their work is I/O, at most 1
  MiB per call.
- **Test switches** (tests only). `AGENTICA_VM_TEST_BLOCKING_OUTPUT=1` keeps
  stdout and stderr on the blocking `FILE` fallback (10.2.2), so that path is
  tested on Linux. `AGENTICA_VM_TEST_NO_TURN_COST=1` skips the turn-cost charge.
  It changes only when tasks switch, never output, step counts or diagnostics,
  so `make vm-latency` can show that the latency test fails without the rule.
  `AGENTICA_VM_TEST_SHARED=1` calls `agc_share`, so a run on one scheduler takes
  every lock (§16.9).
- **Fairness with I/O.** After each turn the scheduler calls
  `uv_run(UV_RUN_NOWAIT)`, so ready I/O and timers wake their tasks while others
  compute. Tasks woken during a `NOWAIT` go behind the queued ones. With N=1 the
  scheduler blocks in `uv_run(UV_RUN_ONCE)` only when its queue is empty. A
  ready event waits at most for the turns queued ahead of it, each about one
  budget plus the last builtin call of that turn. A parked task waits on I/O, a
  timer, another live task (a timed await also has a timer), or a channel with a
  timer.
- **Quotas.**
  - `--max-steps` is one global budget shared by all tasks (`steps_left`, 6.1),
    and turn costs are never charged to it. With one task, a runaway program
    stops with `RUNTIME-STEP-LIMIT`. With several, which task fails depends on
    the interleaving, and tests do not compare it.
  - With N schedulers, `steps_left` is one atomic counter. A scheduler takes a
    batch per turn and gives back the unspent part when the turn ends, the task
    parks, or the scheduler goes idle. With N=1 the counts are exact. With N>1
    the run may stop up to (N-1) turn budgets early.
  - Per-task step quotas are not in 7h. Per-task memory quotas are out of scope,
    since the Boehm heap is shared. Only a global heap limit is possible (13).
- **As built.** The turn and its budget code are in `vm/interp.c`.
  `Task.sleep(0)` yields. `Task.sleep(n)` is a timer of the task (§16.9). Under
  `no_files` (the fuzzer) every sleep yields. Stdin EOF is delivered once to
  every task that waited for the read, so a TTY reader never waits for a second
  Ctrl-D. `Task.await` parks the caller with *retry*: when the target ends, each
  waiter re-runs its builtin and gets the cached result. Stdin reads use the
  same retry (a wake is only a hint, 10.2.3). A task whose bottom frame returns,
  or leaves through `try`, is done.
- **Await cycles (17b).** A task can receive its own handle over a channel, or
  hide it in a closure, so awaits can form a cycle. Each task waits on at most
  one task (`awaiting`). Before `Task.await` parks, it follows the chain from
  the target through `awaiting`. If the chain reaches the caller, the call fails
  with `RUNTIME-TASK-AWAIT-CYCLE` at the `Task.await` span, and the caller does
  not park. A task that awaits its own handle is the shortest cycle. The walk
  costs one turn-cost unit per hop. It stops at a task with a timeout
  (`await_deadline` is set while it waits), since that task ends by itself.
- **Await with a timeout (17c, `docs/future/27-iteration-and-concurrency.md`
  §27.3).** `Task.await(task, timeout_ms)` returns `Await[T]`
  (`Await.Done(value)` or `Await.TimedOut`). `Task.await_result` has the same
  second arity for a `Result` target. `timeout_ms` of 0 or less is
  `RUNTIME-INVALID-DURATION` at that argument, checked first. A target that has
  settled (done, and not closing files) gives `Await.Done` with the plain
  await's outcome, also when the timer and the target's end wake the caller
  together. Otherwise the deadline is stored in the task (`await_deadline`, set
  at the first call), the task joins the target's waiters, and a timer of the
  task is armed (`agc_task_park_until`, §16.9 "Timers"). The timed form runs no
  cycle check, since it cannot wait forever: a task that awaits its own handle
  with a timeout gets `Await.TimedOut`. The first of two wakes wins. The
  target's end wakes the waiters and `resume` disarms the timer. Or the timer's
  retry leaves the waiters, clears `awaiting` and the deadline, and returns
  `Await.TimedOut`. A wake before the deadline, with the target unsettled, waits
  for the time left. A cancelled caller leaves through `unlink_task`. After a
  timeout the target is untouched, and a later crash or cancel of it does not
  reach the caller.
- **Ending with `main`.** When `main` returns, ready and parked tasks never run
  again, and the exit path (End of run) does not wait for their jobs. A
  `System.exit`, a failure in `main`, `RUNTIME-STEP-LIMIT` or `RUNTIME-INTERNAL`
  in any task end the run at once.
- **Crashes (phase 24, [task rules][task-rules]).** A failure in a task crashes
  that task, unless it is a failure in `main` or one of the two codes above,
  which end the run. The text `task crashed: CODE at FILE:LINE:COLUMN: MESSAGE`
  joins the run's unobserved crashes. Crashes of `hidden` tasks (the HTTP
  connection tasks of 20c) join only the first per test (or per run outside
  `Test.run`); the others count as `quiet_more`, so the list stays bounded. The
  diagnostic goes to stderr with ` in a task` (`"task":true` in `--json`). The
  task ends like a cancelled one: its jobs, locks and FIFOs go, its running
  descendants are cancelled, its owned handles close (Owners), and its awaiters
  wake. `Task.await` halts with `RUNTIME-TASK-CRASHED` (or
  `RUNTIME-TASK-CANCELLED`). `Task.await_result` returns `error(text)` or
  `error("task: cancelled")`. Either entry marks the crash observed. If `main`
  returns with a crash that no await observed, the run prints one summary line
  and exits with code 1.
- **Owners (phase 24, 24b).** The task that makes a user-visible handle owns it.
  The resource records the owner and its kind's close, and the task keeps the
  list of what it owns (`agc_own`). `finish_task` calls `agc_close_owned` for
  every task that ends, whether it returns, crashes or is cancelled. A socket,
  listener or TLS socket is disowned. A process closes with `shut`, which only
  signals (§10.4 Close), never with the release that kills every child. A file
  closes by an `OP_CLOSE` job, and a server by `close_server`. The process
  guard, job resources, stream locks and `HttpClient` have no owner.
  `Task.spawn` moves nothing, so a handle that a helper returns is closed when
  the helper ends. The one hand-off is `Task.spawn_owning(&f, handle)` ([handle
  ownership][task-rules]). `agc_task_spawn_owning` checks that the caller owns
  an open handle, else `RUNTIME-HANDLE-NOT-OWNED` at the handle argument, before
  any task is made. Then it moves the owner to the new task. `HttpWire.spawn`
  does the same (10.7.2).
  - A file's close is an `OP_CLOSE` job with no task. It waits while another job
    holds the file, also a detached one (`agc_io_finish` and `end_detached` pass
    the lock on first). A file that is closing gives every caller the closed
    error. `File.close` on a handle whose close job is in flight waits for it
    and returns its result.
  - For a regular file the ending task counts its close (`closing` in the task,
    `ender` in the resource). The awaiters of an ended task stay parked until
    those closes finish (`agc_task_close_done`), so a parent that awaits a
    helper sees everything the helper wrote. A flush to a FIFO or a pipe is not
    counted, since it waits on the loop for a reader. Only the flush limit
    bounds it. A close that waits behind a job that can wait for ever (a FIFO or
    pipe read) keeps the descriptor open until that job ends or times out. The
    awaiters do not wait for it.
  - A cancelled task's handles close too, also those of a task parked in a
    stepper (`File.each_line`). A file that a detached job still holds closes
    when that job ends. A handle made outside a turn has no owner, and is closed
    when its result is dropped.
- **Cancellation (20b).** A program cancels tasks only through a crash (which
  cancels the crashed task's descendants), `HTTP.close_server`, and the deadline
  of a `Task.map` item. Each task records its parent and its running children,
  and a task that ends hands its running children to its parent. A group node
  (20c) never runs and has no id: it parents an `HttpServer`'s connection tasks,
  so cancelling the group reaches them. A cancel reaches running descendants,
  children first. A cancelled task gets its flag, then: a ready task leaves the
  run queue; a parked task detaches from its job (Detached jobs); a task waiting
  for a handle's lock leaves the FIFO and passes ownership on if it was
  `next_owner`; a task waiting on a channel leaves its FIFO, has its timer
  disarmed (`unlink_task`), and hands on any reservation it holds (Channel
  waits); a task in `Task.await` or a stdin wait leaves its FIFO. The task then
  ends like a returning task. A later `Task.await` halts with
  `RUNTIME-TASK-CANCELLED` (or returns `error("task: cancelled")` for a
  `Result`). A program can reach this, since a task can send its child's handle
  over a channel and then crash. A task that cancels itself finishes its builtin
  and then ends. A cancel spends no step and charges one turn unit per cancelled
  task, to the caller.
- **Task.map (17a, `vm/task_map.c`, core layer).** The builtin checks `limit` (1
  to 1024, `RUNTIME-INVALID-COUNT`), then `timeout_ms` (above 0,
  `RUNTIME-INVALID-DURATION`), then the empty list. Otherwise it installs a
  stepper on the caller (`agc_task_stepper`), so the caller is the one task
  parked in the call and nothing else waits for the group. Each item is a child
  of the caller (`agc_task_spawn_seeded`). The caller does all the spawning and
  cancelling, so the random streams split in input order and nothing runs on
  another task's turn. Starting an item costs one step (`agc_count_step`), and
  the result list costs one turn unit per item. All items have the same timeout
  and start in input order, so their deadlines grow along the running list. One
  timer of the caller, for the oldest deadline, is enough. The step function
  runs when the caller wakes. It moves ended items into their slots (a crashed
  item becomes `error("task crashed: ...")`), expires the oldest item past its
  deadline (`error("task: timed out")`, and `agc_task_cancel` stops it and its
  descendants), starts items up to `limit`, and ends with the list once every
  slot is set. An item reports its end through a hook (`end`, `end_data`), which
  `finish_task` calls for a return, a crash and a cancel. The hook ignores an
  item that already timed out. An item cancelled by someone else can only be
  cancelled through its caller. The caller, a stepper parked on the group's
  timer, is then cancelled like any parked task (its timer is disarmed): it
  cancels its children first, never runs the step function again, and so starts
  nothing and writes no slot. An item with a file close pending is not settled:
  the hook waits, and `agc_task_close_done` calls it when the last close ends.
  If the deadline comes first, the item settles as timed out without waiting
  for the close (`expire` marks its crash, if any, as observed), and the hook,
  when the close ends, finds a settled item and does nothing. An item that ends
  after its deadline, but before the caller runs, keeps its result.
  The handles an item opened are closed when it ends or is cancelled (Owners).
  With more than one scheduler (not built) the hook runs on the item's
  scheduler, so the group needs its small lock (10.2.3, "Task.map group lock").
- **Stall check (N=1).** If the queue is empty, no libuv handle is alive, no
  timer of a task is armed (§16.9, "Timers"), and `main` is not done, the VM
  fails with `RUNTIME-INTERNAL` ("every task is waiting and nothing can wake
  them"). No program reaches it. Every channel wait and every timed await holds
  a timer, every other wait holds a libuv request, a timer or a live task, and
  plain await cycles halt before they park (`Task.await` above). For N>1 see
  10.2.3.
- **Multi-task runs.** A runaway multi-task run must stop with
  `RUNTIME-STEP-LIMIT` (the black-box rule, §1). The `--max-steps` sweep (§12.1)
  needs each limit to give the full outcome, or the step limit with stdout a
  prefix of the full run. The task fixtures keep that deterministic: their step
  counts do not depend on the clock.

#### 10.2.2 The loop

- **Resource registry** (`vm/loop.c`). Every handle, request and job is a GC
  resource that owns its `malloc` memory and keeps its registry slot until it is
  released. A `FileHandle` points to its resource. A job stays registered until
  its work has run, its timer is closed, and its result was taken. No GC pointer
  is stored in `malloc` memory. Callbacks find their job with `offsetof`, never
  through `handle->data`.
- **Blocking builtins are two halves.** The C builtin checks its arguments,
  copies what the OS needs into a `malloc`'d request (paths through the rules of
  2.8), and starts the job. One `uv_queue_work` covers the whole operation
  (stat, open, read, close), so the task parks once per call. The call's timeout
  is the job's timer (a negative timeout starts none). `CALL_BUILTIN` ends the
  turn.
- **Waking and parking.** The work and timer callbacks only set flags and put
  the job on the loop's ready list. After each `uv_run` the scheduler drains
  that list and queues the tasks. On completion the `done` half runs on the
  interpreter thread and builds GC values from the `malloc`'d result. On timeout
  the `expired` half gives the timeout error (`filesystem: operation timed out`
  for a file) and, for a handle operation, closes the handle.
- **Thread-pool threads** run only the `work` half, on `malloc` memory.
  `UV_USE_IO_URING` is set to `0` (unless already set) before the loop is made,
  so libuv uses its thread pool and epoll. `SIGINT`, `SIGTERM` and `SIGHUP` are
  blocked around every pool start, and in the `tcp.c` threads. So the stop
  handler, which may run on any thread, touches only lock-free atomics and
  async-signal-safe calls.
- **Pool size.** The VM never sets the pool size. The libuv variable
  `UV_THREADPOOL_SIZE` does (there is no `AGENTICA_*` variable). libuv reads it
  once, when the pool is created, so it must be set before the VM starts. The
  default is 4, and the cap 1024. The pool runs regular-file I/O, opens and path
  calls, DNS (`getaddrinfo`), and the TLS setup jobs. Blocking stdin is the
  exception: a failed Unix poller setup can keep one pool thread until input
  arrives (Stdin below). Windows stdin never uses the pool. All other work must
  finish without waiting indefinitely for input.
- **We only wait where the loop can cancel** (§14.1). Files open with
  `O_CLOEXEC` and `O_NONBLOCK`, so opening a FIFO never waits for a peer. The
  pool job then picks the path by `fstat` and an `epoll_ctl` probe, never by
  name. A regular file, a block device, or a device that epoll refuses with
  `EPERM` (`/dev/null`, `/dev/zero`) is blocking and runs in the pool. Any other
  probe error is the call's error, never a fall back to blocking. A pipe, FIFO,
  terminal or other waiting character device is non-blocking on the loop through
  a poller (`uv_poll_t`). A handle call tries its step on the loop thread. When
  it would wait, it parks on an `external` job, and the poller's callback
  repeats the step. A whole-file call opens in the pool. If the path is
  pollable, its `more` step keeps the same job and task waiting on the loop (a
  pool kind with a `cancel` half must have a `more` step, which `start_job`
  checks). A poller error is reported by repeating the step, so the call gets
  the real error (`EPIPE` for a reader that left). `read_text` of a pipe, or of
  a regular file that reports size 0 (`/proc`, `/sys`), reads to EOF, at most 1
  MiB. `File.each_line` reads one job per read, of at most `buffer_bytes` into a
  buffer made once. A timed-out read closes the handle. Between reads the task
  runs the block for every complete line already buffered. On Windows no `File`
  call waits on the loop: `probe` refuses a named pipe or a device with
  `ENOTSUP`, and the call closes it (§14.1).
- **End of run: one exit path.** However the run ends (`main` returns,
  `System.exit`, a runtime error, the step limit, a stop signal),
  `agc_launch_settle` in `vm/launch.c` takes the same steps and nothing else
  (§14.4):
  1. kill the children and drive the loop until libuv's exit callbacks have
     reaped them (10.4, Close; at most about 2 seconds);
  2. one non-blocking TLS `close_notify` on each TLS session that finished its
     handshake: TCP sockets (10.3) and `HttpClient` connections (10.7.1). Each
     TCP socket and listener still open is then closed the way a close from a
     task closes it, so the peer reads the end of input: Windows resets a
     socket left to the exit while a read is pending (#489);
  3. flush the blocking stdout and stderr (`fflush`, retried on `EINTR`), then
     queue the diagnostic of a failed run as a kept notice (10.2.2), so the wait
     below covers it. Close every open file, and wait for their flush jobs and
     for the stdout and stderr buffers to drain. The wait first drains the pool
     jobs that have already finished. It is always bounded: 30 seconds by
     default, or `--flush-timeout MS`, or `AGENTICA_FLUSH_TIMEOUT_MS` (the flag
     wins; there is no way to turn the limit off). So a FIFO whose reader
     stopped cannot keep the run open for ever. When it runs out, the VM prints
     `agentica: file data may not be written: the flush took longer than MS ms`
     (or `{"flush_timeout_ms":MS,"warning":...}` with `--json`). The exit code
     does not change;
  4. print what is only known now without blocking (the flush-timeout warning, a
     `RUNTIME-INTERNAL` diagnostic for a stdout or stderr write error), and end
     with `_exit`, so libuv's destructor never joins the pool. These go through
     `agc_notice_end` as final notices (Notices, below). No task, pool job or
     socket is waited for. Killing the children first means data buffered for a
     FIFO's reader is lost. A file close that fails here prints `agentica: file
     data may not be written: the flush failed (CODE: message)` (or
     `{"flush_failed":"CODE","warning":...}`); the exit code does not change.
     `agc_io_close`, which closes every resource and frees the loop, is only for
     the in-process harnesses.
- **Stop signals.** One `sigaction` handler covers `SIGINT`, `SIGTERM` and
  `SIGHUP`, except a signal the VM started ignored (`nohup`). Its state is one
  process-wide record (`stop_status()` in `vm/loop.c`, lock-free atomics). The
  first signal is stored and wakes the loop. The scheduler checks it after every
  turn, before it waits and before it reports a stall, and the run ends as an
  exit with code 128 + signal. `end_run` runs the steps above, then raises the
  signal again with its default action. A second signal ends the VM at once, but
  only after the children are stopped. Until then it is only recorded. A
  3-second grace timer (`STOP_GRACE_SECONDS`) backs this up. A driven VM
  (`--driver-pid`) whose driver is gone treats even the first signal as a second
  one. The handler has no `SA_RESTART`, so a blocking fallback write that nobody
  reads returns `EINTR`. The run then ends as the stop (128 + signal, no
  diagnostic), and that write is not retried. A stream on the loop has no
  blocked write. Once a stop signal is set, its wait in step 3 ends after one
  non-blocking write (End of run and stop). A CPU-bound task delays the stop by
  at most one turn.
- **Per-handle lock.** A `FileHandle` has a `holder` (the job in flight), a
  `next_owner` task, and a FIFO of waiting tasks, all in GC memory. Every handle
  builtin (`read_bytes`, `read_line`, `write`, `write_bytes`, `flush`, `close`)
  checks its arguments and timeout first, then takes the lock, and only then
  checks that the handle is open and has the right mode. A task that cannot take
  the lock parks with retry on a timer at its deadline, which covers both the
  lock wait and the operation. Release is a FIFO hand-off. The head waiter
  becomes `next_owner` and is the only one woken, so the releasing task cannot
  take the handle back in the same turn. A cancelled `next_owner` passes
  ownership on. So `close` waits for the operation in flight, two readers take
  turns, and buffered writes keep their order. On an operation timeout the stuck
  operation keeps the state, the handle is closed, and the next owner gets `file
  handle is closed`. A closing handle that a job still holds makes callers wait
  for the lock as for any other handle. Once no job holds it, they get the
  closed error.
- **Channel waits (17b, `vm/channel.c`).** A channel is a GC object: a ring
  buffer, the capacity, a closed flag, and two FIFOs of waiting receivers and
  senders linked through `wait_next`. The ring starts with at most 8 slots and
  doubles up to the capacity, so `Channel.new(1048576)` allocates little.
  Copying a growing ring charges one turn-cost unit per slot. Other calls charge
  nothing, and a value is one pointer. A call that must wait parks with retry on
  a timer of the task, ending at the call's deadline (`agc_task_park_until`,
  `vm/timers.c`). There is no job, so no `io` trace line. The `sched` trace
  shows `timer_arm` and `timer_fire`. The deadline is set at the first wait and
  kept in the task (`channel.deadline`), as `agc_handle_wait` does. A timeout of
  0 tries once and never parks.
  - **Reservations.** A value that arrives while receivers wait is not put in
    the ring. The head receiver is popped, the value is stored in the task
    (`channel.value`), and the task is woken. This is a direct hand-off, so no
    other `recv` takes it first. A slot freed while senders wait is reserved for
    the head sender the same way, and so is a slot freed when a woken sender
    hands its value to a waiting receiver. Each accepted value gets a send
    sequence number, kept in its ring slot and its reservation. The counters
    `reserved_values` and `reserved_slots` keep `closed?` and the free space
    exact. A woken waiter re-runs its builtin and gets its reservation, even if
    its deadline passed, since the reservation came first.
  - **A waiter that leaves.** A waiter woken with a reservation is already off
    its FIFO. A timer wakes its task and leaves it in the FIFO. The next pop
    skips a task that is no longer parked, so a reservation never goes to a
    waiter whose timeout came first. A cancelled waiter (`agc_channel_leave`)
    hands its reservation on, to the next receiver or back to the head of the
    ring. A value goes back by its sequence number, so values stay in send
    order. So the ring may hold more than the capacity, by at most one value per
    handed-back reservation. Senders wait while `count + reserved slots >=
    capacity`. No value is lost.
  - **Close.** `close` marks the channel, revokes the reserved send slots (their
    `send` returns the closed error and the value is not added), and wakes all
    senders. Receivers keep getting the values left. A `recv` on a closed
    channel with an empty ring, but a value reserved for a woken receiver,
    waits. The receiver that takes the last reservation wakes the others, which
    then get the closed error. `closed?` is true when the channel is closed, the
    ring is empty and nothing is reserved, and it stays true.
  - **An owner.** `Task.spawn_owning` can give a channel to the task it spawns
    (`agc_channel_claim`). When the owner ends in any way, `finish_task` runs
    `agc_close_owned`, which calls the same close. A `close` from any task drops
    the entry first. A channel never handed over has no entry (§14.5 of
    `docs/vm/14-core-invariants.md`).
  - **Choices.** Mid-FIFO removal is O(n), as for the lock FIFO. A waiter whose
    timer fired before any wake still takes a value that reached the ring before
    it re-ran, instead of failing at once.
- **Detached jobs (20b).** When its task is cancelled, a job is detached. It has
  no task, it is never abandoned with a close, and it runs to its own end or
  deadline, keeping the handle's lock. Its `done` half runs and the result is
  dropped, not charged to the current task. Its lock passes to the head waiter.
  A handle that the dropped result would have handed out is closed. The
  `expired` half never runs on a detached job, so it never closes a handle a
  task holds. A kind may set a `cancel` half, which ends the job early and
  returns true. No pool kind may have one, since a pool thread may still use the
  data. `HttpWire.accept` and `HttpWire.wait` use it to leave at once. For TCP
  and process kinds at the deadline, a read, accept or wait leaves its handle
  open, a connect closes the socket it was opening, and a send waits for its
  write callback. A listen has no deadline. A pool job (files, stdin) runs until
  its work ends.
- **External jobs.** A kind with `external` set has no `work` half. A libuv
  callback on the loop thread completes it, which puts the job on the ready
  list. A second call does nothing.
- **Fuzzing.** `agc_fuzz_one` sets `vm->no_files`: a file builtin (also
  `Path.cwd`, `Path.resolve` and `Path.real`) ends the run with
  `RUNTIME-INTERNAL`, and `Process.spawn` returns its error. Every loop and
  resource is released before the mutant ends.
- **Stdin.** Stdin follows the rule of files. A pipe, FIFO or terminal is
  reopened through `/proc/self/fd/N` (N is 0) with `O_NONBLOCK`, so the shared
  open file description keeps its flags, and it is then read on the loop. A
  socket keeps its flags and is read with `MSG_DONTWAIT`. A regular file, a
  device epoll refuses, a write-only stdin, a failed reopen (no `/proc`, or
  `EACCES` after `su` or `sudo -u`), or a failed poller stays a pool job with
  one blocking `read` (§14.1). One read of up to 1 MiB is in flight at a time,
  and a second reader parks in the input's FIFO. A read with no data at the end
  of the run is not waited for. On Windows every stdin kind (a pipe, the
  console, a file, `NUL`) is read by one thread of the VM's own
  (`vm/stdio_windows.c`), never by the pool. That thread does one blocking
  `_read` in binary mode when a read is asked for, and wakes the loop with an
  async handle. The handle keeps the loop alive only while a read is out. The
  thread and its handle are made on the I/O thread at the first read, after the
  job's start. Stop signals are handled by libuv on the loop, independently of
  the reader. A cancelled reader leaves the read in flight, as on Unix, and its
  bytes or EOF go to the next reader. At the end of the run the read is
  cancelled where Windows can (`CancelSynchronousIo`, a pipe); a read that
  cannot be cancelled ends with the process, or, in an in-process harness, when
  input comes, and then touches nothing of the closed loop. Other unsupported
  hosts keep a blocking read on the interpreter thread.
- **stdout and stderr (row 7.2.1f, `vm/output.c`).** Each stream has one output
  buffer, a `malloc`'d ring of 64 KiB (`AGC_OUTPUT_BUFFER`), and one FIFO of
  waiting writers. `puts`, `print`, `IO.inspect` and `IO.warn` copy their whole
  text into the buffer and return at once when it fits and no writer waits.
  Otherwise the task keeps a pointer to the text in its `output` slot
  (`agc_output_wait`; the GC scans task memory, so a big print is not copied
  twice) and parks in the FIFO. A later writer does not jump the queue. This is
  the parking pattern of `docs/future/27-iteration-and-concurrency.md` §27.2:
  the head waiter wakes when its whole text fits, and the retry finds its slot.
  `agc_output_waiting` hides that protocol from the builtins. A print longer
  than the buffer holds the stream and copies in pieces, so prints never
  interleave, and nothing else the VM writes lands inside one. A print has no
  `timeout_ms`. Its wait is not a stall, since the writer is alive on the loop
  (10.2.1). A cancelled waiter leaves the FIFO (`agc_output_leave`, §14.3), and
  text it already copied is written whole. `IO.flush` returns when the data
  reached the pipe or file, and fails when the stream failed (a reader that
  left). The loop thread is the only writer of a loop stream.
  - **How a stream is written.** `agc_output_open` (in `main`, after
    `agc_input_open`) picks the way. A pipe, FIFO or terminal is reopened
    through `/proc/self/fd/1` or `/proc/self/fd/2` (`agc_fd_reopen`, shared with
    `vm/input.c`) with `O_WRONLY | O_NONBLOCK`. So `O_NONBLOCK` is set only on
    the VM's own open file description, never on the one the shell and children
    share. A socket is duplicated with `F_DUPFD_CLOEXEC` and written with
    `send(MSG_DONTWAIT | MSG_NOSIGNAL)`. Both are written when the poller says
    the descriptor is writable. On macOS each write is first guarded by
    `poll(POLLOUT)` and cut to `PIPE_BUF` (a socket: `SO_SNDLOWAT`), because
    `send(MSG_DONTWAIT)` alone stalled the loop on such a socket. The poller
    runs one `external` detached job per writable event. Its request holds the
    stream's index, not a pointer. A regular file, a block device, or a device
    that epoll refuses with `EPERM` (`/dev/null`, `/dev/full`), is drained by a
    pool job on the descriptor the process was given, since a reopen would reset
    the offset and `O_APPEND`. One job runs at a time.
  - **Windows.** `vm/stdio_windows.c` (`vm/stdio_posix.c` is the Linux and macOS
    side) sorts the descriptor with `uv_guess_handle` into one of four write
    modes (`agc_write_mode`). A file, or `NUL`, is drained by a pool job on
    `_write`. A pipe is written by a libuv pipe handle, one request at a time. A
    console is written by a pool job that converts UTF-8 to UTF-16 and calls
    `WriteConsoleW`, not by `uv_tty_t`. libuv writes a console on the loop
    thread, where a paused console (a selection, Ctrl+S) would stop every task
    and the stop signals. A handle that libuv refuses (a socket, a pipe nobody
    can write to) also goes to a pool job. Stdout and stderr in this mode hold
    one pool thread each, so with the default pool of 4 they leave 2 threads for
    files, DNS and processes. The loop never writes a pipe, a console or a
    refused handle. Windows resets a socket when its last handle closes, and the
    reader loses what it has not read. So just before the exit, a socket given
    as stdout or stderr gets `shutdown(SD_SEND)` (`agc_output_end`), but only
    when no write of it is in flight, when this process holds every handle to it
    (`CompareObjectHandles`, Windows 10 1607 and later), and, if it is also
    stdin, when no read of stdin is in flight. A socket that is not overlapped
    serializes its I/O. When it is both stdin and stdout, a blocked read stalls
    the writes of stdout, and that output is lost after `--flush-timeout`. The
    pipe's handle is a private, non-inheritable copy of the descriptor, so
    closing it leaves stdout open, and closing it cancels the request in flight.
    A request takes the ranges of the ring as they are and ends all or nothing,
    so the ring is consumed when the request ends. Where Unix makes one
    non-blocking write (a stop signal, a final notice), Windows waits for the
    request up to 200 ms, shared with the other final writes of the exit
    (`settle`). The jobs do not set `flush`, since `agc_output_busy` counts the
    buffered bytes instead. `agc_io_close`, used only by in-process harnesses,
    does not free the buffer of a stream whose pool write is still in flight; a
    real exit ends with `_exit`.
  - **Descriptor guard.** A `File` path that names the reopened descriptor
    (above 2) through `/proc/self/fd` or `/proc/thread-self/fd` on Linux, or
    through `/dev/fd` elsewhere, is refused with the not-a-regular-file error
    (`names_output_fd` in `vm/files.c`). The guard compares directories by
    device and inode. Other `/proc/<pid>/task/<tid>/fd` paths reach the same
    pipe as `/dev/stdout` does, and they stay open, as `/dev/stdout`,
    `/dev/stderr`, `/proc/self/fd/1` and `/proc/self/fd/2` do (§2.8).
  - **Write errors.** A write error (`EPIPE`, `EIO`, `ENOSPC`) is final for the
    stream. The buffered data and the queued notices are dropped, the waiters
    wake, and the print that notices it fails with `RUNTIME-INTERNAL` (`cannot
    write to standard output` or `standard error`). `end_run` folds a failed
    stream into exit code 1, even when no print saw the error. The blocking
    `fwrite` of the `FILE` stays for the fallbacks of §14.1: a reopen or `dup`
    that fails, a descriptor not open for writing, another descriptor type, and
    builds that are not Linux, macOS or Windows. The records of `agentica test`
    do not use this module. They travel on the child channel (§10.4).
  - **One target, one buffer.** When stdout and stderr are one target (the same
    `st_dev` and `st_ino`, or on Windows the same kernel object by
    `CompareObjectHandles`, such as a terminal, `2>&1`, or one file), stderr
    shares stdout's buffer and FIFO (`err.base`). So `puts a`, `IO.warn b` and
    `puts c` appear in call order. Two different files have no order between the
    streams.
  - **Notices.** Text the VM writes to stderr goes through `agc_notice_begin`
    and `agc_notice_end` as a memory stream, written whole. Crash diagnostics
    and the unobserved-task summary are non-final. They join a `malloc`'d queue
    of at most 1 MiB. A notice past that is dropped, so a stuck stderr cannot
    make the VM grow. The queue moves into the buffer ahead of the waiting
    writers, never between the pieces of a print that holds the stream. The
    driver diagnostic of a failed run is a kept notice (`AGC_NOTICE_KEPT`),
    which the 1 MiB limit never drops. It is queued after the blocking streams
    are flushed and before the end-of-run wait, inside a `setjmp` of `vm->fail`,
    so the flush limit covers it. The flush warnings and the `RUNTIME-INTERNAL`
    write-error diagnostic are final. `end_run` writes them without blocking,
    and what a stuck pipe will not take is dropped. So a stuck stderr cannot
    hold the exit, and a stop signal drops what is still queued. The
    flush-timeout warning is known only at the deadline, so it comes after the
    diagnostic. If a pool job still writes the stream when the flush limit runs
    out, a final notice is skipped, since a second write could block.
  - **End of run and stop.** At the end of the run, stdout and stderr drain
    within the flush limit (§14.4). No task runs any more, so a cut print is
    abandoned with the pieces it copied. `agc_output_busy` moves the queued
    notices in with force, and restarts the writer for each stream that is not
    writing. So the wait ends when the data is written, not at the limit. With a
    stop signal set, `agc_output_busy` makes one non-blocking write per stream
    (on Windows, within the shared 200 ms). It then stops waiting for stdout and
    stderr, so a reader that never reads cannot hold a stopped VM for the flush
    limit. Files keep their wait.
  - **A child's stderr.** `vm/process.c` hands each chunk of a plain child's
    stderr to `agc_output_forward` on the I/O thread. The bytes join the notice
    queue, so they never enter a print that holds the stream. They keep their
    arrival order with prints: the child bytes queued before a print go ahead of
    it, and the ones after take only the buffer room that the head of the FIFO
    does not need. So a child that writes without end holds back `IO.warn` or
    `IO.flush` by at most what was queued when it came (the 64 KiB bound plus
    one read chunk). When more than 64 KiB wait, the child's pipe is no longer
    read (`uv_read_stop`) until the queue is down to 32 KiB. So a stuck stderr
    stops the child, not the loop. A failed stderr drops these bytes, and fails
    the run only when program or VM text was lost with them. A write error on
    stdout keeps the exit-code rule of `agc_launch_settle` (`vm/launch.c`). The
    builtins keep their names, types and results, and a full stdout pipe stalls
    only the tasks that print.
  - **Tests:** `tests/test_vm_stdout.py` (peer `tests/fixtures/stdout-peer.py`),
    `tests/test_vm_stop.py` and `vm/tests/output_test.c`.

[task-rules]: ../grammar/06c-tasks-and-tests.md#lightweight-tasks
