## 27. Iteration and concurrent collections

**Status:** 27.1 (`Task.map`) is built (roadmap 17a, order step 7.3; "As
built" at the end of 27.1 says where it differs from the plan below); 27.2
(channels) is built (roadmap 17b, order step 7.2.1e, moved earlier by the owner
on 2026-10-13); both on the C VM only. They come before strict diagnostics
([section 26](26-strict-diagnostics.md#26-strict-diagnostics), order step 7.6),
so their examples, fixtures and site pages are written in today's forms, and
each phase 16 PR counts and migrates them. 17d (`File.each_line`, order row
7.2.1h, built) adds a small checker change for a block whose result is
`Result[T]`: its last expression is checked as a completion value, so a Void or
non-Result last expression is `CHECK-TYPE-MISMATCH` with a help that shows
`ok()`. `try` in a block with a fixed `Result` type already worked; the case
where `T` is inferred from the block comes with the first of 27.1 and
`File.open` with a block (§25.9). 27.3 (`Task.await` with a timeout, returning
the builtin enum `Await[T]`) is built (roadmap 17c): the owner decided on
2026-10-14 to build it as a C builtin now, in place of the prelude code planned
for order step 8.2. 27.4 (`File.each_line` and `Stream[T]`) is in two steps,
decided by the owner on 2026-10-14: step 1 is item 17d at order row 7.2.1h
(built), step 2 is item 17e at order step 8.2. 27.5 records what was decided
against (generators, fibers, Agent-style shared state, public locks), so it is
not proposed again. This section finalizes the earlier channel proposal and
answers [section
25.12.7](25-ruby-typed-idioms.md#25127-lazy-enumerators-and-generators).

**What is asked for:** something like Elixir's `Stream` and `Task.async_stream`,
Ruby's iterators, generators and accumulators, and faster programs through
concurrency.

**What exists today** (`grammar.md`, "Lightweight tasks", "Ranges", "Blocks and
closures"): `Task.spawn`, `Task.await` and `Task.sleep` give I/O concurrency on
one core (the VM runs one scheduler, `docs/vm/10-io-scheduler.md` §10.2.1).
`List` and `Range` methods are eager; `for` over a range does not build a list;
`reduce` is the accumulator. Channels (27.2) are built; there are no lazy
streams and no CPU parallelism. `Task.await(task, timeout_ms)` (27.3) bounds a
wait without stopping the task, and a task cannot be cancelled by the program.

**Rules.** Those of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms):
one way to do each thing (its Principle and its test), values stay immutable
with no shared mutable state (the one exception is the `std/logger`
registry, which only the Logger functions reach; the grammar's logging
section), types stay static, and
the users are LLM agents, who do best with one obvious form and an error whose
help shows it.

**Primitives in C, helpers in Agentica.** The concurrency primitives are a small
set of C builtins: `Task.spawn`, `Task.await`, `Task.sleep`, `Channel` (27.2)
and `Task.map` (27.1). Higher-level concurrency helpers, such as future ones
like "the first of several tasks" or "all settled", are written in Agentica in
the compiler prelude over those primitives, as the [std-first
rule](../roadmap/README.md#new-library-features-std-first) asks; they go in the
prelude, not in `std/`, because they need the catalog's type variables. Each
future helper still needs its own spec and must pass the one-way test.
`Task.map` stays a C builtin because it must cancel timed-out items, which no
primitive can do, and because it lands at order step 7.3, before the prelude
(27.1, "Where it lives"). `Task.await` with a timeout (27.3) is a C builtin too,
by the owner's decision of 2026-10-14: the timeout lives in the scheduler, as a
timer on the job (`docs/vm/14-core-invariants.md` §14.2), and the prelude it
would have waited for does not exist yet.

**One way for each job.** After this section, the programming skill teaches
these forms, and only these, for each job. The skill updates of 17a and 17b
teach only the rows whose forms exist when they land; each later item adds its
own row:

- **Job:** Change, select or combine the items of a list
  - **The one form:** `List.map`, `filter`, `reduce` and the other `List`
    methods (eager)

- **Job:** Keep a running total, or build a value in a loop
  - **The one form:** `reduce`, or a `for` or `while` loop that reassigns a
    local variable

- **Job:** Run the same I/O for each item of a list, at most N at a time, each
  with a timeout
  - **The one form:** `Task.map` (27.1)

- **Job:** Long-lived workers, producer and consumer, a flow of unknown length,
  results in the order they end
  - **The one form:** tasks and a `Channel` (27.2)

- **Job:** Wait for a task's result, for at most N ms
  - **The one form:** `Task.await(task, timeout_ms)` (27.3), matched as
    `Await.Done(v)` or `Await.TimedOut`; the task keeps running after a timeout

- **Job:** Read a big file line by line
  - **The one form:** `File.each_line` (27.4, step 1, built)

- **Job:** An endless sequence, or the lines of a file that a step filters,
  takes or folds
  - **The one form:** a `while` loop; `Stream[T]` (27.4, step 2) once 17e lands

- **Job:** State that several tasks update
  - **The one form:** one owner task that receives messages on a channel (27.5);
    a shared table (§13) when a program needs it

- **§:** 27.1
  - **Item:** `Task.map`
  - **Decision:** planned
  - **Where it lives:** C builtin in the VM scheduler
  - **Roadmap:** 17a

- **§:** 27.2
  - **Item:** `Channel[T]`
  - **Decision:** built
  - **Where it lives:** C builtins, a builtin opaque generic
  - **Roadmap:** 17b

- **§:** 27.3
  - **Item:** `Task.await(task, timeout_ms)` returning `Await[T]`
  - **Decision:** built
  - **Where it lives:** C builtin and a builtin generic enum
  - **Roadmap:** 17c

- **§:** 27.4
  - **Item:** `File.each_line` (step 1) and `Stream[T]` (step 2)
  - **Decision:** step 1 built (17d); step 2 planned (owner, 2026-10-14)
  - **Where it lives:** step 1 a C builtin; step 2 prelude code
  - **Roadmap:** 17d, 17e

- **§:** 27.5
  - **Item:** Generators, fibers, Agent-style state, public locks and threads
  - **Decision:** decided against
  - **Where it lives:** help hints only, added by 17a and 17b
  - **Roadmap:** none

### 27.1 `Task.map`

Elixir's `Task.async_stream` for a list: run a block for each item in its own
task, at most `limit` at a time, each item with its own timeout, and get one
`Result` per item, in input order.

```agentica
def slow_double(n: Int) -> Result[Int]
  Task.sleep(100)
  return ok(n * 2)
end

def main() -> Void
  results = Task.map([1, 2, 3, 4], 2, 1000) do |n|
    slow_double(n)
  end
  puts(results)   # [ok(2), ok(4), ok(6), ok(8)], in about 200 ms, not 400
end
```

```text
Task.map(items: List[A], limit: Int, timeout_ms: Int, f: Fn[A, Result[R]]) -> List[Result[R]]
```

**Decisions:**

- **Parameter order.** The list, then `limit`, then `timeout_ms`, then the
  function, which is the trailing block:
  `Task.map(urls, 8, 5000) do |url| ... end`. It follows Elixir
  (`async_stream(enumerable, fun, max_concurrency: ..., timeout: ...)`) without
  keyword arguments (decided against, §25.13), and the library's habit of
  putting `timeout_ms` last (`File.open(path, mode, timeout_ms)`, and its block
  form `File.open(path, mode, timeout_ms) do |f|`, §25.9). Both numbers are
  required, with no defaults: a good limit and timeout depend on the work, and
  the agent must choose them.
- **The block returns `Result[R]`.** The work `Task.map` is for (HTTP, files,
  processes) already returns `Result`, so `Fn[A, R]` would give
  `List[Result[Result[T]]]`. With one level, the block's own `error(...)` and a
  timeout are both one `error` in the list. A block that cannot fail returns
  `ok(x)`. A block that returns `error("task: timed out")` itself looks the same
  as a timeout; this is accepted, since both mean the item gave no value. `try`
  works in the block by a small checker rule for builtins whose block result is
  `Result[T]` with `T` inferred, which this item or `File.open` with a block
  (§25.9, roadmap 15i) adds, whichever lands first: `R` comes from the expected
  type of the call if there is one, or else from the body, and `try` works even
  when `R` is inferred, since the outer type is always `Result`.
  `File.each_line` (27.4, row 7.2.1h, built before this item) has a fixed
  `Result[Void]` block and adds only the completion-value check and its help. A
  block whose result is not a `Result` is `CHECK-TYPE-MISMATCH` at its last
  expression, with a help that shows `ok(...)`.
- **Not a method.** It is always `Task.map(...)`. Methods come from the
  receiver's module, so `xs.map` stays `List.map`, the sequential one; `Task`
  owns concurrency.
- **Order.** Items start in input order. At most `limit` run at once; when one
  ends, the next item starts (a sliding window, as in Elixir, not batches). The
  result list is in input order, whatever order the items end in. There is no
  unordered mode (Elixir's `ordered: false`): a program that wants results as
  they end uses a channel (27.2).
- **Timeout per item**, as in Elixir. `timeout_ms` counts from the moment that
  item's task starts until it ends: its waits for I/O, its turns on the CPU, and
  the time it waits in the run queue while other tasks run. An item that runs
  out of time is cancelled (below) and its slot gets `error("task: timed out")`.
  There is no total timeout: a call takes at most about ⌈n / limit⌉ ×
  `timeout_ms`, plus the time other tasks hold the CPU. A total deadline would
  be a second number for the same need; a program that needs a shorter bound
  uses a smaller per-item timeout.
- **Errors do not stop the others.** Each item gets its own `Result`, and an
  item's `error(...)` does not cancel the rest. Partial success is the normal
  case for I/O (fetch 100 pages, 3 fail), and a fail-fast mode would be a second
  form with its own cancel rules. A caller that must stop at the first error
  checks the list (`results.all? do |r| r.ok? end`). A runtime diagnostic in an
  item (a bug, such as `RUNTIME-INDEX-OUT-OF-RANGE`) is a crash of that item's
  task: with task crash isolation
  (crash isolation, roadmap phase 24,
  which lands before 17a), the item's slot gets `error("task crashed: ...")`,
  its descendants are cancelled and the other items go on (task rules).
- **Cancellation.** The caller cannot leave a `Task.map` call early: it waits
  until every item has ended, and an `error` result does not stop it. So
  in-flight items stop early only at their own timeout, or when the run ends
  (`main` returns, a diagnostic in `main`, `System.exit`), which already stops
  every task. The rules when an item is cancelled:
  - Its task and every task it spawned that is still running (its descendants)
    are cancelled. The work of a timed-out item is everything it started, so it
    leaves nothing behind that still prints or spends steps.
  - "Descendants" holds even when a task in between has ended: when a task ends,
    its children that are still running move to its parent. So a grandchild
    still running after its own parent ended is a child of the item, and is
    cancelled with it. The other choice, a walk up the ancestors of every
    running task at each cancel, was not taken: moving children at the end of a
    task is O(its children) once, and a cancel then only walks down.
  - `Task.map` items are children of the task that called `Task.map`. If that
    caller is itself cancelled (it is an item of an outer `Task.map` that timed
    out, or a descendant of one), its group is marked dead: no pending item
    starts, the in-flight items are cancelled as the caller's children, their
    timers are closed, and their slots are never written and never wake the
    caller. So a `Task.map` inside an item that is cancelled has its in-flight
    items cancelled with it, its pending items never start, and an item that
    ends normally hands its still-running children to the caller, like any task
    that ends.
  - A cancelled task runs no more user code. A wait for a handle's lock, for
    `Task.await` or on a channel (27.2) leaves its queue; if the task was the
    next owner of a handle's lock, or held a channel reservation, that passes to
    the next waiter (27.2, "Waiters are served in order").
  - An I/O operation in flight is detached, never abandoned with a close: it
    finishes or times out on its own deadline as if its task were still there,
    and its result is dropped. It never closes the handle, so a timed-out item
    cannot close a handle that other items share. The handle's lock stays with
    the operation until it ends, as today, and then passes to the next waiter.
  - Handles the cancelled task opened are closed with it (phase 24b:
    `finish_task` closes what a task owns when it returns, crashes or is
    cancelled), so a timed-out item does not leak them, whatever form opened
    them. The plan here said that they stay open until the end of the run; 24b
    came first and changed it. The pooled connection of an `HTTP.get` or
    `HTTP.request` is not owned by the item: it is closed, not put back in the
    pool, when the detached job ends, since its state is unknown. The skill
    teaches: open the handles inside the item; do not share a handle across
    `Task.map` items; give a handle that many tasks need to one owner task
    (27.5).
  - `Task.await` on a cancelled task halts with `RUNTIME-TASK-CANCELLED` at the
    call, for an await made after the cancel and for one already parked on the
    task (built in 20b, `docs/vm/10-io-scheduler.md` §10.2.1, with its C test
    and diagnostics line). A program can reach it only through a handle that a
    descendant passed out, which needs a channel, so its program-level tests (in
    `tests/test_vm_task_map.py`, since they depend on an item timing out) came
    with 17a, which has `Task.map`; 17b has a crash-based golden fixture (§27.2,
    "Tests").
- **No public cancel.** `Task.cancel` is not added: per-item timeouts and
  channel timeouts cover the known uses, and a cancel call would be a second way
  to stop work. Section 8 keeps it open until a program needs it. `Task.await`
  with a timeout (27.3) bounds the wait only and cancels nothing.
- **Limits.** `limit` is 1 to 1024; otherwise `RUNTIME-INVALID-COUNT` at the
  `limit` argument. 1024 bounds the tasks and timers of one call, and matches a
  common open-file limit (`ulimit -n`) and the `--schedulers` cap. `timeout_ms`
  must be positive; otherwise `RUNTIME-INVALID-DURATION` at the argument, the
  code of a negative `Task.sleep`. Both are bugs in the program, not I/O
  failures, so they are diagnostics, not `error` results. Both arguments are
  checked before any item starts, and before the empty-list shortcut, so
  `Task.map([], 0, 1000)` is `RUNTIME-INVALID-COUNT`. An empty list with valid
  arguments returns `[]` and starts nothing; a `limit` larger than the list
  starts every item at once. The skill says in one sentence: `limit` is for I/O;
  CPU work does not get faster on one core, and since the per-item clock
  includes the time an item waits in the run queue, a large `limit` over CPU
  work makes timeouts more likely, not the work faster.
- **Nesting.** An item may call `Task.map`; each call has its own limit, so the
  limits multiply.
- **Values.** Items, captured variables and results are immutable, so the tasks
  share them without copies. A block may capture a handle (a file, a socket, a
  channel); handles keep their per-handle lock (§10.2.2).
- **BDD.** `Task.map` ends all its items before it returns, so it can be used in
  a step handler. Only the items are sure to be done: an item that ended
  normally after spawning a task it did not await leaves that task running, like
  any unawaited task, and the handler then fails with
  `RUNTIME-BDD-PENDING-TASKS` as today.
- **Effects:** `concurrency`, like `Task.spawn`.

**Costs and turns.** Each item is its own VM task, so the turn rules of
`docs/vm/10-io-scheduler.md` §10.2.1 apply unchanged: an item that loops on the
CPU is switched out after its turn budget, and timers and I/O stay responsive.
Starting an item costs one step on the shared `--max-steps` counter, like a
callback of `Range.each`, and its block costs its own steps, so a `Task.map`
where no item times out has a fixed step count. Steps an item spends before it
is cancelled stay spent, and their number depends on timing. **The golden
rule:** every golden fixture records its step count and runs the `--max-steps`
sweep (`tests/vm-diff-common.rkt`), so a golden fixture's step count and output
must not depend on timing. Golden fixtures therefore have no timeout that races
with work (no item that times out, no timed await whose outcome depends on the
clock, no receive loop that may retry), and their sleeps stay in the tens of ms.
Every case whose outcome depends on a timeout firing goes in a C test or in
`tests/test_vm_task_map.py`. The caller spends no steps while it waits.
Building the result list charges one turn unit per item (`AGC_COST_SIZE` on the
result), like `Range.to_a`.

**Speed-ups: I/O now, CPU later.** On today's VM (one scheduler), `Task.map`
speeds up I/O-bound work: while one item waits for the network, a file, a
process or a timer, others run, so n requests of d ms take about ⌈n / limit⌉ × d
instead of n × d. CPU-bound work does not get faster on one scheduler: items
take turns on one core, and the total is the same, plus the switches. Once the
multicore schedulers land (`docs/vm/10-io-multicore.md` §10.2.3, decided at
order step 11), the items are ordinary ready tasks, so idle schedulers pull them
from the global run queue (§16), and a CPU-bound `Task.map` uses up to
`min(limit, N)` cores with no change to the program. `Task.map` is then the one
way to spread CPU work over a list across cores. A CPU-bound `Task.map` program
joins round 2 of the cross-language benchmarks (phase 12), as evidence for that
decision.

**Where it lives: a C builtin in the VM, not prelude code.** The std-first rule
([roadmap](../roadmap/README.md#new-library-features-std-first)) is for pure
computation over types that exist. `Task.map` is runtime work: it schedules
tasks, starts timers (exception 1 of the rule: time) and cancels tasks. It also
cannot be prelude code on the primitives, and it should not wait for the
prelude:

- With `Task.spawn` and `Task.await` (even with 27.3's timeout) there is no way
  to wait for whichever item ends first (to keep `limit` items running) and no
  way to cancel a task. A prelude version would first need a public cancel, a
  second way to stop work ("No public cancel").
- Channels (27.2) do not close the gap: a pool of `limit` workers that read
  items from one channel and send indexed results to another gives bounded
  concurrency and input order, but not the per-item timeout. A receive with a
  timeout stops only the waiter, not the work, so a timed-out item would keep
  its worker busy and keep running. So `Task.map` is not built on channels.
- The prelude starts at order step 8.2, after faster lists (8d), because of its
  cost contract. As a builtin, `Task.map` builds its result list in C, needs no
  8d, and lands at order step 7.3.

It is generic in `A` and `R` and takes a block, which a `std/` module could not
be anyway (no user generics).

**VM design.**

- `Task.map` is a builtin appended to the VM's builtin table, with no new opcode
  and no bytecode format bump (as `File.eof?` will be, §25.9). It checks
  `limit`, then `timeout_ms`, then builds a group object in GC memory: the
  items, the function, the next index, a results array of n slots, the number
  running, the limit, the timeout and the caller. It starts the first
  `min(limit, n)` items and parks the caller with retry, as `Task.await` of a
  running task does (§10.2.1, "As built").
- Each item is a task whose entry calls the function on the item (as
  `Task.spawn` does), with a timer-only job for its deadline (like the handle
  lock's deadline, §10.2.2). When an item ends, its result goes into its slot,
  its timer is closed, and the next item starts. When the timer fires first, the
  item is cancelled, its slot gets the timeout error, and the next item starts.
  When the last slot is filled, the caller is woken; on its retry it builds the
  result list.
- **Task cancellation.** Its core landed earlier, in 20b, because
  `HTTP.close_server` must cancel handlers. It is specified as built in
  `docs/vm/10-io-scheduler.md` §10.2.1 and §10.2.2 (the parent and children
  links, `agc_task_cancel` for every task state, detached I/O jobs, the
  `next_owner` hand-on, the move of a finished task's children to its parent,
  `RUNTIME-TASK-CANCELLED` for an await of a cancelled task) and tested in
  `vm/tests/task_cancel_test.c`. This item adds only the state of a task parked
  as the caller of a `Task.map`: its group is marked dead, so no pending item
  starts; its in-flight items are cancelled as its children, their timers are
  closed, and a late end or timeout of an item writes no slot and wakes nobody.
  27.2 adds the channel waiters. With one scheduler, timer callbacks run between
  turns, so the cancelled item is never in the middle of a turn. With N
  schedulers, cancel uses the cancel flag and wake of §10.2.3 ("Cancel and stop
  flags"), so a CPU-bound item stops within one turn budget, and each slot is
  written once, under the group's small lock (never held across a park), by
  whichever comes first: the item's end or its timeout.
- **Await cycles.** Once channels exist (27.2), a task can receive its own
  handle (a `Channel[Task[R]]`, or a closure that captures a handle), so the
  premise of `docs/vm/10-io-scheduler.md` §10.2.1, "a task can only await tasks
  created before it, so awaits form no cycle", no longer holds. Forbidding
  `Task` as a channel element type would not be enough, since a closure can hide
  a handle. So `Task.await` checks: each task waits on at most one task, so
  before it parks, the VM follows the chain target, the task the target awaits,
  and so on; if the chain reaches the caller, the call halts with a new stable
  code, `RUNTIME-TASK-AWAIT-CYCLE`, at the `Task.await` span. A task that awaits
  its own handle is the shortest cycle. The walk is O(length of the chain), and
  chains are short. The timed form of the await (27.3) takes no part: it does
  not run the check, and a task that waits with a timeout is not a link of the
  chain. A cycle through the caller of a `Task.map` is not caught (an item
  awaits the task that called `Task.map`, which waits on its group, not in an
  await): it ends with that item's timeout instead, which is harmless. With N
  schedulers, each task's "awaiting" field is written before it parks, under the
  target's lock (§10.2.3, "Park and wake protocol"), so two tasks that close a
  cycle at the same time cannot both miss it: the second to take the lock sees
  the first's field. 17b adds the check, since 17b makes cycles possible; its
  text replaces the premise in §10.2.1 ("As built", stall check), and the
  sentence "Without channels, a parked task waits on I/O, a timer, or another
  live task" in §10.2.1 ("Fairness with I/O") gains "or a channel, with a
  timer".
- The stall check (§10.2.1) stays a guard against VM bugs: while items run, the
  caller waits on live tasks, each item holds a timer, every channel wait holds
  a timer (27.2), and await cycles halt with `RUNTIME-TASK-AWAIT-CYCLE` before
  they park.

**Diagnostics and help.** No new codes in 17a (`RUNTIME-TASK-AWAIT-CYCLE` comes
with 17b). These forms get a help, through the hint table of `grammar.md` §7
(today each is `CHECK-UNKNOWN-NAME`, "unknown function"):
`Task.async_stream(...)` and `Parallel.map(...)` (a Ruby gem) show
`Task.map(items, limit, timeout_ms) do |x| ... end`; `Task.async(...)` shows
`Task.spawn(&f, arg)`.

**Tests** (VM only):

- Checker tests with codes and spans: the block's parameter type from the list;
  `try` in the block with and without an expected type; a block that does not
  return a `Result` (`CHECK-TYPE-MISMATCH` with the `ok(...)` help);
  `CHECK-ARITY`; `Task.map([], ...)` (`CHECK-EMPTY-LIST-TYPE` at the literal, as
  for `List.map`); the hints of 27.1 and `Thread.new` (27.5).
- Golden fixtures (`tests/fixtures/vm/*.expected`): results in input order when
  items end in reverse order (sleeps of 30, 20 and 10 ms, with a `timeout_ms`
  far above them); an item's `error` next to `ok` items; an empty list
  (`empty: List[Int] = []`, then `Task.map(empty, 2, 1000) do |n| ok(n) end`
  gives `[]`); `limit` larger than the list; `limit` 0 and 1025
  (`RUNTIME-INVALID-COUNT` at the argument span); `empty: List[Int] = []`, then
  `Task.map(empty, 0, 1000) do |n| ok(n) end` (`RUNTIME-INVALID-COUNT`, the
  arguments are checked first); `timeout_ms` 0 (`RUNTIME-INVALID-DURATION` at
  the argument span); a diagnostic inside an item (its slot is
  `error("task crashed: ...")` and the other items give `ok`); a nested
  `Task.map`; the step count of a 1,000-item call with no timeouts.
- A Python timing test, `tests/test_vm_task_map.py`, like
  `tests/test_vm_latency.py`: `PY_ALONE` in the Makefile keeps it out of
  directory runs, so `make test`'s parallel batch skips it; a `make vm-task-map`
  target runs it alone; the CI `test` job runs it right after `make vm-latency`;
  the Commands section of `AGENTS.md` has the target; it skips when
  `AGENTICA_VM_BINARY` names another binary; it uses lower bounds that cannot be
  flaky and generous upper bounds.
  It holds every timing-dependent case of 27.1 and 27.2 (27.3's goldens and C
  tests do not depend on the clock): items print `start i` and `end i`; at no
  point are more than `limit` items between their `start` and `end`, and at some
  point exactly `limit` are; 8 items that sleep 250 ms with `limit` 2 take at
  least 1 s; with `limit` 8 they take well under the 2 s of a serial run.
- Timeout and cancellation, in `tests/test_vm_task_map.py`: an item that sleeps
  60 s with `timeout_ms` 200 gives `error("task: timed out")` while the other
  items give `ok`, and the run ends within a few seconds; the timed-out item's
  line after its sleep never prints; a task it spawned that would print after
  500 ms never prints (main sleeps 1 s after the call before it returns). A
  grandchild: an item spawns a child that spawns a grandchild and ends at once;
  the grandchild would print after 500 ms; the item times out at 200 ms, and the
  grandchild never prints. A nested `Task.map` with `limit` 1 over several
  items, inside an item that times out while the first nested item runs: the
  nested items print `start i` and, after a sleep, `end i`; only the first
  `start` is printed, no `end`, and none of the pending items ever prints. A
  detached read: two items share one TCP socket to a local Python peer on port 0
  that sends a line after 1 s and another after 1.5 s; the first item reads with
  a long operation timeout, times out as an item at 200 ms, and its read is
  detached (a socket read is an external job on the loop,
  `docs/vm/10-io-scheduler.md` §10.2.2, so it really is in flight; a file on a
  FIFO is not used, since `File.open` rejects special files); the socket is not
  closed, the second item gets the second line, and the first line, read by the
  detached job, is dropped.
- Hermetic I/O, in `tests/test_vm_task_map.py`: `Task.map` over HTTP requests
  to a local Python `http.server.ThreadingHTTPServer` counterpart on port 0
  (standard library only, as AGENTS.md asks; threaded, so the requests really
  overlap) whose handler sleeps 300 ms per request: 8 requests with `limit` 8
  take well under the 2.4 s of a serial run, and every body arrives in input
  order. A timed-out HTTP item leaves no open socket: one request's handler
  sleeps 2 s while its item times out at 300 ms; `main` waits 3 s, and the
  Python server sees that connection closed by the client (not kept in the
  pool).
- A C test of the group logic and of `agc_task_cancel` on a task parked as a
  `Task.map` caller (the group is dead: no pending item starts, in-flight items
  are cancelled, a late item end writes no slot), added to
  `vm/tests/task_cancel_test.c`. The other cancel states (a ready task, a timer,
  an I/O job, a handle lock and its `next_owner`, `Task.await` before and after
  the cancel, the move of a finished task's children) are tested there by 20b,
  so they are not planned twice.

**Docs:** `grammar.md` ("Lightweight tasks", the §7 hint table), the programming
skill (`references/tasks.md`, the "one way for each job" table, the `limit`
sentence and the handle rules above), `site/content/library/concurrency/task.md`
and `site/content/tour/tasks.md` (runnable examples whose output does not depend
on timing), `docs/vm/10-io-scheduler.md` §10.2.1 and §10.2.2 (task cancellation,
detached jobs, the `next_owner` hand-on), `docs/vm/10-io-multicore.md` §10.2.3
(the group lock), the development skill's notes (`references/vm-tasks.md`
and `references/vm-io.md`).

**As built (17a).** `vm/task_map.c` (core layer) and
`docs/vm/10-io-scheduler.md` §10.2.1, "Task.map", describe the code. It follows
the plan above, with these choices where the plan left room or changed:

- One timer, not one timer-only job for each item. The caller, parked in a
  stepper (as `File.each_line` is), starts one `agc_wait_io` job for the oldest
  deadline and, when it wakes, expires every item whose deadline has passed.
  Every item has the same timeout and starts in input order, so the deadlines
  grow along the running list. The caller also does all the spawning and
  cancelling, in its own turns, so the random streams split in input order.
- No `dead` flag. A cancelled caller never runs its step function again, and its
  items are cancelled children-first; the end hook of an item ignores an item
  that is `cancelled`, so no slot is written and nobody is woken. Late ends
  cannot reach the group.
- An item that ends after its deadline but before the caller runs keeps its
  result (accepted by the owner in the review of the PR). The plan's per-item
  timer callback would have cancelled it between turns; with one timer on the
  caller, an item that was already ready (for example a receiver that got its
  value) runs first. Nothing is lost either way. The hand-off case of §27.2
  keeps its sketched form only as a C test of the channel; its `Task.map` form
  holds the CPU in one sort past the deadline and checks that the item keeps the
  value.
- An item is settled, as for `Task.await`, only when it is done and has no file
  close pending (`closing` is 0). If its files are still closing, the end hook
  puts itself back on the task and `agc_task_close_done` calls it again when the
  last close ends, so a file that an item wrote is closed (and its lock
  released) when the call returns. This holds for an item that ended in time. A
  timed-out item is settled at its deadline and the call does not wait for its
  close, so the file of such an item may still be closing when the call returns
  (the close ends on its own and the hook then finds a settled item and does
  nothing). A crash of an item settled that way is marked observed, since
  nobody will read it.
- The handles an item opened are closed when it ends or is cancelled (24b),
  which the plan did not know; see the cancellation rules above.
- Costs: one step for each item started (`agc_count_step`), and `agc_charge(n)`
  on the result list.
- Checker: the block of `Task.map` gets the expected type `Result[R]` taken from
  the expected `List[Result[R]]`, else `Result[Unknown]`, and `check_block_body`
  turns `Result[Unknown]` into the `Slot.InferResult` slot. A first value of
  `error(...)` has nothing to infer from, so it is `CHECK-RESULT-TYPE` and the
  program annotates the variable (`r: List[Result[Int]] = Task.map(...)`). A
  later improvement could treat a first `return error(...)` as `Result[Unknown]`
  and let a later `ok(...)` decide `R`.
- Tests: the timing cases are in `tests/test_vm_task_map.py` (a Python module,
  since Racket is gone), run alone by `make vm-task-map`.

### 27.2 Channels

This finalizes the earlier channel proposal: a bounded buffer that tasks
send values into and receive values from, so producer and consumer pipelines
work.

```agentica
def send_all(jobs: Channel[Int]) -> Result[Void]
  for n in 1..5
    try jobs.send(n, 1000)
  end
  return ok()
end

def produce(jobs: Channel[Int]) -> Result[Void]
  result = send_all(jobs)
  jobs.close
  return result
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(2)
  producer = Task.spawn(&produce, jobs)
  total = 0
  while true
    case jobs.recv(1000)
      ok(n) -> total += n
      error(_) ->
        if jobs.closed?
          break
        end
    end
  end
  puts(total)                  # 15
  puts(Task.await(producer))   # ok()
end
```

This is the canonical receive loop: on an error, `closed?` says whether the
stream has ended; if not, the error was a timeout, and the loop receives again.
It ends only because the producer closes the channel on every path: `produce`
puts the sending in its own function, so a `try` that returns early from
`send_all` still reaches `jobs.close`.

```text
Channel.new(capacity: Int) -> Channel[T]
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
Channel.close(channel: Channel[T]) -> Void
Channel.closed?(channel: Channel[T]) -> Bool
```

All but `new` are also methods (`jobs.send(v, 1000)`, `jobs.recv(1000)`,
`jobs.close`, `jobs.closed?`); `Channel.new` has no channel to be called on.
Against the earlier proposal: `new` takes a capacity, `send` and `recv` take a
timeout and return a `Result`, and `close` and `closed?` are added.

**Rules:**

- **Type.** `Channel[T]` is a builtin opaque generic, like `Task[T]`. A channel
  value is a handle: assigning or passing it shares the same channel. `Channel`
  becomes a reserved type and module name, a breaking change: a user
  `struct Channel`, `enum Channel` or `import ... as Channel` becomes
  `CHECK-REDEFINED-NAME`, as for `Range` and `Set` (and 8c's `Queue`).
- **Element type.** `T` is any type a variable can have, so not `Void`
  (`CHECK-VOID-TYPE`, as for a `List[Void]`; use `Nil` or `Bool` for a plain
  signal). `Fn`, `Task` and handles (files, sockets, processes, other channels)
  are allowed: handing a socket to a worker is a main use (an accept loop sends
  each connection to a pool of workers). The shared table of §13 rejects them
  because it is a mutable store that many tasks read again and again; a channel
  only moves a value from one task to another, and the GC handles cycles. Since
  a task can now receive its own handle, `Task.await` checks for await cycles
  (27.1, "Await cycles").
- **`Channel.new`** needs an expected type, from an annotated variable, a
  parameter, a field or a return: `jobs: Channel[String] = Channel.new(16)`.
  Without one: `CHECK-EXPECTED-TYPE` at the call, a new code ("this call needs
  an expected type"), with a help that shows the annotated form. The code is
  general, so `Table.new` (§13) can use it too.
- **Capacity** is 1 to 1,048,576 (the cap of `List.repeat` and `Range.to_a`);
  otherwise `RUNTIME-INVALID-COUNT` at the argument. Channels are bounded only:
  an unbounded channel lets a fast producer fill memory, while a full buffer
  slows the producer down to the consumer's speed (backpressure). There is no
  capacity 0 (Go's unbuffered rendezvous): capacity 1 is close enough, and one
  form is enough.
- **`send`.** If the channel is open and has a free slot, the value is added at
  the back and the call returns `ok()` at once. If it is full, the task waits
  until a slot is free for it, the channel is closed, or `timeout_ms` passes. It
  returns `error("channel: closed")` if the channel is closed before or during
  the wait, and `error("channel: timed out")` at the timeout; in both cases the
  value is not added.
- **`recv`** returns the oldest value as `ok(v)`. If the channel is empty and
  open, the task waits until a value is handed to it, the channel is closed, or
  the timeout passes. It returns `error("channel: closed")` when the channel is
  closed and drained, and `error("channel: timed out")` at the timeout. Values
  sent before `close` are still received after it. A closed channel with an
  empty buffer but a value still reserved for a woken receiver is not drained: a
  `recv` on it waits, as on an open empty channel, until the reservation
  resolves (the value is taken, or it comes back to the buffer and this `recv`
  may get it) or its own timeout passes.
- **Timeouts are required.** `timeout_ms` is 0 or more: 0 means do not wait (try
  once and return). A negative value is `RUNTIME-INVALID-DURATION` at the
  argument, as for `Task.sleep`. There is no "wait forever" value, on purpose: a
  single call never hangs, since tasks that wait on each other through channels
  (a deadlock) get timeout errors, and every task that waits on a channel holds
  a timer, so the VM's stall check (§10.2.1) stays a guard against VM bugs only.
  A worker that must wait as long as needed uses the receive loop above. That
  loop retries on a timeout, so if the producer never closes the channel, the
  loop polls forever: the program hangs while it keeps running, and the stall
  check cannot see it, since the loop is not parked. This is why the close rule
  below exists. A diagnostic in `main` ends the whole run. With several
  producers, or a producer that may crash, each producer returns a
  `Result` and a coordinator awaits them all and then closes the channel: a
  crashed producer gives the coordinator an `error`, so the close still happens
  (task rules). With one producer, `Task.spawn_owning(&produce, jobs)` makes it
  the
  owner of the channel: the channel is closed when that task ends in any way, a
  crash or a cancel included, so the receive loop does not wait for a producer
  that died (handle ownership).
- **`close`** marks the channel closed and returns `Void`; closing again does
  nothing. Waiting senders get the closed error; so do woken senders that hold a
  reserved slot but have not run yet: `close` revokes their reservations, since
  nothing can be added after a close, and their `send` returns
  `error("channel: closed")`. Waiting receivers get the values left and then the
  closed error. Any holder may close it, also a channel that has an owner (the
  owner's end then closes nothing more). The rule the skill teaches: the
  producer closes, consumers never do, and the producer closes on every path,
  errors included. It puts the sending in its own function and closes after it
  (`result = send_all(jobs)`, then `jobs.close`, then `return result`), so a
  `try` that returns early still closes. With several producers, one coordinator
  awaits all of them and then closes (the fan-in pattern). No `Task.done?` is
  added for consumers to check a producer instead: 27.3 leaves it out under the
  one-way rule.
- **`closed?`** is `true` when the channel is closed and drained: `close` was
  called, the buffer is empty, and no value is reserved for a woken receiver
  that has not run yet (a reservation can go back to the buffer if that receiver
  is cancelled). Once it is `true` it stays `true`, since nothing can be added
  after a close, so it is exact: after a `recv` error, `closed?` tells the end
  of the stream (`true`) from a timeout (`false`) without matching error text. A
  closed channel that still holds values answers `false`, and the next `recv`
  returns a value.
- **Waiters are served in order.** Values come out in the order they went in
  (FIFO). Waiting receivers are served in the order they started waiting, and so
  are waiting senders, with no barging:
  - When a value arrives and receivers are waiting, the head receiver is popped
    from the FIFO and the value is reserved for it (a direct hand-off); it does
    not go into the buffer, so a task that calls `recv` before the woken one
    runs cannot take it. The woken receiver returns it when it runs.
  - When a value leaves a full buffer and senders are waiting, the freed slot is
    reserved for the head sender, which is popped and woken; it adds its value
    when it runs.
  - A woken waiter that leaves without completing hands its reservation on: it
    was cancelled (27.1), or its timeout was recorded before the reservation
    reached it (the first of the two to reach a waiter wins; a waiter whose
    reservation came first returns the value even if its deadline passes before
    it runs). A reserved value passes to the next waiting receiver, or, if there
    is none, goes back to the head of the buffer, in send order with the other
    values that went back (so FIFO holds when several receivers are cancelled,
    in any order); a reserved slot passes to the next waiting sender, or becomes
    free. A slot also frees when a woken sender hands its value straight to a
    waiting receiver instead of adding it, and then it passes to the next
    waiting sender too.
- **No lost values.** A value is in exactly one place: the sender's call (until
  it returns `ok()`), the buffer, or a receiver's reservation. So a cancelled
  receiver never loses a value, and a cancelled sender never adds one.
- **No `==`, no text, no JSON**, as for `Task`: `puts`, `print`, interpolation
  and `==` on a channel are `CHECK-TYPE-MISMATCH`, `.to_s` is
  `CHECK-UNKNOWN-METHOD`, JSON encoding is `CHECK-NOT-ENCODABLE`, and
  `IO.inspect` prints `<Channel>`.
- **Lifetime.** A channel belongs to the run, like a task handle: the GC frees
  it when nothing refers to it, and using it from another execution halts with
  `RUNTIME-TASK-CONTEXT`, the code planned for task handles, since both are
  concurrency handles and are fixed the same way. On the VM one run is one
  execution, and after phase 21 each BDD scenario is its own VM run whose steps
  share one execution (`docs/bdd.md`, "How a run works"), so BDD gives no way to
  reach this case; a channel created in a step program's `main` is fresh in each
  scenario.
- **Effects:** `send`, `recv` and `close` carry `concurrency`, like
  `Task.spawn`; `new` and `closed?` have none.
- **Left out**, each until a real program needs it: `select` over several
  channels (fan-in uses one channel of an enum type, `Channel[Event]` with one
  variant per source, and each source sends into it; a coordinator awaits all
  the sources and then closes it); `for x in channel` (a second way to write the
  receive loop); unbounded and rendezvous channels; broadcast; `size` (its
  answer is stale at once with other tasks); `try_send` and `try_recv` (a
  timeout of 0); separate send-only and receive-only types.

**Is `Task.map` built on channels?** No (27.1, "Where it lives"): a channel
cannot stop a timed-out item's work. And channels do not replace `Task.map`: for
"the same I/O for each item of a list", `Task.map` is the one form; channels are
for flows of unknown length, long-lived workers and results in the order they
end.

**Where it lives.** C builtins in `vm/channel.c`, under exception 4 of the
std-first rule (its own memory layout in the runtime), and because `send` and
`recv` park tasks, which only the scheduler can do. Front end: catalog entries
in `src/builtins.rkt`; in `src/checker.rkt`, the reserved name, `Channel[T]` as
a receiver type for methods (`resolve-method`), the expected-type rule of `new`,
and the rules for printing, `==` and JSON. No lowering change.

**VM design.**

- A channel is a GC object: the capacity, a ring buffer that grows by doubling
  up to the capacity (so `Channel.new(1048576)` does not allocate a million
  slots at once), the closed flag, and two FIFOs of waiting tasks (senders and
  receivers), kept like the handle lock's FIFO (§10.2.2). A waiting receiver has
  a reservation field for a handed-off value; a waiting sender has a flag for a
  reserved slot. Each accepted value gets a send sequence number, kept in its
  ring slot and in the receiver's reservation, so a value that goes back is
  inserted at the head by it. The ring can hold more than the capacity only by
  values handed back from cancelled receivers, at most one per task that held a
  reservation; senders still wait while the count plus the reserved slots is at
  or above the capacity, so the extra values drain as receivers take them, and
  nothing is lost.
- A call that must wait parks with retry on a timer-only job that ends at its
  deadline, set at the first wait and kept across retries, as `agc_handle_wait`
  does (§10.2.2); it is the same job kind as the lock's, so the I/O trace skips
  its `done` and `timeout` lines (its `start` and `detach` lines print
  `kind=lock`) and the metrics skip it (§28). A timeout of 0 never parks. A wake
  pops the head waiter and gives it its reservation (above); `close` wakes all.
  Each call is amortized O(1): a value is one pointer, never copied, and when
  the ring grows, the copy of its slots is charged as a turn cost (one unit per
  slot, §10.2.1, "Builtins"); other calls charge none.
- Cancellation (27.1): a cancelled waiter leaves its FIFO, its timer job is
  closed, and a reservation it holds is handed on as above. The same hand-on
  applies to the handle lock's `next_owner` (27.1, VM design).
- This item adds the await-cycle check (`RUNTIME-TASK-AWAIT-CYCLE`, 27.1, "Await
  cycles"), since channels make cycles possible.
- Stall check: still not reachable by a program, since every channel wait holds
  a timer and await cycles halt before they park. The text of §10.2.1 ("there
  are no channels and no way to pass a task its own handle") changes to say so.
- **The parking pattern.** A channel wait follows the pattern of the handle lock
  wait (`agc_handle_wait`, §10.2.2): a FIFO of waiters, a timer-only job for the
  deadline, a reservation given to the head waiter, and a hand-on when a woken
  waiter leaves without using it. Every parked channel wait has a deadline
  ("Timeouts are required"). It differs from the lock in three points, so it is
  not `agc_handle_wait` reused as is: a timeout of 0 tries once instead of
  failing; a waiter whose reservation came first keeps it past its deadline; and
  a woken waiter that leaves for any reason (cancel or timeout) hands its
  reservation on ("Waiters are served in order"). Row 7.2.1f (stdout and stderr
  on the loop) builds on the same pattern; its buffering, ordering and deadline
  are fixed in its own spec.
- **With N schedulers** (§16.5): each channel has a short lock, taken by `send`,
  `recv`, `close`, the wakes, the hand-on and a cancelled waiter that leaves its
  FIFO, and never held across a park. Ring growth copies the slots under the
  lock: an accepted exception, bounded by the capacity and charged as turn cost.
  It orders the write of a value before its read on another scheduler. A wake or
  hand-on is a scheduler waker that reaches the waiter's timer job: under the
  channel lock it takes the job's reference and sets the outcome by the CAS of
  §16.5 rule 3; if the timer wins instead, the timer side takes the channel lock
  before it pushes the task, and a wake or hand-on that lost passes the value or
  slot to the next waiter, so nothing is lost.
- The builtins are appended to the builtin table: no new opcode and no format
  bump.

**Tests** (VM only):

- Checker tests with codes and spans: `Channel.new(4)` without an expected type
  (`CHECK-EXPECTED-TYPE`); `Channel[Void]` (`CHECK-VOID-TYPE`); a `send` of the
  wrong type (`CHECK-TYPE-MISMATCH` at the value); `puts(ch)`, `ch == ch` and
  `JSON.encode` of a struct with a channel field; `struct Channel` and
  `import ... as Channel` (`CHECK-REDEFINED-NAME`); the methods on a
  `Channel[T]` receiver; the hints of 27.5.
- Golden fixtures (no timeout races, as the golden rule of 27.1 asks; receive
  loops use timeouts far longer than the run, so they never retry): FIFO order;
  a full channel with `send` timeout 0 (an error, and `closed?` is `false`); an
  empty channel with `recv` timeout 0; a closed channel that still holds values
  (`closed?` is `false`, and `recv` returns the values), then the closed error
  once it is drained, with `closed?` `true`; `send` after `close`; capacity 0
  and 1,048,577 (`RUNTIME-INVALID-COUNT` at the argument); a negative timeout
  (`RUNTIME-INVALID-DURATION` at the argument); a pipeline (a producer, three
  workers with the canonical receive loop, and a collector that sorts by index,
  so the output does not depend on timing); fan-in through a `Channel[Event]`
  enum, where a coordinator task awaits every source task and then closes the
  channel, so the consumer's loop ends; a deadlock (two tasks that each wait,
  with a 20 ms timeout, to receive from the other, and nothing is ever sent)
  that always ends with timeout errors, not `RUNTIME-INTERNAL`; two receivers
  cancelled by their parents' crashes, whose reserved values come back in send
  order.
- In `tests/test_vm_channel.py` (unittest, with a Python peer): a socket handed
  to a worker over a channel, against a local Python TCP counterpart on port 0.
- `RUNTIME-TASK-CANCELLED` without `Task.map` (a golden fixture): a task spawns
  a child, sends the child's handle to `main` over a channel, then crashes; the
  crash cancels the child, and `main`'s `Task.await` on it halts with the
  code at its span. The cancel of a parked channel waiter is a case in
  `vm/tests/task_cancel_test.c` (§14.3: a new kind of wait adds its case there).
- Await cycles: a task that receives its own handle over a channel and awaits it
  halts with `RUNTIME-TASK-AWAIT-CYCLE` at the `Task.await` span; for two tasks
  that each receive the other's handle and await it, the second `Task.await`
  halts with the code, and the first task gets that crash as the error of its
  await; a closure that captures a handle gives the same as the first case.
- `RUNTIME-TASK-CANCELLED` (these land with 17a, which has `Task.map`), in
  `tests/test_vm_task_map.py`, since both depend on an item timing out: a
  `Task.map` item spawns a child and sends the child's handle over a channel; in
  one case `main` awaits the handle after the item timed out, in the other
  `main` is already parked in that `Task.await` before the item times out. Both
  halt with the code at `main`'s `Task.await` span.
- Hand-off in order. With 17a, in `tests/test_vm_task_map.py` (it depends on
  timing, so it is not a golden fixture): receiver 1 is a `Task.map` item
  waiting in `recv`; the sender sends one value and then, in the same turn, runs
  one long builtin that outlasts the item's remaining time, so the item's
  deadline fires after the reservation and before receiver 1 runs; receiver 1 is
  cancelled, and receiver 2, which started waiting after receiver 1, still gets
  the value before its own timeout. The same case runs deterministically as a C
  test; so do a reservation that goes back to the head of the buffer when no
  receiver is left, and a reserved send slot handed to the next sender. Those
  three C tests are 17b's and need no `Task.map`.
- A C test of the ring buffer (growth and its turn cost, wrap-around, the
  capacity) and of the wait FIFOs, with the two late-reservation races: `close`
  while a value is reserved for a woken receiver (`closed?` stays `false` until
  that receiver takes it, and if it is cancelled instead, the value goes back to
  the buffer and is still received), and `close` while a woken sender holds a
  reserved slot (its `send` returns the closed error and the value is not
  added). Two more cases: the values of two cancelled receivers come back in
  send order, whichever was cancelled first; and a woken sender whose value goes
  straight to a waiting receiver passes its slot to the next waiting sender.
- When the multicore schedulers land, the channel and await-cycle fixtures join
  their `--schedulers 4` stress run under TSan.

**Docs:** `grammar.md` ("Lightweight tasks", or a new "Channels" part next to
it; the reserved names; the §7 hint table), the programming skill
(`references/tasks.md` with the canonical receive loop and the pipeline, fan-in
and owner-task patterns, and `references/diagnostics.md` for
`CHECK-EXPECTED-TYPE`, `RUNTIME-TASK-AWAIT-CYCLE` and `RUNTIME-TASK-CANCELLED`
on the VM), `site/content/library/concurrency/task.md` or a new
`site/content/library/concurrency/channel.md` (front matter `title` and
`weight`, runnable examples), `site/content/tour/tasks.md`,
`docs/vm/10-io-scheduler.md` §10.2.1 (the stall-check text, the await-cycle
check) and §10.2.2 (channel waits and reservations),
`docs/vm/10-io-multicore.md` §10.2.3 (the channel lock), the development skill's
notes. Section 8 then points here and keeps only its open questions.

### 27.3 `Task.await` with a timeout

**Status: built** (roadmap 17c). The owner decided on 2026-10-14 to build it now
as a C builtin that returns a new builtin enum, `Await[T]`. This replaced the
earlier plan (decided on 2026-10-12): prelude code over a helper task, a
capacity-1 channel and two prelude-only builtins (`__task_settled?` and
`__task_wait`), returning `Result[T]`. That plan needed lambdas (15e) and the
prelude (15f), which wait for the bootstrap, and it made a timeout an `error`
next to the `error("task crashed: ...")` of a crashed task and a
`Result[Result[U]]` for a task that returns a `Result`.

Wait for a task's result, but not longer than `timeout_ms`.

```agentica
def slow(n: Int) -> Int
  Task.sleep(5000)
  return n * 2
end

def main() -> Void
  task = Task.spawn(&slow, 21)
  case Task.await(task, 100)
    Await.Done(n) -> puts(n)
    Await.TimedOut -> puts("not yet")
  end
  puts(Task.await(task))              # 42, after the rest of the 5 s
end
```

```text
Task.await(task: Task[T], timeout_ms: Int) -> Await[T]

enum Await[T]
  Done(T)
  TimedOut
end
```

`Await[T]` is a builtin generic enum: it behaves like a user enum declared in
the program, and a user cannot declare one with that name.

**Decisions:**

- **A second arity of `Task.await`, not a new name.** The one-way test (§25
  Principle) rejects forms that only rename or re-spell an existing call. This
  one adds behavior: the wait is bounded, and the result says whether it ended
  in time. Waiting forever stays `Task.await(task)`, and waiting at most N ms is
  `Task.await(task, timeout_ms)`, so each job still has one form. The builtin
  catalog already selects signatures by arity (`Map.get` with 2 or 3 arguments,
  `File.open` with a block in §25.9), and agents know the pattern from it. A
  separate name (`await_timeout`, `wait`) would be two names for "await", which
  agents would mix up.
- **A timeout is a normal outcome, so it is not an error.** The result is
  `Await[T]`, not `Result[T]`, because a timeout is not a failure of the task:
  the task is fine, and the answer is "not yet". A dedicated type keeps it apart
  from a crash (`error("task crashed: ...")` when `T` is a `Result`) and
  from the `error` a task returns itself, and it avoids `Result[Result[U]]` for
  a task that returns `Result[U]`: that task gives `Await.Done(ok(5))`,
  `Await.Done(error("..."))` or `Await.TimedOut`, three cases that cannot be
  mixed up. `try` does not apply to an `Await` (it is not a `Result`):
  `try Task.await(t, 10)` is `CHECK-TYPE-MISMATCH`.
- **Matching.** A program matches it with `case`, like a user enum:
  `Await.Done(n) -> ...` and `Await.TimedOut -> ...`, the nullary variant
  without parentheses. Exhaustiveness is checked as for a user enum
  (`CHECK-NON-EXHAUSTIVE-CASE` for a missing arm, `CHECK-UNREACHABLE-CASE-ARM`
  after a catch-all), and `Await.Done(n)` binds `n` with the task's result type.
  `Await.Done(7)` and `Await.TimedOut` are also values that a program may write
  (for a test double, say), with the same inference rules as a user enum
  (`Await.TimedOut` alone needs an expected type: `CHECK-ENUM-TYPE-INFERENCE`).
  `IO.inspect`, `to_s` and interpolation print it as an enum value:
  `Await.Done(42)`, `Await.TimedOut`.
- **`T = Void`.** A `Task[Void]` gives `Await[Void]`. `Done` carries no value,
  and it is matched as `Result[Void]` is: `Await.Done(_)` discards the payload
  (a named binding is `CHECK-VOID-TYPE`, "a Void payload must be discarded with
  _", as `Result.Ok(_)` is), and a program cannot write the value
  `Await.Done(...)` for `Void`. It prints as `Await.Done()`, like `ok()`.
  `Await[Void]` cannot be written as a type annotation (`CHECK-VOID-TYPE`, as
  for any enum), but a variable gets it by inference.
- **A timeout does not cancel the task.** On a timeout the call returns
  `Await.TimedOut`, and the target keeps running. A later `Task.await(task)` or
  `Task.await(task, timeout_ms)` on the same task is valid: `grammar.md`
  ("Lightweight tasks") says await returns the cached result and may be
  repeated, and that does not change. The caller is not halted, and it is not
  affected by what happens to the target afterwards: if the target later crashes
  or is cancelled, the caller, which already has its answer, goes on. A crash
  that no await observed stays unobserved (the summary at the end of the run,
  cancellation), and a later await observes it as it does today. So a program
  can wait a
  bit, do other work, and wait again. Stopping the work is `Task.map`'s per-item
  timeout; a public `Task.cancel` stays open (see 27.6).
- **A settled task never times out.** The call checks whether the target has
  already settled (ended, or been cancelled, and its owned files closed, handle
  ownership)
  before it waits, and again when its wait times out; in both cases it returns
  the target's outcome, not a timeout. So a small timeout on a task that is
  done, or that ended while the CPU was busy with other tasks, still gives
  `Await.Done(v)`.
- **`timeout_ms` must be positive**; otherwise `RUNTIME-INVALID-DURATION` at the
  `timeout_ms` argument, checked before anything else, also for a settled
  target. "Has it finished?" without any wait is not part of this item.
- **Errors.** The target's outcome is what the plain `Task.await` gives. If the
  target ends in time, the call returns `Await.Done(v)` (`Await.Done(_)` for a
  `Task[Void]`). If it crashed and `T` is a `Result`, the call returns
  `Await.Done(error("task crashed: CODE at FILE:LINE:COLUMN: MESSAGE"))`; for
  any other `T` the caller halts with `RUNTIME-TASK-CRASHED` at the call. Either
  way the crash is now observed. If the target is cancelled (or was cancelled
  before the call) and `T` is a `Result`, the call returns
  `Await.Done(error("task: cancelled"))`; for any other `T` the caller halts
  with `RUNTIME-TASK-CANCELLED` at the call, at once, also when the target is
  cancelled while the caller waits (27.1). If the call already returned
  `Await.TimedOut`, a later crash or cancel of the target does not touch the
  caller.
- **No await cycles.** The timed form never waits forever, so it takes no part
  in the cycle check of 27.1 ("Await cycles"), and a timeout never halts the
  caller. A task that awaits its own handle with a timeout, or two tasks that
  await each other with timeouts, wait out the timeout and get `Await.TimedOut`.
  A task that waits with a timeout is not a link of the chain that the plain
  `Task.await` walks (the walk stops at it, since `await_deadline` is set while
  the task waits), so a plain await that reaches it does not halt: if A awaits B
  with `Task.await(b)` and B awaits A with `Task.await(a, 20)`, B times out and
  ends, and then A gets B's result. The plain form keeps its check: a plain
  await that would close a cycle of plain awaits halts with
  `RUNTIME-TASK-AWAIT-CYCLE`.
- **Effects:** `concurrency`, like the plain form.

**Where it lives: a C builtin in `vm/task.c`.** This is an exception to "helpers
in Agentica" (the top of this section), and it is the owner's decision of
2026-10-14. The reason is the one the rule gives for `Task.map`: the timeout
lives in the scheduler, where one rule decides how a task waits (a timer on the
job, `docs/vm/14-core-invariants.md` §14.2), and it needs the target's waiter
list, which no Agentica code can reach without a helper task. The builtin is two
entries of the table, `Task.await` with arity 2 and `Task.await_result` with
arity 2 (lowering picks the second when `T` is a `Result`, as it does for arity
1, the VM design). No opcode and no format change: the entries are appended to
the
builtin table.

How the wait works (`docs/vm/10-io-scheduler.md` §10.2.1, "Await with a
timeout"):

- The call checks `timeout_ms` (`RUNTIME-INVALID-DURATION`), takes itself off
  the waiter list of the task it waited on, if it was woken by its timer, and
  looks at the target. If the target is settled it returns `Await.Done`.
  Otherwise it computes the deadline once (there is no cycle check, see "No
  await cycles") and keeps it in the task (`await_deadline`, as a channel wait
  keeps its deadline), joins the target's waiter list as the plain await does,
  starts a timer job with the time left (the one wait job of the lock and
  channel waits, `agc_wait_io`), and parks with retry.
- Two things can wake it, and whichever comes first wins. If the target ends,
  `finish_task` wakes the waiters as it does today; the caller re-runs,
  `agc_io_finish` closes the timer job, and the call returns `Await.Done`. If
  the timer fires, the scheduler wakes the caller; it re-runs, leaves the
  target's waiter list, clears `awaiting` and the deadline, and returns
  `Await.TimedOut`, unless the target settled meanwhile, which is checked first.
  A woken task whose deadline has not come (a wake is only a hint, §10.2.3)
  waits again for the time left.
- The losing side is cleaned up by the winner, so nothing leaks and nobody wakes
  twice: the timer is closed when the caller resumes after the target ended; the
  waiter is removed from the target's list when the caller resumes after the
  timer; a wake of a task that is already ready does nothing (`agc_task_wake`
  ignores it).
- Cancelling a caller that waits (§14.3) needs no new case in `agc_task_cancel`:
  `unlink_task` already detaches the task's timer job (it ends at once, since a
  timer-only job has no work) and takes the task off the target's waiter list
  through `awaiting`. `vm/tests/task_cancel_test.c` adds the case.
- Turn and step accounting is the plain await's: the call is one builtin call,
  `AGC_COST_NONE`, with no cycle walk. A call on a settled target starts no
  timer and does not touch the event loop.

How `Await[T]` reuses the enum machinery: no special case per site.

- `src/builtin-types.rkt` holds a table of builtin enum declarations (`Await`,
  type parameter `T`, `Done(T)` and `TimedOut`). The checker starts with them in
  its table of enums, so type annotations (`Await[Int]`), constructors,
  patterns, exhaustiveness and printing all take the user-enum paths, and the
  name is in the checker's reserved type names: a user `struct Await`,
  `enum Await`, an enum type parameter `Await`, or `import Await from "..."` is
  `CHECK-REDEFINED-NAME`, as for `Range` and `Channel`. The module linker leaves
  `Await` unmangled in every module and reads `Await.TimedOut` and
  `Await.Done(...)` as enum constructors.
- The catalog row of `Task.await` has a second signature (`Task[R]`, `Int`) with
  the rule `task-await-timeout`, which gives the type `Await[R]` and checks
  `timeout_ms` as an `Int`.
- Lowering appends the `Await` enum to the program's enum table when the program
  mentions it (a type, a constructor, a pattern, or an expression of that type,
  as it does for the builtin structs such as `HttpResponse`), after the user
  enums, so user variant numbers do not change. The C builtin finds its two
  variants by name, `Await.Done` with one field and `Await.TimedOut` with none
  (`agc_builtin_variant`, next to `agc_builtin_struct`), and builds the value
  like the `ENUM` opcode does (`TimedOut` is the shared value of its variant). A
  file that calls the builtin without that enum fails with `RUNTIME-INTERNAL`.
  `vm/text.c` prints an enum whose only field is a `Void` as `Await.Done()`.

**Await cycles and the stall check.** The caller holds a timer while it waits,
so the stall check (§10.2.1) is unchanged: every wait has a job or a live task.
The call does not run the cycle check, and the plain check skips a task that
waits with a timeout, so a timed await adds no way to a
`RUNTIME-TASK-AWAIT-CYCLE`, and a plain await never halts because of one. A
timed waiter always holds a timer, so the stall check still only guards VM bugs.

**BDD.** There is no helper task, so `RUNTIME-BDD-PENDING-TASKS` and
`Task.pending_count` are not affected: a timed-out await leaves only the target,
which is the program's own task.

**Costs.** One timer job for each call that parks, and none for a call on a
settled target. A loop that calls `Task.await(task, 10)` again and again leaves
no waiter behind: each call removes itself from the target's list. The skill
teaches one call with the whole timeout the program can afford, not a polling
loop, and says that a timeout does not stop the task.

**Tests** (nothing depends on the clock: a target that must not finish waits on
a channel nobody has sent to yet, and a timeout that must not fire is 10
seconds): golden fixtures (`await-timeout`: a timeout, the caller goes on, then
the value; a settled task with a 1 ms timeout; the catch-all arm; `IO.inspect`,
`to_s` and interpolation; `await-timeout-void`: `Await.Done(_)` and
`Await.Done()`; `await-timeout-crash`: a crashed `Result` task gives
`Await.Done(error("task crashed: ..."))` and a plain crashed task halts with
`RUNTIME-TASK-CRASHED` at the call; `await-timeout-late-crash`: a crash after a
timeout leaves the caller running and is unobserved until the next await;
`await-timeout-invalid`: `timeout_ms` 0 and -1 are `RUNTIME-INVALID-DURATION` at
the argument, also for a settled target; `await-timeout-cancelled`:
`Await.Done(error("task: cancelled"))`, a watcher halted with
`RUNTIME-TASK-CANCELLED` while it waited, and the caller that already got a
timeout going on; `await-timeout-cycle`: a task that awaits its own handle with
a timeout gets `Await.TimedOut`, a plain await of a task that awaits it back
with a timeout ends with that task's result, and two tasks that await each other
with timeouts both time out; the plain cycles keep their own fixture,
`task-await-cycle`). Checker tests (`tests/checker-test.rkt`): the type of the
call, missing and unreachable arms, an unknown variant, a wrong payload type,
`Await.Done(n)` on a `Void` payload, `try` on an `Await`, the arity and argument
types, and `CHECK-REDEFINED-NAME` for `struct Await`, `enum Await` and a type
parameter `Await`; `tests/modules-test.rkt` (`import ... as Await`);
`tests/parser-test.rkt` (the help for `Await.Done()`); `tests/bytecode-test.rkt`
(the `Result` entry is picked for arity 2, and the enum is in the program only
when used). C tests (`vm/tests/task_cancel_test.c`): a caller cancelled while it
waits leaves the target's list and its timer is closed; a timeout leaves the
list and clears the deadline; a target that ends first closes the 30-second
timer (the loop is not alive at the end of the test). **Docs:** `grammar.md`
("Lightweight tasks" and the builtin and reserved-name lists), the programming
skill (`references/tasks.md`: a timeout does not stop the task, one call and not
a polling loop, how to match `Await`),
`site/content/library/concurrency/task.md` and `tour/tasks.md`, the development
skill's notes, `docs/vm/10-io-scheduler.md` §10.2.1.

### 27.4 Streams: `File.each_line` and `Stream[T]`

**Decision:** two steps, decided by the owner on 2026-10-14. Step 1 is
`File.each_line`, a C builtin that reads a big file line by line in bounded
memory and adds no type (roadmap 17d, order row 7.2.1h, built). Step 2 is
`Stream[T]`, a lazy recipe over sources such as lines, written in the prelude
(roadmap 17e, order step 8.2).

The owner judged that streaming without loading everything is needed: Python
iterators and Ruby `yield` cover it, and Agentica's loop and channel forms are
too much ceremony to compose. This replaces the earlier criteria for planning
streams (a real program first, then a narrower fix). The rules that stay are at
the end of this section.

**Step 1: `File.each_line` (roadmap 17d, order row 7.2.1h).** A C builtin,
VM-only, with a block for each line:

```text
File.each_line(path: String, buffer_bytes: Int, timeout_ms: Int) do |line: String| ... end -> Result[Void]
```

```agentica
def print_lines(path: String) -> Result[Void]
  return File.each_line(path, 65536, 1000) do |line|
    puts(line)
    ok()
  end
end
```

- **Reads.** It opens the file, reads it in blocks of at most `buffer_bytes`
  bytes, and calls the block once for each line, in order. One read fills the
  buffer; every complete line in it goes to the block, one by one, before the
  next read. A partial line at the end of the buffer moves to the front, and the
  next read fills the rest. So memory stays at about `buffer_bytes`, whatever
  the file size, and one read serves many lines, so there are far fewer reads
  than one `File.read_line` per line.
- **Lines.** A line, with its LF or CRLF, is at most `buffer_bytes` bytes. A
  longer line ends the call with
  `error("filesystem: line exceeds buffer_bytes")` (the `filesystem:` prefix of
  the other file errors), and the buffer never grows. LF or CRLF is removed, as
  in `File.read_line`. A last line without a newline is still passed. Lines are
  strict UTF-8, as in `File.read_text`; invalid text ends the call with an
  error.
- **Limits.** `buffer_bytes` is 1,024 to 16,777,216 (16 MiB); otherwise
  `RUNTIME-INVALID-COUNT` at the argument, checked before the file is opened.
  `timeout_ms` bounds each read, the open and the close, not the whole call: a
  10 GB file may take as long as it needs while each block arrives in time. A
  `timeout_ms` of 0 or less is not a diagnostic: the call returns
  `error("filesystem: timeout must be positive milliseconds")`, which every file
  call returns (`vm/files.c`, `bad_timeout`).
- **Block.** The block returns `Result[Void]`. `ok()` goes on; `error(e)` stops
  at once, and the call returns that error. `try` works in the block, as it does
  in a `Test.test` block: the block type is a fixed `Result[Void]`, so the
  checker knows what `try` returns from it. This item changes one thing: the
  block's last expression is checked as a completion value, so a Void or
  non-Result last expression is `CHECK-TYPE-MISMATCH` (not `CHECK-VOID-VALUE`)
  with the help `give a Result with ok() or error("message")`; the help shows
  for any mismatch with an expected `Result`. `try` in a block whose `T` is
  inferred (`Task.map`, §27.1; `File.open` with a block, §25.9) has no consumer
  in this item, so the first of those two adds it.
- **Result.** The call returns `ok()` at the end of the file, or the first
  error: open, read, timeout, a line too long, invalid UTF-8, or the block's
  error.
- **Close.** The file is closed whenever the call returns, for any reason, with
  the guarantee of `File.open` with a block (§25.9). A runtime diagnostic ends
  the run, which closes it as today.
- **Reads on the loop.** Reads follow §14.1, as other file reads do: a regular
  file is read by a pool job; a pipe, FIFO or character device that can wait is
  read non-blocking on the loop, as `File` reads of a FIFO already are
  (`docs/vm/10-io-scheduler.md` §10.2.2). The call is a resumable builtin
  (`docs/vm/03-ir-and-bytecode.md` §4.3, as `List.each` is): it parks on each
  read and calls the block between lines, so a block can wait on other tasks.
- **Effects:** `filesystem`, like the other file calls.
- **One way.** It replaces a composition of `File.open`, a loop, `eof?`,
  `read_line` and `close`, so it is the one form for that job. It adds no type.
- **Left out:** the same form for process and TCP lines (`Process.each_line`,
  `TCP.each_line`). Their handles already keep a read buffer in the VM, and each
  waits for its own item when a real program needs it.
- **Tests** (VM only, in the PR that builds it): golden fixtures for a small
  file, a last line without a newline, CRLF, an empty file, a block that stops
  early with `error`, a block that uses `try`, and the capacity error at the
  argument span. A Racket test reads a 10 MB file of short lines with
  `buffer_bytes` 4096, checking the line count and that the number of reads is
  about the file size over the buffer size (through the trace, if the
  development skill shows how). Also: a line longer than the buffer, invalid
  UTF-8, a FIFO fed by a Python stdlib peer (hermetic: a FIFO in a temporary
  directory), and the file closed after an early stop and after a timeout.
- **Docs:** `docs/grammar` (the builtins and the files section), the programming
  skill (`references/files.md` and the one-way table of this section),
  `site/content/library/io-and-system/files.md` with a runnable example, and
  `docs/vm/03-ir-and-bytecode.md` §4.3 and `docs/vm/10-io-scheduler.md` §10.2.1
  and §10.2.2, where the resumable builtins and the file reads are described.

**Step 2: `Stream[T]` (roadmap 17e, order step 8.2, after the prelude of 15f).**
The shape below is its base. Its checker and VM rules are added to this section
before its code lands, as 27.1 and 27.2 were.

- `Stream[T]` is a builtin opaque generic and an immutable recipe, not a cursor:
  building one does no work and opens nothing. Only a terminal step runs it, and
  two terminals on the same stream run its source twice. Elixir's streams are
  recipes too.
- Sources, only where a list cannot be:
  `Stream.lines(path, buffer_bytes, timeout_ms)`, the lines of a file by path,
  read with the block buffer of step 1; and an endless
  `Stream.iterate(seed, f)`. `Stream.unfold` waits for tuples (§12.5). Socket
  and process lines are an open question: a handle cannot be reopened, so a
  second run would go on where the first one stopped.
- Lazy steps: `map`, `filter`, `take(n)`, `take_while`. Terminals:
  `to_list(max)` (an error when the stream has more than `max` items, so an
  endless stream cannot fill memory), `each`, `reduce`. Terminals return a
  `Result`, and a read error of the source ends the terminal with that error.
- Resources: a file source opens its file when a terminal starts and closes it
  when the terminal returns, whether it reached the end, `take` or `take_while`
  had enough, a step returned an error, or a `try` failed in a block. That is
  the guarantee of `File.open` with a block (§25.9), with the terminal call as
  the block. A stream that is dropped without a terminal opened nothing, so
  nothing leaks. A runtime diagnostic ends the run, which closes the file as
  today.
- Costs: each element pulled costs one step plus its callbacks, like
  `Range.each`, and a terminal can be switched out between elements (a resumable
  native frame, §10.2.1).
- **Form.** Stream steps are methods on `Stream[T]`, since methods come from
  the receiver's module. So the one form of a step is `s.filter(f)`, and
  `s |> Stream.filter(f)` is `CHECK-PIPE-METHOD`, with the help `s.filter(...)`.
  A source is a plain call; `|>` is for user functions between them:

```agentica
def is_valid(line: String) -> Bool
  return line.length > 0
end

def add_length(total: Int, line: String) -> Int
  return total + line.length
end

def total_length(path: String) -> Result[Int]
  return Stream.lines(path, 65536, 1000).filter(&is_valid).take(1000).reduce(0, &add_length)
end
```

- **One form per job.** Each line of a file, in order, is `File.each_line`. A
  stream is for steps before a terminal (`filter`, `take`, `take_while`, `map`,
  `reduce`, `to_list`). A stream with no step before its terminal
  (`Stream.lines(path, ...).each`) is the same job as `File.each_line`; whether
  the checker rejects it, with a help that shows `File.each_line`, is decided in
  step 2's spec, as the principle of §25 asks.
- **Rules that stay.** Step 2 waits for the prelude (15f) and for faster lists
  (8d), since its steps are generic code over closures. Each step passes
  the one-way test against `List`: no `list.stream`, no `Range.stream`, and no
  step that only re-spells a `List` method over a source that a list can hold.
- **Generators stay decided against** (§27.5): a task that sends into a channel
  is the producer, and a stream is a recipe of fixed steps, not a producer with
  `yield`.

### 27.5 Decided against

Each of these is decided; it gets a help that names the Agentica form.

- **Generators and fibers:** Ruby's `Enumerator.new do |y| y << v end` with
  `e.next`, `Fiber.new` and `Fiber.yield`, and `yield` in Python or JavaScript.
  - A second way to write a producer: a task that sends into a channel is a
    generator, its capacity gives backpressure, and `next` is `recv`.
  - External iteration hides changing state inside a value (`e.next` changes
    `e`), and values are immutable.
  - Fibers are what tasks already are: green VM stacks that the scheduler
    switches.
  - `yield` is already decided against (§25.13: the block is a named `Fn`
    parameter, called with `.call`).
  - A lazy `Stream[T]` (27.4) is not a generator either: it is a recipe of fixed
    steps over a source, with no `yield`.
  - Help: `Enumerator.new(...)` and `Fiber.new(...)` (today
    `CHECK-UNKNOWN-NAME`) show a producer task that sends into a `Channel`
    (`Task.spawn(&produce, ch)`, then `ch.recv(timeout_ms)`). `xs.lazy` on a
    `List` or a `Range` (today `CHECK-UNKNOWN-METHOD`) shows that lists are
    eager, and that a source too big for a list is read in a `while` loop. Added
    by 17b.
- **Elixir `Agent` and other shared mutable accumulators:** `Agent.start_link`,
  `Agent.update` and `Agent.get`, Ruby's `Concurrent::AtomicFixnum`, or a
  counter that blocks change.
  - Shared mutable state, which the language does not have: values are
    immutable. The one exception is the `std/logger` registry (the grammar's
    logging section),
    which only the Logger functions reach; the shared table of §13 waits until a
    program needs it, with atomic calls. Unlike an `Agent`, the registry is not
    a value that programs hold: a program never gets a reference to it.
  - A second way to accumulate: in one task, `reduce` or a loop variable; across
    tasks, each task returns its part (`Task.await`, `Task.map`) and the caller
    combines the parts with `reduce`; state that lives while tasks run belongs
    to one owner task that receives messages on a channel. An Elixir `Agent` is
    itself a process that receives messages, so the owner task is the same idea,
    written with the language's own parts (example below).
  - Help: `Agent.start_link(...)` and the other `Agent` calls (today
    `CHECK-UNKNOWN-NAME`) show "return values from tasks and combine them with
    `reduce`, or keep the state in one task that receives on a `Channel`". A
    block that assigns to an outer variable keeps its
    `CHECK-CAPTURED-ASSIGNMENT` and its help (use `reduce` or a `for` loop).
    Added by 17b.
- **Public locks and threads:** `Mutex`, `Monitor`, `ConditionVariable`,
  semaphores, `Thread.new`, Ruby's `SizedQueue`.
  - With no shared mutable state there is nothing to lock (the `std/logger`
    registry is the one planned exception, and only the Logger functions read
    it); a lock held across a wait is also the classic deadlock, and agents get
    lock order wrong.
  - `Thread` is `Task`, and `SizedQueue` (a bounded, blocking queue) is
    `Channel`.
  - Help (today `CHECK-UNKNOWN-NAME`): `Thread.new` shows `Task.spawn(&f, arg)`;
    `Mutex.new` shows an owner task with a `Channel`; `SizedQueue.new` shows
    `Channel.new(capacity)`. `Thread.new` is added by 17a, the others by 17b.
- **Options on `Task.map`:** Elixir's `ordered: false`, `on_timeout:` and
  `zip_input_on_exit:`. Keyword arguments are decided against (§25.13), and each
  option is a second behavior of one call. `Task.map` has one: input order,
  per-item timeout, cancel on timeout.

**The owner task, in place of an `Agent`:**

```agentica
def count(inbox: Channel[Int]) -> Int
  total = 0
  while true
    case inbox.recv(1000)
      ok(n) -> total += n
      error(_) ->
        if inbox.closed?
          break
        end
    end
  end
  return total
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(64)
  counter = Task.spawn(&count, inbox)
  sent = Task.map(["a", "bb", "ccc"], 3, 1000) do |word|
    inbox.send(word.length, 1000)
  end
  inbox.close
  puts(sent.all? do |r| r.ok? end)   # true
  puts(Task.await(counter))          # 6
end
```

When the parts can simply be returned, returning them is the one form:
`Task.map(words, 3, 1000) do |w| ok(w.length) end`, then `reduce` over the
results.

### 27.6 Open questions

- **Resources over a channel.** Immutable values can be shared safely, but
  ports, sockets and contextual services carry state. A handle sent over a
  channel stays owned by the task that opened it; the ownership and
  synchronization rules for the others are open.
- **A diagnostic in a task other than `main`** ends only that task;
  `Result.error` stays a normal result.
- **A public `Task.cancel`.** This section cancels only the timed-out items of
  `Task.map`, and a cancel call would be a second way to stop work; returning
  from the entrypoint still cancels pending work.
- **Handles of a cancelled task** stay open until the end of the run (27.1).
  Whether a long-running program, such as a server, should close them when the
  task is cancelled is open. Until then open handles inside the item and do not
  share them across items.
- **`Process.poll_line(p: Process, timeout_ms: Int) -> Result[String]`** may
  come later, so a loop can alternate requests with polling child output. It is
  not part of the task work, and no application has needed it yet.

### 27.7 Implementation (rows 7.3, 8.2)

- 17a `Task.map` is built (PR #316); 17b channels, 17c `Task.await`
  with a timeout and 17d `File.each_line` are built (records in §27.1–
  §27.4 and the grammar). 17e `Stream[T]` (§27.4, step 2, order step
  8.2, after the prelude) is one item with its own tests and docs.
- Done when: the site examples run on the VM; timed-out items leave no
  open socket, task or shared handle; the pipeline, await-cycle and
  `Await.TimedOut` cases hold; and agents pick `Task.map` for fan-out
  and channels for pipelines (§27.5).

[task-rules]: ../grammar/06c-tasks-and-tests.md#lightweight-tasks
