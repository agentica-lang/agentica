### 10.2 Rules for 7h

- The design target is multicore: N scheduler threads (M:N, as in BEAM,
  10.2.3), each running the interpreter and its own libuv loop. The first
  tasks PR of 7h runs N=1, but on the structures built for N schedulers.
  N>1 is built only if a measured server needs it (roadmap order). Tasks are
  VM stacks. A blocking builtin starts a libuv request, parks its task, and
  the scheduler runs another ready task (10.2.1). Only the scheduler that
  owns a loop calls `uv_run` on it. libuv and OpenSSL callbacks only copy
  results and mark tasks ready.
- Racket threads are preemptive, so the scheduler also switches tasks that do
  not block, by reductions (10.2.1). Cross-task output order is not compared.
- Builtins that take a function (`Task.spawn`, `HTTP.listen` and
  `HTTP.listen_tls` handlers, `HTTP.request_stream`'s producer, `BDD.step`)
  run it as a new VM task; the ones that need its result await it.
- Stdin may be a TTY, pipe or file: `uv_guess_handle` picks the reader, and a
  file (`UV_FILE`) uses a `uv_fs_read` path. Stdout and stderr stay on
  blocking stdio.
- Files open with `O_NONBLOCK`, then `fstat` checks the kind. The libuv thread
  pool keeps its default size (4, `UV_THREADPOOL_SIZE`); this is documented.
- Thread-pool threads never touch GC memory. Requests and handles are
  `malloc`'d, and `uv_fs` buffers are `malloc`'d copies. The GC object that owns a handle sits in the owning scheduler's resource
  registry (a GC object, like the registries in `src/process.rkt` and
  `src/filesystem.rkt`) until its `uv_close` callback; only then does it leave.
  `uv_write` and `uv_fs` buffers stay reachable from the registry until their
  callback. `handle->data` and `SSL_set_app_data` point to GC objects only
  while registered. `CRYPTO_set_mem_functions` is never routed to the GC.
- All VM file descriptors and handles are created non-inheritable
  (`O_CLOEXEC`, no handle inheritance on Windows).

#### 10.2.1 Scheduler

- **libuv does I/O only.** It gives readiness, timers, processes, DNS, and
  the thread pool for file I/O, which epoll cannot poll. It never decides
  which task runs; the scheduler is ours. Raw epoll or io_uring would make us
  rewrite the file thread pool, processes, signals and DNS ourselves, on each
  platform.
- **Run queue.** Each scheduler has its own FIFO run queue of ready tasks. A
  new task, a task whose turn ended, and a task woken by a libuv callback
  all go to the back of their scheduler's queue. With N>1, an idle scheduler
  steals ready tasks from other queues (10.2.3).
- **Reductions, as in BEAM.** Each turn has a budget of steps, counted by
  `STEP` like `--max-steps` (`STEP n` counts n). It starts at 2000 and is
  tuned by measurement in 7h; 7g gives the cost of `STEP` with one task. When
  a `STEP` spends the turn's budget, the task goes to the back of the run
  queue and the next one runs. A merged `STEP n` that crosses the turn
  budget charges all n, then yields at the next instruction; the extra is not
  carried over to the next turn. If it crosses `--max-steps`, the task fails
  at the span of 4.2 instead (see "One counter for both budgets"). To the
  program the scheduler is preemptive; inside the VM it switches only at a
  `STEP`, a safe point, or right after a builtin or opcode whose turn cost
  spent the turn (see "Builtins"; the next instruction is a safe point
  too). Every loop passes a `STEP`: backward jumps land on one, and every
  function that calls starts with one (8), so a `TAIL_CALL` loop passes it
  too. A task also leaves its turn when it blocks.
- **Builtins.** No builtin's C code is stopped halfway. A resumable builtin
  (4.3: `map`, `filter`, `reduce`, `each`, `any?`, `all?`, `sort_by`) can be
  switched out only between its callbacks. Any other builtin finishes in its
  turn: `List.sort` on a big list, `String.join` of many parts,
  `JSON.encode` of a big value, or the sort inside `sort_by` after its keys
  are collected, runs to the end without a switch. `STEP` alone would then
  be the only fairness signal, and one task could hold the scheduler long
  past its turn. So a builtin whose work grows with its input charges a
  **turn cost** for that work: about one unit per item it handles (list
  items, map entries, JSON nodes; a sort counts n·⌈log2 n⌉ comparisons) and
  one per 64 bytes of text it copies or scans. The units are tuned with the
  turn budget in 7h; a builtin with constant work charges nothing. The turn
  cost is taken from the turn only, never from `--max-steps`
  (`steps_left`), so it never changes when `--max-steps` stops a program. When the builtin has
  returned and its result is stored, the task yields at the next
  instruction if its turn is spent (see "One counter for both budgets").
  This does not cut a long builtin in half: it bounds what runs after it.
  A resumable builtin charges one turn unit per callback call the same way
  and may yield between two callbacks, so a callback short enough to skip
  its leading `STEP` (8), which charges no step, no longer runs a whole
  list in one turn. The counting builtins (`Range.each`, `Int.times`,
  `upto`, `downto`) have no list to bound them, so each callback call
  charges one step through the same check as `STEP` and is a switch point.
  Some opcodes also do work that grows with their operands, outside
  `CALL_BUILTIN`: `CONCAT` copies both strings, `TO_TEXT` and `INSPECT`
  build the text of a whole value (interpolation, `to_s`, `inspect`,
  `puts` of a big list), and `EQ`, `NE` and `SAME` compare whole strings
  (`==` on big strings, String literal patterns in `case`; the checker
  allows `==` only on scalars, strings and ranges). `MAP_GET`, and `MAP`
  for each entry, hash a String key whole (SipHash, `vm/map.c`) and
  compare it with the keys they meet (`key_equal`). They leave a turn cost
  in the same per-task field, with the same units (one per 64 bytes
  copied, built, hashed or compared), and it is applied after the
  instruction through the same path (below). The other opcodes do
  constant work, or work bounded by their operand count (`LIST`,
  `STRUCT`, `CLOSURE`, at most 255 items), and charge nothing.
- **One counter for both budgets.** `STEP` counts down one "next stop"
  counter. It is set to `min(turn_left, steps_left)` when a turn starts and
  after each sync (below), and the value it was set to is kept. The fast
  path runs while `counter > n` for `STEP n`: one compare and one
  subtraction. Turn costs never touch the counter, so the fast path stays
  that. Otherwise the slow path first syncs: it takes the steps spent since
  the counter was set (the kept value minus the counter) out of both
  `turn_left` and `steps_left`. Then, if `steps_left < n`, the task fails
  with `RUNTIME-STEP-LIMIT` at span `s + steps_left` (4.2), and nothing more
  is charged. If not, all n is charged to both budgets, and the task yields
  if `turn_left <= 0`; it resumes at the next instruction. Otherwise the
  counter is set again.
  A turn cost of c units is applied by `CALL_BUILTIN` after the builtin
  returns, by a native frame between two callbacks, and by the opcodes of
  "Builtins" after their work, and only when c > 0. The builtin or opcode
  leaves c in a per-task field that is 0 by default; the apply path reads
  it and sets it back to 0 before it charges, so a cost is charged once. A
  builtin or opcode that fails through `agc_fail` (`longjmp`) never reaches
  the apply path: the run ends (6.2), and a field left non-zero is dropped,
  since the field is also cleared when a turn starts. A constant builtin
  pays one compare on the builtin path and nothing on `STEP`. The apply
  path syncs as above, then takes c from `turn_left` only. If
  `turn_left <= 0`, the task yields at the next instruction, with the
  result already in its register; otherwise the counter is set again to
  `min(turn_left, steps_left)`. The sync cannot fail: the counter is never
  above `steps_left`, so the steps spent fit in it.
  `steps_left` never sees c. Like the extra of a merged `STEP n`, a turn
  cost past the end of the turn is not carried over to the next turn. The
  other way, setting the counter to 0 so that the next `STEP` takes the
  slow path, was not chosen: the slow path would have to tell that forced
  stop from a real one and keep the steps spent somewhere else, and the
  task would yield only at the next `STEP`, not right after the builtin.
  So that the 7h latency test can show it fails without the rule, a test
  environment variable, `AGENTICA_VM_TEST_NO_TURN_COST=1`, read once at
  start-up into the runtime config, makes the apply path skip the charge.
  It changes only when tasks switch, never output, step counts or
  diagnostics, so every build honors it and the latency test uses the
  normal `make vm` binary. It is for tests only, not documented for users,
  and may be removed after 7i.
  With N schedulers, `steps_left` in this bullet is the scheduler's batch
  (Quotas): the sync takes spent steps out of the batch, not the atomic
  counter, and a turn cost touches neither. The turn-cost path checks the
  cancel and stop flags as the `STEP` slow path does (10.2.3).
- **Fairness with I/O.** After each turn (or every N turns, if measurement
  asks for it) the scheduler calls `uv_run(UV_RUN_NOWAIT)`, so ready I/O wakes
  its tasks even while other tasks keep computing. Timers (`Task.sleep`) wake
  the same way, inside `uv_run`. Tasks woken during a `NOWAIT` go behind the
  tasks already queued. The scheduler blocks in `uv_run(UV_RUN_ONCE)` only
  when its run queue is empty and, with N>1, it found nothing to steal.
  Without channels, a parked task waits on I/O, a timer, or another live
  task, so either some loop has an active handle or some queue is not empty.
  If every scheduler is idle, no loop has an active handle, and tasks are
  still parked, the VM fails with `RUNTIME-INTERNAL` and does not spin. With
  N=1 this is the plain check that `uv_run` reports no active handles; for
  N>1 see 10.2.3, Stall check. With the turn costs of "Builtins", a ready
  timer or I/O event waits at most for the turns of the tasks queued ahead
  of it, each about one turn budget plus the last builtin call or opcode
  of that turn. A test in the 7h tasks PR (roadmap) checks it: while one
  task loops on CPU, one calls a long builtin and one runs a `CONCAT`-heavy
  loop, a `Task.sleep` wake and a stdin pipe read must stay within a
  generous measured limit.
- **Quotas.**
  - `--max-steps` stays one global budget shared by all tasks (`steps_left`,
    6.1), as today. Preemption never changes what is charged, and turn
    costs (see "Builtins") are never charged to it. With one task, a
    runaway program stops with `RUNTIME-STEP-LIMIT` as on the evaluator
    (black-box parity, 1; today counts and spans also match, 2.1). With several tasks,
    which task fails at the limit depends on the interleaving, so, like
    cross-task output order, it is not compared.
  - With N schedulers, `steps_left` is one atomic counter. A scheduler takes
    a batch from it when a turn starts (one turn's budget, or what is left
    if less) and gives the unspent part back at once when the turn ends,
    when the task parks mid-turn, and when the scheduler goes idle. The "next
    stop" counter is set from the batch, so the fast path stays one compare
    and one subtraction and touches no atomic. A `STEP n` that crosses the
    end of its batch first takes more from the shared counter, and fails
    with `RUNTIME-STEP-LIMIT` only when that is not enough. With N=1 this is
    the same as one plain counter, so counts and the span `s + steps_left`
    are those of one task's counter. With N>1, other schedulers may hold
    unspent batches, so the run may stop up to (N-1) times the turn budget
    below the limit, and which task hits the limit is not compared, as
    cross-task output order is not compared.
  - Per-task step quotas could later use the same counter. They are not in
    7h.
  - Per-task memory quotas are out of scope: the Boehm heap is shared, unlike
    BEAM's per-process heaps. Only a global heap limit is possible (13).
- **N=1 first.** The first tasks PR of 7h runs one scheduler, but on the
  split structures of 10.2.3, so going to N>1 later adds threads, stealing
  and the I/O hand-off without a rewrite.
- **As built (tasks PR).** `vm/task.c` holds the scheduler (`agc_vm_run`,
  the FIFO run queue, wake, park) and the `Task` builtins; `vm/interp.c`
  runs one turn of the current task (`agc_run_turn`, which returns yield,
  parked or done) and owns the budget code (`agc_turn_begin`,
  `agc_turn_finish`, the `STEP` slow path, the turn-cost apply path).
  Decisions and tuning:
  - The turn budget stays 2000 steps (`AGC_TURN_STEPS`), and one turn
    unit is one step, one list item, map entry or JSON node, or 64 bytes
    (`AGC_COST_BYTES`). Measured with the latency test: a `Task.sleep(10)`
    wake is at most about 20 ms late next to a CPU loop, a task sorting
    100,000 Ints (one sort is about 25 ms) and a task concatenating a
    1 MiB string; a stdin echo about 30 ms. Without turn costs the same
    waits take about 4.5 s. Single-task speed did not change measurably
    (the `make bench` programs within noise of the previous VM).
  - Builtin costs come from a `cost` field in each C table entry:
    `AGC_COST_SIZE` charges the size of the arguments and of the result
    (String bytes / 64, List items, Map entries, Json members) around
    the call, for the builtins whose work is linear in those sizes
    (`String.upcase`, `split`, `join`, `replace`, `index_of`, ...,
    `List.append`, `concat`, `take`, `drop`, `reverse`, `repeat`,
    `Map.keys`, `values`, `Range.to_a`, `JSON.parse`, `JSON.list`,
    `puts`, `IO.read`, `Path.join`). Walkers charge from inside:
    `agc_sort_by_keys` (n·⌈log2 n⌉), `agc_debug`, `agc_text` and
    `agc_json_encode` (output bytes), `agc_json_from` and
    `agc_json_decode` (one per node), `agc_key_hash` and the map key
    compare (String bytes, so `MAP`, `MAP_GET` and every `Map` builtin
    are covered), and `EQ`/`NE`/`SAME` on equal-length Strings. `CONCAT`
    charges its result bytes. File builtins charge nothing: their work is
    I/O, at most 1 MiB per call.
  - The step budget is the runtime's atomic `steps_left`; a turn takes a
    batch of `AGC_TURN_STEPS` (or what is left) and gives the unspent part
    back at its end, and a `STEP n` past its batch takes more first, so
    with N=1 the stop is exact: the program stops at the step that passes
    the limit. Without
    `--max-steps` the counter starts at `INT64_MAX`.
  - `Task.sleep(0)` yields (the task goes to the back of the queue).
    `Task.sleep(n)` starts a timer-only job (`agc_io_kind` with no `work`
    half) and parks. Under `no_files` (the fuzzer) every sleep yields, so
    a mutant never waits on a clock.
  - A turn cost charged where no apply path follows is applied at the
    next one: the cost of a resumable builtin's last step (the sort in
    `sort_by`) right after its native frame finishes, and the cost of a
    parked task's `done` half (a big `Dir.list` sort) right after the
    turn begins, so the task may yield before it runs anything.
  - Stdin EOF: each read that returns EOF bumps the input's `eof_seq`, and
    each task keeps the last `eof_seq` it has seen (`input_seen`; a spawn
    starts at the current one). A task that needs more input and has not
    seen the latest EOF gets it once, so every task that waited for that
    read sees the EOF and a TTY reader never blocks for a second Ctrl-D.
  - `Task.await` of a running task appends the caller to that task's
    FIFO of waiters and parks with *retry*: when the target finishes, the
    waiters are queued in order and each re-runs its `CALL_BUILTIN`,
    which now returns the cached result. Stdin reads and a second
    reader waiting for a read in flight use the same retry (a wake is
    only a hint, as 10.2.3 asks). A task whose bottom frame returns, or
    leaves through `try`, is done; its registers and frames are dropped.
  - Cancellation: when `main` returns, the run ends; ready and parked
    tasks never run again, and `agc_io_close` closes their timers and
    jobs as before. A failure or `System.exit` in any task ends the run at
    once through `agc_fail`/`agc_exit`, as the evaluator's first
    published outcome does.
  - Stall check (N=1): the queue is empty and `uv_loop_alive` is false
    (or there is no loop) while `main` is not done: `RUNTIME-INTERNAL`
    ("every task is waiting and nothing can wake them"). No Agentica
    program reaches it: a task can only await tasks created before it
    (there are no channels and no way to pass a task its own handle), so
    awaits form no cycle, and every other wait holds a libuv request or
    timer. It guards against VM bugs.
  - Under the black-box rule (§1) a multi-task run must stop with
    `RUNTIME-STEP-LIMIT` when it runs away, and the `--max-steps` sweep
    (§12.1) needs each limit to give the full outcome or the step limit
    with stdout a prefix of the full run. The task fixtures keep that
    deterministic: their step counts do not depend on the clock, and main
    prints after its awaits. Which task meets the limit depends on the
    interleaving, so the span may differ from the evaluator's.

