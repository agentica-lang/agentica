## 27. Iteration and concurrent collections

What was decided against in tasks and streams, so it is not proposed again, and
what is open. The principles are in `docs/grammar/01-overview.md` §2; values
have no shared mutable state except the `std/logger` registry and the `ATS`
tables. The concurrency primitives are a small set of C builtins (`Task.spawn`,
`Task.await`, `Task.sleep`, `Channel`, `Task.map`); higher-level helpers are
written in Agentica in the compiler prelude over them.

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
  - A `Lazy[T]` is not a generator either: it is a recipe of fixed steps
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
    registry is the one exception, and only the Logger functions read it); a
    lock held across a wait is also the classic deadlock, and agents get
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
  come later (issue #997), so a loop can alternate requests with polling child
  output. It is not part of the task work, and no application has needed it
  yet.
