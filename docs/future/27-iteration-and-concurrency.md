## 27. Iteration and concurrent collections

**Status:** built, on the C VM only: 27.1 (`Task.map`, roadmap 17a), 27.2
(channels, 17b), 27.3 (`Task.await` with a timeout, 17c) and 27.4
(`File.each_line`, 17d, and `Lazy[T]`, 17e). The contracts are in the grammar
([`06c-tasks-and-tests.md`](../grammar/06c-tasks-and-tests.md), "Lightweight
tasks" and "Channels"; [`06b-builtins.md`](../grammar/06b-builtins.md),
"`Lazy[T]`") and the library pages; this section keeps the decisions and the
rationale. Owner decisions: channels moved earlier, to order row 7.2.1e
(2026-10-13); `Task.await` with a timeout is a C builtin, not the prelude code
planned for order step 8.2 (2026-10-14); streams in two steps, `File.each_line`
first (row 7.2.1h) and a lazy type second (2026-10-14), named `Lazy[T]`
(2026-10-20). 27.5 records what was decided against, so it is not proposed
again. It answers [section
25.12.7](25-ruby-typed-idioms.md#25127-lazy-enumerators-and-generators).

**Rules.** Those of [section 25](25-ruby-typed-idioms.md#25-ruby-typed-idioms):
one way to do each thing, values immutable with no shared mutable state (the
exception is the `std/logger` registry, which only the Logger functions reach),
static types, and users that are LLM agents, who do best with one obvious form
and an error whose help shows it.

**Primitives in C, helpers in Agentica.** The concurrency primitives are a
small set of C builtins: `Task.spawn`, `Task.await`, `Task.sleep`, `Channel`
(27.2) and `Task.map` (27.1). Higher-level helpers (for example "the first of
several tasks") are written in Agentica in the compiler prelude over those
primitives, as the [std-first
rule](../roadmap/README.md#new-library-features-std-first) asks; they go in the
prelude, not in `std/`, because they need the catalog's type variables, and
each needs its own spec and must pass the one-way test. `Task.map` is a C
builtin because it must cancel timed-out items, which no primitive can do.
`Task.await` with a timeout is a C builtin because the timeout lives in the
scheduler, as a timer on the job (`docs/vm/14-core-invariants.md` §14.2).

**One way for each job** (the programming skill teaches only these):

- Change, select or combine list items: the eager `List` methods. A running
  total: `reduce`, or a loop that reassigns a local.
- The same I/O for each item, at most N at a time, each with a timeout:
  `Task.map` (27.1).
- Long-lived workers, producer and consumer, a flow of unknown length, results
  in the order they end: tasks and a `Channel` (27.2).
- Wait for a task for at most N ms: `Task.await(task, timeout_ms)` (27.3).
- A big file line by line: `File.each_line`. An endless sequence, or a long
  chain of which only the first results are needed: `Lazy[T]` (27.4).
- State that several tasks update: one owner task that receives messages on a
  channel (27.5); an `ATS` table for a counter or a cache.

### 27.1 `Task.map`

Elixir's `Task.async_stream` for a list: run a block for each item in its own
task, at most `limit` at a time, each item with its own timeout, and get one
`Result` per item, in input order. The contract is in
[`library/concurrency/task.md`](../../site/content/library/concurrency/task.md)
("Task.map"); the VM design is in `docs/vm/10-io-scheduler.md` §10.2.1
("Task.map").

**Decisions:**

- **Parameter order.** The list, `limit`, `timeout_ms`, then the trailing
  block: `Task.map(urls, 8, 5000) do |url| ... end`. It follows Elixir without
  keyword arguments (§25.13) and the library's habit of `timeout_ms` last
  (§25.9). Both numbers are required, with no defaults: a good value depends on
  the work, and the agent must choose it.
- **The block returns `Result[R]`.** The work `Task.map` is for (HTTP, files,
  processes) already returns `Result`, so `Fn[A, R]` would give
  `List[Result[Result[T]]]`. With one level, the block's own `error(...)` and a
  timeout are both one `error`; a block that returns `error("task: timed out")`
  itself looks like a timeout, which is accepted, since both mean no value. `try`
  works in the block by a checker rule for builtins whose block result is
  `Result[T]` with `T` inferred (`Slot.InferResult`: `R` comes from the expected
  type of the call, else from the body); `File.open` with a block (§25.9) reuses
  it.
- **Not a method.** It is always `Task.map(...)`: `xs.map` stays the sequential
  `List.map`, and `Task` owns concurrency.
- **Sliding window, not batches; input order only.** No unordered mode
  (Elixir's `ordered: false`): a program that wants results as they end uses a
  channel (27.2).
- **Timeout per item, no total timeout.** A total deadline would be a second
  number for the same need; a shorter bound is a smaller per-item timeout.
- **Errors do not stop the others.** Partial success is the normal case for I/O
  (fetch 100 pages, 3 fail), and a fail-fast mode would be a second form with
  its own cancel rules; a caller that must stop checks the list. A runtime
  diagnostic in an item is a crash of that item's task only ([task
  rules][task-rules]): its slot gets `error("task crashed: ...")`.
- **Cancellation.** The caller cannot leave a `Task.map` call early; in-flight
  items stop early only at their own timeout, or when the run ends (rules: the
  grammar, `docs/vm/10-io-scheduler.md` §10.2.1, `docs/vm/14-core-invariants.md`).
  The choices behind them: a timed-out item's work is everything it started,
  running descendants included (a task that ends hands its running children to
  its parent, so a cancel only walks down); an I/O operation in flight is
  detached, never closed, so a timed-out item cannot close a handle that other
  items share; handles the cancelled task opened close with it. The skill
  teaches: open handles inside the item, and give a handle that many tasks need
  to one owner task (27.5).
- **Public cancel (built, owner decision of 2026-10-20).**
  `Task.cancel(task: Task[R]) -> Void` runs the same cancel on the task it names
  (contract:
  [`task.md`](../../site/content/library/concurrency/task.md)). The use: a task
  that keeps state is dropped without a "stop" message through a channel. A task
  that cancels itself or an ancestor is a descendant of the task it names, so
  the plain walk needs no special case. A cancel is not a crash. `Task.await`
  with a timeout (27.3) bounds the wait only and cancels nothing.
- **Limits.** `limit` is 1 to 1024: it bounds the tasks and timers of one call,
  and matches a common open-file limit (`ulimit -n`) and the `--schedulers`
  cap. `timeout_ms` must be positive. Both are program bugs, not I/O failures,
  so they are diagnostics, not `error` results. `limit` is for I/O: the item
  clock includes the wait in the run queue, so a large `limit` over CPU work
  makes timeouts likelier, not the work faster. Nested calls multiply limits.

**Why a builtin, not prelude code.** With `Task.spawn` and `Task.await` nothing
can wait for whichever item ends first, and channels bound concurrency but give
no per-item timeouts (a receive with a timeout stops only the waiter, not the
work). So it schedules tasks and starts timers in the VM, under exception 1 of
the std-first rule (time).

### 27.2 Channels

A bounded buffer that tasks
send values into and receive values from, so producer and consumer pipelines
work. The contract is in
[`library/concurrency/channel.md`](../../site/content/library/concurrency/channel.md);
the VM design (waits, reservations, close, owner, fairness) is in
`docs/vm/10-io-scheduler.md` §10.2.2 ("Channel waits", `vm/channel.c`).

**Decisions:**

- **Type.** `Channel[T]` is a builtin opaque generic, like `Task[T]`. A channel
  value is a handle. `Channel` becomes a reserved type and module name, a
  breaking change: a user `struct Channel`, `enum Channel` or `import ... as
  Channel` is `CHECK-REDEFINED-NAME`, as for `Range` and `Set`.
- **Element type.** `T` is any type a variable can have, so not `Void`
  (`CHECK-VOID-TYPE`, as for a `List[Void]`; use `Nil` or `Bool` for a plain
  signal). `Fn`, `Task` and handles (files, sockets, processes, other channels)
  are allowed: handing a socket to a worker is a main use (an accept loop sends
  each connection to a pool of workers). An `ATS` table rejects them
  because it is a mutable store that many tasks read again and again; a channel
  only moves a value from one task to another, and the GC handles cycles. Since
  a task can now receive its own handle, `Task.await` checks for await cycles
  (grammar, "Lightweight tasks").
- **`Channel.new`** needs an expected type; without one, `CHECK-EXPECTED-TYPE`
  at the call, a new code ("this call needs an expected type"). The code is
  general, so `Table.new` (§13) can use it too.
- **Bounded only.** The capacity is 1 to 1,048,576 (the cap of `List.repeat` and
  `Range.to_a`). An unbounded channel lets a fast producer fill memory, while a
  full buffer slows the producer down to the consumer's speed (backpressure).
  There is no capacity 0 (Go's unbuffered rendezvous): capacity 1 is close
  enough, and one form is enough.
- **Timeouts are required**, with no "wait forever" value, on purpose: a single
  call never hangs, tasks that wait on each other through channels (a deadlock)
  get timeout errors, and every task waiting on a channel holds a timer, so the
  VM's stall check (§10.2.1) stays a guard against VM bugs only. A worker that
  must wait as long as needed uses the receive loop of the grammar example. That
  loop retries on a timeout, so if the producer never closes the channel it
  polls forever and the stall check cannot see it (the loop is not parked);
  hence the close rule below. With several producers, or one that may crash,
  each producer returns a `Result` and a coordinator awaits them all and then
  closes the channel. With one producer, `Task.spawn_owning(&produce, jobs)`
  makes it the owner of the channel, so the receive loop does not wait for a
  producer that died.
- **The close rule the skill teaches:** the producer closes, consumers never do,
  and the producer closes on every path, errors included. It puts the sending
  in its own function and closes after it (`result = send_all(jobs)`, then
  `jobs.close`, then `return result`), so a `try` that returns early still
  closes. No `Task.done?` is added for consumers to check a producer instead:
  27.3 leaves it out under the one-way rule.
- **`closed? and empty?` is exact.** Once it is `true` it stays `true`, since
  nothing can be added after a close, so after a `recv` error it tells the end
  of the stream from a timeout without matching error text. A closed channel
  that still holds values answers `false` to `empty?`, and the next `recv`
  returns a value.
- **Left out**, each until a real program needs it: `select` over several
  channels (fan-in uses one channel of an enum type, `Channel[Event]` with one
  variant per source, and each source sends into it; a coordinator awaits all
  the sources and then closes it); `for x in channel` (a second way to write the
  receive loop); unbounded and rendezvous channels; broadcast; `size` (its
  answer is stale at once with other tasks); `try_send` and `try_recv` (a
  timeout of 0); separate send-only and receive-only types.

**Is `Task.map` built on channels?** No: a channel cannot stop a timed-out
item's work, and channels do not replace `Task.map`, the one form for "the same
I/O for each item of a list".

### 27.3 `Task.await` with a timeout

Wait for a task's result, but not longer than `timeout_ms`. The contract is in
the grammar ([`06c-tasks-and-tests.md`](../grammar/06c-tasks-and-tests.md),
"Lightweight tasks"). The owner decided on 2026-10-14 to build it as a C builtin
that returns a builtin enum, `Await[T]`. Rejected: prelude code over a helper
task and a capacity-1 channel, returning `Result[T]`, which would make a timeout
an `error` next to the `error("task crashed: ...")` of a crashed task and a
`Result[Result[U]]` for a task that returns a `Result`.

**Decisions:**

- **A second arity of `Task.await`, not a new name.** The one-way test (§25
  Principle) rejects forms that only re-spell an existing call; this one adds
  behavior (the wait is bounded and the result says whether it ended in time).
  The catalog already selects signatures by arity (`Map.get`, `File.open` with a
  block, §25.9). A separate name (`await_timeout`, `wait`) would be two names
  for "await".
- **A timeout is a normal outcome, so it is not an error.** The result is
  `Await[T]`, not `Result[T]`, because a timeout is not a failure of the task:
  the task is fine, and the answer is "not yet". A dedicated type keeps it apart
  from a crash (`error("task crashed: ...")` when `T` is a `Result`) and
  from the `error` a task returns itself, and it avoids `Result[Result[U]]` for
  a task that returns `Result[U]`: that task gives `Await.Done(ok(5))`,
  `Await.Done(error("..."))` or `Await.TimedOut`, three cases that cannot be
  mixed up. `Await.Done(7)` and `Await.TimedOut` are also values that a program
  may write (for a test double, say), with the same inference rules as a user
  enum (`Await.TimedOut` alone needs an expected type:
  `CHECK-ENUM-TYPE-INFERENCE`).
- **`T = Void`.** `Await[Void]` cannot be written as a type annotation
  (`CHECK-VOID-TYPE`, as for any enum), but a variable gets it by inference; a
  program cannot write the value `Await.Done(...)` for `Void`. It prints as
  `Await.Done()`, like `ok()`.
- **A timeout does not cancel the task**, so a program can wait a bit, do other
  work, and wait again. Stopping the work is `Task.map`'s per-item timeout or
  `Task.cancel` (27.1). "Has it finished?" without any wait is not part of this
  item.
- **A settled task never times out.** The call checks the target before it
  waits and again when its wait times out, so a small timeout on a task that
  ended while the CPU was busy still gives `Await.Done(v)`.
- **No await cycles.** The timed form never waits forever, so it takes no part
  in the cycle check, and a timeout never halts the caller. A plain
  `Task.await` that reaches a task waiting with a timeout does not halt (the
  walk stops there, since `await_deadline` is set while it waits): if A awaits B
  with `Task.await(b)` and B awaits A with `Task.await(a, 20)`, B times out and
  ends, and then A gets B's result. The plain form keeps its check
  (`RUNTIME-TASK-AWAIT-CYCLE`). The stall check (§10.2.1) is unchanged.

### 27.4 Streams: `File.each_line` and `Lazy[T]`

**Decision:** two steps, decided by the owner on 2026-10-14. Step 1 is
`File.each_line`, a C builtin that reads a big file line by line in bounded
memory and adds no type (roadmap 17d, order row 7.2.1h). Step 2 is a lazy
recipe over sources, named `Lazy[T]` by the owner on 2026-10-20 (after Ruby's
`Enumerator::Lazy`; it was planned as `Stream[T]`), roadmap 17e, built in three
PRs.

The owner judged that streaming without loading everything is needed: Agentica's
loop and channel forms are too much ceremony to compose.

**Step 1: `File.each_line`.** The contract is in the programming skill
(`references/files.md`) and the site files page. It is the one form for that
job: it replaces a composition of `File.open`, a loop, `eof?`, `read_line` and
`close`. Left out: the same form for process and TCP lines
(`Process.each_line`, `TCP.each_line`); each waits for its own item when a real
program needs it.

**Step 2: `Lazy[T]`.** The contract is in the grammar
([`06b-builtins.md`](../grammar/06b-builtins.md), "`Lazy[T]`") and the site page
`library/data-structures/lazy.md`. The decisions:

- **Names.** Ruby's names first (`Enumerator::Lazy`, `Enumerator.produce`),
  Elixir's `Stream` only where simpler. Each method has one name, and a name
  `List` already has keeps its meaning: `filter` (not `select` or `reject`),
  `find`, `take`, `each_slice`, `reduce`.
- **A recipe, not a cursor.** `Lazy[T]` is a builtin generic type and an
  immutable value: building one does no work and opens nothing. A step returns
  a new `Lazy`; only a terminal runs it, and two terminals on the same `Lazy`
  run its source twice. There is no `next`, no `yield`, no generator and no
  `Enumerator.new` (27.5).
- **Sources.** `xs.lazy` and `Range.lazy` were decided against under the plan's
  one-way test ("no `list.stream`"); the owner reversed that on 2026-10-20: a
  recipe over a list is how `take`, `first` and `find` stop early on a long
  chain without building each list in between.
- **Steps.** `with_index do |x, i| ... end` maps each item with its index from
  0, since the language has no tuples to pair them (`List.each_with_index`
  passes the index to its block the same way); a program that needs both
  returns a struct. `filter_map` is left out: a `Result` from the block would
  mix "skip this item" with "this failed", and an `Optional` from the block
  (a builtin type) is not decided; it is `filter` then `map`.
- **Terminals return a `Result`, always.** One rule, since the I/O sources can
  fail in the middle. `to_list(max)` of the old plan is not taken: `first(n)`
  bounds the items, and `to_a` is Ruby's name.
- **Where it lives.** The catalog rows are prelude rows
  (`stdlib/prelude/lazy.agc`), so the checker binds the type variables as for
  the other prelude methods. The bodies call prelude-only builtins in
  `vm/lazy.c`: a heterogeneous chain of steps (each with its own item type)
  has no static type in the language, so the recipe cannot be written in the
  prelude itself.
- **Form.** Steps are methods of `Lazy`, since methods come from the
  receiver's module: `lz |> Lazy.map() do ... end` is `CHECK-PIPE-METHOD`.
- **A second terminal on `ch.lazy` is allowed, and goes on where the first
  stopped.** A channel cannot be read twice, so this is the one thing the
  second terminal can do. Rejecting it would need the checker to follow a
  `Lazy` value through variables and calls, or a run-time flag on an immutable
  recipe, and a program that reads a channel in two phases (a header with
  `first(n)`, then the rest with `each`) is natural. Socket and process lines
  stay an open question for the same reason: a stream cannot be read twice.
- **`File.foreach(...).each` with no step in between, written as one chain,
  is `CHECK-LAZY-NO-STEP`,** with a help that shows `File.each_line`. That chain
  is exactly the job of `File.each_line`, so it fails the one-way principle of
  §25. The check looks at the chain as written (the receiver of `.each` is the
  `File.foreach` call); a `Lazy` kept in a variable is not followed. The other
  terminals stay allowed with no step (`File.foreach(...).first(10)` is the
  head of a file, which `File.each_line` cannot give), and so does
  `ch.lazy(t).each`: a loop over `recv` is the only other form, and it is more
  ceremony, not one form for the job.
- **`try` works in every block of a `Lazy` method** (decided by the owner on
  2026-10-20, after comparing a CSV ledger ETL in Ruby, Elixir and Agentica).
  A block nested in such a block follows the usual rule (`CHECK-TRY-CONTEXT`
  unless it returns a `Result`). The checker marks each such `try` and the
  lowering emits the opcode `try-step` for it
  (`docs/vm/03-ir-and-bytecode.md`): on an error it returns from the block like
  `try` and sets `escaped` on the terminal's stepper, so a block whose value is
  itself a `Result` is never mistaken for a failure, and no other path pays for
  it. Wrapping the block's value in `ok(...)` was the other way; it costs an
  allocation per item and a second form of every step.
- **`lz.write_lines(path, timeout_ms)`** buffers its output 64 KiB at a time
  (not the 4 KiB of `File.write`, which would make a file job per 4 KiB), and a
  line over 1 MiB is an error, as `File.write` refuses such a text. There is no
  `buffer_bytes` argument: the reader needs one to bound a line, the writer does
  not. `--deny-fs` turns it off, as it does the other file calls.

**Later.** An Elixir-style `transform` (an accumulator, 0 to n items out per
item in, and a halt), if a program needs it, returns a std builtin struct from
its block, such as `Lazy.Step(emit: [row], state: key, halt: false)`: the
language has no tuples (owner, 2026-10-20; §25.12.6), and a struct carries the
grouped values. It is not built. Generators stay decided against
(§27.5): a task that sends into a channel is the producer, and a `Lazy` is a
recipe of fixed steps, not a producer with `yield`.

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
  - A `Lazy[T]` (27.4) is not a generator either: it is a recipe of fixed steps
    over a source, with no `yield` and no external `next`.
  - Help: `Enumerator.new(...)` and `Fiber.new(...)` show a producer task that
    sends into a `Channel` (`Task.spawn(&produce, ch)`, then
    `ch.recv(timeout_ms)`).
- **Elixir `Agent` and other shared mutable accumulators:** `Agent.start_link`,
  `Agent.update` and `Agent.get`, Ruby's `Concurrent::AtomicFixnum`, or a
  counter that blocks change.
  - Shared mutable state beyond two forms: values are immutable. The
    exceptions are the `std/logger` registry (the grammar's logging section),
    which only the Logger functions reach, and the `ATS` tables (the grammar's
    "Shared tables"), whose calls are atomic and take no block. Unlike an
    `Agent`, the registry is not a value that programs hold: a program never
    gets a reference to it.
  - A second way to accumulate: in one task, `reduce` or a loop variable; across
    tasks, each task returns its part (`Task.await`, `Task.map`) and the caller
    combines the parts with `reduce`; state that lives while tasks run belongs
    to one owner task that receives messages on a channel. An Elixir `Agent` is
    itself a process that receives messages, so the owner task is the same idea,
    written with the language's own parts (the example, with plain
    `Task.spawn` senders, is on the
    [channel page](../../site/content/library/concurrency/channel.md); a
    fan-in from `Task.map` follows the same shape).
  - Help: `Agent.start_link(...)` and the other `Agent` calls show "return
    values from tasks and combine them with `reduce`, or keep the state in one
    task that receives on a `Channel`". A block that assigns to an outer
    variable keeps its `CHECK-CAPTURED-ASSIGNMENT` and its help (use `reduce` or
    a `for` loop).
- **Public locks and threads:** `Mutex`, `Monitor`, `ConditionVariable`,
  semaphores, `Thread.new`, Ruby's `SizedQueue`.
  - With no shared mutable state there is nothing to lock (the `std/logger`
    registry is the one planned exception, and only the Logger functions read
    it); a lock held across a wait is also the classic deadlock, and agents get
    lock order wrong.
  - `Thread` is `Task`, and `SizedQueue` (a bounded, blocking queue) is
    `Channel`.
  - Help: `Thread.new` shows `Task.spawn(&f, arg)`; `Mutex.new` shows an owner
    task with a `Channel`; `SizedQueue.new` shows `Channel.new(capacity)`.
- **Options on `Task.map`:** Elixir's `ordered: false`, `on_timeout:` and
  `zip_input_on_exit:`. Keyword arguments are decided against (§25.13), and each
  option is a second behavior of one call. `Task.map` has one: input order,
  per-item timeout, cancel on timeout.

When the parts can simply be returned, returning them is the one form:
`Task.map(words, 3, 1000) do |w| ok(w.length) end`, then `reduce` over the
results.

### 27.6 Open questions

- **Resources over a channel.** Immutable values can be shared safely, but
  ports, sockets and contextual services carry state. A handle sent over a
  channel stays owned by the task that opened it; the ownership and
  synchronization rules for the others are open.
- **`Process.poll_line(p: Process, timeout_ms: Int) -> Result[String]`** may
  come later, so a loop can alternate requests with polling child output. It is
  not part of the task work, and no application has needed it yet.

[task-rules]: ../grammar/06c-tasks-and-tests.md#lightweight-tasks
