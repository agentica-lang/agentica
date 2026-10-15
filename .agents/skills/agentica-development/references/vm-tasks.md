# VM tasks, channels and Test builtins

The scheduler, task cancellation, `Channel` and the `Test` builtins.

Read first: `references/vm.md` and `references/vm-c.md`.

## Files

| Path | Owns |
|---|---|
| `vm/task.c` | The scheduler (run queue, turns, park and wake), task cancellation and the `Task` builtins. |
| `vm/channel.c` | The `Channel` builtins: a ring buffer, waiter queues and reservations. |
| `vm/testing.c` | The `Test` builtins for unit tests, such as `Test.test`. |

- `vm/task.c`
  - the scheduler (`docs/vm/10-io-scheduler.md` §10.2.1, "As built")
    - `agc_vm_run` (
      - setjmp, FIFO run queue, one turn per task, `uv_run` NOWAIT after each
        turn and ONCE when idle, the stall check)
    - `agc_task_wake`, `agc_task_park`, task cancellation (
      - 20b, `docs/vm/10-io-scheduler.md` §10.2.1: each task has `parent` and a
        `children` list
      - a task that ends moves its running children to its parent
      - `agc_task_cancel` cancels a task and its descendants, children first: it
        leaves the run queue, detaches its job, leaves lock, await and stdin
        FIFOs and ends
      - the running task only gets `cancelled` and `vm->yield`, so it stops
        after the current builtin and the scheduler ends it
      - `Task.await` on a cancelled task halts with `RUNTIME-TASK-CANCELLED` at
        the call
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
          waiters and starts an `agc_wait_io` timer job before it parks with
          retry
        - the first wake wins: the target's end finishes the job on the retry,
          and a fired timer takes the caller off the target's waiters
          (`leave_target`), clears the deadline and returns `Await.TimedOut`
          without touching the target)
      - sleep as a timer job, `sleep(0)` and fuzz sleeps yield, `pending_count`
        from `pending_tasks`, tasks made minus tasks done minus `main`: it
        counts ready, running and parked tasks, not tasks that returned or
        crashed (even unawaited ones), `unobserved_crash`)
  - `agc_task_spawn` (shared by `Task.spawn` and `Test.run`; the child inherits
    its parent's `test`), `agc_task_observe`
  - a crash keeps `crash_code`, `crash_message` and `crash_span` for `Test.run`,
    and `finish_task` sets `left_children` when a task ends with running
    children
- `vm/channel.c`
  - the `Channel` builtins (`agc_channel_builtins`,
    `docs/future/27-iteration-and-concurrency.md` §27.2,
    `docs/vm/10-io-scheduler.md` §10.2.2, "Channel waits"; core layer): a GC
    `agc_channel` with a ring (at most 8 slots at first, doubling up to the
    capacity, one turn-cost unit per slot copied; each slot holds the value and
    its send sequence number, so a value handed back by a cancelled receiver is
    inserted by it and FIFO holds), two FIFOs of waiting tasks through
    `wait_next`, and counters for the reserved values and slots.
  - A call that must wait parks with retry on `agc_wait_io`, the lock wait's
    timer-only job kind (the I/O trace skips its `done` and `timeout` lines;
    `start` and `detach` print `kind=lock`)
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
  - the `Test` builtins (`agc_test_builtins`, `docs/future/36-unit-tests.md`
    §36.3, §36.6, as built in `docs/roadmap/25-unit-tests.md` 25a): `Test.test`
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

- Tasks: `make vm-latency` runs `tests/test_vm_latency.py` alone (kept
  out of `make test`'s parallel batch by `PY_ALONE` in the Makefile; CI runs it right
  after `make test`). A sleeping task and a stdin reader must wake within
  250 ms next to CPU, sort and concat tasks, and must not with
  `AGENTICA_VM_TEST_BLOCKING_OUTPUT=1` (a test-only switch that leaves
  stdout and stderr on the blocking `FILE` fallback, so
  `tests/test_vm_stdout.py` can test that path on Linux) and
  `AGENTICA_VM_TEST_NO_TURN_COST=1` (a test-only switch that skips turn
  costs, `docs/vm/10-io-scheduler.md` §10.2.1). A task reading a
  `FileHandle` in a loop must let `main` close it, and the run must end.
  Every read from the VM has a 60-second timeout. The test skips when
  `AGENTICA_VM` names another binary. The `task-*` fixtures keep tasks
  from running side by side where the step-limit span matters, since with
  several runnable tasks the span depends on the interleaving. Builtins get
  `vm->task->regs + base`; `Task.spawn` builds the child's frame with
  `agc_task_call` on the child, never on the caller.
