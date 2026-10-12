## 27. Iteration and concurrent collections

**Status:** 27.1 (`Task.map`) and 27.2 (channels) are planned (roadmap phase 17) at order step 7.3, the first new features after 7i deletes the evaluator (order 7.2), on the C VM only. They come before strict diagnostics ([section 26](26-strict-diagnostics.md#26-strict-diagnostics), order step 7.6), so their examples, fixtures and site pages are written in today's forms, and each phase 16 PR counts and migrates them. 27.1 adds the checker rule for `try` in a block whose result is `Result[T]`, which `File.open` with a block (§25.9) reuses. 27.3 (`Task.await` with a timeout) is planned too, at order step 8.2: it is prelude code over channels, so it comes after 27.2 and after the compiler prelude (§25.6). 27.4 (lazy streams) is to evaluate later, with the criteria that would plan it. 27.5 records what was decided against (generators, fibers, Agent-style shared state, public locks), so it is not proposed again. This section finalizes the channel proposal of [section 8](08-concurrency.md#8-concurrency-and-parallelism) and answers [section 25.12.7](25-ruby-typed-idioms.md#25127-lazy-enumerators-and-generators).

**What is asked for:** something like Elixir's `Stream` and `Task.async_stream`, Ruby's iterators, generators and accumulators, and faster programs through concurrency.

**What exists today** (`grammar.md`, "Lightweight tasks", "Ranges", "Blocks and closures"): `Task.spawn`, `Task.await` and `Task.sleep` give I/O concurrency on one core (the VM runs one scheduler, `docs/vm/10-io-scheduler.md` §10.2.1). `List` and `Range` methods are eager; `for` over a range does not build a list; `reduce` is the accumulator. There are no channels, no lazy streams and no CPU parallelism. `Task.await` has no timeout, and a task cannot be cancelled.

**Rules.** Those of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms): one way to do each thing (its Principle and its test), values stay immutable with no shared mutable state, types stay static, and the users are LLM agents, who do best with one obvious form and an error whose help shows it.

**Primitives in C, helpers in Agentica.** The concurrency primitives are a small set of C builtins: `Task.spawn`, `Task.await`, `Task.sleep`, `Channel` (27.2) and `Task.map` (27.1). Higher-level concurrency helpers, such as `Task.await` with a timeout (27.3) and future ones such as "the first of several tasks" or "all settled", are written in Agentica in the compiler prelude (§25.6) over those primitives, as the [std-first rule](../roadmap/README.md#new-library-features-std-first) asks; they go in the prelude, not in `std/`, because they need the catalog's type variables. Each future helper still needs its own spec and must pass the one-way test. `Task.map` stays a C builtin because it must cancel timed-out items, which no primitive can do, and because it lands at order step 7.3, before the prelude (27.1, "Where it lives").

**One way for each job.** After this section, the programming skill teaches these forms, and only these, for each job. The skill updates of 17a and 17b teach only the rows whose forms exist when they land; each later item adds its own row:

| Job | The one form |
|---|---|
| Change, select or combine the items of a list | `List.map`, `filter`, `reduce` and the other `List` methods (eager) |
| Keep a running total, or build a value in a loop | `reduce`, or a `for` or `while` loop that reassigns a local variable |
| Run the same I/O for each item of a list, at most N at a time, each with a timeout | `Task.map` (27.1) |
| Long-lived workers, producer and consumer, a flow of unknown length, results in the order they end | tasks and a `Channel` (27.2) |
| Wait for a task's result, for at most N ms | `Task.await(task, timeout_ms)` (27.3); the task keeps running after a timeout |
| Read a big file line by line | `File.open` with a block (§25.9, once 15i lands) and a `while` loop over `File.read_line` |
| An endless sequence | a `while` loop |
| State that several tasks update | one owner task that receives messages on a channel (27.5); a shared table (§13) when a program needs it |

| § | Item | Decision | Where it lives | Roadmap |
|---|---|---|---|---|
| 27.1 | `Task.map` | planned | C builtin in the VM scheduler | 17a |
| 27.2 | `Channel[T]` | planned | C builtins, a builtin opaque generic | 17b |
| 27.3 | `Task.await(task, timeout_ms)` | planned | prelude code over `Channel` | 17c |
| 27.4 | Lazy `Stream[T]` | to evaluate later | none yet | none |
| 27.5 | Generators, fibers, Agent-style state, public locks and threads | decided against | help hints only, added by 17a and 17b | none |

### 27.1 `Task.map`

Elixir's `Task.async_stream` for a list: run a block for each item in its own task, at most `limit` at a time, each item with its own timeout, and get one `Result` per item, in input order.

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

- **Parameter order.** The list, then `limit`, then `timeout_ms`, then the function, which is the trailing block: `Task.map(urls, 8, 5000) do |url| ... end`. It follows Elixir (`async_stream(enumerable, fun, max_concurrency: ..., timeout: ...)`) without keyword arguments (decided against, §25.13), and the library's habit of putting `timeout_ms` last (`File.open(path, mode, timeout_ms)`, and its block form `File.open(path, mode, timeout_ms) do |f|`, §25.9). Both numbers are required, with no defaults: a good limit and timeout depend on the work, and the agent must choose them.
- **The block returns `Result[R]`.** The work `Task.map` is for (HTTP, files, processes) already returns `Result`, so `Fn[A, R]` would give `List[Result[Result[T]]]`. With one level, the block's own `error(...)` and a timeout are both one `error` in the list. A block that cannot fail returns `ok(x)`. A block that returns `error("task: timed out")` itself looks the same as a timeout; this is accepted, since both mean the item gave no value. `try` works in the block by a small checker rule for builtins whose block result is `Result[T]`, which this item adds: `R` comes from the expected type of the call if there is one, or else from the body, and `try` works even when `R` is inferred, since the outer type is always `Result`. The rule is general: `File.open` with a block (§25.9, roadmap 15i) reuses it. A block whose result is not a `Result` is `CHECK-TYPE-MISMATCH` at its last expression, with a help that shows `ok(...)`.
- **Not a method.** It is always `Task.map(...)`. Methods come from the receiver's module, so `xs.map` stays `List.map`, the sequential one; `Task` owns concurrency.
- **Order.** Items start in input order. At most `limit` run at once; when one ends, the next item starts (a sliding window, as in Elixir, not batches). The result list is in input order, whatever order the items end in. There is no unordered mode (Elixir's `ordered: false`): a program that wants results as they end uses a channel (27.2).
- **Timeout per item**, as in Elixir. `timeout_ms` counts from the moment that item's task starts until it ends: its waits for I/O, its turns on the CPU, and the time it waits in the run queue while other tasks run. An item that runs out of time is cancelled (below) and its slot gets `error("task: timed out")`. There is no total timeout: a call takes at most about ⌈n / limit⌉ × `timeout_ms`, plus the time other tasks hold the CPU. A total deadline would be a second number for the same need; a program that needs a shorter bound uses a smaller per-item timeout.
- **Errors do not stop the others.** Each item gets its own `Result`, and an item's `error(...)` does not cancel the rest. Partial success is the normal case for I/O (fetch 100 pages, 3 fail), and a fail-fast mode would be a second form with its own cancel rules. A caller that must stop at the first error checks the list (`results.all? do |r| r.ok? end`). A runtime diagnostic in an item (a bug, such as `RUNTIME-INDEX-OUT-OF-RANGE`) ends the whole run with its code and span, as a diagnostic in any task does today; `Task.map` does not catch it.
- **Cancellation.** The caller cannot leave a `Task.map` call early: it waits until every item has ended, and an `error` result does not stop it. So in-flight items stop early only at their own timeout, or when the run ends (`main` returns, a diagnostic, `System.exit`), which already stops every task. The rules when an item is cancelled:
  - Its task and every task it spawned that is still running (its descendants) are cancelled. The work of a timed-out item is everything it started, so it leaves nothing behind that still prints or spends steps.
  - "Descendants" holds even when a task in between has ended: when a task ends, its children that are still running move to its parent. So a grandchild still running after its own parent ended is a child of the item, and is cancelled with it. The other choice, a walk up the ancestors of every running task at each cancel, was not taken: moving children at the end of a task is O(its children) once, and a cancel then only walks down.
  - `Task.map` items are children of the task that called `Task.map`. If that caller is itself cancelled (it is an item of an outer `Task.map` that timed out, or a descendant of one), its group is marked dead: no pending item starts, the in-flight items are cancelled as the caller's children, their timers are closed, and their slots are never written and never wake the caller. So a `Task.map` inside an item that is cancelled has its in-flight items cancelled with it, its pending items never start, and an item that ends normally hands its still-running children to the caller, like any task that ends.
  - A cancelled task runs no more user code. A wait for a handle's lock, for `Task.await` or on a channel (27.2) leaves its queue; if the task was the next owner of a handle's lock, or held a channel reservation, that passes to the next waiter (27.2, "Waiters are served in order").
  - An I/O operation in flight is detached, never abandoned with a close: it finishes or times out on its own deadline as if its task were still there, and its result is dropped. It never closes the handle, so a timed-out item cannot close a handle that other items share. The handle's lock stays with the operation until it ends, as today, and then passes to the next waiter.
  - Handles the cancelled task opened stay open until the end of the run, as today: a timed-out item leaks the handles it opened, whatever form opened them (`File.open` with a block too, since no user code runs to close it). The one exception is a handle that a builtin opens inside itself and never returns to user code, such as the pooled connection of an `HTTP.get` or `HTTP.request`: it is closed, not put back in the pool, when the detached job ends, since its state is unknown. For long-running programs (servers) this is an open question in section 8. Until it is decided, the skill says plainly that a timed-out item's open handles leak until the run ends, and teaches: open handles inside the item and close them with the block forms (`File.open` with a block, §25.9, once 15i lands; until then, `File.close` on every path); do not share a handle across `Task.map` items; give a handle that many tasks need to one owner task (27.5).
  - `Task.await` on a cancelled task halts with `RUNTIME-TASK-CANCELLED` at the call, the code the evaluator already uses for awaiting cancelled work. This holds for an await made after the cancel and for one already parked on the task when it is cancelled: the parked waiters are woken, and on retry each halts at once at its own `Task.await` span. A program can reach it only through a handle that a descendant passed out, which needs a channel, so 17a adds this VM path with a C test, and its program-level tests (in `tests/vm-task-map-test.rkt`, since they depend on an item timing out) and its diagnostics doc line come with 17b.
- **No public cancel.** `Task.cancel` is not added: per-item timeouts and channel timeouts cover the known uses, and a cancel call would be a second way to stop work. Section 8 keeps it open until a program needs it. `Task.await` with a timeout is planned in 27.3; it bounds the wait only and cancels nothing.
- **Limits.** `limit` is 1 to 1024; otherwise `RUNTIME-INVALID-COUNT` at the `limit` argument. 1024 bounds the tasks and timers of one call, and matches a common open-file limit (`ulimit -n`) and the `--schedulers` cap. `timeout_ms` must be positive; otherwise `RUNTIME-INVALID-DURATION` at the argument, the code of a negative `Task.sleep`. Both are bugs in the program, not I/O failures, so they are diagnostics, not `error` results. Both arguments are checked before any item starts, and before the empty-list shortcut, so `Task.map([], 0, 1000)` is `RUNTIME-INVALID-COUNT`. An empty list with valid arguments returns `[]` and starts nothing; a `limit` larger than the list starts every item at once. The skill says in one sentence: `limit` is for I/O; CPU work does not get faster on one core, and since the per-item clock includes the time an item waits in the run queue, a large `limit` over CPU work makes timeouts more likely, not the work faster.
- **Nesting.** An item may call `Task.map`; each call has its own limit, so the limits multiply.
- **Values.** Items, captured variables and results are immutable, so the tasks share them without copies. A block may capture a handle (a file, a socket, a channel); handles keep their per-handle lock (§10.2.2).
- **BDD.** `Task.map` ends all its items before it returns, so it can be used in a step handler. Only the items are sure to be done: an item that ended normally after spawning a task it did not await leaves that task running, like any unawaited task, and the handler then fails with `RUNTIME-BDD-PENDING-TASKS` as today.
- **Effects:** `concurrency`, like `Task.spawn`.

**Costs and turns.** Each item is its own VM task, so the turn rules of `docs/vm/10-io-scheduler.md` §10.2.1 apply unchanged: an item that loops on the CPU is switched out after its turn budget, and timers and I/O stay responsive. Starting an item costs one step on the shared `--max-steps` counter, like a callback of `Range.each`, and its block costs its own steps, so a `Task.map` where no item times out has a fixed step count. Steps an item spends before it is cancelled stay spent, and their number depends on timing. **The golden rule:** every golden fixture records its step count and runs the `--max-steps` sweep (`tests/vm-diff-common.rkt`), so a golden fixture's step count and output must not depend on timing. Golden fixtures therefore have no timeout that races with work (no item that times out, no timed await whose outcome depends on the clock, no receive loop that may retry), and their sleeps stay in the tens of ms. Every case whose outcome depends on a timeout firing goes in a C test or in `tests/vm-task-map-test.rkt`. The caller spends no steps while it waits. Building the result list charges one turn unit per item (`AGC_COST_SIZE` on the result), like `Range.to_a`.

**Speed-ups: I/O now, CPU later.** On today's VM (one scheduler), `Task.map` speeds up I/O-bound work: while one item waits for the network, a file, a process or a timer, others run, so n requests of d ms take about ⌈n / limit⌉ × d instead of n × d. CPU-bound work does not get faster on one scheduler: items take turns on one core, and the total is the same, plus the switches. Once the multicore schedulers land (`docs/vm/10-io-multicore.md` §10.2.3, decided at order step 11), the items are ordinary ready tasks, so idle schedulers steal them, and a CPU-bound `Task.map` uses up to `min(limit, N)` cores with no change to the program. `Task.map` is then the one way to spread CPU work over a list across cores. A CPU-bound `Task.map` program joins round 2 of the cross-language benchmarks (phase 12), as evidence for that decision.

**Where it lives: a C builtin in the VM, not prelude code.** The std-first rule ([roadmap](../roadmap/README.md#new-library-features-std-first)) is for pure computation over types that exist. `Task.map` is runtime work: it schedules tasks, starts timers (exception 1 of the rule: time) and cancels tasks. It also cannot be prelude code (§25.6) on the primitives, and it should not wait for the prelude:

- With `Task.spawn` and `Task.await` (even with 27.3's timeout) there is no way to wait for whichever item ends first (to keep `limit` items running) and no way to cancel a task. A prelude version would first need a public cancel, a second way to stop work ("No public cancel").
- Channels (27.2) do not close the gap: a pool of `limit` workers that read items from one channel and send indexed results to another gives bounded concurrency and input order, but not the per-item timeout. A receive with a timeout stops only the waiter, not the work, so a timed-out item would keep its worker busy and keep running. So `Task.map` is not built on channels.
- The prelude starts at order step 8.2, after faster lists (8d), because of its cost contract. As a builtin, `Task.map` builds its result list in C, needs no 8d, and lands at order step 7.3.

It is generic in `A` and `R` and takes a block, which a `std/` module could not be anyway (no user generics).

**VM design.**

- `Task.map` is a builtin appended to the VM's builtin table, with no new opcode and no bytecode format bump (as `File.eof?` will be, §25.9). It checks `limit`, then `timeout_ms`, then builds a group object in GC memory: the items, the function, the next index, a results array of n slots, the number running, the limit, the timeout and the caller. It starts the first `min(limit, n)` items and parks the caller with retry, as `Task.await` of a running task does (§10.2.1, "As built").
- Each item is a task whose entry calls the function on the item (builtins that take a function run it as a new VM task, §10.2), with a timer-only job for its deadline (like the handle lock's deadline, §10.2.2). When an item ends, its result goes into its slot, its timer is closed, and the next item starts. When the timer fires first, the item is cancelled, its slot gets the timeout error, and the next item starts. When the last slot is filled, the caller is woken; on its retry it builds the result list.
- **Task cancellation** is new VM code that this item adds and 27.2 extends. Each task records its parent and a list of its running children (the tasks PR keeps none). `agc_task_cancel` marks a task and its running descendants cancelled:
  - a ready task leaves the run queue;
  - a task parked on an I/O job detaches from it: the job runs to its own end or deadline, keeps the handle's lock until then, and its `done` or `expired` half drops the result instead of storing it in a register (and does not close the handle for the dropped task);
  - a task waiting for a handle's lock leaves the FIFO; if it was the `next_owner`, ownership passes to the head waiter, which is woken, as at a release (§10.2.2);
  - a task in a `Task.await` leaves the target's waiters;
  - a task parked as the caller of a `Task.map`: its group is marked dead, so no pending item starts; its in-flight items are cancelled as its children, their timers are closed, and a late end or timeout of an item writes no slot and wakes nobody;
  - a task parked on a timer (`Task.sleep`): the timer is closed;
  - the tasks parked in `Task.await` on the cancelled task are woken, as when a task ends; on retry they see it cancelled and halt with `RUNTIME-TASK-CANCELLED` at their own `Task.await` span;
  - a cancelled task never runs again, and a later `Task.await` on it halts with `RUNTIME-TASK-CANCELLED`;
  - when any task ends, normally or cancelled, its running children are moved to its parent's list, so "descendants" stays right after a task in between has ended.

  With one scheduler, timer callbacks run between turns, so the cancelled item is never in the middle of a turn. With N schedulers, cancel uses the cancel flag and wake of §10.2.3 ("Cancel and stop flags"), so a CPU-bound item stops within one turn budget, and each slot is written once, under the group's small lock (never held across a park), by whichever comes first: the item's end or its timeout.
- **Await cycles.** Once channels exist (27.2), a task can receive its own handle (a `Channel[Task[R]]`, or a closure that captures a handle), so the premise of `docs/vm/10-io-scheduler.md` §10.2.1, "a task can only await tasks created before it, so awaits form no cycle", no longer holds. Forbidding `Task` as a channel element type would not be enough, since a closure can hide a handle. So `Task.await` checks: each task waits on at most one task, so before it parks, the VM follows the chain target, the task the target awaits, and so on; if the chain reaches the caller, the call halts with a new stable code, `RUNTIME-TASK-AWAIT-CYCLE`, at the `Task.await` span. A task that awaits its own handle is the shortest cycle. The walk is O(length of the chain), and chains are short. A cycle through the caller of a `Task.map` is not caught (an item awaits the task that called `Task.map`, which waits on its group, not in an await): it ends with that item's timeout instead, which is harmless. With N schedulers, each task's "awaiting" field is written before it parks, under the target's lock (§10.2.3, "Park and wake protocol"), so two tasks that close a cycle at the same time cannot both miss it: the second to take the lock sees the first's field. 17b adds the check, since 17b makes cycles possible; its text replaces the premise in §10.2.1 ("As built", stall check), and the sentence "Without channels, a parked task waits on I/O, a timer, or another live task" in §10.2.1 ("Fairness with I/O") gains "or a channel, with a timer".
- The stall check (§10.2.1) stays a guard against VM bugs: while items run, the caller waits on live tasks, each item holds a timer, every channel wait holds a timer (27.2), and await cycles halt with `RUNTIME-TASK-AWAIT-CYCLE` before they park.

**Diagnostics and help.** No new codes in 17a (`RUNTIME-TASK-AWAIT-CYCLE` comes with 17b). These forms get a help, through the hint table of `grammar.md` §7 (today each is `CHECK-UNKNOWN-NAME`, "unknown function"): `Task.async_stream(...)` and `Parallel.map(...)` (a Ruby gem) show `Task.map(items, limit, timeout_ms) do |x| ... end`; `Task.async(...)` shows `Task.spawn(&f, arg)`.

**Tests** (VM only):

- Checker tests with codes and spans: the block's parameter type from the list; `try` in the block with and without an expected type; a block that does not return a `Result` (`CHECK-TYPE-MISMATCH` with the `ok(...)` help); `CHECK-ARITY`; `Task.map([], ...)` (`CHECK-EMPTY-LIST-TYPE` at the literal, as for `List.map`); the hints of 27.1 and `Thread.new` (27.5).
- Golden fixtures (`tests/fixtures/vm/*.expected`): results in input order when items end in reverse order (sleeps of 30, 20 and 10 ms, with a `timeout_ms` far above them); an item's `error` next to `ok` items; an empty list (`empty: List[Int] = []`, then `Task.map(empty, 2, 1000) do |n| ok(n) end` gives `[]`); `limit` larger than the list; `limit` 0 and 1025 (`RUNTIME-INVALID-COUNT` at the argument span); `empty: List[Int] = []`, then `Task.map(empty, 0, 1000) do |n| ok(n) end` (`RUNTIME-INVALID-COUNT`, the arguments are checked first); `timeout_ms` 0 (`RUNTIME-INVALID-DURATION` at the argument span); a diagnostic inside an item (the whole run ends with its code and span); a nested `Task.map`; the step count of a 1,000-item call with no timeouts.
- A Racket timing test, `tests/vm-task-map-test.rkt`, planned like `tests/vm-latency-test.rkt`: it is listed in `test-omit-paths` in `tests/info.rkt`, so `make test`'s parallel batch skips it; a `make vm-task-map` target runs it alone; the CI `test` job runs it right after `make vm-latency`; the Commands section of `AGENTS.md` gets the target; it skips when `AGENTICA_VM` names another binary; it uses lower bounds that cannot be flaky and generous upper bounds. It holds every timing-dependent case of 27.1, 27.2 and 27.3: items print `start i` and `end i`; at no point are more than `limit` items between their `start` and `end`, and at some point exactly `limit` are; 8 items that sleep 250 ms with `limit` 2 take at least 1 s; with `limit` 8 they take well under the 2 s of a serial run.
- Timeout and cancellation, in `tests/vm-task-map-test.rkt`: an item that sleeps 60 s with `timeout_ms` 200 gives `error("task: timed out")` while the other items give `ok`, and the run ends within a few seconds; the timed-out item's line after its sleep never prints; a task it spawned that would print after 500 ms never prints (main sleeps 1 s after the call before it returns). A grandchild: an item spawns a child that spawns a grandchild and ends at once; the grandchild would print after 500 ms; the item times out at 200 ms, and the grandchild never prints. A nested `Task.map` with `limit` 1 over several items, inside an item that times out while the first nested item runs: the nested items print `start i` and, after a sleep, `end i`; only the first `start` is printed, no `end`, and none of the pending items ever prints. A detached read: two items share one TCP socket to a local Python peer on port 0 that sends a line after 1 s and another after 1.5 s; the first item reads with a long operation timeout, times out as an item at 200 ms, and its read is detached (a socket read is an external job on the loop, `docs/vm/10-io-scheduler.md` §10.2.2, so it really is in flight; a file on a FIFO is not used, since `File.open` rejects special files); the socket is not closed, the second item gets the second line, and the first line, read by the detached job, is dropped.
- Hermetic I/O, in `tests/vm-task-map-test.rkt`: `Task.map` over HTTP requests to a local Python `http.server.ThreadingHTTPServer` counterpart on port 0 (standard library only, as AGENTS.md asks; threaded, so the requests really overlap) whose handler sleeps 300 ms per request: 8 requests with `limit` 8 take well under the 2.4 s of a serial run, and every body arrives in input order. A timed-out HTTP item leaves no open socket: one request's handler sleeps 2 s while its item times out at 300 ms; `main` waits 3 s, and the Python server sees that connection closed by the client (not kept in the pool).
- A C test (`vm/tests/`) of the group logic and of `agc_task_cancel` on a ready task, a task parked on a timer (`Task.sleep`; the timer is closed), a task parked as a `Task.map` caller (the group is dead: no pending item starts, in-flight items are cancelled, a late item end writes no slot), a task parked on an I/O job (the job's result is dropped and the handle stays open), a task waiting for a handle lock, the `next_owner` of a handle lock (ownership passes to the next waiter), a task in a `Task.await`, tasks already parked in `Task.await` on the cancelled task (woken, then `RUNTIME-TASK-CANCELLED` at their own span), a later `Task.await` on the cancelled task (`RUNTIME-TASK-CANCELLED`), and the move of a finished task's running children to its parent.

**Docs:** `grammar.md` ("Lightweight tasks", the §7 hint table), the programming skill (`references/tasks.md`, the "one way for each job" table, the `limit` sentence and the handle rules above), `site/content/library/task.md` and `site/content/tour/tasks.md` (runnable examples whose output does not depend on timing), `docs/vm/10-io-scheduler.md` §10.2.1 and §10.2.2 (task cancellation, detached jobs, the `next_owner` hand-on), `docs/vm/10-io-multicore.md` §10.2.3 (the group lock), the development skill's notes (`references/vm.md`).

### 27.2 Channels

This finalizes the channel proposal of section 8: a bounded buffer that tasks send values into and receive values from, so producer and consumer pipelines work.

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

This is the canonical receive loop: on an error, `closed?` says whether the stream has ended; if not, the error was a timeout, and the loop receives again. It ends only because the producer closes the channel on every path: `produce` puts the sending in its own function, so a `try` that returns early from `send_all` still reaches `jobs.close`.

```text
Channel.new(capacity: Int) -> Channel[T]
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
Channel.close(channel: Channel[T]) -> Void
Channel.closed?(channel: Channel[T]) -> Bool
```

All but `new` are also methods (`jobs.send(v, 1000)`, `jobs.recv(1000)`, `jobs.close`, `jobs.closed?`); `Channel.new` has no channel to be called on. Against the section 8 proposal: `new` takes a capacity, `send` and `recv` take a timeout and return a `Result`, and `close` and `closed?` are added.

**Rules:**

- **Type.** `Channel[T]` is a builtin opaque generic, like `Task[T]`. A channel value is a handle: assigning or passing it shares the same channel. `Channel` becomes a reserved type and module name, a breaking change: a user `struct Channel`, `enum Channel` or `import ... as Channel` becomes `CHECK-REDEFINED-NAME` (say so in the changelog), as section 12 does for `Range`, `Set` and `Queue`.
- **Element type.** `T` is any type a variable can have, so not `Void` (`CHECK-VOID-TYPE`, as for a `List[Void]`; use `Nil` or `Bool` for a plain signal). `Fn`, `Task` and handles (files, sockets, processes, other channels) are allowed: handing a socket to a worker is a main use (an accept loop sends each connection to a pool of workers). The shared table of §13 rejects them because it is a mutable store that many tasks read again and again; a channel only moves a value from one task to another, and the GC handles cycles. Since a task can now receive its own handle, `Task.await` checks for await cycles (27.1, "Await cycles").
- **`Channel.new`** needs an expected type, from an annotated variable, a parameter, a field or a return: `jobs: Channel[String] = Channel.new(16)`. Without one: `CHECK-EXPECTED-TYPE` at the call, a new code ("this call needs an expected type"), with a help that shows the annotated form. The code is general, so `Table.new` (§13) can use it too.
- **Capacity** is 1 to 1,048,576 (the cap of `List.repeat` and `Range.to_a`); otherwise `RUNTIME-INVALID-COUNT` at the argument. Channels are bounded only: an unbounded channel lets a fast producer fill memory, while a full buffer slows the producer down to the consumer's speed (backpressure). There is no capacity 0 (Go's unbuffered rendezvous): capacity 1 is close enough, and one form is enough.
- **`send`.** If the channel is open and has a free slot, the value is added at the back and the call returns `ok()` at once. If it is full, the task waits until a slot is free for it, the channel is closed, or `timeout_ms` passes. It returns `error("channel: closed")` if the channel is closed before or during the wait, and `error("channel: timed out")` at the timeout; in both cases the value is not added.
- **`recv`** returns the oldest value as `ok(v)`. If the channel is empty and open, the task waits until a value is handed to it, the channel is closed, or the timeout passes. It returns `error("channel: closed")` when the channel is closed and drained, and `error("channel: timed out")` at the timeout. Values sent before `close` are still received after it. A closed channel with an empty buffer but a value still reserved for a woken receiver is not drained: a `recv` on it waits, as on an open empty channel, until the reservation resolves (the value is taken, or it comes back to the buffer and this `recv` may get it) or its own timeout passes.
- **Timeouts are required.** `timeout_ms` is 0 or more: 0 means do not wait (try once and return). A negative value is `RUNTIME-INVALID-DURATION` at the argument, as for `Task.sleep`. There is no "wait forever" value, on purpose: a single call never hangs, since tasks that wait on each other through channels (a deadlock) get timeout errors, and every task that waits on a channel holds a timer, so the VM's stall check (§10.2.1) stays a guard against VM bugs only. A worker that must wait as long as needed uses the receive loop above. That loop retries on a timeout, so if the producer never closes the channel, the loop polls forever: the program hangs while it keeps running, and the stall check cannot see it, since the loop is not parked. This is why the close rule below exists. A program that halts with a diagnostic ends the whole run, so it cannot leave a loop polling.
- **`close`** marks the channel closed and returns `Void`; closing again does nothing. Waiting senders get the closed error; so do woken senders that hold a reserved slot but have not run yet: `close` revokes their reservations, since nothing can be added after a close, and their `send` returns `error("channel: closed")`. Waiting receivers get the values left and then the closed error. Any holder may close it. The rule the skill teaches: the producer closes, consumers never do, and the producer closes on every path, errors included. It puts the sending in its own function and closes after it (`result = send_all(jobs)`, then `jobs.close`, then `return result`), so a `try` that returns early still closes. With several producers, one coordinator awaits all of them and then closes (the fan-in pattern). No `Task.done?` is added for consumers to check a producer instead: 27.3 leaves it out under the one-way rule.
- **`closed?`** is `true` when the channel is closed and drained: `close` was called, the buffer is empty, and no value is reserved for a woken receiver that has not run yet (a reservation can go back to the buffer if that receiver is cancelled). Once it is `true` it stays `true`, since nothing can be added after a close, so it is exact: after a `recv` error, `closed?` tells the end of the stream (`true`) from a timeout (`false`) without matching error text. A closed channel that still holds values answers `false`, and the next `recv` returns a value.
- **Waiters are served in order.** Values come out in the order they went in (FIFO). Waiting receivers are served in the order they started waiting, and so are waiting senders, with no barging:
  - When a value arrives and receivers are waiting, the head receiver is popped from the FIFO and the value is reserved for it (a direct hand-off); it does not go into the buffer, so a task that calls `recv` before the woken one runs cannot take it. The woken receiver returns it when it runs.
  - When a value leaves a full buffer and senders are waiting, the freed slot is reserved for the head sender, which is popped and woken; it adds its value when it runs.
  - A woken waiter that leaves without completing hands its reservation on: it was cancelled (27.1), or its timeout was recorded before the reservation reached it (the first of the two to reach a waiter wins; a waiter whose reservation came first returns the value even if its deadline passes before it runs). A reserved value passes to the next waiting receiver, or, if there is none, goes back to the head of the buffer; a reserved slot passes to the next waiting sender, or becomes free.
- **No lost values.** A value is in exactly one place: the sender's call (until it returns `ok()`), the buffer, or a receiver's reservation. So a cancelled receiver never loses a value, and a cancelled sender never adds one.
- **No `==`, no text, no JSON**, as for `Task`: `puts`, `print`, interpolation and `==` on a channel are `CHECK-TYPE-MISMATCH`, `.to_s` is `CHECK-UNKNOWN-METHOD`, JSON encoding is `CHECK-NOT-ENCODABLE`, and `IO.inspect` prints `<Channel>`.
- **Lifetime.** A channel belongs to the run, like a task handle: the GC frees it when nothing refers to it, and using it from another execution halts with `RUNTIME-TASK-CONTEXT`, the code for task handles, since both are concurrency handles and are fixed the same way. On the VM one run is one execution, and after phase 21 each BDD scenario is its own VM run whose steps share one execution (§31.5), so BDD gives no way to reach this case; a channel created in a step program's `main` is fresh in each scenario.
- **Effects:** `send`, `recv` and `close` carry `concurrency`, like `Task.spawn`; `new` and `closed?` have none.
- **Left out**, each until a real program needs it: `select` over several channels (fan-in uses one channel of an enum type, `Channel[Event]` with one variant per source, and each source sends into it; a coordinator awaits all the sources and then closes it); `for x in channel` (a second way to write the receive loop); unbounded and rendezvous channels; broadcast; `size` (its answer is stale at once with other tasks); `try_send` and `try_recv` (a timeout of 0); separate send-only and receive-only types.

**Is `Task.map` built on channels?** No (27.1, "Where it lives"): a channel cannot stop a timed-out item's work. And channels do not replace `Task.map`: for "the same I/O for each item of a list", `Task.map` is the one form; channels are for flows of unknown length, long-lived workers and results in the order they end.

**Where it lives.** C builtins in `vm/channel.c`, under exception 4 of the std-first rule (its own memory layout in the runtime), and because `send` and `recv` park tasks, which only the scheduler can do. Front end: catalog entries in `src/builtins.rkt`; in `src/checker.rkt`, the reserved name, `Channel[T]` as a receiver type for methods (`resolve-method`), the expected-type rule of `new`, and the rules for printing, `==` and JSON. No lowering change.

**VM design.**

- A channel is a GC object: the capacity, a ring buffer that grows by doubling up to the capacity (so `Channel.new(1048576)` does not allocate a million slots at once), the closed flag, and two FIFOs of waiting tasks (senders and receivers), linked through `wait_next` like the handle lock's waiters (§10.2.2). A waiting receiver has a reservation field for a handed-off value; a waiting sender has a flag for a reserved slot.
- A call that must wait parks with retry on a timer-only job that ends at its deadline, set at the first wait and kept across retries, as `agc_handle_wait` does (§10.2.2). A timeout of 0 never parks. A wake pops the head waiter and gives it its reservation (above); `close` wakes all. Each call is amortized O(1): a value is one pointer, never copied, and when the ring grows, the copy of its slots is charged as a turn cost (one unit per slot, §10.2.1, "Builtins"); other calls charge none.
- Cancellation (27.1): a cancelled waiter leaves its FIFO, its timer job is closed, and a reservation it holds is handed on as above. The same hand-on applies to the handle lock's `next_owner` (27.1, VM design).
- This item adds the await-cycle check (`RUNTIME-TASK-AWAIT-CYCLE`, 27.1, "Await cycles"), since channels make cycles possible.
- Stall check: still not reachable by a program, since every channel wait holds a timer and await cycles halt before they park. The text of §10.2.1 ("there are no channels and no way to pass a task its own handle") changes to say so.
- With N schedulers, each channel has a small lock, never held across a park, taken by `send`, `recv`, `close`, the wakes and the reservation hand-on; the park and wake protocol of §10.2.3 does the rest, and the lock orders the write of a value before its read on another scheduler.
- The builtins are appended to the builtin table: no new opcode and no format bump.

**Tests** (VM only):

- Checker tests with codes and spans: `Channel.new(4)` without an expected type (`CHECK-EXPECTED-TYPE`); `Channel[Void]` (`CHECK-VOID-TYPE`); a `send` of the wrong type (`CHECK-TYPE-MISMATCH` at the value); `puts(ch)`, `ch == ch` and `JSON.encode` of a struct with a channel field; `struct Channel` and `import ... as Channel` (`CHECK-REDEFINED-NAME`); the methods on a `Channel[T]` receiver; the hints of 27.5.
- Golden fixtures (no timeout races, as the golden rule of 27.1 asks; receive loops use timeouts far longer than the run, so they never retry): FIFO order; a full channel with `send` timeout 0 (an error, and `closed?` is `false`); an empty channel with `recv` timeout 0; a closed channel that still holds values (`closed?` is `false`, and `recv` returns the values), then the closed error once it is drained, with `closed?` `true`; `send` after `close`; capacity 0 and 1,048,577 (`RUNTIME-INVALID-COUNT` at the argument); a negative timeout (`RUNTIME-INVALID-DURATION` at the argument); a pipeline (a producer, three workers with the canonical receive loop, and a collector that sorts by index, so the output does not depend on timing); fan-in through a `Channel[Event]` enum, where a coordinator task awaits every source task and then closes the channel, so the consumer's loop ends; a deadlock (two tasks that each wait, with a 20 ms timeout, to receive from the other, and nothing is ever sent) that always ends with timeout errors, not `RUNTIME-INTERNAL`.
- In `tests/vm-task-map-test.rkt` (Racket, with a Python peer): a socket handed to a worker over a channel, against a local Python TCP counterpart on port 0.
- Await cycles: a task that receives its own handle over a channel and awaits it, and two tasks that each receive the other's handle and await it, both halt with `RUNTIME-TASK-AWAIT-CYCLE` at the `Task.await` span; a closure that captures a handle gives the same.
- `RUNTIME-TASK-CANCELLED` (moved here from 17a), in `tests/vm-task-map-test.rkt`, since both depend on an item timing out: a `Task.map` item spawns a child and sends the child's handle over a channel; in one case `main` awaits the handle after the item timed out, in the other `main` is already parked in that `Task.await` before the item times out. Both halt with the code at `main`'s `Task.await` span.
- Hand-off in order, in `tests/vm-task-map-test.rkt` (it depends on timing, so it is not a golden fixture): receiver 1 is a `Task.map` item waiting in `recv`; the sender sends one value and then, in the same turn, runs one long builtin that outlasts the item's remaining time, so the item's deadline fires after the reservation and before receiver 1 runs; receiver 1 is cancelled, and receiver 2, which started waiting after receiver 1, still gets the value before its own timeout. The same case runs deterministically as a C test; so do a reservation that goes back to the head of the buffer when no receiver is left, and a reserved send slot handed to the next sender.
- A C test of the ring buffer (growth and its turn cost, wrap-around, the capacity) and of the wait FIFOs, with the two late-reservation races: `close` while a value is reserved for a woken receiver (`closed?` stays `false` until that receiver takes it, and if it is cancelled instead, the value goes back to the buffer and is still received), and `close` while a woken sender holds a reserved slot (its `send` returns the closed error and the value is not added).
- When the multicore schedulers land, the channel and await-cycle fixtures join their `--schedulers 4` stress run under TSan.

**Docs:** `grammar.md` ("Lightweight tasks", or a new "Channels" part next to it; the reserved names; the §7 hint table), the programming skill (`references/tasks.md` with the canonical receive loop and the pipeline, fan-in and owner-task patterns, and `references/diagnostics.md` for `CHECK-EXPECTED-TYPE`, `RUNTIME-TASK-AWAIT-CYCLE` and `RUNTIME-TASK-CANCELLED` on the VM), `site/content/library/task.md` or a new `site/content/library/channel.md` (front matter `title` and `weight`, runnable examples), `site/content/tour/tasks.md`, `docs/vm/10-io-scheduler.md` §10.2.1 (the stall-check text, the await-cycle check) and §10.2.2 (channel waits and reservations), `docs/vm/10-io-multicore.md` §10.2.3 (the channel lock), the development skill's notes. Section 8 then points here and keeps only its open questions.

### 27.3 `Task.await` with a timeout

Wait for a task's result, but not longer than `timeout_ms`.

```agentica
def slow(n: Int) -> Int
  Task.sleep(5000)
  return n * 2
end

def main() -> Void
  task = Task.spawn(&slow, 21)
  case Task.await(task, 100)
    ok(n) -> puts(n)
    error(message) -> puts(message)   # task: timed out
  end
  puts(Task.await(task))              # 42, after the rest of the 5 s
end
```

```text
Task.await(task: Task[T], timeout_ms: Int) -> Result[T]
```

**Decisions:**

- **A second arity of `Task.await`, not a new name.** The one-way test (§25 Principle) rejects forms that only rename or re-spell an existing call. This one adds behavior: the wait is bounded, and the result is a `Result` that can be a timeout. Waiting forever stays `Task.await(task)`, and waiting at most N ms is `Task.await(task, timeout_ms)`, so each job still has one form. The builtin catalog already selects signatures by arity (`Map.get` with 2 or 3 arguments, `File.open` with a block in §25.9), and agents know the pattern from it. A separate name (`await_timeout`, `wait`) would be two names for "await", which agents would mix up.
- **A timeout does not cancel the task.** On a timeout the call returns `error("task: timed out")` (the text of a `Task.map` timeout), and the target keeps running. A later `Task.await(task)` or `Task.await(task, timeout_ms)` on the same task is valid: `grammar.md` ("Lightweight tasks") says await returns the cached result and may be repeated, and that does not change. So a program can wait a bit, do other work, and wait again. Stopping the work is `Task.map`'s per-item timeout; a public `Task.cancel` stays open in section 8.
- **A finished task never times out.** The call checks whether the target has already settled (ended, or been cancelled) before it waits, and again when its wait times out; in both cases it returns the target's outcome, not a timeout. So a small timeout on a task that is done, or that ended while the CPU was busy with other tasks, still gives `ok(v)`.
- **`timeout_ms` must be positive**; otherwise `RUNTIME-INVALID-DURATION` at the argument, as for `Task.map`. "Has it finished?" without any wait is not part of this item.
- **Errors.** If the target ends in time, the call returns `ok(v)`, or `ok()` for a `Task[Void]`. A runtime diagnostic in the target ends the run, as with the plain form. If the target is cancelled (or was cancelled before the call), the call halts with `RUNTIME-TASK-CANCELLED` at the user's `Task.await(task, timeout_ms)` call, at once, as the plain form does (27.1). If the call already returned a timeout, a later cancel of the target does not halt the run: the caller already has its answer, and the helper below ends quietly. Awaiting a task from another execution is `RUNTIME-TASK-CONTEXT`, as today.
- **Effects:** `concurrency`, like the plain form.

**Where it lives: the compiler prelude, over a channel.** It is generic in `T`, so it cannot be a `std/` module, and by the rule at the top of this section it is Agentica code, not C. The body, in `stdlib/prelude/task.agc`:

```text
def await_timeout(task: Task[T], timeout_ms: Int) -> Result[T]
  if timeout_ms <= 0
    __fail_arg("RUNTIME-INVALID-DURATION", 1, "timeout must be positive milliseconds")
  end
  if !__task_settled?(task)
    signal: Channel[Nil] = Channel.new(1)
    waiter: Fn[Task[T], Void] = lambda do |t: Task[T]|
      __task_wait(t)
      _ = signal.send(nil, 0)
    end
    Task.spawn(waiter, task)
    _ = signal.recv(timeout_ms)
    if !__task_settled?(task)
      return error("task: timed out")
    end
  end
  return ok(Task.await(task))
end
```

- A helper task waits until the target settles and then sends `nil` into a capacity-1 signal channel; the caller receives with the timeout. The value itself never travels through the channel: once the target has settled, the final `Task.await(task)` returns the cached result without parking, or halts with `RUNTIME-TASK-CANCELLED` for a cancelled target, reported at the user's call by the span rule of §25.6. The helper's `send` uses a timeout of 0 and always succeeds: the channel has one slot, only this helper sends into it, and nobody closes it.
- Two prelude-only builtins, guarded like `__fail_arg` (a catalog entry with the prelude-only flag, `CHECK-UNKNOWN-NAME` outside the prelude, rejected by the loader outside prelude functions, left out of `agentica help`): `__task_settled?(task) -> Bool`, true when the task has ended or been cancelled, so that `Task.await` on it will not park; and `__task_wait(task) -> Void`, which parks like `Task.await` until the task settles (it runs the await-cycle check of 27.1, which cannot fire for the helper, since no task holds the helper's handle), but returns nothing and never halts, even for a cancelled task. They are what lets the helper end quietly and the call check for a finished task; with only the public `Task.await`, the helper would halt the run when a target is cancelled after the caller timed out, and a finished task could still time out under CPU load.
- **`T = Void`.** The checker checks the body with `T` opaque, so `ok(Task.await(task))` passes, but for a `Task[Void]` it would pass a `Void` value as an argument, which user code may not do (`CHECK-VOID-VALUE`), and whose runtime form is not promised to equal `ok()`. So this is not sound as one body. The catalog entry names a second body, `await_timeout_void`, the same text except the last line, which is `Task.await(task)` as a statement and then `return ok()`; the checker picks it when `T` is `Void`. §25.6's restricted type variables do not cover this, so it is an addition of this item.
- It needs lambdas (15e) for the helper, channels (17b) and the prelude (15f).

**What 17c adds to the prelude mechanism of §25.6**, and nothing else:

- one catalog name, `Task.await`, with a C body for arity 1 and a prelude body for arity 2 (today a name is either a builtin or a prelude function);
- the `Void` body above;
- the two prelude-only builtins `__task_settled?` and `__task_wait`, appended to the builtin table (no format bump);
- lambdas written in prelude files carry the prelude flag, as §25.6 already says for blocks there;
- a span for prelude-spawned tasks: a task spawned with a prelude-flagged entry function (the helper's lambda) stores the span of the user's call that spawned it (the outermost frame of the innermost run of prelude frames at the spawn, as in the span rule), and the span rule uses that stored span when it finds no user frame in the task. So a `RUNTIME-STEP-LIMIT`, a `RUNTIME-INTERNAL` or a trace line inside the helper points at the user's `Task.await(task, timeout_ms)` call, never at `<prelude>/task.agc`. §25.6's sentence on a crafted `.agcb` with no user frame says this fallback comes first;
- the helper mark for BDD (below): a task whose entry function has the prelude flag is a helper.

**The helper task after a timeout.** On a timeout, the caller returns, and nothing reads the channel again. The helper stays parked in `__task_wait` until the target settles; then it sends `nil` into the unread buffer (the one slot is free, so the send succeeds at once) and ends, also when the target was cancelled. The channel is then unreachable, and the GC frees it. The helper cannot keep the run alive: when `main` returns, the run ends and every pending task is cancelled, the helper too, as today. If the target never ends, the helper waits until the run ends. If the caller is cancelled (a `Task.map` item that times out), the helper is its child, so it is cancelled with it (27.1).

**Await cycles and the stall check.** `__task_wait` runs the await-cycle check (27.1, "Await cycles"), but the helper cannot be part of a cycle: no program holds its handle, so no task can await it. While the caller waits, it is in a channel `recv` with a timer, not in an await, so a target that awaits the caller does not make a cycle: the caller times out and goes on, and the target gets the caller's result once the caller ends. For the same reason, a task that awaits its own handle with a timeout gets the timeout error, not `RUNTIME-TASK-AWAIT-CYCLE`: only the plain form can wait forever, so only it needs the check. The stall check is unchanged: the helper waits on a live task, and the caller holds a timer.

**BDD.** Prelude helper tasks (the helper of this item, parked in `__task_wait`) do not count as pending for `RUNTIME-BDD-PENDING-TASKS`: they are internal and run no user code. So whether a step handler passes does not depend on whether a helper has ended yet: a handler whose timed await timed out passes or fails on its own user tasks only. A task is a helper when its entry function has the prelude flag (the helper's lambda has it), and the pending check skips helpers. After phase 21 that check is `Task.pending_count()`, which `std/bdd` calls after each handler (§31.9), so `Task.pending_count` skips helpers too. Test: a step that times out on a task and then awaits it plainly passes, whether the helper has already ended or is still queued when the handler returns (the step is run many times to cover both orders).

**Costs.** A call on a settled task spawns nothing. Otherwise each call spawns one helper task and makes one channel, a few steps each, on the shared `--max-steps` counter; when the target ends in time, the step count is fixed. A loop that calls `Task.await(task, 10)` again and again leaves one parked helper per call until the target ends. The skill teaches one call with the whole timeout the program can afford, not a polling loop, and says that a timeout does not stop the task. The function moves to C only if a measurement shows it is hot (the std-first rule); its catalog entry would not change.

**Tests:** golden fixtures, with no timeout races: a target that has ended (awaited plainly first), then awaited with a timeout (`ok(v)`, with no helper spawned); two timed awaits on the same ended task; a `Task[Void]` (`ok()`); `timeout_ms` 0 and -1 (`RUNTIME-INVALID-DURATION` at the argument span, through `__fail_arg`); a target that never ends (it waits on a channel nobody sends to, with a long timeout) awaited with a 20 ms timeout (always `error("task: timed out")`), after which `main` returns while the helper still waits, and the run ends at once; the step count of a call on an ended task. In `tests/vm-task-map-test.rkt`, since they depend on timing: a target that ends within the timeout (`ok(v)`); a target that does not, then a plain `Task.await` on it that returns its result; a target that has already ended, awaited with a 1 ms timeout while other tasks keep the CPU busy (`ok(v)`, never a timeout); a timed await on a target that is cancelled while the caller waits (`RUNTIME-TASK-CANCELLED` at the user's call); a timed await that timed out, then the target is cancelled (the run goes on); a step limit hit inside the helper (a `--max-steps` small enough to stop the run while the helper runs), reported at the user's `Task.await(task, timeout_ms)` call, not at `<prelude>/task.agc`. Checker tests: the arity overload (`CHECK-ARITY` with 3 arguments; `agentica help Task.await` lists both arities), the `Void` body, and `__task_settled?` and `__task_wait` in user code (`CHECK-UNKNOWN-NAME`); a loader test that rejects them outside prelude functions. **Docs:** `grammar.md` ("Lightweight tasks"), the programming skill (`references/tasks.md`: a timeout does not stop the task; one call, not a polling loop), `site/content/library/task.md`, the development skill's notes (the prelude's task body, the split arity, the two prelude-only builtins, the spawn span and the helper mark), `docs/vm/03-ir-and-bytecode.md` §4.5 (the list of guarded prelude-only builtins).

### 27.4 Lazy streams (to evaluate later)

**Decision:** not planned now. A `Stream[T]` stays here, to evaluate later, with the criteria below.

**Why not now.** The one-way test, applied hard:

- A lazy pipeline over a source that fits in a `List` is a second way to write the `List` methods. So a stream could only exist where a list cannot: an endless sequence, or data too big for memory (a big file, or the lines of a socket or a process).
- Those cases already have a form: a `while` loop over `File.read_line` inside `File.open` with a block (§25.9) keeps one line in memory at a time; an endless sequence is a `while` loop; `for` over a range is already lazy; and a producer task with a channel (27.2) streams values into concurrent work, with backpressure. A stream would be a second way to write each of those loops.
- Ranges have no endless form (`(1..)`), and adding one would serve only streams.
- Lazy steps are generic code over closures, so they would be prelude code (§25.6), which waits for faster lists (8d, order step 8.2).

**Criteria to plan it** (all of them):

1. A real program (the applications of order step 13, MCP, or an evaluation round) shows that agents get the loop forms wrong, or write much longer code, for reading, changing and stopping early over a source that does not fit in memory. Measured, not assumed.
2. A narrower fix does not cover it. First evaluate one block builtin per source, such as `File.each_line(path, timeout_ms) do |line| ... end`: one call in place of `open`, a loop, `eof?`, `read_line` and `close`, so it passes the one-way test as a composition of several calls, and it adds no type.
3. The prelude (order step 8.2, after 8d) has landed.
4. Each step passes the one-way test against `List`: no `list.stream`, no `Range.stream`, and no step that only re-spells a `List` method over a source that a list can hold.

**Shape if it is planned** (a sketch for its spec, not a decision):

- `Stream[T]` is a builtin opaque generic and an immutable recipe, not a cursor: building one does no work and opens nothing. Only a terminal step runs it, and two terminals on the same stream run its source twice. Elixir's streams are recipes too.
- Sources, only where a list cannot be: lines of a file by path, and an endless `Stream.iterate(seed, f)`. `Stream.unfold` waits for tuples (§12.5). Socket and process lines are an open question: a handle cannot be reopened, so a second run would go on where the first one stopped.
- Lazy steps: `map`, `filter`, `take(n)`, `take_while`. Terminals: `to_list(max)` (an error when the stream has more than `max` items, so an endless stream cannot fill memory), `each`, `reduce`. Terminals return a `Result`, and a read error of the source ends the terminal with that error.
- Resources: a file source opens its file when a terminal starts and closes it when the terminal returns, whether it reached the end, `take` or `take_while` had enough, a step returned an error, or a `try` failed in a block. That is the guarantee of `File.open` with a block (§25.9), with the terminal call as the block. A stream that is dropped without a terminal opened nothing, so nothing leaks. A runtime diagnostic ends the run, which closes the file as today.
- Costs: each element pulled costs one step plus its callbacks, like `Range.each`, and a terminal can be switched out between elements (a resumable native frame, §10.2.1).

### 27.5 Decided against

Each of these is decided; it gets a help that names the Agentica form.

- **Generators and fibers:** Ruby's `Enumerator.new do |y| y << v end` with `e.next`, `Fiber.new` and `Fiber.yield`, and `yield` in Python or JavaScript.
  - A second way to write a producer: a task that sends into a channel is a generator, its capacity gives backpressure, and `next` is `recv`.
  - External iteration hides changing state inside a value (`e.next` changes `e`), and values are immutable.
  - Fibers are what tasks already are: green VM stacks that the scheduler switches.
  - `yield` is already decided against (§25.13: the block is a named `Fn` parameter, called with `.call`).
  - Help: `Enumerator.new(...)` and `Fiber.new(...)` (today `CHECK-UNKNOWN-NAME`) show a producer task that sends into a `Channel` (`Task.spawn(&produce, ch)`, then `ch.recv(timeout_ms)`). `xs.lazy` on a `List` or a `Range` (today `CHECK-UNKNOWN-METHOD`) shows that lists are eager, and that a source too big for a list is read in a `while` loop. Added by 17b.
- **Elixir `Agent` and other shared mutable accumulators:** `Agent.start_link`, `Agent.update` and `Agent.get`, Ruby's `Concurrent::AtomicFixnum`, or a counter that blocks change.
  - Shared mutable state, which the language does not have: values are immutable, and the only planned exception is the shared table of §13, on demand, with atomic calls.
  - A second way to accumulate: in one task, `reduce` or a loop variable; across tasks, each task returns its part (`Task.await`, `Task.map`) and the caller combines the parts with `reduce`; state that lives while tasks run belongs to one owner task that receives messages on a channel. An Elixir `Agent` is itself a process that receives messages, so the owner task is the same idea, written with the language's own parts (example below).
  - Help: `Agent.start_link(...)` and the other `Agent` calls (today `CHECK-UNKNOWN-NAME`) show "return values from tasks and combine them with `reduce`, or keep the state in one task that receives on a `Channel`". A block that assigns to an outer variable keeps its `CHECK-CAPTURED-ASSIGNMENT` and its help (use `reduce` or a `for` loop). Added by 17b.
- **Public locks and threads:** `Mutex`, `Monitor`, `ConditionVariable`, semaphores, `Thread.new`, Ruby's `SizedQueue`.
  - With no shared mutable state there is nothing to lock; a lock held across a wait is also the classic deadlock, and agents get lock order wrong.
  - `Thread` is `Task`, and `SizedQueue` (a bounded, blocking queue) is `Channel`.
  - Help (today `CHECK-UNKNOWN-NAME`): `Thread.new` shows `Task.spawn(&f, arg)`; `Mutex.new` shows an owner task with a `Channel`; `SizedQueue.new` shows `Channel.new(capacity)`. `Thread.new` is added by 17a, the others by 17b.
- **Options on `Task.map`:** Elixir's `ordered: false`, `on_timeout:` and `zip_input_on_exit:`. Keyword arguments are decided against (§25.13), and each option is a second behavior of one call. `Task.map` has one: input order, per-item timeout, cancel on timeout.

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

When the parts can simply be returned, returning them is the one form: `Task.map(words, 3, 1000) do |w| ok(w.length) end`, then `reduce` over the results.
