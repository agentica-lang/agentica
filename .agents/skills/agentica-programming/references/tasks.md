# Tasks, channels and shared tables

```text
Task.spawn(f: Fn[R]) -> Task[R]
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.spawn_owning(f: Fn[A, R], handle: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.await(task: Task[R], timeout_ms: Int) -> Await[R]
Task.map(items: List[A], limit: Int, timeout_ms: Int, f: Fn[A, Result[R]]) -> List[Result[R]]
Task.sleep(milliseconds: Int) -> Void
Task.cancel(task: Task[R]) -> Void
Task.pending_count() -> Int
Task.unobserved_crash() -> Result[String]
Task.monitor(task: Task[R], channel: Channel[M], wrap: Fn[TaskDown, M]) -> Void
Task.current() -> TaskRef
task.id -> Int
```

Start tasks before awaiting them to overlap I/O. A task calls a named function
with one argument or none (a struct for several values, built by the caller: the
task only uses it) and has its own variables.
Await returns the cached value and can repeat. `false`, `nil` and error Results
are normal values. `Task[R]` has no constructor, equality, fields or
JSON encoding. `Task.spawn do ... end` runs a
block as the task (it may capture locals); give a block or `&f`, not both. A
block that takes the argument goes through a `Fn` variable or parameter.

A runtime error in a task other than `main` is a crash and ends only that task:
its diagnostic prints at once (` in a task` after the code; `"task": true` in
`--json`), its running descendants are cancelled and its handles closed.
`Task.await` on a crashed task returns `error("task crashed: CODE at
FILE:LINE:COLUMN: MESSAGE")` when `R` is a `Result`, else the awaiter halts with
`RUNTIME-TASK-CRASHED` at its await: give a task a `Result` return type when
its caller should handle a crash. When `main` returns with a crash never
awaited, the run exits 1 with `1 task crash was not observed; first: ...` on
stderr. `Task.unobserved_crash()` returns `ok(text)` for the first such crash,
or an error, without observing it.

A runtime error in `main`, `RUNTIME-STEP-LIMIT` and `System.exit` in any task
end the whole run (`System.exit` keeps its code). Returning from `main` cancels
pending work: await tasks that must finish. Cross-task output order is
unspecified.

Tasks run in parallel on one scheduler per logical core (`--schedulers N` or
`AGENTICA_SCHEDULERS`; `agentica test` reads only the variable).
`--schedulers 1` runs one task at a time in a fixed order. Each task has its
own `Random` generator split from its parent at spawn, so `--seed N` repeats
each task's values but not the interleaving: do not depend on cross-task order.

`Task.sleep` takes nonnegative milliseconds (0 yields); a negative value is
`RUNTIME-INVALID-DURATION` at the argument. `pending_count` counts tasks of this
run that have not ended, not `main` and not the tasks `std/http` starts for an
`HTTP.Client`.

## Handles and ownership

A handle (file, socket, listener, process, `std/http` server) belongs to the
task that opened it, and the VM closes it when that task returns, crashes or is
cancelled (never an `HTTP.Client`; a channel has an owner only through
`Task.spawn_owning`, below). Nothing passes to the parent: a handle opened in a
helper and returned through `Task.await` is closed when the helper ends, so
open a long-lived handle in the task that keeps it, such as `main`. Ownership
decides who closes, not who may use: `Task.spawn(&f, handle)` passes the handle
and the caller keeps ownership, and any task holding the handle can use it until
its owner closes it (then it gets the closed error).

`Task.spawn_owning(&f, handle)` is the one hand-off: it starts the task like
`Task.spawn` and gives it a handle the caller owns, so the new task closes it
when it ends (a server takes its listener with it). Use it for a connection that
a server loop passes to its own task; a crash then closes only that connection.
The argument must be a `File.Handle`, `TCP.Socket`, `TCP.Listener`, `Process`,
`HTTP.Server`, `Channel[T]`, native resource or owned buffer, or a struct, enum,
`List`, `Map` or `Result` whose type holds one (else `CHECK-NOT-A-HANDLE`). The
new task gets the value and owns every handle in it, so an enum
`Conn.Sqlite(db)` hands over `db`. A handle the caller does not own, one already
handed over, or a closed one halts the caller with `RUNTIME-HANDLE-NOT-OWNED` at
the argument, and then none of the value's handles move.
`Task.await` of an ended task returns after the regular files it owned are
flushed and closed (not after a flush to a FIFO or pipe).