#### 10.2.2 The loop

The first 7h PR had one task; the tasks PR added the run queue (10.2.1,
"As built"). What the loop has:

- **Resource registry** (`vm/loop.c`). `vm->registry` is a GC object with
  an array of `agc_resource` GC objects. Each one owns `malloc` memory
  (`native`) and a `release` function, and keeps its slot until it is
  unregistered. A `FileHandle` value points to its resource; its `native`
  is the `malloc`'d file state (descriptor and read buffer), NULL once
  closed. Each pending request is a resource too, whose `native` is a
  `malloc`'d job with the `uv_work_t` and its `uv_timer_t`. The job stays
  registered until its work callback has run, its timer's `uv_close`
  callback has run, and its result was taken. No GC pointer is stored in
  `malloc` memory, and no `handle->data` is used: callbacks find their job
  with `offsetof`.
- **Blocking builtins** are two halves. The C builtin checks its arguments
  in the evaluator's order, copies what the OS needs into a `malloc`'d
  request (paths through the rules of 2.8), and calls `agc_io_start`, which
  queues one `uv_queue_work` request for the whole operation (stat, open,
  read, close: one thread-pool job, so the task parks once per call) and
  starts a timer for the call's timeout after `uv_update_time` (a
  negative timeout starts no timer, a kind without `work` is a timer
  only). It records the task in the resource (`r->task`) and in
  `task->parked`, and marks the task as parking. `CALL_BUILTIN` sees that,
  keeps the result register (`park_reg`) and ends the turn.
