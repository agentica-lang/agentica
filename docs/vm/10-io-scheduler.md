### 10.2 Rules for 7h

The core rules (waiting, timeouts, cancelling, ending, handles) are in §14. This
section says how the scheduler and the loop keep them, as built.

- **Target.** N scheduler threads run the interpreter and pull ready tasks from
  one global run queue. One I/O thread, the main thread, runs the only libuv
  loop (10.2.3, §16). The built VM runs N=1: the scheduler and the loop share
  one thread.
- **Tasks are VM stacks.** A blocking builtin starts a libuv request, parks its
  task, and the scheduler runs another (10.2.1). Only the loop's thread calls
  `uv_run`. libuv callbacks only copy results and mark tasks ready. With N>1,
  TLS and HTTP parsing run on the scheduler that resumes the task (§16.2).
  Output order across tasks is not defined.
- **Output on the loop, blocking files.** Stdout and stderr are buffered and
  written by the loop (10.2.2), the forwarded stderr of a child process too;
  only the fallbacks of §14.1 keep a blocking write. The VM never sets
  the thread pool size (10.2.2, Pool size).
- **Thread-pool threads never touch GC memory.** Requests and handles are
  `malloc`'d, and file buffers are `malloc`'d copies. The GC object that owns a
  handle stays registered until its `uv_close` callback. `handle->data` and
  `SSL_set_app_data` point to GC objects only while registered.
  `CRYPTO_set_mem_functions` is never routed to the GC.
- **Descriptors are non-inheritable.** All VM file descriptors and handles are
  `O_CLOEXEC`.

#### 10.2.1 Scheduler

- **Run queue.** One FIFO of ready tasks, ordered by the scheduler alone: libuv
  never decides which task runs. A new task, a task whose turn ended, and a task
  woken by a libuv callback go to its back. It is the global run queue
  (`vm/runq.c`) under its lock (§16.3, 10.2.3); with N=1 one thread uses it.
- **Reductions.** Each turn has a budget of 2000 steps (`AGC_TURN_STEPS`),
  counted by `STEP` as `--max-steps` counts them (`STEP n` counts n). When a
  `STEP` spends the budget, the task goes to the back of the queue. A merged
  `STEP n` that crosses the budget charges all n and yields at the next
  instruction; the excess is not carried over. Crossing `--max-steps` fails the
  task with `RUNTIME-STEP-LIMIT` at the span of 4.2. The scheduler switches only
  at a `STEP`, at a safe point, or right after a builtin or opcode whose turn
  cost spent the budget (Builtins). Every loop passes a `STEP`, and every
  function that calls starts with one (8). A task also leaves its turn when it
  blocks.
- **One counter for both budgets.** `STEP` counts down one "next stop" counter,
  set to `min(turn_left, batch)` when a turn starts and after each sync, where
  the batch is the part of `steps_left` the scheduler holds (Quotas). Turn costs
  never touch it, so the fast path is one compare and one subtraction. The sync
  cannot fail, since the counter is never above the batch, and a turn cost is
  charged once and then cleared. Neither the `STEP` slow path nor the turn-cost
  path reads the cancel or stop flags; the scheduler reads them after each turn
  (`vm/task.c`).
- **Builtins.** No builtin's C code is stopped halfway. A resumable builtin
  (4.3: `map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`) can be
  switched out only between its callbacks, and so can `File.each_line` (a
  stepper, 4.3), which also parks while a read or the close runs. Each block
  call costs one step and the turn cost of the bytes read for that line. Any
  other builtin finishes its turn, so a builtin whose work grows with its input
  charges a **turn cost**: one unit per item (a sort counts n·⌈log2 n⌉) and one
  per 64 bytes it copies or scans. Constant work charges nothing. Some opcodes
  charge the same way: string concatenation, interpolation, `to_s`, `inspect`,
  string equality (the checker allows `==` only on scalars, strings and ranges),
  and map access with String keys. The turn cost comes from the turn only, never
  from `--max-steps` (`steps_left`). The task yields at the next instruction if
  its turn is spent. File builtins charge nothing: their work is I/O, at most 1
  MiB per call.
- **Test switches.** `AGENTICA_VM_TEST_BLOCKING_OUTPUT=1` leaves stdout and
  stderr on the blocking `FILE` fallback (10.2.2), so that path is tested on
  Linux. `AGENTICA_VM_TEST_NO_TURN_COST=1` skips the turn-cost charge. It
  changes only when tasks switch, never output, step counts or diagnostics. It
  is for tests only, so the latency test (`make vm-latency`) can show that it
  fails without the rule. `AGENTICA_VM_TEST_SHARED=1` calls `agc_share`, so a
  run on one scheduler takes every lock (§16.9); it is for tests only.
