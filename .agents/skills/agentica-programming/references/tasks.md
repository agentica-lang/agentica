# Tasks and channels

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.spawn_owning(f: Fn[A, R], handle: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.await(task: Task[R], timeout_ms: Int) -> Await[R]
Task.map(items: List[A], limit: Int, timeout_ms: Int, f: Fn[A, Result[R]]) -> List[Result[R]]
Task.sleep(milliseconds: Int) -> Void
Task.cancel(task: Task[R]) -> Void
Task.pending_count() -> Int
Task.unobserved_crash() -> Result[String]
```

Start tasks before awaiting them to overlap I/O. A task calls a named function
with one argument (pass a struct for several values) and has its own variables.
Await returns the cached value and can repeat. `false`, `nil` and error Results
are normal values. `Task[R]` has no constructor, equality, fields, indexing or
JSON encoding; inspect prints `<Task>`. A block works as the task function
through a `Fn` variable or parameter.

A runtime error in a task other than `main` is a crash and ends only that task:
its diagnostic prints at once (` in a task` after the code; `"task": true` in
`--json`), its running descendants are cancelled and its handles closed.
`Task.await` on a crashed task returns `error("task crashed: CODE at
FILE:LINE:COLUMN: MESSAGE")` when `R` is a `Result`, else the awaiter halts with
`RUNTIME-TASK-CRASHED` at its await: give a task a `Result` return type when
its caller should handle a crash. When `main` returns with a crash never
awaited, the run exits 1 with `1 task crash was not observed; first: ...` on
stderr (`--json`: a final `{"unobserved_crashes": ...}` line; a task crash line
is not the run's diagnostic). `Task.unobserved_crash()` returns `ok(text)` for
the first such crash, or an error, without observing it.

A runtime error in `main`, `RUNTIME-STEP-LIMIT` and `System.exit` in any task
end the whole run (`System.exit` keeps its code). Returning from `main` cancels
pending work: await tasks that must finish. External interruption cancels tasks
and closes newly created resources, keeping caller-supplied ports. Cross-task
output order is unspecified. Tasks inherit ports, program arguments and
services.

Tasks run in parallel on one scheduler per logical core (`--schedulers N`, 1 to
1024, or `AGENTICA_SCHEDULERS`; `agentica test` reads only the variable; an
empty variable is unset). `--schedulers 1` runs one task at a time in a fixed
order. With more than one, `--max-steps` can trip a little late. Each task has
its own `Random` generator split from its parent at spawn, so `--seed N` repeats
each task's values but not the interleaving (timers, sleeps, file and stdin
reads and the thread pool vary it): do not depend on cross-task order.

`Task.sleep` takes nonnegative milliseconds (0 yields); a negative value is
`RUNTIME-INVALID-DURATION` at the argument. `pending_count` counts tasks of this
run that have not ended, not `main`: waiting to run, the caller when it is not
`main`, sleeping, awaiting, or waiting on a channel or I/O. Ended tasks and the
tasks `std/http` starts for an `HttpClient` are not counted.

## Handles and ownership

A handle (file, socket, listener, process, `std/http` server) belongs to the
task that opened it, and the VM closes it when that task returns, crashes or is
cancelled (never an `HttpClient`; a channel has an owner only through
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
The argument must be a `FileHandle`, `Socket`, `Listener`, `Process`,
`HttpServer` or `Channel[T]` (else `CHECK-NOT-A-HANDLE`, also for a struct or
list holding one). A handle the caller does not own, one already handed over, or
a closed one halts the caller with `RUNTIME-HANDLE-NOT-OWNED` at the argument.
`Task.await` of an ended task returns after the regular files it owned are
flushed and closed (not after a flush to a FIFO or pipe).

## Timed await

`Task.await(task, timeout_ms)` waits at most `timeout_ms` and returns
`Await[R]`: `Await.Done(value)` or `Await.TimedOut` (no payload, no
parentheses). Match both or add `_`; `Await` is reserved (`CHECK-REDEFINED-NAME`
for a struct, enum, type parameter or import alias with it) and `try` does not
apply. A timeout does not cancel the task or stop the caller: the task runs on,
and a later await returns its result. A task that already ended never times
out. `timeout_ms` must be positive: 0 or less is `RUNTIME-INVALID-DURATION` at
the argument (no poll with 0, unlike `Channel`). Call it once with the total
time you can spare, not in a polling loop. A crash or cancel before the timeout
gives the plain-await outcome (`Await.Done(error("task crashed: ..."))` for a
`Result` task, else a halt); one after `Await.TimedOut` does not reach the
caller. A `Task[Void]` gives `Await[Void]`: match `Await.Done(_)` (a named
binding is `CHECK-VOID-TYPE`). For a `Result` task `Await.Done(r)` holds the
Result: match it in a second `case`.

The plain `Task.await` halts with `RUNTIME-TASK-AWAIT-CYCLE` at the await when
the awaited task, or a task it awaits in turn, is waiting for the caller (a task
awaiting its own handle, received over a channel or captured, is the shortest
cycle). The timed form takes no part in a cycle: a task that timed-awaits its
own handle, or two that timed-await each other, get `Await.TimedOut` after the
timeout, and a plain await of a task waiting with a timeout does not halt.

## Cancel

`Task.cancel(task)` stops a task you no longer need (such as an owner task that
keeps state) without a "stop" message. It does not wait: it marks the task and
every task it started cancelled and returns. A cancelled task runs at most the
rest of its current turn: a sleep, channel wait, await or I/O wait ends at once;
a task mid-turn on another scheduler (a long loop) stops at the end of that
turn, so one in its last turn may end cancelled although it reached its return.
Its handles close as for any task end (a channel it owns closes, and receivers
get `error("channel: closed")`). Cancelling an ended task, or twice, does
nothing. Any task holding the handle may cancel it, also one received on a
channel. A task that cancels itself or an ancestor is cancelled too and stops
right after the call. A cancel is not a crash: no report, no exit code change. A
timed await does not cancel; the VM also cancels a task when an ancestor crashes
or its `Task.map` item times out. `Task.await` on a cancelled task returns
`error("task: cancelled")` when `R` is a `Result`, else halts with
`RUNTIME-TASK-CANCELLED` at the await: give a task you may cancel a `Result`
return type when something awaits it.

## Task.map

`Task.map(items, limit, timeout_ms) do |item| ... end` runs the block on each
item in its own task, at most `limit` at a time, and gives one `Result` per
item, in input order. Write `Task.map(...)`, never a method (`xs.map` is the
sequential `List.map`). A function value works as the last argument:
`Task.map(ids, 8, 5000, &fetch)`.

The block gives a `Result[R]`; `try` works in it, and a block that cannot fail
ends with `ok(x)`. Another last expression is `CHECK-TYPE-MISMATCH`. `R` comes
from the expected type or the first value the block gives, so a block whose
first value is `error(...)` needs `r: List[Result[Int]] = Task.map(...)`
(`CHECK-RESULT-TYPE` otherwise).

```ruby
def fetch(n: Int) -> Result[String]
  if n == 2
    Task.sleep(10000)
  end
  return ok("page #{n}")
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
- A cancelled item runs no more user code, nor does anything it started (a
  grandchild too, and a `Task.map` it called starts no more items). An I/O wait
  is detached, not abandoned: it ends on its own, its result is dropped and it
  never closes the handle; a `TCP.accept` or socket read that has taken nothing
  yet is dropped at once, so the next connection or bytes go to the next call.
  The item's handles close when it ends or is cancelled; an item that ended in
  time settles after its regular files are written and closed (a file it wrote
  is on disk when the call returns); a timed-out item settles at its deadline
  without waiting for its close. A timed-out `HTTP.get` connection is closed,
  not pooled.
- Open the handles an item needs inside the item. Calls on one handle wait for
  each other, so give a handle that many tasks need to one owner task and talk
  to it over a `Channel`. Items, captured variables and results are immutable
  and shared without copies.
- An item may call `Task.map`; the limits multiply. Starting an item costs one
  step of `--max-steps`.

## Channels

```text
Channel.new(capacity: Int) -> Channel[T]
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
Channel.close(channel: Channel[T]) -> Void
Channel.closed?(channel: Channel[T]) -> Bool
Channel.lazy(channel: Channel[T], timeout_ms: Int) -> Lazy[T]   # lazy.md
```

A channel is a bounded queue that tasks send into and receive from. All but
`new` are methods too: `ch.send(v, 1000)`, `ch.recv(1000)`, `ch.close`,
`ch.closed?`. `Channel[T]` takes any type a variable can have except `Void`
(`CHECK-VOID-TYPE`; use `Bool` or `Nil` for a signal), including a task handle,
a socket or another channel. A channel is a handle: passing it shares it. It
has no equality, text or JSON encoding; inspect prints `<Channel>`.

`Channel.new` needs an expected type (annotation, parameter, field or return
type): `jobs: Channel[Int] = Channel.new(16)`, else `CHECK-EXPECTED-TYPE`. The
capacity is 1 to 1048576, else `RUNTIME-INVALID-COUNT`. A full channel slows the
producer down.

`send` returns `ok()` once the value is in; a full channel makes the task wait
for room, a close or the timeout. `recv` returns `ok(v)` with the oldest value;
an empty channel makes the task wait for a value, a close or the timeout.
Errors: `error("channel: closed")` (a send to a closed channel, or a recv from
a closed, drained one) and `error("channel: timed out")`. A value that did not
go in is not added; values sent before `close` are still received after it.
Every call has a timeout: 0 tries once, a negative value is
`RUNTIME-INVALID-DURATION`, and there is no wait-forever value. Values come out
in order and waiting tasks are served in the order they began waiting.

`ch.lazy(timeout_ms)` reads the channel as a `Lazy` until it is closed and
drained (`lazy.md`): `jobs.lazy(5000).select do |n| n > 0 end.reduce(0) do |s,
n| s + n end`.

`closed?` is `true` once the channel is closed and every value was received,
and stays `true`. After a `recv` error it tells the end of the stream (`true`)
from a timeout (`false`); do not match the error text.

The receive loop retries on a timeout and ends when the producer closed the
channel:

```ruby
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
one collector; pass several channels in a struct, have workers return how many
items they handled, and sort what the collector gets so output does not depend
on timing. Fan-in: several sources send into one channel of an enum type with a
variant per source; a coordinator awaits every source, then closes the channel
so the consumer's loop ends. There is no `select`. A channel wait holds a timer,
so tasks waiting on each other through channels get timeout errors, not a hang.
A handle sent over a channel stays owned by the task that opened it, which must
outlive its users, or hand the handle over with `Task.spawn_owning`.

State that several tasks update belongs to one owner task that receives
messages on a channel and keeps the state in local variables; others send it
requests. There is no shared mutable state (the one exception is the
`std/logger` registry) and no `Agent`, `Mutex`, `Thread`, `SizedQueue`,
`Enumerator` or `Fiber`; a `Lazy` is a recipe one terminal runs in the calling
task, not a producer. A producer task sending into a channel is the generator:
its capacity gives backpressure and `recv` is `next`.

## One form per job

- Change, select or combine list items: `map`, `select`, `reduce` (eager).
- A running total or a value built in a loop: `reduce`; a `for` loop (its body
  can assign outer variables) only to update several at once.
- Run over a list at the same time, a few at a time, a timeout each, results in
  input order: `Task.map(items, limit, timeout_ms)`.
- Long-lived workers, producer and consumer, flows of unknown length, results in
  the order they end: tasks and a `Channel`.
- State several tasks update: one owner task receiving messages on a channel.
- Each line of a big file in bounded memory: `File.each_line`.
- An endless sequence or a source too big for a list: `Lazy` (`lazy.md`).