- **Waking**: the work and timer callbacks only set flags and append the
  `malloc`'d job to the loop's ready list. After each `uv_run` the
  scheduler drains that list: the job keeps its registry slot (an index,
  updated when `agc_unregister` moves an entry), so the scheduler finds
  the resource and queues its task. No GC pointer is stored in `malloc`
  memory.
- **Parking** is the scheduler's job. After each turn it calls
  `uv_run(UV_RUN_NOWAIT)` when the loop is alive; with an empty run queue
  it calls `uv_run(UV_RUN_ONCE)`, or fails with `RUNTIME-INTERNAL` when the
  loop has nothing alive (stall check, 10.2.1). When a parked task runs
  again, `agc_io_finish` closes the timer and, on completion, calls the
  request's `done` half on the interpreter thread, which turns the
  `malloc`'d result into GC values and frees the request; on timeout it
  calls `expired`, which
  gives `filesystem: operation timed out` and, for a handle operation,
  closes the handle as the evaluator does (the stuck request then owns the
  file state). The result goes into the call's result register. A
  timed-out job stays registered until its work ends; then its `drop` half
  frees it and the file state it owns, which closes the descriptor.
- **Thread-pool threads** only run the `work` half: system calls on
  `malloc` memory. The libuv pool keeps its default size (4,
  `UV_THREADPOOL_SIZE`). `UV_USE_IO_URING` is set to `0` (unless already
  set) before the loop is created, so libuv uses its plain thread pool and
  epoll. Boehm is built without thread support (until 10.2.3) and never
  sees these threads. `agc_io_start` blocks `SIGINT`, `SIGTERM` and
  `SIGHUP` around `uv_queue_work`, so the pool threads (made on the first
  call) start with them blocked and only the loop thread runs libuv's
  handler for them (10.4).
