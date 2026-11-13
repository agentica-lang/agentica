# VM tasks, channels and Test builtins

The scheduler, task cancellation, `Task.map`, `Channel` and the `Test` builtins.

Read first: `references/vm.md` and `references/vm-c.md`.

## Scheduler (`vm/task.c`, `vm/runq.c`, `vm/sync.c`)

- The scheduler count is one per logical core, unless `--schedulers` or
  `AGENTICA_SCHEDULERS` sets it (`vm/launch.c`); the front end always runs at 1.
  At N > 1 `agc_vm_run` goes to `run_threads`: one `agc_vm` per scheduler
  thread, the calling thread is the I/O thread (`agc_io_serve`, `vm/loop.c`),
  and the threads are joined before the exit path (`docs/vm/16-architecture.md`
  §16.9). A failure writes `*vm->outcome`, that scheduler's record, never
  `rt->outcome` directly.
- Test-run defaults: `tests/vm_diff_support.py` sets `AGENTICA_SCHEDULERS=1`,
  since step counts, the `--max-steps` sweep and task order hold only there. A
  test whose output depends on task order pins `--schedulers 1` (the ORDER set
  of `tests/test_vm_multicore.py`). N = 4 runs: `make test-multicore`,
  `make vm-tsan-run`, `make test-multicore-modules` (TCP, TLS, HTTP, process,
  BDD and native-call modules; `AGENTICA_VM_TEST_MODULE_SCHEDULERS`),
  `make vm-tsan-native` (the native modules under TSan, also at N = 2), and
  `vm/tests/threads_test.c` in C.
- The wake protocol (task states READY, RUNNING, PARKING, PARKED, WOKEN, DONE;
  the run queue and `runnext`; a cancel as a claim; the one `rt->sync` lock and
  its nesting) is `docs/vm/16-architecture.md` §16.9. Read it before changing
  `vm/task.c`, `vm/runq.c` or `vm/sync.c`. Rules for builtin code:
- A builtin that waits calls `agc_task_parking` before it registers anything (a
  waiter list, a FIFO, or a job, which `agc_io_start_then` does), then
  `agc_task_park(vm, retry)`. `agc_task_unpark` undoes the mark when the builtin
  does not wait after all.
- `rt->sync` covers the task tree, waiter lists, channels, `Task.map` groups,
  the logger table, stdin and the FIFOs. Each output stream has its own lock.
  The interpreter takes `rt->sync` around each builtin whose row has `shared`
  set, a stepper step, the halves of a job whose kind says `locked`, and each
  end of a task. `Native.call` runs C without it and pins its resources
  (`vm/ffi.c`); a program guards a library that is not thread-safe with a
  `Native.Mutex` (`vm/mutex.c`, a stepper whose waiters park in a FIFO). Never
  hold it across a park or a turn. Lock order: sync, then a stream's lock, then
  the inbox's and the run queue's. `agc_sync_take` and `agc_sync_drop` nest per
  scheduler; `agc_sync_reset` undoes them after `agc_fail`.
