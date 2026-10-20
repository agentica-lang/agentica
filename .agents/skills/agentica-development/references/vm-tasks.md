# VM tasks, channels and Test builtins

The scheduler, task cancellation, `Task.map`, `Channel` and the `Test` builtins.

Read first: `references/vm.md` and `references/vm-c.md`.

## Files

- **Path:** `vm/task.c`
  - **Owns:** The scheduler (run queue, turns, park and wake), task cancellation
    and the `Task` builtins. With `rt->schedulers > 1` (test-only:
    `AGENTICA_VM_TEST_MULTICORE=1`) `agc_vm_run` goes to `run_threads`: one
    `agc_vm` per scheduler thread (`sched_main`, `sched_turns`), the calling
    thread as the I/O thread (`agc_io_serve` in `vm/loop.c`), the first end
    recorded once by `agc_run_over`, the threads joined before the exit path
    (`docs/vm/16-architecture.md` §16.9, "Threads"). A failure writes
    `*vm->outcome`, the record of that scheduler, never `rt->outcome` directly.
    Programs at N = 4: `tests/test_vm_multicore.py` (`make test-multicore`,
    `make vm-tsan-run`) and the TCP, TLS and HTTP modules
    (`make test-multicore-net`, `AGENTICA_VM_TEST_MODULE_SCHEDULERS`); whole
    runs in C: `vm/tests/threads_test.c`. `agc_task_service` (the `HttpClient`'s
    tree, `HttpWire.service`) spawns under a root with no parent: its tasks
    carry `service`, are counted done when spawned (so `Task.pending_count`
    leaves them out), have no test, and their timers count in `rt->timers_weak`,
    which the stall checks ignore (`agc_timers_strong`;
    `test_stall_beside_a_service`).