- **Descriptors** open with `O_CLOEXEC` (and `O_NONBLOCK` before the kind
  check, then blocking for reads and writes in the pool).
- **End of run.** `vm/main.c` calls `agc_io_close` after the run, however
  it ended: open handles are closed (the evaluator's cleanup), timers are
  closed, the loop runs once without waiting, and the loop is freed when no
  job is left. Closing a handle writes its pending output. `agc_io_close`
  returns false when a job is still stuck in the OS (a read on a silent
  FIFO, say); `vm/main.c` then flushes stdout and stderr and ends with
  `_exit`, because a normal exit would run libuv's destructor, which joins
  the pool threads and would wait for that read. The flush of a handle's
  write buffer at the end of run is a blocking write, so it can block on a
  FIFO whose reader stopped reading, as Racket's flush in
  `filesystem-close-all!` does (parity). A handle whose operation is still
  running in the pool (`main` returned while a child task's read was in
  flight) is not released: the job still uses its state. It is released
  after the loop's last run once that job's work is done; otherwise it
  stays registered, `agc_io_close` returns false, and the process ends
  with `_exit` as above.
- **Per-handle lock (tasks PR, as built).** A `FileHandle` resource has a
  `holder` (the job resource of the operation in flight on it), a
  `next_owner` task and a FIFO of waiting tasks, all on the GC
  `agc_resource`, never in `malloc` memory. `agc_io_start` sets `holder`
  when its context is a handle. Every handle builtin (`read_bytes`,
  `read_line`, `write`, `write_bytes`, `flush`, `close`) first checks its
  arguments and timeout, then calls `agc_handle_wait`, and only then checks
  that the handle is open and has the right mode, as the evaluator does
  inside its semaphore. `agc_handle_wait` gives the lock to the task when
  it is the `next_owner`, or when there is no holder and no `next_owner`;
  otherwise the task joins the FIFO and parks with retry on a timer-only
  job that ends at its own deadline (set from its `timeout_ms` at the
  first wait and kept across retries). At the deadline the task leaves
  the FIFO and the builtin returns the timeout error; the handle stays
  open, as with the evaluator's `network-timed` around the semaphore. One
  deadline covers the wait and the operation, as there: a task that gets
  the lock passes what is left of its timeout to the operation, and one
  that gets it after its deadline returns the timeout error (waking the
  other waiters first, as a `next_owner` does).
  Release is a FIFO hand-off, never a free-for-all: `agc_io_finish`
  clears `holder` before the `done` or `expired` half runs, pops the
  head waiter, makes it `next_owner` and wakes only it, so the releasing
  task cannot take the handle back in the same turn (a looping reader
  next to `File.close` ends, as with Racket's fair semaphore). When the
  `next_owner` takes the lock it wakes the rest, which re-run and queue
  again in order behind it; that also covers an owner whose call ends
  without a job (a buffered write, a closed handle). So `close` waits
  for the operation in flight, two readers take turns and never share
  the read buffer, and buffered writes keep their order. On an operation
  timeout, `expired` hands the state to the stuck operation and closes the
  handle (`native` is NULL), so the next owner gets "file handle is
  closed" and never touches the state the stuck work still uses. Wait
  lists link tasks through `wait_next`, apart from the run queue's
  `next`, since a waiter woken by its timer is in both until it runs.
- **External jobs (processes PR).** A kind with `external` set has no
  `work` half: nothing runs in the pool. A libuv callback on the loop
  thread (a pipe read, a finished write, a child's exit) completes it with
  `agc_io_ready`, which marks the work done and puts the job on the ready
  list like a pool job; a second call, or one after the job was taken, does
  nothing. The timer, the `done` and `expired` halves, the lock hand-off
  and `drop` are the same as for pool jobs, and `agc_io_close` marks an
  external job done when it takes it at the end of the run.
- **Fuzzing.** `agc_fuzz_one` sets `vm->no_files`, so mutated programs
  never touch the file system; a file builtin (`Path.cwd` and
  `Path.resolve` too, since they read the current directory) then ends the
  run with `RUNTIME-INTERNAL`. It never sets `--allow-run`, so `Process.spawn`
  returns its error and no child starts. It still calls `agc_io_close` before
  `agc_release_all`, on the normal path and after the allocation limit, so
  a loop or a resource would never outlive the mutant.

**Stdin (deviation from 10.2).** Stdin is read by thread-pool jobs, not
by `uv_pipe_t`/`uv_tty_t` handles chosen with `uv_guess_handle`: a job
does one blocking `read(0)` (with `poll` on `EAGAIN`) into a `malloc`'d
buffer of up to 1 MiB, and its `done` half appends the bytes to the
shared `agc_input` buffer (owned by the runtime, served by scheduler 0)
and wakes the tasks waiting for that read. It works for every kind of
descriptor (TTY, pipe, file, socket) with one code path, and it never
changes the descriptor's flags: `uv_pipe_open` and `uv_tty_init` make the
inherited descriptor non-blocking, which leaks into the parent's open file
description (a shell's terminal) when the VM is killed. One read is in
flight at a time; a second reader parks in the input's FIFO. A read stuck
at the end of the run is handled like a stuck file job (`_exit`). A stdin
read shares the pool with file jobs, so four stuck file calls delay it.
Non-Linux builds keep the blocking read.

How tasks extended it (10.2.1): `agc_io_park` became the place where a task
leaves its turn. It records the task and the result register, and the
scheduler runs the next ready task; the work and timer callbacks, which
today only set flags, also put the task at the back of the run queue;
when the task runs again, the same completion code calls `done` or
`expired` and stores the result. The scheduler calls `uv_run` with
`UV_RUN_NOWAIT` between turns and `UV_RUN_ONCE` only when the run queue is
empty. Handles got a per-handle lock (the evaluator's semaphore), as
built above. It is a task-level lock: waiters park in a FIFO, and it is
never an OS mutex. With N>1 (10.2.3) each scheduler has its own
loop, and an operation on a handle owned by another scheduler goes through
the I/O hand-off.