- `agc_sync_assert` fails the run when a shared VM reaches a checked mutator
  without the lock; `agc_share` turns it on. `AGENTICA_VM_TEST_SHARED=1` does it
  for a whole run on one scheduler (`make test-shared` runs the binary modules
  that way; `tests/test_vm_shared.py` covers the rarer paths). A change to
  state that more than one thread reads (the run queue, the inbox, a job, the
  registry, an `_Atomic`, a row's `shared` mark) runs `make vm-tsan` and `make
  test-shared` before the PR; a new threaded C test goes in `VM_TSAN_TESTS`
  (`mk/vm-test.mk`).
- A scheduler or the I/O thread never blocks without a deadline: stdin is read
  through `agc_input_whole` and its port (`vm/input.c`), never by a blocking
  read on the loop thread, and a push that skipped its wake is followed by
  `agc_runq_kick` (`vm/core.h`), or the other schedulers sleep on.
- A new builtin that touches shared state sets `shared` to true in its row.
  `vm/tests/sync_test.c` checks that the task, `Task.map`, channel, logger,
  process, duplex, TCP and HTTP rows are marked, that no String, number or JSON
  row is, and some core and `File` rows.
- `vm/inbox.c`: the I/O thread's inbox (`agc_inbox_open`, `agc_inbox_post`,
  `agc_inbox_keep`, `agc_inbox_close`), a locked queue taken whole, with a
  `uv_async_t` that wakes the loop. It exists only at N > 1; at N = 1 a request
  runs inline. The threaded C tests run under TSan: `make vm-tsan` (`TSAN=1`, no
  libgc, `AGC_NO_GC`).

## Timers (`vm/timers.c`)

- `agc_timer` lives in `agc_task`; the heap (`agc_timers`) is in `agc_vm`, one
  per scheduler, ordered by (deadline, arming order).
- A builtin that waits for a deadline calls `agc_task_parking`, registers its
  other waits, then `agc_task_park_until(vm, deadline_ms, retry)`. No job is
  involved. A channel wait calls `agc_task_park_within(vm, timeout_ms)` instead,
  which reads no clock: the entry sits in the heap's `pending` slot until the
  end of the scheduler's next turn, its next such park, or `agc_timers_settle`
  before it sleeps. It is dropped if the task was woken first.
- `agc_timers_run` (at turn boundaries and when idle) starts the clock and wakes
  the due tasks. `resume` and `unlink_task` remove the entry
  (`agc_timers_disarm`). Every change is made with `rt->sync` held, by any
  scheduler. The idle step (`idle_wait`) runs the loop until the nearest
  deadline (`agc_io_run_for`), and `agc_runq_wait_until` does the same for a
  scheduler thread. Arm and disarm keep `rt->timers_armed`, which the N > 1
  stall check reads.
- Channel, `Task.await` and `Task.map` timeouts go through `agc_timeout_length`,
  which is 0 under `no_files`: the fuzzer has no wall clock, so its steps bound
  every wait.

## Tasks, cancellation and crashes (`vm/task.c`)

- Cancel and parent/children rules: `docs/vm/10-io-scheduler.md` §10.2.1
  ("Cancellation") and §16.9 (the claim protocol). A task spawned during the
  canceller's turn starts cancelled (`spawn_child` reads the parent's flag under
  `rt->sync`).
- `Task.cancel` (`builtin_cancel`, `shared`) walks the tree through
  `cancel_tree`. It never waits. A caller that cancels itself or an ancestor
  stops after the call (`yield`). The `task-cancel-*` fixtures run at N = 1 and
  N = 4; their output must not depend on timing.
- A crash runs `run_turn` under one `setjmp`. `fatal` decides what still ends
  the run (`main`, an exit, `RUNTIME-STEP-LIMIT`, `RUNTIME-INTERNAL`). Otherwise
  `crash` stores and prints the crash, unlinks the task, cancels its descendants
  and calls `finish_task`. The unobserved summary is printed when `main`
  returns. A crash keeps `crash_code`, `crash_message` and `crash_span` for
  `Test.run`. `finish_task` sets `left_children` when a task ends with running
  children.
- `finish_task` is the one end of every task (return, crash or cancel). It first
  calls `agc_close_owned(vm, t)`, which closes the handles on the task's own
  `owned` list, and nothing is given to the parent. A regular-file (pool) close
  counts on the ending task in `closing`; a polled FIFO or pipe close does not.
  `agc_task_join` keeps parking awaiters, new ones included, until
  `agc_task_close_done` has run for each counted job.
- A cancelled task that has not settled (still on a turn on another scheduler,
  or ended with a close pending) holds the task the cancel reached it through
  (`hold`: `holder` and one count in its `closing`). A task already held makes
  the top of its holder chain hold instead. `settle` gives the count back, so a
  crashed or cancelled task is observed only after its cancelled descendants
  have closed their handles.
- Monitors (`Task.monitor`, `shared`): an `agc_monitor` on the target's
  `monitors` list, fired by `settle` (so after the target's file closes, as an
  await sees it) or at once for a settled target. `monitor_fire` runs
  `wrap(TaskDown)` in a service task (`service_root`, no parent, so no cancel
  reaches it) whose end hook `monitor_sent` offers the result with
  `agc_channel_offer` (never waits; dropped when closed or full) and observes a
  crashed target. The builtin checks the wrap and finds `TaskDown` and
  `TaskExit` (`down_types`), so a task's end cannot fail on them.
- Spawns: `make_child` and `start_child` set the random stream and a test's
  `test` mark before another scheduler can run the child, and the child inherits
  its parent's `test` (`agc_task_spawn_seeded`). `agc_task_observe` marks a
  crash as observed.
- `Task.spawn_owning` (`agc_task_spawn_owning`, also used by `HttpWire.spawn`)
  walks the argument for handles without `rt->sync` (`find_handles`). Then,
  under the lock, it fails with `RUNTIME-HANDLE-NOT-OWNED` at the handle
  argument before it creates the task or moves any handle. Only then does it
  spawn, seed and hand over.
- Await: `agc_task_join` clears `awaiting`, or queues on the target's waiters
  and parks with retry. `Test.run` waits the same way. `Task.await` halts with
  `RUNTIME-TASK-CRASHED` or `RUNTIME-TASK-CANCELLED`; `Task.await_result`,
  picked by lowering for a `Result`, returns the error instead. The timeout
  arity (`await_timeout`, which shares `outcome` with `await_task`) rejects
  `timeout <= 0` with `RUNTIME-INVALID-DURATION` at `span + 2`. It returns
  `Await.Done` at once for an ended task. It runs no cycle check:
  `awaits_caller` stops at a task whose `await_deadline` is set, so a timed
  waiter is not an edge of the plain walk. A fired timer removes the caller from
  the target's waiters (`leave_target`).
- `Task.sleep` is a timer of the task. `sleep(0)` and fuzz sleeps yield.
  `Task.pending_count` counts ready, running and parked tasks: not tasks that
  returned or crashed, even unawaited ones.
- `agc_task_service` (the `HttpWire.Client` tree, `HttpWire.service`) spawns
  under a root with no parent. Its tasks carry `service`, count as done when
  spawned (so `Task.pending_count` leaves them out), have no test, and their
  timers count in `rt->timers_weak`, which the stall checks ignore
  (`agc_timers_strong`; `test_stall_beside_a_service`).

## Task.map (`vm/task_map.c`)

The design (a stepper on the caller, the deadlines, the end hook, cancel and
pending closes) is `docs/vm/10-io-scheduler.md` §10.2.1 (Task.map). Rules for
the code: arguments are checked first, in order: `limit` (1 to 1024,
`RUNTIME-INVALID-COUNT` at `span + 2`), then `timeout_ms` (above 0,
`RUNTIME-INVALID-DURATION` at `span + 3`); an empty list returns itself. A
non-`Result` item result is `RUNTIME-INTERNAL`. The group is a GC `map_group`
whose first member is the `agc_stepper`, installed by `agc_task_stepper`.

## Channels (`vm/channel.c`)

The ring, the reservations and the FIFOs of waiters are
`docs/vm/10-io-scheduler.md` ("Channel waits"). Rules for the code:

- A call that must wait parks with retry on the task's own timer
  (`agc_task_park_within`); a retry is recognised by `channel.channel == c`.
  `agc_channel_leave` (from `unlink_task`) removes a cancelled waiter and hands
  its reservation on.
- Ownership: `agc_channel_claim` registers an entry, with no native object, the
  first time `Task.spawn_owning` hands the channel over. `shut` is the one
  close. It runs from `Channel.close` and from `agc_close_owned` at the owner's
  end, and drops the entry first, so a closed channel has none.
- Arguments are checked before any wait state changes. `Channel.new` and the
  timeouts fail at their argument (`span + 1 + index`; the receiver is argument
  0).

## ATS (`vm/ats.c`)

- Tag `AGC_T_ATS`, service layer; the rules are in
  `site/content/library/concurrency/ats.md`. A table is an `_Atomic` pointer to
  an immutable `state` (two persistent AVL trees over the same entries, by key
  and by insertion number, plus the size); a writer builds the next state and
  installs it with a strong CAS, building again if another writer won.
- No row is `shared`: a call takes neither `rt->sync` nor a lock. A failure
  happens before the CAS, so the table keeps its state. `vm/tests/ats_test.c`
  races threads on one table (in `VM_TSAN_TESTS`).

## Test builtins (`vm/testing.c`)

- `Test.test` makes an `agc_test_case` (tag `AGC_T_TEST`). Assertions return
  `ok()` or `error(text)`, and record their first failure (`agc_test_note`) on
  `vm->task->test`, the test the task was spawned under.
  `site/content/library/testing/test.md` holds the rules.
- `Test.run` fails with `RUNTIME-TEST-RUN` when the caller is not `main`. It
  checks the names, then the arguments (`--agentica-test list|run`; run directly
  it prints `run this file with agentica test` and exits 2), then the channel
  (`agc_parent_open`; none is `RUNTIME-TEST-RUN`). `list` sends every `test`
  record and `ready` as one batch, exit 0. `run` is a retry builtin whose state
  (`agc_test_run`) lives on the calling task: it reads an index line with
  `agc_parent_line` (the program's stdin and stdout are not touched), starts the
  test with `agc_task_spawn_test` (seeded from the run's seed and the name), and
  waits with `agc_task_join`. On wake it builds the record: crash, first note,
  the block's error, `left_children`, and an unobserved crash of the test's
  tasks. It then cancels the test's leftover tasks and observes every crash of
  its tasks. `deliver` flushes stdout with `agc_drain`, sends the record with
  `agc_parent_send`, and only then reads the next index.
- At the end of the channel, and after a list, the run ends like a return from
  `main` (`agc_report_unobserved`; exit 1). An index line that is not a plain
  index, or that cannot be read (`AGC_INPUT_FAILED`), is a `RUNTIME-BDD-INFRA`
  fail record with exit 1. A channel that is already shut just exits 1.

## Gotchas

- A task is finished only when `state == DONE && !closing`. `agc_task_join`
  (`Task.await` with one argument) and `await_timeout` keep waiting while its
  file closes are pending. A `Task.map` item does the same through `item_ended`.
  A test of a task whose handle is still closing must allow for that wait.
- `Task.map` goldens (`task-map-*`) never race a timeout against work: they
  record step counts and run the `--max-steps` sweep. Their timing cases run
  alone with `make vm-task-map` (`references/vm-tests.md`).
- `make vm-latency` runs `tests/test_vm_latency.py` alone (`PY_ALONE` in
  `mk/test.mk`; CI runs it right after `make test`). On one scheduler, a
  sleeping task and a stdin reader must wake within 250 ms beside CPU, sort and
  concat tasks, and must not with `AGENTICA_VM_TEST_BLOCKING_OUTPUT=1` (stdout
  and stderr on the blocking `FILE` fallback) or
  `AGENTICA_VM_TEST_NO_TURN_COST=1` (no turn costs, `docs/vm/10-io-scheduler.md`
  §10.2.1). A task reading a `File.Handle` in a loop must let `main` close it,
  and the run must end. The test skips when `AGENTICA_VM_BINARY` names another
  binary.
- The `task-*` fixtures keep tasks from running side by side wherever the
  step-limit span matters, since with several runnable tasks the span depends on
  the interleaving.
- Builtins get `vm->task->regs + base`. `Task.spawn` builds the child's frame
  with `agc_task_call` on the child, never on the caller.