- **Fairness with I/O.** After each turn the scheduler calls
  `uv_run(UV_RUN_NOWAIT)`, so ready I/O and timers wake their tasks while others
  compute. Tasks woken during a `NOWAIT` go behind the queued ones. With N=1 it
  blocks in `uv_run(UV_RUN_ONCE)` only when its queue is empty. A ready event
  waits at most for the turns queued ahead of it, each about one budget plus the
  last builtin call of that turn. The latency test checks this next to CPU-bound
  tasks. A parked task waits on I/O, a timer, another live task (with a timer,
  for `Task.await` with a timeout), or a channel, with a timer.
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
- **As built (tasks PR).** `vm/task.c` holds the scheduler and the `Task`
  builtins. `vm/interp.c` runs one turn and owns the budget code.
  - `Task.sleep(0)` yields. `Task.sleep(n)` is a timer of the task (§16.9).
    Under `no_files` (the fuzzer) every sleep yields.
  - Stdin EOF is delivered once to every task that waited for the read, so a TTY
    reader never waits for a second Ctrl-D.
  - `Task.await` parks the caller with *retry*: when the target ends, each
    waiter re-runs its builtin and gets the cached result. Stdin reads use the
    same retry (a wake is only a hint, 10.2.3). A task whose bottom frame
    returns, or leaves through `try`, is done.
  - **Await cycles (17b).** A task can receive its own handle over a channel, or
    hide it in a closure, so awaits can form a cycle. Each task waits on at most
    one task (`awaiting`). Before `Task.await` parks, it follows the chain from
    the target through the `awaiting` fields. If the chain reaches the caller,
    the call fails with `RUNTIME-TASK-AWAIT-CYCLE` at the `Task.await` span and
    the caller does not park. A task that awaits its own handle is the shortest
    cycle. The walk is one turn-cost unit for each hop. It stops at a task that
    waits with a timeout (`await_deadline` is set while it waits), since that
    task ends by itself.
  - **Await with a timeout (17c, `docs/future/27-iteration-and-concurrency.md`
    §27.3).** `Task.await(task, timeout_ms)` is a C builtin that returns the
    builtin enum `Await[T]` (`Await.Done(value)` or `Await.TimedOut`);
    `Task.await_result` has the same second arity for a target whose result is a
    `Result`, as the plain pair does. `timeout_ms` of 0 or less is
    `RUNTIME-INVALID-DURATION` at that argument, checked first. The call takes
    the task off the waiter list it may still be in (it was woken by its timer),
    and a target that has settled (done, and not closing files) gives
    `Await.Done` with the outcome of the plain await, also when the timer woke
    the caller at the same time as the target's end. Otherwise the deadline is
    stored in the task (`await_deadline`, computed at the first call from
    `agc_clock_ms`; the timed form runs no cycle check, since it cannot wait
    forever, so a task that awaits its own handle with a timeout gets
    `Await.TimedOut`), the task joins the target's waiters as the plain await
    does, a timer of the task is armed for the deadline (`agc_task_park_until`,
    §16.9 "Timers", as for the lock and channel waits), and the task parks with
    retry. The first of two wakes wins: the target's end (`finish_task` wakes
    the waiters; `resume` disarms the timer) or the timer (the retry leaves the
    target's waiters, clears `awaiting` and the deadline, and returns
    `Await.TimedOut`). A wake before the deadline, with the target unsettled,
    waits again for the time left. A caller that is cancelled while it waits
    leaves through `unlink_task` as any awaiter does: its timer is disarmed, and
    it leaves the target's waiters through `awaiting`; the case
    is in `vm/tests/task_cancel_test.c`. After a timeout the target is
    untouched, and a later crash or cancel of it does not reach the caller. The
    value is built by `vm/task.c` from the program's `Await` enum, found by name
    (`agc_builtin_variant`).
  - When `main` returns, ready and parked tasks never run again, and the exit
    path (End of run) does not wait for their jobs. `System.exit`, a failure in
    `main`, `RUNTIME-STEP-LIMIT` or `RUNTIME-INTERNAL` in any task end the run
    at once.
  - **Crashes (phase 24, [task rules][task-rules]).** Any
    failure in a task other than `main` crashes that task. The text
    `task crashed: CODE at FILE:LINE:COLUMN: MESSAGE` joins the run's unobserved
    crashes. Crashes of `hidden` tasks (the HTTP connection tasks of 20c) join
    only the first per test (or per run outside `Test.run`); the others count as
    `quiet_more`, so the list stays bounded. The diagnostic goes to stderr with
    ` in a task` (`"task":true` in `--json`). The task leaves its jobs, locks
    and FIFOs as a cancelled task does, its running descendants are cancelled,
    and it then ends like any task: the handles it owns are closed (Owners) and
    its awaiters wake. `Task.await` halts with `RUNTIME-TASK-CRASHED` (the crash
    text) or `RUNTIME-TASK-CANCELLED`. `Task.await_result` (used when `R` is a
    `Result`) returns `error(text)` or `error("task: cancelled")`. Either entry
    marks the crash observed. If `main` returns with a crash no await observed,
    the run prints one summary line and exits with code 1.
  - **Owners (phase 24, 24b).** The task that makes a user-visible handle owns
    it: the resource records the owner and its kind's close, and the task keeps
    the list of what it owns (`agc_own`). One path closes them: `finish_task`
    calls `agc_close_owned` for every task that ends, whether it returns,
    crashes or is cancelled. A socket, listener or TLS socket is disowned, a
    process closes with `shut`, which only signals (§10.4 Close), never with the
    release that would kill every child, a file by an `OP_CLOSE` job, and a
    server by `close_server`. The process guard, job resources, stream locks and
    `HttpClient` have no owner. `Task.spawn` moves nothing, and nothing goes to
    the parent when a task ends, so a handle returned by a helper task is closed
    when the helper ends. The one hand-off is `Task.spawn_owning(&f, handle)`
