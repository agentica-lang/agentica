## 27. Iteration and concurrent collections

**Status:** 27.1 (`Task.map`) and 27.2 (channels) are planned (roadmap phase 17) at order step 7.5: after 7i deletes the evaluator (order 7.2) and after the items of order step 7.4, on the C VM only. 27.3 (lazy streams) is to evaluate later, with the criteria that would plan it. 27.4 records what was decided against (generators, fibers, Agent-style shared state, public locks), so it is not proposed again. This section finalizes the channel proposal of [section 8](08-concurrency.md#8-concurrency-and-parallelism) and answers [section 25.12.7](25-ruby-typed-idioms.md#25127-lazy-enumerators-and-generators).

**What is asked for:** something like Elixir's `Stream` and `Task.async_stream`, Ruby's iterators, generators and accumulators, and faster programs through concurrency.

**What exists today** (`grammar.md`, "Lightweight tasks", "Ranges", "Blocks and closures"): `Task.spawn`, `Task.await` and `Task.sleep` give I/O concurrency on one core (the VM runs one scheduler, `docs/vm/10-io-scheduler.md` §10.2.1). `List` and `Range` methods are eager; `for` over a range does not build a list; `reduce` is the accumulator. There are no channels, no lazy streams and no CPU parallelism. `Task.await` has no timeout, and a task cannot be cancelled.

**Rules.** Those of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms): one way to do each thing (its Principle and its test), values stay immutable with no shared mutable state, types stay static, and the users are LLM agents, who do best with one obvious form and an error whose help shows it.

**One way for each job.** After this section, the programming skill teaches these forms, and only these, for each job:

| Job | The one form |
|---|---|
| Change, select or combine the items of a list | `List.map`, `filter`, `reduce` and the other `List` methods (eager) |
| Keep a running total, or build a value in a loop | `reduce`, or a `for` or `while` loop that reassigns a local variable |
| Run the same I/O for each item of a list, at most N at a time, each with a timeout | `Task.map` (27.1) |
| Long-lived workers, producer and consumer, a flow of unknown length, results in the order they end | tasks and a `Channel` (27.2) |
| Read a big file line by line | `File.open` with a block (§25.9) and a `while` loop over `File.read_line` |
| An endless sequence | a `while` loop |
| State that several tasks update | one owner task that receives messages on a channel (27.4); a shared table (§13) when a program needs it |

| § | Item | Decision | Where it lives | Roadmap |
|---|---|---|---|---|
| 27.1 | `Task.map` | planned | C builtin in the VM scheduler | 17a |
| 27.2 | `Channel[T]` | planned | C builtins, a builtin opaque generic | 17b |
| 27.3 | Lazy `Stream[T]` | to evaluate later | none yet | none |
| 27.4 | Generators, fibers, Agent-style state, public locks and threads | decided against | help hints only, added by 17a and 17b | none |

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