## Timed await

`Task.await(task, timeout_ms)` waits at most `timeout_ms` and returns
`Await[R]`: `Await.Done(value)` or `Await.TimedOut` (no payload, no
parentheses). Match both or add `_`; `Await` is reserved (`CHECK-REDEFINED-NAME`
for a struct, enum, type parameter or import alias with it) and `try` does not
apply. A timeout does not cancel the task or stop the caller: the task runs on,
and a later await returns its result. `timeout_ms` must be positive: 0 or less
is `RUNTIME-INVALID-DURATION` (no poll with 0, unlike `Channel`). Call it once
with the total time you can spare, not in a polling loop. A crash or cancel
before the timeout gives the plain-await outcome (`Await.Done(error("task
crashed: ..."))` for a `Result` task, else a halt). A `Task[Void]` gives
`Await[Void]`: match `Await.Done(_)` (a named binding is `CHECK-VOID-TYPE`). For
a `Result` task `Await.Done(r)` holds the Result: match it in a second `case`.

The plain `Task.await` halts with `RUNTIME-TASK-AWAIT-CYCLE` at the await when
the awaited task, or a task it awaits in turn, is waiting for the caller (a task
awaiting its own handle, received over a channel or captured, is the shortest
cycle). The timed form takes no part in a cycle: it gives `Await.TimedOut` after
the timeout.

## Cancel

`Task.cancel(task)` stops a task you no longer need (such as an owner task that
keeps state) without a "stop" message. It does not wait: it marks the task and
every task it started cancelled and returns. A cancelled task runs at most the
rest of its current turn: a sleep, channel wait, await or I/O wait ends at once;
a long loop stops at the end of its turn. Its handles close as for any task end
(a channel it owns closes, and receivers get `error("channel: closed")`).
Cancelling an ended task, or twice, does nothing. Any task holding the handle
may cancel it, also one received on a channel. A cancel is not a crash: no
report, no exit code change. A timed await does not cancel; the VM also cancels
a task when an ancestor crashes or its `Task.map` item times out. `Task.await`
on a cancelled task returns `error("task: cancelled")` when `R` is a `Result`,
else halts with `RUNTIME-TASK-CANCELLED` at the await: give a task you may
cancel a `Result` return type when something awaits it.

## Monitors

`Task.monitor(task, inbox) do |down| Msg.Down(down) end` sends
`wrap(TaskDown(...))` into the channel once when the task ends (returns,
crashes or is cancelled), at once for a task that has ended; several monitors
of one task each get one, and none can be removed. Use the consumer's one
channel of an enum (there is no `select`). `TaskDown` is a builtin record:
`task_id: Int` (equal to `task.id`), `reason: TaskExit` (`TaskExit.Ok`,
`TaskExit.Crashed` or `TaskExit.Cancelled`), and for a crash its diagnostic:
`code` (the stable `RUNTIME-` code, to match on), `message`, `file`, `line`
and `column` (`""` and `0` otherwise). The send never
waits or fails: a closed or full channel drops the notice, so give it room for
every notice that can be pending at once. A
crash whose notice went in counts as observed. `wrap` runs in a task of its
own. Monitor a task after any setup step that can fail: a failed start leaves
a stale notice in the inbox.

`Task.current` is the running task as a `TaskRef`: `Task.monitor`,
`Task.cancel` and `.id` take it, but `Task.await` of it is
`CHECK-TYPE-MISMATCH`.

## Task.map

`Task.map(items, limit, timeout_ms) do |item| ... end` runs the block on each
item in its own task, at most `limit` at a time, and gives one `Result` per
item, in input order. Write `Task.map(...)`, never a method (`xs.map` is the
sequential `List.map`). A function value works as the last argument:
`Task.map(ids, 8, 5000, &fetch)`.