([handle ownership][task-rules]):
    `agc_task_spawn_owning` checks that the calling task owns the handle and
    that it is open (else `RUNTIME-HANDLE-NOT-OWNED` at the handle argument,
    before any task is made), spawns the task and moves the owner to it.
    `HttpWire.spawn` calls it too (10.7.2). A cancelled task's handles are
    closed, also those of a task parked in a stepper (`File.each_line`): its job
    is detached first, and a file that the detached job still holds closes when
    that job ends. A file that is closing gives every caller the closed error. A
    file's close is an `OP_CLOSE` job with no task: while another job holds the
    file, it waits and runs when that job ends, also for a detached job
    (`agc_io_finish` and `end_detached` first pass the lock on, then run the
    pending close, which wakes the waiters to the closed error). The close job
    holds the handle until it ends (the handle is the job's context). For a
    regular file (a pool job) the ending task counts it (`closing` in the task,
    `ender` in the resource): the awaiters of an ended task stay parked until
    those closes have finished (`agc_task_close_done` wakes them), and a
    `Task.await` that comes later parks too, so a parent that awaits a helper
    and then reads what the helper wrote sees all of it. A flush to a FIFO or a
    pipe, a job that waits on the loop for the reader, is not counted: an await
    does not wait for it, and only the flush limit of the end of the run bounds
    it. `File.close` on a handle whose close job is in flight waits for that job
    and returns its result. A close that waits behind any job that holds the
    file (for example another task's read of a FIFO or a pipe, which can wait
    for ever) keeps the descriptor open until that job ends or times out, and
    the awaiters of the ended task do not wait for it. `agc_close_fn` takes the
    ending task, which only the file close uses; `HttpWire.server` takes the
    listener off its owner's list (`agc_disown`), so the server owns it and a
    hand-off of the server moves both. A handle made outside a turn has no
    owner, and is closed when its result is dropped.
  - **Cancellation (20b).** A program cancels tasks only through a crash, which
    cancels the crashed task's descendants, through `HTTP.close_server`, and
    through the deadline of a `Task.map` item (below).
    Each task records its parent and its running children, and a task that ends
    hands its running children to its parent. A group node (20c) never runs and
    has no id: it parents an `HttpServer`'s connection tasks, so cancelling the
    group reaches them. Cancelling a task cancels its running descendants,
    children first. A cancelled task gets its flag, then: a ready task leaves
    the run queue; a parked task detaches from its job (Detached jobs); a task
    waiting for a handle's lock leaves the FIFO, and passes ownership on if it
    was the `next_owner`; a task waiting on a channel leaves its FIFO, has its
    timer disarmed (`unlink_task`), and hands on a reservation it holds (Channel
    waits); a task in `Task.await` or a stdin wait leaves its FIFO. The task
    then ends like a returning task. A later `Task.await` on it halts with
    `RUNTIME-TASK-CANCELLED` (the `Result` entry returns
    `error("task: cancelled")`). A program can reach it, since a task can send
    its child's handle over a channel and then crash. A task that cancels itself
    finishes its builtin and then ends, so no instruction of it runs after that.
    A cancel spends no step and charges one turn unit per cancelled task, to the
    caller.
  - **Task.map (17a, `vm/task_map.c`, core layer).** The builtin checks `limit`
    (1 to 1024, `RUNTIME-INVALID-COUNT` at the argument), then `timeout_ms`
    (above 0, `RUNTIME-INVALID-DURATION`), then the empty list, and otherwise
    installs a stepper on the caller (`agc_task_stepper`, as `File.each_line`
    does), so the caller is one task parked in the call and nothing else waits
    for the group. The group is a GC object: the items, the function, the result
    slots, the counters, the running list (in start order) and the list of items
    that ended. The step function runs on the caller each time it wakes: it
    moves the ended items into their slots (a crashed item is observed and its
    slot is `error("task crashed: ...")`), reads `agc_clock_ms`, expires the
    oldest running item whose deadline has passed (its slot is `error("task:
    timed out")` and `agc_task_cancel` stops it and its descendants), starts
    items up to `limit`, and, when every slot is set, ends with the list.
    Otherwise it arms one timer of the caller for the oldest deadline
    (`agc_task_park_until`) and waits. All items have the same timeout and start
    in input order, so the deadlines grow along the running list and one timer
    is enough. The caller does the spawning and the cancelling, so the random
    streams split in input order and nothing runs on another task's turn. Each
    item is a child of the caller (`agc_task_spawn_seeded`), and starting it
    costs one step (`agc_count_step`); the result list costs one turn unit per
    item. An item tells the group that it ended through a hook on the task
    (`end`, `end_data`), which `finish_task` calls for a return, a crash and a
    cancel. The hook ignores an item that already timed out and an item that was
    cancelled by someone else, which can only be a cancel that reached it
    through its caller: the caller, a stepper parked on the group's timer, is
    cancelled like any parked task (its timer is disarmed), cancels its children
    first, never runs the step function again, and so starts nothing and writes
    no slot. An item that still has a file close pending (`closing`, as
    `Task.await` checks) is not settled: the hook puts itself back and
    `agc_task_close_done` calls it when the last close ends. If the deadline
    comes first, the item is settled as timed out without waiting for the close
    (`expire` marks its crash, if any, as observed), and the hook, when the
    close ends, finds a settled item and does nothing. An item that ends after
    its deadline but before the caller runs keeps its result. The handles an
    item opened are closed when it ends or is cancelled (Owners); an I/O job it
    had in flight is detached and ends on its own. With more than one scheduler
    (not built) the hook runs on the item's scheduler while the step function
    runs on the caller's, so the group needs its small lock (10.2.3, "Task.map
    group lock").
- **Stall check (N=1).** If the queue is empty, no libuv handle is alive, no
  timer of a task is armed (§16.9, "Timers"), and `main` is not done, the VM
  fails with `RUNTIME-INTERNAL` ("every task is waiting and nothing can wake
  them"). No program reaches it: every channel wait and every timed await holds
  a timer, every other wait holds a libuv request or a timer or a live task, and
  plain await cycles halt before they park (`Task.await` below). For N>1 see
  10.2.3.
- **Multi-task runs.** A runaway multi-task run must stop with
  `RUNTIME-STEP-LIMIT` (the black-box rule, §1). The `--max-steps` sweep (§12.1)
  needs each limit to give the full outcome, or the step limit with stdout a
  prefix of the full run. The task fixtures keep that deterministic: their step
  counts do not depend on the clock.

#### 10.2.2 The loop

- **Resource registry** (`vm/loop.c`). Every handle, request and job is a GC
  resource that owns its `malloc` memory and keeps its registry slot until it is
  released. A `FileHandle` points to its resource. A pending request's job holds
  the libuv work and timer. The job stays registered until its work has run, its
  timer is closed, and its result was taken. No GC pointer is stored in `malloc`
  memory, and callbacks find their job with `offsetof`, never through
  `handle->data`.
- **Blocking builtins are two halves.** The C builtin checks its arguments,
  copies what the OS needs into a `malloc`'d request (paths through the rules of
  2.8), and starts the job. One `uv_queue_work` covers the whole operation
  (stat, open, read, close), so the task parks once per call. The call's timeout
  is the job's timer (a negative timeout starts none). `CALL_BUILTIN` ends the
  turn.
- **Waking and parking.** The work and timer callbacks only set flags and put
  the job on the loop's ready list. After each `uv_run` the scheduler drains
  that list and queues the tasks. After each turn it calls
  `uv_run(UV_RUN_NOWAIT)`. With an empty run queue it calls
  `uv_run(UV_RUN_ONCE)`, or fails with `RUNTIME-INTERNAL` when nothing is alive
  (Stall check). On completion the `done` half runs on the interpreter thread
  and builds GC values from the `malloc`'d result. On timeout the `expired` half
  gives the call's timeout error (`filesystem: operation timed out` for a file)
  and, for a handle operation, closes the handle.
- **Thread-pool threads** run only the `work` half, on `malloc` memory.
  `UV_USE_IO_URING` is set to `0` (unless already set) before the loop is made,
  so libuv uses its thread pool and epoll. `SIGINT`, `SIGTERM` and `SIGHUP` are
  blocked around every pool start, and in the `tcp.c` threads, so the stop
  handler, which may run on any thread, touches only
  lock-free atomics and async-signal-safe calls.
- **Pool size.** The VM never sets it. libuv's `UV_THREADPOOL_SIZE` does (there
  is no `AGENTICA_*` variable). It is read once, when the pool is created, so it
  must be set before the VM starts. The default is 4, and the cap 1024. The pool
  runs regular-file I/O, opens and path calls, DNS (`getaddrinfo`), and the TLS
  setup jobs. Blocking stdin is the exception: a failed Unix poller setup can
  keep one pool thread until input arrives (Stdin below). Windows stdin never
  uses the pool. All other work must finish without waiting indefinitely for
  input.
