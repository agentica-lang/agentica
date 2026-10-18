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
(see 27.1, "Why a builtin"). `Task.await` with a timeout (27.3) is a C builtin
too, by the owner's decision of 2026-10-14: the timeout lives in the scheduler,
as a timer on the job (`docs/vm/14-core-invariants.md` §14.2), and the prelude
it would have waited for does not exist yet.

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
**Status:** built (roadmap 17a, order row 7.3). The contract is in the grammar
([`06c-tasks-and-tests.md`](../grammar/06c-tasks-and-tests.md), "`Task.map`").

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

**Why a builtin, not prelude code.** With `Task.spawn` and `Task.await` there
is no way to wait for whichever item ends first and no way to cancel a task;
channels give bounded concurrency but not per-item timeouts (a receive with a
timeout stops only the waiter, not the work). So it schedules tasks and starts
timers in the VM, under exception 1 of the std-first rule (time).

**As built (17a).** `vm/task_map.c` and `docs/vm/10-io-scheduler.md` §10.2.1
("Task.map") describe the code. Where the plan left room: one timer on the
caller for the oldest deadline (not one job per item); no `dead` flag; an item
that ends after its deadline but before the caller runs keeps its result; an
item is settled only when done with no file close pending; the checker infers
`R` through the `Slot.InferResult` slot.

### 27.2 Channels

This finalizes the earlier channel proposal: a bounded buffer that tasks
send values into and receive values from, so producer and consumer pipelines
work.
**Status:** built (roadmap 17b). The contract is in the grammar
([`06c-tasks-and-tests.md`](../grammar/06c-tasks-and-tests.md), "Channels").
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

**Is `Task.map` built on channels?** No (see 27.1, "Why a builtin"): a channel
cannot stop a timed-out item's work. And channels do not replace `Task.map`: for
"the same I/O for each item of a list", `Task.map` is the one form; channels are
for flows of unknown length, long-lived workers and results in the order they
end.

**Where it lives.** C builtins in `vm/channel.c`; front end in `compiler/`.

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

**Await cycles and the stall check.** The caller holds a timer while it waits,
so the stall check (§10.2.1) is unchanged: every wait has a job or a live task.
The call does not run the cycle check, and the plain check skips a task that
waits with a timeout, so a timed await adds no way to a
`RUNTIME-TASK-AWAIT-CYCLE`, and a plain await never halts because of one. A
timed waiter always holds a timer, so the stall check still only guards VM bugs.

**BDD.** There is no helper task, so `RUNTIME-BDD-PENDING-TASKS` and
`Task.pending_count` are not affected: a timed-out await leaves only the target,
which is the program's own task.

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

**Step 1: `File.each_line` (roadmap 17d, order row 7.2.1h).** Built: a C
builtin, VM-only, that reads a file line by line in bounded memory and calls a
block for each line. The contract is in the programming skill
(`references/files.md`) and the site files page; the resumable-builtin and
file-read notes are in `docs/vm/03-ir-and-bytecode.md` §4.3 and
`docs/vm/10-io-scheduler.md` §10.2.1 and §10.2.2. It is the one form for that
job: it replaces a composition of `File.open`, a loop, `eof?`, `read_line` and
`close`. Left out: the same form for process and TCP lines
(`Process.each_line`, `TCP.each_line`); each waits for its own item when a real
program needs it.

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