- **Parameter order.** The list, then `limit`, then `timeout_ms`, then the function, which is the trailing block: `Task.map(urls, 8, 5000) do |url| ... end`. It follows Elixir (`async_stream(enumerable, fun, max_concurrency: ..., timeout: ...)`) without keyword arguments (decided against, §25.13), and the library's habit of putting `timeout_ms` last before a block (`File.open(path, mode, timeout_ms) do |f|`, §25.9). Both numbers are required, with no defaults: a good limit and timeout depend on the work, and the agent must choose them.
- **The block returns `Result[R]`.** The work `Task.map` is for (HTTP, files, processes) already returns `Result`, so `Fn[A, R]` would give `List[Result[Result[T]]]`. With one level, the block's own `error(...)` and a timeout are both one `error` in the list. A block that cannot fail returns `ok(x)`. `try` works in the block by the rule of §25.9 for builtins whose block result is `Result[T]`: `R` comes from the expected type of the call if there is one, or else from the body. A block whose result is not a `Result` is `CHECK-TYPE-MISMATCH` at its last expression, with a help that shows `ok(...)`.
- **Not a method.** It is always `Task.map(...)`. Methods come from the receiver's module, so `xs.map` stays `List.map`, the sequential one; `Task` owns concurrency.
- **Order.** Items start in input order. At most `limit` run at once; when one ends, the next item starts (a sliding window, as in Elixir, not batches). The result list is in input order, whatever order the items end in. There is no unordered mode (Elixir's `ordered: false`): a program that wants results as they end uses a channel (27.2).
- **Timeout per item**, as in Elixir. `timeout_ms` counts from the moment that item's task starts until it ends, both its waits for I/O and its turns on the CPU. An item that runs out of time is cancelled (below) and its slot gets `error("task: timed out")`. There is no total timeout: a call takes at most about ⌈n / limit⌉ × `timeout_ms`, plus the time other tasks hold the CPU. A total deadline would be a second number for the same need; a program that needs a shorter bound uses a smaller per-item timeout.
- **Errors do not stop the others.** Each item gets its own `Result`, and an item's `error(...)` does not cancel the rest. Partial success is the normal case for I/O (fetch 100 pages, 3 fail), and a fail-fast mode would be a second form with its own cancel rules. A caller that must stop at the first error checks the list (`results.all? do |r| r.ok? end`). A runtime diagnostic in an item (a bug, such as `RUNTIME-INDEX-OUT-OF-RANGE`) ends the whole run with its code and span, as a diagnostic in any task does today; `Task.map` does not catch it.
- **Cancellation.** The caller cannot leave a `Task.map` call early: it waits until every item has ended, and an `error` result does not stop it. So in-flight items stop early only at their own timeout, or when the run ends (`main` returns, a diagnostic, `System.exit`), which already stops every task. The rules when an item is cancelled:
  - Its task and every task it spawned that is still running (its descendants) are cancelled. The work of an item is everything it started, so a timed-out item leaves nothing behind that still prints or spends steps.
  - A cancelled task runs no more user code. What it was waiting for is let go the way a timeout lets it go today: an operation in flight on a handle is abandoned as on its own timeout (a file handle is closed, as `expired` does in `docs/vm/10-io-scheduler.md` §10.2.2); a wait for a handle's lock, for `Task.await` or on a channel (27.2) just leaves its queue, and no channel value is lost (27.2, "No lost values").
  - Handles the item opened stay open until the end of the run, as today. `File.open` with a block does not close its handle for a cancelled task, since no user code runs.
  - `Task.await` on a cancelled task (a handle that a descendant passed out, for example over a channel) halts with `RUNTIME-TASK-CANCELLED` at the call, the code the evaluator already uses for awaiting cancelled work.
- **No public cancel.** `Task.cancel` and a `Task.await` with a timeout are not added: per-item timeouts and channel timeouts cover the known uses, and each would be a second way to stop or wait for work. Section 8 keeps them open until a program needs them.
- **Limits.** `limit` is 1 to 1024; otherwise `RUNTIME-INVALID-COUNT` at the `limit` argument. 1024 bounds the tasks and timers of one call, and matches a common open-file limit (`ulimit -n`) and the `--schedulers` cap. `timeout_ms` must be positive; otherwise `RUNTIME-INVALID-DURATION` at the argument, the code of a negative `Task.sleep`. Both are bugs in the program, not I/O failures, so they are diagnostics, not `error` results. Both arguments are checked before any item starts. An empty list returns `[]` and starts nothing; a `limit` larger than the list starts every item at once.
- **Nesting.** An item may call `Task.map`; each call has its own limit, so the limits multiply.
- **Values.** Items, captured variables and results are immutable, so the tasks share them without copies. A block may capture a handle (a file, a socket, a channel); handles keep their per-handle lock (§10.2.2).
- **BDD.** `Task.map` ends all its items before it returns, so it is valid in a step handler (no `RUNTIME-BDD-PENDING-TASKS`).
- **Effects:** `concurrency`, like `Task.spawn`.

**Costs and turns.** Each item is its own VM task, so the turn rules of `docs/vm/10-io-scheduler.md` §10.2.1 apply unchanged: an item that loops on the CPU is switched out after its turn budget, and timers and I/O stay responsive. Starting an item costs one step on the shared `--max-steps` counter, like a callback of `Range.each`, and its block costs its own steps, so a `Task.map` where no item times out has a fixed step count, which golden fixtures can record. Steps an item spends before it is cancelled stay spent; their number depends on timing, so fixtures that record step counts have no timeouts. The caller spends no steps while it waits. Building the result list charges one turn unit per item (`AGC_COST_SIZE` on the result), like `Range.to_a`.

**Speed-ups: I/O now, CPU later.** On today's VM (one scheduler), `Task.map` speeds up I/O-bound work: while one item waits for the network, a file, a process or a timer, others run, so n requests of d ms take about ⌈n / limit⌉ × d instead of n × d. CPU-bound work does not get faster on one scheduler: items take turns on one core, and the total is the same, plus the switches. Once the multicore schedulers land (`docs/vm/10-io-multicore.md` §10.2.3, decided at order step 11), the items are ordinary ready tasks, so idle schedulers steal them, and a CPU-bound `Task.map` uses up to `min(limit, N)` cores with no change to the program. `Task.map` is then the one way to spread CPU work over a list across cores. A CPU-bound `Task.map` program joins round 2 of the cross-language benchmarks (phase 12), as evidence for that decision.

**Where it lives: a C builtin in the VM, not prelude code.** The std-first rule ([roadmap](../roadmap/README.md#new-library-features-std-first)) is for pure computation over types that exist. `Task.map` is runtime work: it schedules tasks, starts timers (exception 1 of the rule: time) and cancels tasks. It also cannot be prelude code (§25.6) on today's API, and it should not wait for the prelude:

- With only `Task.spawn` and `Task.await` there is no way to wait for whichever item ends first (to keep `limit` items running), no timeout on `Task.await`, and no way to cancel a task. A prelude version would first need new public primitives, each a second way to stop or wait for work ("No public cancel").
- Channels (27.2) do not close the gap either: a pool of `limit` workers that read items from one channel and send indexed results to another gives bounded concurrency and input order, but not the per-item timeout. A receive with a timeout stops only the waiter, not the work, so a timed-out item would keep its worker busy and keep running. So `Task.map` is not built on channels.
- The prelude starts at order step 8.2, after faster lists (8d), because of its cost contract. As a builtin, `Task.map` builds its result list in C, needs no 8d, and lands at order step 7.5.

It is generic in `A` and `R` and takes a block, which a `std/` module could not be anyway (no user generics).

**VM design.**

- `Task.map` is a builtin appended to the VM's builtin table, with no new opcode and no bytecode format bump (as `File.eof?`, §25.9). It checks `limit`, then `timeout_ms`, then builds a group object in GC memory: the items, the function, the next index, a results array of n slots, the number running, the limit, the timeout and the caller. It starts the first `min(limit, n)` items and parks the caller with retry, as `Task.await` of a running task does (§10.2.1, "As built").
- Each item is a task whose entry calls the function on the item (builtins that take a function run it as a new VM task, §10.2), with a timer-only job for its deadline (like the handle lock's deadline, §10.2.2). When an item ends, its result goes into its slot, its timer is closed, and the next item starts. When the timer fires first, the item is cancelled, its slot gets the timeout error, and the next item starts. When the last slot is filled, the caller is woken; on its retry it builds the result list.
- **Task cancellation** is new VM code that this item adds and 27.2 extends. Each task records its parent and a list of its running children (the tasks PR keeps none). `agc_task_cancel` marks a task and its running descendants cancelled: a ready task leaves the run queue, a parked task leaves what it waits on (its job is abandoned as on its own timeout, or it leaves a handle lock's FIFO or the waiters of a `Task.await`), and a cancelled task never runs again. With one scheduler, timer callbacks run between turns, so the cancelled item is never in the middle of a turn. With N schedulers, cancel uses the cancel flag and wake of §10.2.3 ("Cancel and stop flags"), so a CPU-bound item stops within one turn budget, and each slot is written once, under the group's small lock (never held across a park), by whichever comes first: the item's end or its timeout.
- The stall check (§10.2.1) does not change: while items run, the caller waits on live tasks, and each item holds a timer.

**Diagnostics and help.** No new codes. These forms get a help, through the hint table of `grammar.md` §7 (today each is `CHECK-UNKNOWN-NAME`, "unknown function"): `Task.async_stream(...)` and `Parallel.map(...)` (a Ruby gem) show `Task.map(items, limit, timeout_ms) do |x| ... end`; `Task.async(...)` shows `Task.spawn(&f, arg)`.

**Tests** (VM only):

- Checker tests with codes and spans: the block's parameter type from the list; `try` in the block with and without an expected type; a block that does not return a `Result` (`CHECK-TYPE-MISMATCH` with the `ok(...)` help); `CHECK-ARITY`; `Task.map([], ...)` (`CHECK-EMPTY-LIST-TYPE` at the literal, as for `List.map`); the hints of 27.1 and `Thread.new` (27.4).
- Golden fixtures (`tests/fixtures/vm/*.expected`): results in input order when items end in reverse order (sleeps of 300, 200 and 100 ms); an item's `error` next to `ok` items; an empty list; `limit` larger than the list; `limit` 0 and 1025 (`RUNTIME-INVALID-COUNT` at the argument span); `timeout_ms` 0 (`RUNTIME-INVALID-DURATION` at the argument span); a diagnostic inside an item (the whole run ends with its code and span); a nested `Task.map`; the step count of a 1,000-item call with no timeouts.
- A Racket timing test (`tests/vm-task-map-test.rkt`, like `tests/vm-latency-test.rkt`, with lower bounds that cannot be flaky and generous upper bounds): items print `start i` and `end i`; at no point are more than `limit` items between their `start` and `end`, and at some point exactly `limit` are; 8 items that sleep 250 ms with `limit` 2 take at least 1 s; with `limit` 8 they take well under the 2 s of a serial run.
- Timeout and cancellation: an item that sleeps 60 s with `timeout_ms` 200 gives `error("task: timed out")` while the other items give `ok`, and the run ends within a few seconds; the timed-out item's line after its sleep never prints; a task it spawned that would print after 500 ms never prints (main sleeps 1 s after the call before it returns); `Task.await` on that child's handle, passed out through a channel, halts with `RUNTIME-TASK-CANCELLED`.
- Hermetic I/O: `Task.map` over HTTP requests to a local Python `http.server` counterpart on port 0 (standard library only, as AGENTS.md asks) whose handler sleeps 300 ms per request: 8 requests with `limit` 8 take well under the 2.4 s of a serial run, and every body arrives in input order.
- A C test (`vm/tests/`) of the group logic and of `agc_task_cancel` on a ready task, a task parked on a timer, a task waiting for a handle lock and a task in a `Task.await`.

**Docs:** `grammar.md` ("Lightweight tasks", the §7 hint table), the programming skill (`references/tasks.md`, the "one way for each job" table, and a line in `references/diagnostics.md` for `RUNTIME-TASK-CANCELLED` on the VM), `site/content/library/task.md` and `site/content/tour/tasks.md` (runnable examples whose output does not depend on timing), `docs/vm/10-io-scheduler.md` §10.2.1 (task cancellation, the cancel rules for parked tasks), `docs/vm/10-io-multicore.md` §10.2.3 (the group lock), the development skill's notes (`references/vm.md`).

### 27.2 Channels

This finalizes the channel proposal of section 8: a bounded buffer that tasks send values into and receive values from, so producer and consumer pipelines work.

```agentica
def produce(jobs: Channel[Int]) -> Result[Void]
  for n in 1..5
    try jobs.send(n, 1000)
  end
  jobs.close
  return ok()
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(2)
  producer = Task.spawn(&produce, jobs)
  total = 0
  while true
    case jobs.recv(1000)
      ok(n) -> total += n
      error(_) -> break
    end
  end
  puts(total)                  # 15
  puts(Task.await(producer))   # ok()
end
```

```text
Channel.new(capacity: Int) -> Channel[T]
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
Channel.close(channel: Channel[T]) -> Void
Channel.closed?(channel: Channel[T]) -> Bool
```

All five are also methods (`jobs.send(v, 1000)`, `jobs.recv(1000)`, `jobs.close`, `jobs.closed?`). Against the section 8 proposal: `new` takes a capacity, `send` and `recv` take a timeout and return a `Result`, and `close` and `closed?` are added.

**Rules:**

- **Type.** `Channel[T]` is a builtin opaque generic, like `Task[T]`. A channel value is a handle: assigning or passing it shares the same channel. `Channel` becomes a reserved type and module name, a breaking change: a user `struct Channel`, `enum Channel` or `import ... as Channel` becomes `CHECK-REDEFINED-NAME` (say so in the changelog), as section 12 does for `Range`, `Set` and `Queue`.
- **Element type.** `T` is any type a variable can have, so not `Void` (`CHECK-VOID-TYPE`, as for a `List[Void]`; use `Nil` or `Bool` for a plain signal). `Fn`, `Task` and handles (files, sockets, processes, other channels) are allowed: handing a socket to a worker is a main use (an accept loop sends each connection to a pool of workers). The shared table of §13 rejects them because it is a mutable store that many tasks read again and again; a channel only moves a value from one task to another, and the GC handles cycles.
- **`Channel.new`** needs an expected type, from an annotated variable, a parameter, a field or a return: `jobs: Channel[String] = Channel.new(16)`. Without one: `CHECK-EXPECTED-TYPE` at the call, a new code ("this call needs an expected type"), with a help that shows the annotated form. The code is general, so `Table.new` (§13) can use it too.
- **Capacity** is 1 to 1,048,576 (the cap of `List.repeat` and `Range.to_a`); otherwise `RUNTIME-INVALID-COUNT` at the argument. Channels are bounded only: an unbounded channel lets a fast producer fill memory, while a full buffer slows the producer down to the consumer's speed (backpressure). There is no capacity 0 (Go's unbuffered rendezvous): capacity 1 is close enough, and one form is enough.
- **`send`.** If the channel is open and has room, the value is added at the back and the call returns `ok()` at once. If it is full, the task waits until there is room, the channel is closed, or `timeout_ms` passes. It returns `error("channel: closed")` if the channel is closed before or during the wait, and `error("channel: timed out")` at the timeout; in both cases the value is not added.
- **`recv`** returns the oldest value as `ok(v)`. If the channel is empty and open, the task waits until a value arrives, the channel is closed, or the timeout passes. It returns `error("channel: closed")` when the channel is closed and empty, and `error("channel: timed out")` at the timeout. Values sent before `close` are still received after it.
- **Timeouts are required.** `timeout_ms` is 0 or more: 0 means do not wait (try once and return). A negative value is `RUNTIME-INVALID-DURATION` at the argument, as for `Task.sleep`. There is no "wait forever" value, on purpose: tasks that wait on each other in a cycle (a deadlock) get timeout errors instead of hanging, and every task that waits on a channel holds a timer, so the VM's stall check (§10.2.1) stays a guard against VM bugs only. A worker that must wait as long as needed loops: on a timeout it checks `closed?` and receives again.
- **`close`** marks the channel closed and returns `Void`; closing again does nothing. Waiting senders get the closed error; waiting receivers get the values left and then the closed error. Any holder may close it; the skill teaches that the producer closes and consumers never do.
- **`closed?`** says whether `close` was called. After a `recv` error, `closed?` tells the end of the stream (`true`) from a timeout (`false`) without matching error text. This is exact: if the error was a timeout, the buffer was empty, and after a close nothing can be added, so a `true` always means no value is left.
- **Order.** Values come out in the order they went in (FIFO). Waiting receivers are served in the order they started waiting, and so are waiting senders.
- **No lost values.** A value enters the buffer only when a `send` returns `ok()`, and leaves it only when a `recv` returns it to a running task. A woken waiter re-runs its call (a wake is only a hint, as for `Task.await`'s retry), so a cancelled receiver (27.1) never takes a value, and a cancelled sender never adds one. So there is no direct hand-off to a waiting receiver: the value always goes through the buffer.
- **No `==`, no text, no JSON**, as for `Task`: `puts`, `print`, interpolation and `==` on a channel are `CHECK-TYPE-MISMATCH`, `.to_s` is `CHECK-UNKNOWN-METHOD`, JSON encoding is `CHECK-NOT-ENCODABLE`, and `IO.inspect` prints `<Channel>`.
- **Lifetime.** A channel belongs to the run, like a task handle: the GC frees it when nothing refers to it, and using it from another execution (a BDD step) halts with `RUNTIME-TASK-CONTEXT`, the code for task handles, since both are concurrency handles and are fixed the same way.
- **Effects:** `send`, `recv` and `close` carry `concurrency`, like `Task.spawn`; `new` and `closed?` have none.
- **Left out**, each until a real program needs it: `select` over several channels (fan-in uses one channel of an enum type, `Channel[Event]` with one variant per source, and each source sends into it); `for x in channel` (a second way to write the `recv` loop); unbounded and rendezvous channels; broadcast; `size` (its answer is stale at once with other tasks); `try_send` and `try_recv` (a timeout of 0); separate send-only and receive-only types.

**Is `Task.map` built on channels?** No (27.1, "Where it lives"): a channel cannot stop a timed-out item's work. And channels do not replace `Task.map`: for "the same I/O for each item of a list", `Task.map` is the one form; channels are for flows of unknown length, long-lived workers and results in the order they end.

**Where it lives.** C builtins in `vm/channel.c`, under exception 4 of the std-first rule (its own memory layout in the runtime), and because `send` and `recv` park tasks, which only the scheduler can do. Front end: catalog entries in `src/builtins.rkt`; in `src/checker.rkt`, the reserved name, `Channel[T]` as a receiver type for methods (`resolve-method`), the expected-type rule of `new`, and the rules for printing, `==` and JSON. No lowering change.

**VM design.**

- A channel is a GC object: the capacity, a ring buffer that grows by doubling up to the capacity (so `Channel.new(1048576)` does not allocate a million slots at once), the closed flag, and two FIFOs of waiting tasks (senders and receivers), linked through `wait_next` like the handle lock's waiters (§10.2.2).
- A call that must wait parks with retry on a timer-only job that ends at its deadline, set at the first wait and kept across retries, as `agc_handle_wait` does (§10.2.2). A timeout of 0 never parks. Adding a value wakes the head receiver; taking one wakes the head sender; `close` wakes all. Each call is O(1) and charges no turn cost; a value is one pointer, never copied.
- Cancellation (27.1): a cancelled waiter leaves its FIFO, and its timer job is closed.
- Stall check: unchanged and still not reachable by a program, since every channel wait holds a timer. The text of §10.2.1 ("there are no channels") changes to say so.
- With N schedulers, each channel has a small lock, never held across a park, taken by `send`, `recv`, `close` and the wakes; the park and wake protocol of §10.2.3 does the rest, and the lock orders the write of a value before its read on another scheduler.
- The builtins are appended to the builtin table: no new opcode and no format bump.

**Tests** (VM only):

- Checker tests with codes and spans: `Channel.new(4)` without an expected type (`CHECK-EXPECTED-TYPE`); `Channel[Void]` (`CHECK-VOID-TYPE`); a `send` of the wrong type (`CHECK-TYPE-MISMATCH` at the value); `puts(ch)`, `ch == ch` and `JSON.encode` of a struct with a channel field; `struct Channel` and `import ... as Channel` (`CHECK-REDEFINED-NAME`); the methods on a `Channel[T]` receiver; the hints of 27.4.
- Golden fixtures: FIFO order; a full channel with `send` timeout 0 (an error, and `closed?` is `false`); an empty channel with `recv` timeout 0; values received after `close`, then the closed error and `closed?` `true`; `send` after `close`; capacity 0 and 1,048,577 (`RUNTIME-INVALID-COUNT` at the argument); a negative timeout (`RUNTIME-INVALID-DURATION` at the argument); a pipeline (a producer, three workers and a collector that sorts by index, so the output does not depend on timing); fan-in through a `Channel[Event]` enum; a deadlock (two tasks that each wait to receive from the other) that ends with timeout errors, not `RUNTIME-INTERNAL`; a socket handed to a worker over a channel, against a local Python TCP counterpart on port 0.
- No lost values: a `Task.map` item that waits in `recv` times out and is cancelled, and the value sent after that is received by the next receiver.
- A C test of the ring buffer (growth, wrap-around, the capacity) and of the wait FIFOs.
- When the multicore schedulers land, the channel fixtures join their `--schedulers 4` stress run under TSan.

**Docs:** `grammar.md` ("Lightweight tasks", or a new "Channels" part next to it; the reserved names; the §7 hint table), the programming skill (`references/tasks.md` with the pipeline, fan-in and owner-task patterns, and `references/diagnostics.md` for `CHECK-EXPECTED-TYPE`), `site/content/library/task.md` or a new `site/content/library/channel.md` (front matter `title` and `weight`, runnable examples), `site/content/tour/tasks.md`, `docs/vm/10-io-scheduler.md` §10.2.1 (the stall-check text) and §10.2.2 (channel waits), `docs/vm/10-io-multicore.md` §10.2.3 (the channel lock), the development skill's notes. Section 8 then points here and keeps only its open questions.

### 27.3 Lazy streams (to evaluate later)

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

### 27.4 Decided against

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
    case inbox.recv(60000)
      ok(n) -> total += n
      error(_) -> break
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