- **We only wait where the loop can cancel** (§14.1). Files open with
  `O_CLOEXEC` and `O_NONBLOCK`, so opening a FIFO never waits for a peer. The
  pool job then picks the path by `fstat` and an `epoll_ctl` probe, never by
  name. A regular file, a block device, or a device epoll refuses with `EPERM`
  (`/dev/null`, `/dev/zero`) is blocking, in the pool. Any other probe error is
  the call's error, never a fall back to blocking. A pipe, FIFO, terminal or
  other waiting character device is non-blocking on the loop through a poller
  (`uv_poll_t`). A handle call first tries its step on the loop thread. When it
  would wait, it parks on an `external` job, and the poller's callback repeats
  the step. A whole-file call opens in the pool, and if the path is pollable,
  its `more` step keeps the same job and task waiting on the loop. A pool kind
  with a `cancel` half must have a `more` step, and `start_job` checks it. A
  poller error is reported by repeating the step, so the call gets the real
  error (`EPIPE` for a reader that left). `read_text` of a pipe, or of a regular
  file that reports size 0 (`/proc`, `/sys`), reads to EOF, at most 1 MiB.
  `File.each_line` (row 7.2.1h) reads with the same rule: one job per read,
  never the whole file. It opens with the read open, then each read is one job
  of at most `buffer_bytes` bytes into a buffer made once, so a regular file
  takes one pool job per read and a pollable path one poller read, each with its
  own `timeout_ms`; a timed-out read closes the handle. Between reads the task
  runs the block for every complete line already in the buffer, so a file of
  short lines costs about one job per `buffer_bytes`. The close is a job too,
  and the task parks for it. A crash of the reader's task or of one of its
  ancestors closes the handle (`agc_own`, `agc_close_owned`). A cancel without a
  crash (a `Test.run` leftover, a `Task.map` timeout) closes it too (24b: the
  close covers every end of a task, a task parked in a stepper included).
  On Windows no `File` call waits on the loop: `probe` refuses a named pipe or
  a device with `ENOTSUP` and the call closes it (§14.1; see #474).
- **End of run: one exit path.** However the run ends (`main` returns,
  `System.exit`, a runtime error, the step limit, a stop signal),
  `agc_launch_settle` in `vm/launch.c` takes the same steps and nothing else
  (§14.4):
  1. kill the children and drive the loop until libuv's exit callbacks have
     reaped them (10.4, Close; at most about 2 seconds);
  2. one non-blocking TLS `close_notify` on each TLS session that finished its
     handshake: TCP sockets (10.3) and `HttpClient` connections (10.7.1);
  3. flush the blocking stdout and stderr (`fflush`, retried on `EINTR`), then
     queue the diagnostic of a failed run on stderr (a kept notice, 10.2.2), so
     that the wait below covers it; close every open file, and wait for their
     flush jobs and for the output buffers of stdout and stderr to drain
     (10.2.2). The limit covers this buffered output and the diagnostic too. The
     wait is always bounded: 30 seconds by default, or `--flush-timeout MS`, or
     the environment variable `AGENTICA_FLUSH_TIMEOUT_MS` (the flag wins; there
     is no way to turn the limit off), so a FIFO whose reader stopped cannot
     keep the run open for ever. When it runs out, the VM prints
     `agentica: file data may not be written: the flush took longer than MS ms`
     (or `{"flush_timeout_ms":MS,"warning":...}` with `--json`); the exit code
     does not change;
  4. print what is only known now without blocking (the flush-timeout warning,
     the `RUNTIME-INTERNAL` diagnostic for a stdout or stderr write error), and
     end with `_exit`, so libuv's destructor never joins the pool. These go
     through `agc_notice_end` (10.2.2) as final notices: they are written with
     non-blocking writes and what a full stderr pipe will not take is dropped,
     so a stuck stderr pipe cannot hold the exit. No task is awaited, no other
     pool job is waited for, and no socket is read to its end. Killing the
     children first means data buffered for a FIFO's reader is lost. A file
     close that fails at this point prints
     `agentica: file data may not be written: the flush failed (CODE: message)`
     (or `{"flush_failed":"CODE","warning":...}`); the exit code does not
     change. `agc_io_close`, which closes every resource and frees the loop, is
     only for the in-process harnesses.
- **Stop signals.** One `sigaction` handler covers `SIGINT`, `SIGTERM` and
  `SIGHUP`, except a signal the VM started ignored (`nohup`). Its state is one
  process-wide variable (`stop` in `vm/loop.c`, lock-free atomics). The first
  signal is stored and wakes the loop. The scheduler checks it after every turn,
  before it waits and before it reports a stall, and the run ends as an exit
  with code 128 + signal. `end_run` runs the steps above, then raises the signal
  again with its default action. A second signal ends the VM at once, but never
  before the children are stopped: until then it is only recorded. A 3-second
  `alarm` (`STOP_GRACE_SECONDS`) backs this up. A driven VM (`--driver-pid`)
  whose driver is gone treats even the first signal as a second one. The handler
  has no `SA_RESTART`, so a blocking write (a fallback stream of §14.1) that
  nobody reads returns `EINTR`, and the run ends as the stop (128 + signal, no
  diagnostic); that write is not retried. A stream on the loop has no blocked
  write: once a stop signal is set, the wait for stdout and stderr in step 3
  tries one non-blocking write per stream and ends at once, so a stuck reader
  cannot hold the exit for the flush limit (10.2.2). A CPU-bound task delays the
  stop by at most one turn.
- **Per-handle lock (tasks PR).** A `FileHandle` has a `holder` (the job in
  flight), a `next_owner` task, and a FIFO of waiting tasks, all in GC memory.
  Every handle builtin (`read_bytes`, `read_line`, `write`, `write_bytes`,
  `flush`, `close`) checks its arguments and timeout first, then takes the lock,
  and only then checks that the handle is open and has the right mode. A task
  that cannot take the lock parks with retry on a timer of the task at
  its deadline. One deadline covers the lock wait and the operation: a task that
  gets the lock after its deadline returns the timeout error. Release is a FIFO
  hand-off: the head waiter becomes `next_owner` and is the only one woken, so
  the releasing task cannot take the handle back in the same turn. A cancelled
  `next_owner` passes ownership on, so a lock never stays with a task that will
  not run. So `close` waits for the operation in flight, two readers take turns,
  and buffered writes keep their order. On an operation timeout the stuck
  operation keeps the state, the handle is closed, and the next owner gets
  `file handle is closed`. A closing handle that a job still holds, its close
  job or the read that the close waits behind, makes callers wait for the lock
  as for any other handle; once no job holds it they get the closed error.
- **Channel waits (17b, `vm/channel.c`).** A channel is a GC object: a ring
  buffer, the capacity, a closed flag, and two FIFOs of waiting tasks (receivers
  and senders) linked through `wait_next`, as the handle lock's FIFO is. The
  ring starts with at most 8 slots and doubles up to the capacity, so
  `Channel.new(1048576)` does not allocate a million slots. The copy of a
  growing ring charges one turn-cost unit per slot copied; other calls charge
  nothing, and a value is one pointer, never copied. A call that must wait parks
  with retry on a timer of the task that ends at the call's deadline
  (`agc_task_park_until`, `vm/timers.c`; no job, so the I/O trace has no line
  for it and the `sched` trace has `timer_arm` and `timer_fire`). The deadline
  is set at the first wait and kept across retries in the task
  (`channel.deadline`), as `agc_handle_wait` does. A timeout of 0 never parks:
  it tries once.
  - **Reservations.** A value that arrives while receivers wait is not put in
    the ring. The head receiver is popped from its FIFO, the value is stored in
    the task (`channel.value`), and the task is woken: a direct hand-off, so no
    other `recv` can take it first. A slot freed by a `recv` while senders wait
    is reserved for the head sender the same way, and so is a slot freed when a
    woken sender hands its value straight to a waiting receiver. Each accepted
    value gets a send sequence number, kept in its ring slot and in the
    reservation. Counters in the channel (`reserved_values`, `reserved_slots`)
    keep `closed?` and the free space exact. A woken waiter re-runs its builtin:
    with its reservation set it returns the value (or adds its own), even if its
    deadline passed, since the reservation came first.
  - **A waiter that leaves.** A waiter woken with a reservation was already
    popped from its FIFO and does not search it again. A timer that fires wakes
    its task and leaves it in the FIFO, and the task leaves it when it runs. The
    next pop skips a task that is no longer parked, so a reservation never goes
    to a waiter whose timeout came first. A cancelled waiter
    (`agc_channel_leave`, called from the task's unlink) leaves its FIFO and
    hands its reservation on: a value goes to the next waiting receiver, or back
    to the head of the ring, inserted by its sequence number so values that went
    back stay in send order. The ring may then hold more than the capacity, only
    by values handed back, at most one per task that held a reservation; senders
    still wait while `count + reserved slots >= capacity`, the extra values
    drain as receivers take them, and no value is lost. A slot goes to the next
    waiting sender, or becomes free.
  - **Close.** `close` marks the channel, revokes the reserved send slots (their
    `send` returns the closed error and the value is not added), and wakes all
    senders. Receivers keep getting the values left. A `recv` on a closed
    channel with an empty ring but a value still reserved for a woken receiver
    waits, and the receiver that takes the last reservation wakes the others,
    which then get the closed error. `closed?` is true when the channel is
    closed, the ring is empty and no value is reserved, and stays true.
  - **An owner.** A channel can have an owner task: `Task.spawn_owning` gives
    it to the task it spawns (`agc_channel_claim`, which registers an entry
    with no native object the first time). When the owner ends in any way,
    `finish_task` runs `agc_close_owned`, which calls the same close, so the
    waiters wake as above. `close` from any task drops the entry first, so the
    owner's end then does nothing. A channel never handed over has no entry
    (§14.5 of `docs/vm/14-core-invariants.md`).
  - **Choices.** Mid-FIFO removal is O(n), as for the lock FIFO. A waiter whose
    timer fired before any wake still takes a value that reached the ring before
    it re-ran, instead of failing at once.
- **Detached jobs (20b).** When its task is cancelled, a job is detached: it has
  no task, it is never abandoned with a close, and it runs to its own end or
  deadline, keeping the handle's lock until then. Its `done` half runs and the
  result is dropped, not charged to the current task. Its lock passes to the
  head waiter, as at a release. A handle the dropped result would have handed
  out is closed then. The `expired` half never runs on a detached job, so it
  never closes a handle a task holds. A kind may set a `cancel` half, which ends
  the job early and returns true; no pool kind may have one, since a pool thread
  may still use the data. The waits of `HttpWire.accept` and `HttpWire.wait` use
  it to leave at once. For the TCP and process kinds at the deadline, a read,
  accept or wait leaves its handle without the `expired` half that would close
  it, a connect closes the socket it was opening, and a send waits for its write
  callback. A listen has no deadline. A pool job (files, stdin) cannot be
  stopped, so it ends when its work ends.
- **External jobs.** A kind with `external` set has no `work` half. A libuv
  callback on the loop thread completes it, which puts the job on the ready
  list. A second call does nothing.
- **Fuzzing.** `agc_fuzz_one` sets `vm->no_files`: a file builtin (also
  `Path.cwd`, `Path.resolve` and `Path.real`) ends the run with
  `RUNTIME-INTERNAL`, and `Process.spawn` returns its error. Every loop and
  resource is released before the mutant ends.
- **Stdin.** Stdin follows the same rule as files. A pipe, FIFO or terminal is
  reopened through `/proc/self/fd/N` (N is 0) with `O_NONBLOCK`, so the
  inherited open file description, which a shell's terminal shares, keeps its
  flags. It is then read on the loop. A socket keeps its flags and is read with
  `MSG_DONTWAIT`. A regular file, a device epoll refuses, a write-only stdin, a
  failed reopen (no `/proc`, or `EACCES` after `su` or `sudo -u`), or a failed
  poller stays a pool job with one blocking `read`, which keeps a pool thread
  until data comes (§14.1). One read of up to 1 MiB is in flight at a time. A
  second reader parks in the input's FIFO. A read with no data at the end of the
  run is not waited for. On Windows, every stdin kind (a pipe, the console, a
  file, `NUL`) is read by one thread of the VM's own (`vm/stdio_windows.c`),
  never by the pool: it waits until a read is asked for, does one blocking
  `_read` in binary mode, and wakes the loop with an async handle, which ends
  the read's `external` job. The handle keeps the loop alive only while a read
  is out. The thread and its handle are made on the I/O thread at the first
  read, after the job's start. A cancelled reader leaves the read in flight, as
  on Unix: its bytes or EOF go to the next reader. Stop signals are handled by
  libuv on the loop, independently of the reader. At the end of the run the
  read is cancelled where Windows can (`CancelSynchronousIo`, a pipe); a read
  that cannot be cancelled ends with the process, or, in an in-process harness,
  when input comes, and then touches nothing of the closed loop.
  Other unsupported hosts keep a blocking read on the interpreter thread.
- **stdout and stderr (row 7.2.1f, `vm/output.c`).** Each stream has one output
  buffer, a `malloc`'d ring of 64 KiB (`AGC_OUTPUT_BUFFER`), and one FIFO of
  waiting writers. `puts`, `print`, `IO.inspect` and `IO.warn` copy their whole
  text into the buffer and return at once when it fits and no writer is waiting.
  Otherwise the task keeps a pointer to the text string in its `output` slot
  (`agc_output_wait`; task memory is scanned by the GC, and a big print is not
  copied a second time), parks in the stream's FIFO, and a later writer does not
  jump the queue. The parking pattern is the one of §27.2: the head waiter is
  woken when its whole text fits, and the retry of the builtin finds its slot
  and ignores its arguments. `agc_output_waiting` tells a builtin to take that
  path, so the builtins do not know the retry protocol. A print of just a
  newline is a `newline` flag with no text. A print longer than the buffer waits
  until the buffer is empty, then holds the stream and copies in pieces as the
  writer drains, until all of it is copied, so prints never interleave on one
  stream, and nothing else the VM writes is put in the middle of one print. A
  print has no `timeout_ms`: it waits until the reader takes data. That is not a
  stall, since the stream's writer is alive on the loop (§10.2.1). A cancelled
  waiter leaves the FIFO (`agc_output_leave`, from `unlink_task`, §14.3), which
  hands on to the next writer and starts the writer if a notice moved into the
  buffer (`advance` always ends with `kick`), and text already copied is written
  whole: a print that fits is copied at once, so a waiter that has copied
  nothing leaves nothing partial; only a long print cancelled in the middle
  leaves the pieces it has copied. `IO.flush` writes what it can at once and,
  when the buffer is not empty, waits in the FIFO as a writer that needs an
  empty buffer, so it returns when the data reached the pipe or file. It fails
  when the stream failed (a reader that left). The loop thread is the only
  writer of a loop stream. **How a stream is written.** `agc_output_open`
  (called in `main` after `agc_input_open`) picks the way. A pipe, FIFO or
  terminal is reopened through `/proc/self/fd/1` or `/proc/self/fd/2`
  (`agc_fd_reopen`, shared with `vm/input.c`) with `O_WRONLY | O_NONBLOCK`, so
  `O_NONBLOCK` is set only on the VM's own open file description, never on the
  one the shell and child processes share. A socket is duplicated with
  `F_DUPFD_CLOEXEC` and written with `send(MSG_DONTWAIT | MSG_NOSIGNAL)`, as
  stdin reads it. Both are written when the poller says the descriptor is
  writable. On macOS each write is first guarded by `poll(POLLOUT)` and cut to
  `PIPE_BUF` (a socket: `SO_SNDLOWAT`, read once), so that it cannot block: the
  description is shared with the program that started the VM and stays blocking,
  and `send(MSG_DONTWAIT)` alone stalled the loop on such a socket. The poller
  runs one `external` detached job per writable event, and the request holds the
  stream's index, not a pointer into the runtime, so no GC pointer is kept in
  `malloc` memory. A regular file or a block device is drained by a pool job, as
  files are (§14.1), on the descriptor the process was given (a reopen would
  reset the file offset and `O_APPEND`); a device epoll refuses with `EPERM`
  (`/dev/null`, `/dev/full`) takes the same path. One job runs at a time.
  **Windows.** `vm/stdio_windows.c` (the Linux and macOS side is
  `vm/stdio_posix.c`, and `vm/output.c` has no OS branch) sorts the descriptor
  with `uv_guess_handle` into one of four write modes (`agc_write_mode`). A
  file, or `NUL`, is drained by a pool job on `_write`. A pipe is written by a
  libuv pipe handle, one write request at a time (libuv writes a pipe that is
  not overlapped on a Windows worker thread and an overlapped one with I/O
  completion ports). A console is written by a pool job that converts UTF-8 to
  UTF-16 and calls `WriteConsoleW` (a character cut by the end of one write
  waits for the next), not by `uv_tty_t`: libuv writes a console on the loop
  thread, where a console that is paused (a selection, Ctrl+S) would stop every
  task and the stop signals, and `uv_tty_init` changes the console mode for
  good. A handle that libuv refuses (a socket, a pipe nobody can write to) is
  also written by a pool job, which holds one pool thread while the reader is
  slow. Stdout and stderr in this mode hold one thread each, so with the default
  pool of 4 a stuck stdout and stderr leave 2 threads for files, DNS and
  processes. The loop never writes a pipe, a console or a refused handle.
  Windows resets a socket whose last handle closes with the process, and its
  reader loses what it has not read. So just before the exit, a socket given as
  stdout or stderr gets `shutdown(SD_SEND)` (`agc_output_end`), which does not
  wait for the reader, when no write of it is in flight, when this process's
  stdin, stdout and stderr hold every handle to it, and, if it is also stdin,
  when no read of stdin is in flight. Windows 10 before 1607 has no
  `CompareObjectHandles`, so there a socket given as two standard streams is not
  shut down. A socket that is not overlapped serializes its I/O: when it is both
  stdin and stdout, a blocked read of stdin stalls the writes of stdout, and
  that output is lost after `--flush-timeout`. The pipe's handle is a private,
  non-inheritable copy of the descriptor, so closing it leaves stdout open, and
  closing it cancels the request in flight. A request takes the ranges of the
  ring as they are and ends all or nothing, so the ring is consumed when the
  request ends. Neither a pipe request nor a pool job has a non-blocking try:
  where Unix makes one non-blocking write (a stop signal, a final notice),
  Windows starts the request and waits for it, in one wait of up to 200 ms that
  the stop and the final notices of the exit share (`settle`).
  The normal end of the run does not use that wait: it is bounded by the flush
  limit. The jobs do not set `flush`, since `agc_output_busy` counts the
  buffered bytes (End of run, below). The trace shows a pool write as
  `kind=output` jobs, and a poller stream as one `output_start stream=...` and
  `output_done` line per run of data (the per-event jobs are quiet,
  `AGC_JOB_QUIET`). `agc_io_close`, used only by in-process harnesses, does not
  free the buffer of a stream whose pool write is still in flight; a real exit
  ends with `_exit`. The reopened descriptor is the VM's own: a `File` path that
  is an entry of `/proc/self/fd` (`/proc/self/fd/N`, `/dev/fd/N`, compared by
  directory device and inode, so extra slashes and symlinked directories do not
  matter) with the number of that descriptor is refused with the
  not-a-regular-file error (`names_output_fd` in `vm/files.c`, before the open).
  The guard is by the directory's device and inode, and it covers
  `/proc/self/fd` and `/proc/thread-self/fd` only, not the
  `/proc/<pid>/task/<tid>/fd` directories (they reach the same pipe as
  `/dev/stdout` does). `/dev/stdout`, `/dev/stderr` and `/proc/self/fd/1` and
  `/proc/self/fd/2` still open, as the pipes the VM got at start do (§2.8). A
  write error (`EPIPE`, `EIO`, `ENOSPC`) is final for the stream: the buffered
  data and the queued notices are dropped, the waiters wake, and the print that
  notices it fails with `RUNTIME-INTERNAL` (`cannot write to standard output` or
  `standard error`). `end_run` folds a failed stream into the exit code (1),
  also when no print saw the error; the message goes to stderr when stderr still
  works. These cases keep the blocking `fwrite` of the `FILE`, listed with the
  other fallbacks of §14.1: a reopen or a `dup` that fails (no `/proc`,
  `EACCES`), a descriptor that is not open for writing (a closed stdout that
  `main` filled with `/dev/null`), another descriptor type, and every build that
  is not Linux, macOS or Windows. The records of `agentica test` do not go
  through this module: they travel on the child channel (§10.4), and `Test.run`
  only flushes stdout before it sends one. **One target, one buffer.** When
  stdout and stderr are the same file (the same `st_dev` and `st_ino` from
  `fstat`: a terminal, `2>&1`, both to one file; on Windows
  `CompareObjectHandles` asks whether the two descriptors are one kernel object,
  since `fstat` gives a pipe no device and inode, so two separate opens of one
  file are two targets there), stderr shares the buffer and the FIFO of stdout
  (`err.base`). So `puts a`, `IO.warn b`, `puts c` appear in the order of the
  calls. When they are different files there is no order between the two
  streams. **Notices.** Text the VM itself writes to stderr goes through
  `agc_notice_begin` and `agc_notice_end`: a memory stream, written whole (on
  Windows, which has no `open_memstream`, a thread collects what is written to a
  pipe). A task crash diagnostic and the unobserved-task summary are non-final.
  The text joins a `malloc`'d queue (at most 1 MiB; a notice that arrives when
  the queue already holds that much is dropped, so a stuck stderr cannot make
  the VM grow). It moves into the buffer ahead of the waiting writers as room
  appears, in pieces if it is longer than the buffer, but never between the
  pieces of a long print that holds the stream. So a diagnostic is not lost
  because the buffer was full, and it never splits a print. The driver
  diagnostic of a failed run is also queued like this (as a kept notice, which
  the 1 MiB limit never drops), after the blocking streams are flushed and
  before the end-of-run wait, so the wait of step 3 and the flush limit cover
  it: a diagnostic longer than the pipe and the buffer reaches a reader that is
  slow but alive. The flush warnings, and the `RUNTIME-INTERNAL` diagnostic for
  a write error that is only known after the flush, are final: `end_run` prints
  them with non-blocking writes until all of the text is written or the pipe
  would block (on Windows the writes share one wait of up to 200 ms for their
  requests). What a stuck pipe will not take is dropped (the exit code still
  reports the result), so a stuck stderr cannot hold the exit; a stop signal
  drops what is still queued. The flush-timeout warning is known only at the
  deadline, so it comes after the diagnostic. If a pool job is still writing the
  stream when the flush limit ran out, a final notice is skipped, since a second
  write on the same descriptor could block. **End of run and stop.** At the end
  of the run, stdout and stderr drain as part of the file flush, within the
  flush limit (§14.4). No task runs any more then, so a print that was cut (a
  head waiting for room, with `holds` set) is abandoned with the pieces it
  copied: `agc_output_busy` moves the queued notices into the buffer with force,
  after the pieces it already copied, and starts the writer again for each
  stream that is not writing, so the wait ends when the data is written and not
  at the flush limit. When a stop signal is set, `agc_output_busy` does one
  non-blocking write per stream (when no pool job is writing it; on Windows a
  request or a pool thread writes, and the exit waits for it within the shared
  200 ms) and then stops waiting for stdout and stderr, so a reader that never
  reads cannot hold a stopped VM for the flush limit; files keep their wait.
  `end_run` flushes the blocking `stdout` and `stderr` first and only then
  queues the diagnostic, so on blocking streams the diagnostic also comes after
  the program's output (`AGENTICA_VM_TEST_BLOCKING_OUTPUT=1` forces those
  streams, for tests). The diagnostic is a kept notice: it is queued even when
  the notice queue already holds its 1 MiB (`AGC_NOTICE_KEPT`), and it is queued
  inside a `setjmp` of `vm->fail`, so a failure in the writer's start
  (`agc_fail`) is caught; the text is already in the queue by then, and the
  end-of-run wait or a later final notice writes it. **A child's stderr.**
  `vm/process.c` hands each chunk of a plain child's stderr to
  `agc_output_forward` on the I/O thread: the bytes join the notice queue (so
  they keep their order with `IO.warn` and never enter a print that holds the
  stream) and the write starts. When more than 64 KiB wait in the queue the
  child's pipe is no longer read (`uv_read_stop`) until the queue is down to 32
  KiB, so a stuck stderr stops the child, not the loop; the end of the run
  flushes what was queued like any notice. A failed stderr drops these bytes,
  and fails the run only when text of the program or the VM was lost with them
  (still in the buffer, or written after the failure). A write error on
  stdout keeps today's exit-code rule (`agc_launch_settle` in `vm/launch.c`). No
  language change: the builtins keep their names, types and results, and a full
  stdout pipe stalls only the tasks that print.
  - **Tests** (VM only, hermetic, Python stdlib peers).
    `tests/test_vm_stdout.py` with `tests/fixtures/stdout-peer.py` (a pipe, a
    socket pair or a pty as stdout, a separate or merged stderr, a delay before
    the reader starts): a pipe that nobody reads for a while, while a timer task
    keeps running, and the run ends once the reader drains; two tasks that print
    long lines into a slow pipe, with no interleaving and each in order; a print
    longer than the buffer next to short prints; the end of run drains within
    the flush limit, and with a reader that never reads, the run ends after
    `--flush-timeout` with the existing warning, also when stderr is the same
    stuck pipe (and then no warning is mixed into the data); a socket as stdout
    not read yet while a timer task keeps running; a socket as stdout, stderr,
    both, or stdin and stdout (with stdin read or not), read only after the
    exit, that still gets every row; a socket that is full at the end, and a
    read of a socket stdin in flight at the end, neither of which holds the exit
    past the flush limit; `puts` and `IO.warn` on
    one pipe and on one pty keep the order of the calls under a slow reader;
    `IO.flush` returns only after the reader started; a task crash diagnostic
    that arrives while stderr is full arrives whole when the reader reads later;
    a `Result.unwrap!` error text longer than 128 KiB reaches a stderr file
    whole; a print cut by the end of the run that does not hold a queued notice
    or the exit; a diagnostic longer than the buffer that reaches a slow stderr
    pipe whole; `File` calls on `/dev/stdout` and `/dev/stderr` that still work
    when they are pipes; a regular file written by the pool while a child is
    stopped at the end of the run (the flush wait first runs the `done` halves
    of jobs that finished during the child stop, `drain` in `finish_flushes`); a
    reader that went away (`RUNTIME-INTERNAL`, exit 1); a crashed parent whose
    waiting child leaves the FIFO with nothing partial written.
    `tests/test_vm_stop.py`: a stop signal with a stdout nobody reads ends the
    run long before the flush limit. `vm/tests/output_test.c`: the buffer and
    the FIFO without the interpreter (order, wrap, `IO.flush`, a head that
    leaves, a leaving long print that lets a queued notice and the next writer
    through, a reader that left, a file drained by the pool, `/dev/null`, a
    read-only descriptor, one buffer for one target, notices that wait for room,
    a notice that does not enter a long print, the end of run moving a notice
    held by a cut print, a record that starts a line after a cut print, final
    notices). The waiter case of `agc_task_cancel` is in
    `vm/tests/task_cancel_test.c` (§14.3).

[task-rules]: ../grammar/06c-tasks-and-tests.md#lightweight-tasks