The block gives a `Result[R]`; `try` works in it, and a block that cannot fail
ends with `ok(x)`. Another last expression is `CHECK-TYPE-MISMATCH`. `R` comes
from the expected type or the first `ok(...)` the block gives, so a block that
gives only `error(...)` needs `r: List[Result[Int]] = Task.map(...)`
(`CHECK-RESULT-TYPE` otherwise).

```ruby
def fetch(n: Int) -> Result[String]
  if n == 2
    Task.sleep(10000)
  end

  ok("page #{n}")
end

def main() -> Void
  pages = Task.map([1, 2, 3], 3, 200, &fetch)
  puts(pages)   # [ok("page 1"), error("task: timed out"), ok("page 3")]
end
```

- Items start in input order and the next starts when one ends (a sliding
  window). The call waits until every item has ended; to get results as they
  end, use a channel.
- `timeout_ms` is per item, from its start until it ends, including its wait in
  the run queue. An item out of time is cancelled and its slot is
  `error("task: timed out")`. There is no total timeout: a call takes at most
  about ceil(items / limit) * `timeout_ms`.
- An item's `error(...)` does not stop the others. A runtime error inside an
  item crashes only that item: its slot is `error("task crashed: ...")`.
- `limit` is 1 to 1024, else `RUNTIME-INVALID-COUNT` at that argument;
  `timeout_ms` must be above 0, else `RUNTIME-INVALID-DURATION`. Both are
  checked first, also for an empty list (which gives `[]`). A `limit` above the
  list size starts every item at once.
- `limit` is for I/O (HTTP, files, processes). CPU work runs on at most one item
  per scheduler, and an item's clock includes its run-queue time, so a `limit`
  above the scheduler count over CPU work makes timeouts likelier, not the work
  faster.
- A cancelled item runs no more user code, nor does anything it started. An I/O
  wait ends on its own, its result is dropped and it never closes the handle.
  The item's handles close when it ends or is cancelled; a file it wrote is on
  disk when the call returns, except for a timed-out item.
- Open the handles an item needs inside the item. Calls on one handle wait for
  each other, so give a handle that many tasks need to one owner task and talk
  to it over a `Channel`. Items, captured variables and results are immutable
  and shared without copies.
- An item may call `Task.map`; the limits multiply.

## Channels

```text
Channel.new(capacity: Int) -> Channel[T]
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
Channel.close(channel: Channel[T]) -> Void
Channel.closed?(channel: Channel[T]) -> Bool
Channel.empty?(channel: Channel[T]) -> Bool
Channel.lazy(channel: Channel[T], timeout_ms: Int) -> Lazy[T]   # lazy.md
Channel.address(channel: Channel[T]) -> Address[T]
Address.send(address: Address[T], value: T, timeout_ms: Int) -> Result[Void]
```

A channel is a bounded queue that tasks send into and receive from. All but
`new` are methods too: `ch.send(v, 1000)`, `ch.recv(1000)`, `ch.close`,
`ch.closed?`, `ch.empty?`. `Channel[T]` takes any type a variable can have
except `Void` (`CHECK-VOID-TYPE`; use `Bool` or `Nil` for a signal), including a
task handle, a socket or another channel. A channel is a handle: passing it
shares it. It has no equality, text or JSON encoding.

`Channel.new` needs an expected type (annotation, parameter, field or return
type): `jobs: Channel[Int] = Channel.new(16)`, else `CHECK-EXPECTED-TYPE`. The
capacity is 1 to 1048576, else `RUNTIME-INVALID-COUNT`.

`send` returns `ok()` once the value is in; a full channel makes the task wait
for room, a close or the timeout. `recv` returns `ok(v)` with the oldest value;
an empty channel makes the task wait for a value, a close or the timeout.
Errors: `error("channel: closed")` (a send to a closed channel, or a recv from a
closed, drained one) and `error("channel: timed out")`. Values sent before
`close` are still received after it. Every call has a timeout: 0 tries once, a
negative value is `RUNTIME-INVALID-DURATION`, and there is no wait-forever
value.

`ch.lazy(timeout_ms)` reads the channel as a `Lazy` until it is closed and
drained (`lazy.md`): `jobs.lazy(5000).select { |n| n > 0 }.reduce(0) do |s,
n| s + n end`.