- **Path:** `vm/runq.c`
  - **Owns:** The global run queue: a FIFO through `agc_task.next` and one
    mutex, in GC memory (`agc_runtime.runq`). `agc_runq_push`, `agc_runq_pop`,
    `agc_runq_remove`, and for an idle scheduler `agc_runq_wait` (blocks on a
    condvar until a task is queued, NULL after `agc_runq_end` or, on a solo
    queue, when empty). The queue is solo (no lock, never waits) until
    `agc_runq_share`, which runs before a second thread touches it. A nudge
    (`agc_runq_nudge`, `agc_runq_nudged`, `agc_runq_take_nudge`) is work for a
    scheduler that is not a task: it ends one `agc_runq_wait` with NULL, and
    the scheduler then calls `agc_io_service` (`vm/loop.c`), which ends the
    detached jobs that the I/O role handed over. The queue counts its idle
    schedulers for the stall check of the I/O thread (`agc_runq_quiet`,
    `agc_runq_still_quiet`, `agc_runq_on_idle`). Before it waits, an idle
    scheduler spins (`agc_runq_spin`, set up by `agc_runq_spin_setup` at
    N > 1), and a push skips the condvar signal while one spins. A task that a
    scheduler thread wakes goes to its runnext slot (`agc_vm.runnext`, taken
    first by `agc_task_next`, `RUNNEXT_LIMIT` in `vm/task.c`; §16.9, "Wakes
    between schedulers").

- **Path:** `vm/sync.c`
  - **Owns:** The locks of the shared state. `agc_lock` (a mutex that is solo
    until `agc_share`, with an owner token that aborts a drop by a thread that
    does not hold it), `rt->sync`, the one coarse lock for the task tree, the
    waiter lists, the channels, the `Task.map` groups, the logger table, stdin
    and the FIFOs, and the lock of each output stream. `agc_sync_take` and
    `agc_sync_drop` nest per scheduler (`vm->sync_depth`); `agc_sync_reset`
    undoes them after `agc_fail`. The interpreter takes the lock around each
    builtin whose row has `shared` set (`agc_builtin.shared`; every row of every
    table says `true` or `false`), a stepper step, the halves of a job whose
    kind says `locked`, and each end of a task; never hold it across a park or
    a turn. Order: sync, a stream's lock, then the inbox's and the run queue's.
    Held checks: `agc_sync_assert` fails the run when a shared VM reaches
    one of the checked mutators without the lock (the list is in
    `docs/vm/16-architecture.md` §16.9: the task tree, a channel's waiter
    queues, the logger table, a handle's waiters, holder and `next_owner`,
    stdin's waiters), and `agc_task_next` fails if a turn ended with it held. `agc_share` turns all of it on;
    `AGENTICA_VM_TEST_SHARED=1` does it for a whole run on one scheduler (test
    only): `make test-shared` runs the binary modules that way (CI runs it) and
    `tests/test_vm_shared.py` has the programs for the rarer paths. A new
    builtin that touches shared state must set `shared` to true in its row;
    `vm/tests/sync_test.c` checks that every row of the task, `Task.map`,
    channel, logger, process, duplex, TCP and HTTP tables is marked, that no
    row of the String, number and JSON tables is, and chosen rows of the core
    and `File` tables.

- **Path:** `vm/inbox.c`
  - **Owns:** The inbox of the I/O thread (`agc_inbox_open`, `agc_inbox_post`,
    `agc_inbox_keep`, `agc_inbox_close`): a locked queue taken whole and the
    `uv_async_t` that wakes the loop. `agc_io_share` makes it; none exists at
    N = 1, where a request runs inline. The threaded C tests run under TSan:
    `make vm-tsan` (`TSAN=1`, no libgc, `AGC_NO_GC`); `make vm-tsan-run` runs
    the multicore programs on a TSan binary.

- **Path:** `vm/timers.c`
  - **Owns:** The timed waits. `agc_timer` lives in `agc_task`; the heap
    (`agc_timers`) in `agc_vm`, one per scheduler, ordered by (deadline,
    arming order). A builtin that waits for a deadline calls
    `agc_task_parking`, registers its other waits, then
    `agc_task_park_until(vm, deadline_ms, retry)` (an `agc_clock_ms` value);
    no job. `agc_timers_run` (turn boundary and idle, in `agc_vm_run`) wakes the
    due tasks; `resume` and `unlink_task` take the entry out
    (`agc_timers_disarm`). Every change is made with `rt->sync` held, by any
    scheduler. The idle step (`idle_wait` in `vm/task.c`) runs the loop until
    the nearest deadline with `agc_io_run_for(vm, ms, false)`;
    `agc_runq_wait_until` does the same for a scheduler thread. Arm and disarm
    keep `rt->timers_armed`, which the stall check at N > 1 reads.

- **Path:** `vm/task_map.c`
  - **Owns:** `Task.map`: a stepper on the caller that starts, times and cancels
    the items.

- **Path:** `vm/channel.c`
  - **Owns:** The `Channel` builtins: a ring buffer, waiter queues and
    reservations.

- **Path:** `vm/testing.c`
  - **Owns:** The `Test` builtins for unit tests, such as `Test.test`.

- `vm/task.c`
  - the scheduler (`docs/vm/10-io-scheduler.md` §10.2.1, "As built")
    - `agc_vm_run` (
      - setjmp, FIFO run queue, one turn per task, `uv_run` NOWAIT after each
        turn and ONCE when idle, the stall check)
    - `agc_task_wake`, `agc_task_park` (
      - the state is an `_Atomic agc_task_state`: READY (in the run queue),
        RUNNING, PARKING, PARKED, WOKEN, DONE
      - a waker CASes PARKED to READY and pushes, or PARKING to WOKEN and queues
        nothing
      - a builtin that waits calls `agc_task_parking` BEFORE it registers
        anything (a waiter list, a FIFO, a job: `agc_io_start_then` does it for
        a job), then `agc_task_park(vm, retry)`; `agc_task_unpark` undoes the
        mark when it does not wait after all
      - `agc_task_end_turn` (called by `agc_vm_run`) ends the turn: trace,
        cancel flag, then `agc_task_commit_park` (PARKING to PARKED); a CAS that
        finds WOKEN queues the task instead, and after a commit the cancel flag
        is read once more and the task is claimed (`agc_task_claim`, PARKED to
        READY) and ended if it is set
      - `agc_task_next` pops the next task, dropping a DONE one and ending a
        cancelled one that a canceller could not take out of the queue
      - `agc_clock_ms` is the clock for deadlines; it does not read the loop)
    - task cancellation (
      - 20b, `docs/vm/10-io-scheduler.md` §10.2.1: each task has `parent` and a
        `children` list
      - a task that ends moves its running children to its parent
      - `agc_task_cancel` cancels a task and its descendants, children first:
        it sets `cancelled`, and then by the state the one party that ends the
        task takes it out of the run queue (READY) or claims it (PARKED),
        detaches its job, leaves lock, await and stdin FIFOs and ends
      - a task on a turn only gets `cancelled`; its scheduler ends it at the end
        of the turn. Only when it is the canceller's own task does the
        cancel set `vm->yield`, so it stops after the current builtin; a
        task that runs on another scheduler finishes its turn first (at
        most the turn's step budget, §10.2.3); a task it spawns in that
        turn starts cancelled (`spawn_child` reads the parent's flag under
        rt->sync, #392)
      - `Task.await` on a cancelled task halts with `RUNTIME-TASK-CANCELLED` at
        the call
      - `Task.cancel` (`builtin_cancel`, row `shared`) is the same walk through
        `cancel_tree` with `at=call` on the named task's trace line; it never
        waits, and a task that cancels itself or an ancestor is in the walk and
        stops after the call (`yield`). Fixtures `task-cancel-*` run at N = 1
        and N = 4; ordering in them comes from channels, never from sleeps
      - `vm/tests/task_cancel_test.c` runs hand-built bytecode with test
        builtins on the real scheduler
      - 17c adds the timed await cases there: a waiter cancelled while it waits
        leaves the target's waiters and closes its timer, and the timer firing
        first or the target ending first gives `TimedOut` or `Done` with the
        other side cleaned up)
    - task crashes (
      - phase 24, `docs/vm/10-io-scheduler.md` §10.2.1, "Crashes": one `setjmp`
        per turn in `run_turn`, `fatal` picks what still ends the run (`main`,
        an exit, `RUNTIME-STEP-LIMIT`, `RUNTIME-INTERNAL`), `crash` stores and
        prints the crash, unlinks the task, cancels its descendants and calls
        `finish_task`
      - the unobserved summary when `main` returns)
    - handle ownership (
      - 24b: `finish_task` is the one end of every task, whether it returns,
        crashes or is cancelled, and it first calls `agc_close_owned(vm, t)`,
        which closes the handles on the task's own `owned` list, each by its
        resource's `close`
      - `agc_own` in `vm/loop.c` puts a handle on the list of `vm->task`,
        `agc_unregister` takes it off, `agc_hand_over` moves it
      - nothing is given to the parent
      - a regular-file (pool) close job counts on the ending task in `closing`,
        a polled FIFO or pipe close does not, and `agc_task_join` keeps parking
        awaiters, new ones too, until `agc_task_close_done` has run for each
        counted job)
    - and the `Task` builtins (
      - `agc_task_builtins`: spawn with a per-task `Random` split (
        - `agc_task_spawn_seeded`)
      - and no move, `Task.spawn_owning` through `agc_task_spawn_owning` (
        - the port function that also `HttpWire.spawn` calls: it fails with
          `RUNTIME-HANDLE-NOT-OWNED` at the handle argument before it makes the
          task, then spawns, seeds and hands the handle over)
      - two await entries with a FIFO of waiters and retry (
        - `agc_task_join`: clear `awaiting`, or enqueue on the target's waiters
          and park with retry
        - `Test.run` waits with it too
        - `Task.await` halts with `RUNTIME-TASK-CRASHED` or
          `RUNTIME-TASK-CANCELLED`, `Task.await_result`, picked by lowering for
          a `Result`, returns the error
        - each has a second arity with a timeout (17c): `await_timeout` shares
          `outcome` with `await_task`, rejects `timeout <= 0` with
          `RUNTIME-INVALID-DURATION` at `span + 2`, returns at once with
          `Await.Done` for a task that has ended (`await_done`, the shared value
          of `await_timed_out` for the other variant), and otherwise stores
          `await_deadline` in the caller on the first call, runs no cycle check
          (`awaits_caller` stops at a task whose `await_deadline` is set, so a
          timed waiter is not an edge of the plain walk), joins the target's
          waiters and arms its own timer (`agc_task_park_until`) as it parks
          with retry
        - the first wake wins: the target's end (`resume` disarms the timer),
          and a fired timer takes the caller off the target's waiters
          (`leave_target`), clears the deadline and returns `Await.TimedOut`
          without touching the target)
      - sleep as a timer of the task (`agc_task_park_until`), `sleep(0)` and
        fuzz sleeps yield, `pending_count` from `pending_tasks`, tasks made
        minus tasks done minus `main`: it counts ready, running and parked
        tasks, not tasks that returned or crashed (even unawaited ones),
        `unobserved_crash`)
  - `agc_task_spawn` (shared by `Task.spawn` and `Test.run`; the child inherits
    its parent's `test`), `agc_task_observe`
  - a crash keeps `crash_code`, `crash_message` and `crash_span` for `Test.run`,
    and `finish_task` sets `left_children` when a task ends with running
    children
- `vm/task_map.c`
  - `Task.map` (`agc_task_map_builtins`, 17a,
    `docs/future/27-iteration-and-concurrency.md` §27.1,
    `docs/vm/10-io-scheduler.md` §10.2.1, "Task.map"; core layer): a GC
    `map_group` whose first member is the `agc_stepper`, installed on the caller
    by `agc_task_stepper` (as `File.each_line` does)
  - the arguments are checked first and in order: `limit` (1 to 1024,
    `RUNTIME-INVALID-COUNT` at `span + 2`), `timeout_ms` (above 0,
    `RUNTIME-INVALID-DURATION` at `span + 3`), then the empty list returns the
    list itself
  - `map_step` runs on the caller at each wake: `collect` the ended items into
    their slots, `expire` the oldest running item whose deadline passed (slot
    `error("task: timed out")`, then `agc_task_cancel`), `start` items up to
    `limit` (one `agc_count_step` each, `agc_task_spawn_seeded` with the caller
    as parent), and, if every slot is set, charge `count` and end with the list;
    else one timer of the caller for the oldest deadline
    (`agc_task_park_until`)
  - one timer is enough because every item has the same timeout and starts in
    input order, so the deadlines grow along the running list
  - an item tells the group through the task hook (`end`, `end_data`, called by
    `finish_task` for a return, a crash and a cancel): `item_ended` ignores an
    item that already timed out and an item that is `cancelled` (its caller was
    cancelled, so the group is gone), else moves it to the ended list and wakes
    the caller. There is no dead flag: a cancelled caller never runs `map_step`
    again
  - a crashed item is observed (`agc_task_observe`) and its slot is
    `error(t->crash)`; a non-`Result` item result is `RUNTIME-INTERNAL`
  - an item that ends after its deadline but before the caller runs keeps its
    result
  - an item with a file close pending (`closing`) is not settled, as for
    `Task.await`: `item_ended` puts the hook back on the task and
    `agc_task_close_done` calls it when the last close ends; if its deadline
    comes first it is settled as timed out without waiting for the close, and
    `expire` marks its crash, if any, as observed
- `vm/channel.c`
  - the `Channel` builtins (`agc_channel_builtins`,
    `docs/future/27-iteration-and-concurrency.md` §27.2,
    `docs/vm/10-io-scheduler.md` §10.2.2, "Channel waits"; core layer): a GC
    `agc_channel` with a ring (at most 8 slots at first, doubling up to the
    capacity, one turn-cost unit per slot copied; each slot holds the value and
    its send sequence number, so a value handed back by a cancelled receiver is
    inserted by it and FIFO holds), two FIFOs of waiting tasks through
    `wait_next`, and counters for the reserved values and slots.
  - A call that must wait parks with retry on the task's own timer
    (`agc_task_park_until`; no job, so no I/O trace line)
  - the deadline lives in the task (`channel.deadline`) and a retry is told by
    `channel.channel == c`.
  - A value for a waiting receiver is reserved in the task (`channel.value`), a
    freed slot for the head sender (`channel.reserved`; `offer_slot` makes the
    offer after a `recv` and after a woken sender hands its value to a receiver)
  - the pops skip tasks that are no longer parked (their timer won), and a woken
    waiter with a reservation does not search the FIFO again.
  - `agc_channel_leave` (called from `unlink_task`) takes a cancelled waiter out
    and hands its reservation on.
  - An owner (24c): `agc_channel_claim` registers an entry with no native object
    the first time `Task.spawn_owning` hands the channel over
    (`agc_task_spawn_owning` in `vm/task.c` takes the resource of a channel from
    it, of any other handle from `agc_owned_of`)
  - `shut` is the one close, run by `Channel.close` and by `agc_close_owned` at
    the owner's end, and it drops the entry first so a closed channel has none.
  - Arguments are checked before any wait state changes
  - `Channel.new` and the timeouts fail at their argument (`span + 1 + index`;
    the receiver is argument 0).
  - No new opcode: the builtins are appended to the table, and `src/lower.rkt`
    lists their names.
- `vm/testing.c`
  - the `Test` builtins (`agc_test_builtins`, as built in
    `docs/roadmap/25-unit-tests.md` 25a; the rules are in the grammar's
    `Unit tests (Test)` section): `Test.test`
    makes an `agc_test_case` (tag `AGC_T_TEST`: name, block, call span)
  - the assertions return `ok()` or `error(text)` and record their first failure
    (`agc_test_note`) on `vm->task->test`, the test the task was spawned under
  - `Test.run` fails with `RUNTIME-TEST-RUN` when the calling task is not `main`
    (`vm->task != vm->main`: a test or any task `main` spawned; there is no
    "served once" state), checks the names, then the arguments (`--agentica-test
    list|run`; run directly it prints `run this file with agentica test` and
    exits 2) and the channel (`agc_parent_open`; none is `RUNTIME-TEST-RUN`).
  - It serves `list` (all `test` records and `ready` built by `list_lines` in
    one pass over an array of lines and sent as one batch, exit 0) or `run`, a
    retry builtin whose state (`agc_test_run`) lives on the calling task: it
    reads an index line with `agc_parent_line` (`vm/duplex.c`; the program's
    stdin and stdout are untouched, there is no token), starts the test with
    `agc_task_spawn` and a seed from the run's seed and the name, waits for it
    with `agc_task_join`, and on wake builds the record (crash, first note, the
    block's error, `left_children`, an unobserved crash of the test's tasks),
    cancels the test's leftover tasks (now the caller's children), observes
    every crash of the test's tasks, then `deliver` flushes stdout with
    `agc_drain` and sends the record with `agc_parent_send` before the next
    index is read
  - at the end of the channel and after a list it ends the run like a return
    from `main` (`agc_report_unobserved` in `vm/task.c`: the unobserved summary,
    exit 1)
  - an index line that is not a plain index, or that cannot be read as a line
    (`AGC_INPUT_FAILED`: invalid UTF-8), is a `RUNTIME-BDD-INFRA` fail record
    and exit 1 (a channel that is already shut just exits 1)

## Gotchas

- A task is finished only when `state == DONE && !closing`: `agc_task_join`
  (`Task.await` with one argument) and `await_timeout` (with a timeout) in
  `vm/task.c` keep waiting while its file closes are pending. A `Task.map` item
  does the same: `item_ended` (`vm/task_map.c`) puts its end hook back while the
  task is `closing`. A test of a task whose handle is still closing must allow
  for that wait.
- Tasks: `make vm-task-map` runs `tests/test_vm_task_map.py` alone, the timing
  cases of `Task.map` (the bound on the items in flight, timeouts, a grandchild,
  a detached read, HTTP against a `ThreadingHTTPServer`,
  `RUNTIME-TASK-CANCELLED`); CI runs it right after `make vm-latency`. Its
  bounds are one-sided or generous (`scaled()`), and it skips when
  `AGENTICA_VM_BINARY` names another binary. The golden fixtures of `Task.map`
  (`task-map-*`) never race a timeout against work: they record step counts and
  run the `--max-steps` sweep.
- Tasks: `make vm-latency` runs `tests/test_vm_latency.py` alone (kept
  out of `make test`'s parallel batch by `PY_ALONE` in the Makefile; CI runs it
right
  after `make test`). A sleeping task and a stdin reader must wake within
  250 ms next to CPU, sort and concat tasks, and must not with
  `AGENTICA_VM_TEST_BLOCKING_OUTPUT=1` (a test-only switch that leaves
  stdout and stderr on the blocking `FILE` fallback, so
  `tests/test_vm_stdout.py` can test that path on Linux) and
  `AGENTICA_VM_TEST_NO_TURN_COST=1` (a test-only switch that skips turn
  costs, `docs/vm/10-io-scheduler.md` §10.2.1). A task reading a
  `FileHandle` in a loop must let `main` close it, and the run must end.
  Every read from the VM has a 60-second timeout. The test skips when
  `AGENTICA_VM_BINARY` names another binary. The `task-*` fixtures keep tasks
  from running side by side where the step-limit span matters, since with
  several runnable tasks the span depends on the interleaving. Builtins get
  `vm->task->regs + base`; `Task.spawn` builds the child's frame with
  `agc_task_call` on the child, never on the caller.