`closed?` is `true` once the channel is closed, even with values still
buffered (Ruby's `Queue#closed?`): a producer reads it between sends to learn
that the reader closed the channel. `empty?` is `true` when no value is left to
receive. `closed? and empty?`, in that order, is the end of the stream and stays
`true`; after a `recv` error it tells the end from a timeout. Do not match the
error text.

The receive loop retries on a timeout and ends when the producer closed the
channel:

```ruby
def send_all(jobs: Channel[Int]) -> Result[Void]
  for n in 1..5
    try jobs.send(n, 1000)
  end

  ok()
end

def produce(jobs: Channel[Int]) -> Result[Void]
  result = send_all(jobs)
  jobs.close
  result
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(2)
  producer = Task.spawn(&produce, jobs)
  total = 0
  while true
    case jobs.recv(1000)
      ok(n) -> total += n
      error(_) -> break if jobs.closed? and jobs.empty?
    end
  end

  puts(total)
  puts(Task.await(producer))
end
```

The close rule: the producer closes the channel on every path; consumers never
do. If nobody closes it, the loop polls forever. Put the sending in its own
function and close after it, as `produce` does, so a `try` that returns early
still closes. A task that may crash should return a `Result`; a coordinator
awaits it, gets an error if it crashed, and still closes.

A channel from `Channel.new` has no owner. `Task.spawn_owning(&produce, jobs)`
makes the new task its owner (the first hand-off can come from any task), and
when that task ends in any way the channel closes as by `Channel.close`: the
loop drains the values already sent, then gets `error("channel: closed")` at
once. Use it for one producer that may die. Any task can still call
`Channel.close` on an owned channel, plain `Task.spawn(&f, jobs)` gives no
ownership, and only the owner can hand an owned channel on
(`RUNTIME-HANDLE-NOT-OWNED` otherwise, or for a closed one). For several
producers keep a coordinator that awaits them all and then closes.

Patterns. Pipeline: one producer, several workers running the receive loop,
one collector; sort what the collector gets so output does not depend on
timing. Fan-in: several sources send into one channel of an enum type with a
variant per source; a coordinator awaits every source, then closes the channel.
There is no `select`. A handle sent over a channel stays owned by the task that
opened it, which must outlive its users, or hand it over with
`Task.spawn_owning`.

Addresses. `ch.address` is an `Address[T]`: a send-only name of the channel
that is data, so an `ATS` value, a list, a map value, a struct field, an enum
payload or a message can hold it, where a channel cannot go. `addr.send(v,
1000)` is `Channel.send` (same waits and errors); `error("address: gone")` once
the channel was collected; no `recv`. Two addresses of one channel are `==`;
`puts` prints `<Address N>`. Not JSON, not a map key or set element, not in a
constant. It is not a handle: to give a task its own socket or channel and also
a shared channel, pass `Link(socket: s, results: results.address)` to
`Task.spawn_owning`; only the socket is handed over, `results` stays open. A
registry by name is a constant table:
`NAMES: ATS[String, Address[Msg]] = ATS.new()` (below). Your own
`struct Address` (no type parameters) is fine; a generic struct, enum or alias
named `Address` is `CHECK-REDEFINED-NAME`.

A counter or a cache that several tasks update goes in an `ATS` table (below);
other shared state belongs to one owner task that receives messages on a
channel. Apart from `ATS` tables and the `std/logger` registry there is no
shared mutable state, and there is no `Agent`, `Mutex`, `Thread`, `SizedQueue`,
`Enumerator` or `Fiber`; a `Lazy` is a recipe one terminal runs in the calling
task, not a producer. A producer task sending into a channel is the generator:
its capacity gives backpressure and `recv` is `next`.

## One form per job

- Change, select or combine list items: `map`, `select`, `reduce` (eager).
- Run over a list at the same time, a few at a time, a timeout each, results in
  input order: `Task.map(items, limit, timeout_ms)`.
- Long-lived workers, producer and consumer, flows of unknown length, results in
  the order they end: tasks and a `Channel`.
- Shared state: an `ATS` table (counter, cache) or one owner task receiving
  messages: an actor (`std/actor`, below).
- Each line of a big file in bounded memory: `File.each_line`.
- An endless sequence or a source too big for a list: `Lazy` (`lazy.md`).

## Shared tables (ATS)

```text
ATS.new() -> ATS[K, V]                                   # needs an expected type
ATS.put(table: ATS[K, V], key: K, value: V) -> Void      # insert or replace
ATS.put_new(table: ATS[K, V], key: K, value: V) -> Bool  # false: key present, no change
ATS.get(table: ATS[K, V], key: K) -> Result[V]
ATS.has_key?(table: ATS[K, V], key: K) -> Bool
ATS.delete(table: ATS[K, V], key: K) -> Void             # absent key ignored
ATS.add(table: ATS[K, Int], key: K, n: Int) -> Int       # absent counts as 0
ATS.size(table: ATS[K, V]) -> Int
ATS.keys(table: ATS[K, V]) -> List[K]                    # first-insertion order
ATS.to_map(table: ATS[K, V]) -> Map[K, V]                # first-insertion order
```

An `ATS[K, V]` is one mutable table that tasks share through a handle: passing
it shares it, never copies it. All but `new` are methods: `hits.add("home",
1)`. `hits: ATS[String, Int] = ATS.new()`, else `CHECK-EXPECTED-TYPE`. Keys are
`Int`, `String` or `Bytes` (`CHECK-MAP-KEY-TYPE`); `V` is data with no `Fn`,
`Task`, `Channel`, handle or table anywhere inside, and not `Nil`
(`CHECK-ATS-VALUE`); an `Address` is data, so it may be a value. A table may be
a struct field or a `Task.spawn` argument; no task owns it, and there is no size
limit or expiry. No `==`, text or JSON; use `to_map` to see it.

A constant may be a table when `ATS.new()` is its whole initializer and its type
is written: `HITS: ATS[String, Int] = ATS.new()` is made once per run, before
`main`, and every task and every file that imports it shares it. A table
anywhere else in a constant (`[ATS.new()]`, another constant's table) is
`CHECK-CONSTANT-TYPE`.

Each call is atomic on any scheduler; there are no multi-key transactions and no
block-based update. `add` is the one atomic read-modify-write (`Int` values
only, `CHECK-TYPE-MISMATCH` otherwise; overflow is `RUNTIME-INTEGER-OVERFLOW`
and leaves the table unchanged), and `put_new` the one conditional insert: the
cache pattern is `get`, compute on a miss, then `put_new`, which stores one
value even when two tasks miss at once. `keys` and `to_map` are snapshots; a key
deleted and put again goes to the end. Sort `keys` before printing when tasks
fill the table, since their order follows the schedule. In BDD, a table made in
`main` and captured by step blocks starts fresh in each scenario.

## Actors (`std/actor`)

```text
import Actor from "std/actor"
Actor.start(b: Actor.Behaviour[S, M], options: Actor.Options = Actor.Options()) -> Actor.Ref[S, M]
Actor.Behaviour(init: Fn[S], handle: Fn[S, M, Actor.Step[S]], terminate: Optional[Fn[S, Void]] = none)
Actor.Options(capacity: Int = 1024)
Actor.continue(state: S) -> Actor.Step[S]
Actor.done(state: S) -> Actor.Step[S]
Actor.cast(address: Address[M], message: M, timeout_ms: Int = 5000) -> Result[Void]
Actor.call(address: Address[M], timeout_ms: Int, make: Fn[Channel[R], M]) -> Result[R]
Actor.reply(channel: Channel[R], value: R) -> Void
Actor.stop(actor: Actor.Ref[S, M], timeout_ms: Int) -> Result[Void]
```

An actor is a task that owns its state `S` and handles the messages `M` (your
enum) of one inbox, one at a time. The handler ends with
`Actor.continue(state)`, or `Actor.done(state)` to end the actor (then
`terminate` runs). A `Ref` has `address` (the `Address[M]` to send to),
`inbox` (only for `Task.monitor(task, actor.inbox) do |d| Msg.Down(d) end`;
never `recv` from it) and `task`. `cast` and `call` take the address, `stop`
the `Ref`; there are no methods.

- `call` builds the message around a new reply channel and waits:
  `Actor.call(addr, 1000) do |reply| Msg.Get(reply) end`; the handler answers
  with `Actor.reply(reply, value)`. The answer type comes from the expected
  type (the function's `Result[Int]`), or else from the variant the block
  builds (`Msg.Get(Channel[Int])`), so the call works in `puts` too.
- Errors: `error("actor: timeout")` (inbox full or no answer in time) and
  `error("address: gone")` (the actor ended). A call whose actor crashes, a
  call to its own address from a handler, and two actors calling each other
  end with the timeout.
- `stop` closes the inbox, lets the actor handle what is in it, run
  `terminate` and end, and waits at most `timeout_ms`; then it cancels the
  actor and gives `actor: timeout`. A crashed actor gives its `task crashed:
  ...` error. Only the `Ref` holder can stop: to stop by address, add a `Stop`
  variant whose handler gives `Actor.done(state)`.
- A crash in a handler ends the actor (its diagnostic prints, `terminate` does
  not run, queued messages are lost). A crash nothing observes fails the run
  when `main` returns: observe it with `Actor.stop`, `Task.await(ref.task)` or
  `Task.monitor(ref.task, ...)`. A monitor notice into a full inbox is dropped.
- The actor is a child of the task that calls `start`: a crash or cancel of
  that task cancels it. Start long-lived actors from `main` or a supervisor.
- `timeout_ms` of `stop` must be above 0 (`RUNTIME-INVALID-DURATION`); give
  `call` one above 0 too: `call(addr, 0)` still enqueues the message, then
  gives `actor: timeout`.
- Names: a module keeps `NAMES: ATS[String, Address[Msg]] = ATS.new()` (a
  constant goes before the enum in a module block) and wraps `cast` and `call`
  in its own functions, so callers never see `Msg`.
- `init: -> { initial }` is a lambda, or use a named `&init`. Annotate
  `b: Actor.Behaviour[Int, Msg] = ...` when lambdas take parameters.

## Supervisors (`std/supervisor`)

```text
import Supervisor from "std/supervisor"
Supervisor.child(name: String, b: Actor.Behaviour[S, M], register: Fn[Address[M], Void]) -> Supervisor.Child
Supervisor.start(children: List[Supervisor.Child], options: Supervisor.Options = Supervisor.Options()) -> Supervisor.Ref
Supervisor.Options(max_restarts: Int = 3, within_ms: Int = 5000)
Supervisor.stop(supervisor: Supervisor.Ref, timeout_ms: Int) -> Result[Void]
```

A supervisor starts its children (actors) in list order and starts again one
that crashes (one for one); `start` returns once each started once. The
register block gets the address of each new actor, in a task of its own:
`do |address| names.put("visits", address) end` (required; a child nobody
reaches by name gives `do |_address| nil end`). After a restart the name holds
the new address; an old address gives `address: gone`, so look the name up on
each call.

- Only a crash restarts; a child that gives `Actor.done` stays down. A failed
  start (crash in `init`, or a register block that crashes or runs over 5 s)
  counts as a crash. `max_restarts` >= 0 and `within_ms` > 0, else `start`
  halts (`RUNTIME-UNWRAP-ERROR`).
- The limit is per child: more than `max_restarts` crashes within `within_ms`,
  or more than `max_restarts` failed starts in a row (no time window), and the
  supervisor stops the others in reverse order and crashes:
  `RUNTIME-UNWRAP-ERROR`, message `supervisor: NAME crashed N times in M ms`
  (`1 time` for one), or `supervisor: NAME failed to start N times in a row`.
  Unobserved (no `stop`, `Task.await(sup.task)` or monitor), it fails the run.
- `stop` stops the children in reverse order within `timeout_ms` (above 0)
  and gives the first child's stop error; after a give-up it gives the give-up
  error, and out of time `supervisor: timeout` (and cancels). Once the time is
  used up, the children left are cancelled without `terminate`.
- The supervisor is a child of the task that calls `start`: start it from
  `main`.
