# Lightweight tasks and channels

```text
Task.spawn(f: Fn[A, R], arg: A) -> Task[R]
Task.spawn_owning(f: Fn[A, R], handle: A) -> Task[R]
Task.await(task: Task[R]) -> R
Task.await(task: Task[R], timeout_ms: Int) -> Await[R]
Task.sleep(milliseconds: Int) -> Void
Task.pending_count() -> Int
Task.unobserved_crash() -> Result[String]
```

Start tasks before awaiting them to overlap I/O. They call named functions with one argument; pass a struct for multiple values. Each has independent variables, scopes and returns. Await returns the cached value and can be repeated. False, nil and error Results are normal values, with no extra Result wrapper. Task[R] has no constructor, equality, fields, indexing or JSON encoding; inspect prints `<Task>`.

A runtime error in a task other than `main` is a crash and ends only that task; `main` goes on. The crash prints its diagnostic on stderr at once (` in a task` after the code; `"task": true` in `--json`), cancels the task's running descendants, and closes the handles it owns. `Task.await` on a crashed task returns `error("task crashed: CODE at FILE:LINE:COLUMN: MESSAGE")` when `R` is a `Result`; otherwise the awaiter halts with RUNTIME-TASK-CRASHED at its await. Give a task a `Result` return type when its caller should handle a crash. When `main` returns and some crash was never awaited, the run exits 1 with a summary line on stderr (`1 task crash was not observed; first: ...`). With `--json`, a task crash line has `"task": true` and is not the run's diagnostic; an exit 1 from an unawaited crash ends with an `{"unobserved_crashes": ...}` line instead. `Task.unobserved_crash()` returns `ok(text)` for the first such crash, or an error; it does not observe it.

A handle (file, socket, listener, process, `std/http` server) belongs to the task that opened it, and the VM closes it when that task ends in any way: it returns, crashes or is cancelled (never an `HttpClient`; a channel has an owner only when `Task.spawn_owning` hands it over, see the close rule under Channel). Nothing goes to the parent, so a handle opened in a helper task and returned through `Task.await` is closed when the helper ends: open a long-lived handle in the task that keeps it, such as `main`. Ownership decides who closes, not who may use: `Task.spawn(&f, handle)` passes the handle and the caller still owns it, and any task that holds the handle can use it until its owner closes it, so the others get the closed error once the owner has ended. `Task.spawn_owning(&f, handle)` is the one hand-off: it starts the task like `Task.spawn` and gives it a handle the caller owns, so the new task closes it when it ends; a server handed over this way takes its listener with it. `Task.await` of an ended task returns after the regular files it owned are flushed and closed (not after a flush to a FIFO or a pipe). Use it for a connection that a server loop passes to its own task; a crash in that task then closes only that connection. The argument must be a `FileHandle`, `Socket`, `Listener`, `Process`, `HttpServer` or `Channel[T]` (CHECK-NOT-A-HANDLE otherwise, with a struct or list that holds a handle too). A handle the caller does not own, one already handed over, and a closed one halt the caller with RUNTIME-HANDLE-NOT-OWNED at the handle argument.

`Task.await(task, timeout_ms)` waits at most `timeout_ms` milliseconds and returns `Await[R]`, a builtin enum with two variants: `Await.Done(value)` holds the task's result and `Await.TimedOut` has no payload and no parentheses. Match both, or add `_`; `Await` is a reserved name (CHECK-REDEFINED-NAME for a struct, enum, type parameter or import alias with it), and `try` does not apply to it. A timeout does not cancel the task and does not stop the caller: the task keeps running, and a later `Task.await(task)` or timed await returns its result. A task that already ended never times out. `timeout_ms` must be positive: 0 or less halts with RUNTIME-INVALID-DURATION at the argument, so there is no poll with 0 (this differs from `Channel`). Call it once with the total time you can spare, not in a loop that polls. A crash or a cancel before the timeout gives the plain-await outcome (`Await.Done(error("task crashed: ..."))` for a `Result` task, otherwise a halt); one after `Await.TimedOut` does not reach the caller. A `Task[Void]` gives `Await[Void]`: match `Await.Done(_)` (a named binding is CHECK-VOID-TYPE). For a `Result` task, `Await.Done(r)` holds the Result: match it in a second `case`. The timed form never takes part in an await cycle: a task that timed-awaits its own handle, or two tasks that timed-await each other, get `Await.TimedOut` after the timeout (no RUNTIME-TASK-AWAIT-CYCLE), and a plain `Task.await` of a task that waits with a timeout does not halt. The plain form keeps its cycle check.

```ruby
def double(inbox: Channel[Int]) -> Int
  n = inbox.recv(10000).unwrap!
  return n * 2
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&double, inbox)
  case Task.await(task, 20)
    Await.Done(n) -> puts("done #{n}")
    Await.TimedOut -> puts("still working")
  end
  inbox.send(21, 1000)
  case Task.await(task, 10000)
    Await.Done(n) -> puts("done #{n}")
    Await.TimedOut -> puts("gave up")
  end
end
```

A runtime error in `main`, RUNTIME-STEP-LIMIT and System.exit in any task still end the whole run; System.exit keeps its code. Returning from the entrypoint cancels pending work; explicitly await tasks that must finish. External interruption cancels tasks and closes newly created resources while preserving caller-supplied ports. No CPU parallelism is exposed. A block can be the task function when passed through a `Fn` variable or parameter.

Random: each task has its own generator, split from its parent at spawn (one parent draw per spawn), so with `--seed N` each task repeats its own values. The interleaving can still vary with timers, sleeps, file and stdin reads, and the thread pool, even on one scheduler, so `--seed` does not make a multi-task run repeatable. Do not depend on cross-task order.

Sleep accepts nonnegative milliseconds; zero yields and negative values halt with RUNTIME-INVALID-DURATION at the argument. There is no `Task.cancel`, and a timed await does not cancel; the VM cancels a task only when an ancestor crashes. `Task.await` on a cancelled task returns `error("task: cancelled")` when `R` is a `Result`, and otherwise halts with RUNTIME-TASK-CANCELLED at the await. A program reaches it when a task sends its child's handle over a channel and then crashes: the child is cancelled, and an await of it in another task halts. Tasks inherit ports, program arguments and contextual services. Cross-task output order is unspecified; coordinate ownership of reads.

`pending_count` returns how many tasks of this run have not ended, not counting `main`: tasks waiting to run, the caller when it is not `main`, and tasks waiting on a sleep, an await, a channel or I/O. A returned or crashed task is not counted, even when nothing awaited it.

`Task.await` halts with RUNTIME-TASK-AWAIT-CYCLE at the await when the awaited task, or a task it awaits in turn, is waiting for the caller. A task that awaits its own handle (received over a channel, or captured by a closure) is the shortest cycle.

```ruby
def double(n: Int) -> Int
  Task.sleep(0)
  return n * 2
end

def main() -> Void
  first = Task.spawn(&double, 21)
  second = Task.spawn(&double, 7)
  puts(Task.await(first).to_s)
  puts(Task.await(second).to_s)
end
```

BDD step handlers may spawn tasks and pass `ctx` to them inside a struct. Finish them before returning, normally by awaiting them: `std/bdd` checks `Task.pending_count()` after each handler, and pending work fails the step with RUNTIME-BDD-PENDING-TASKS (also a `main` that leaves tasks running when it calls `BDD.run`). Assertions made by tasks count for the step. A context changed in a task is lost unless the handler takes it back from `Task.await`. A task that crashes and is not awaited fails the step with RUNTIME-TASK-CRASHED when the handler returns. A runtime error in the handler itself ends the scenario's child VM, so only that scenario fails.

## Channels

```text
Channel.new(capacity: Int) -> Channel[T]
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
Channel.close(channel: Channel[T]) -> Void
Channel.closed?(channel: Channel[T]) -> Bool
```

A channel is a bounded queue that tasks send values into and receive values from. All but `new` are methods too: `ch.send(v, 1000)`, `ch.recv(1000)`, `ch.close`, `ch.closed?`. `Channel` is a reserved name. `Channel[T]` takes any type a variable can have except `Void` (CHECK-VOID-TYPE); use `Bool` or `Nil` for a plain signal. A task handle, a socket or another channel is allowed. A channel is a handle: passing it shares it. It has no equality, text or JSON encoding; inspect prints `<Channel>`.

`Channel.new` needs an expected type, from an annotation, a parameter, a field or a return type: `jobs: Channel[Int] = Channel.new(16)`. Without one it is CHECK-EXPECTED-TYPE at the call. The capacity is 1 to 1048576, else RUNTIME-INVALID-COUNT at the argument. Channels are always bounded: a full channel slows the producer down.

`send` returns `ok()` once the value is in. A full channel makes the task wait for room, for a close, or for the timeout. `recv` returns `ok(v)` with the oldest value; an empty channel makes the task wait for a value, a close, or the timeout. Errors: `error("channel: closed")` (a send to a closed channel, or a recv from a closed and drained one) and `error("channel: timed out")`. A value that did not go in is not added. Values sent before `close` are still received after it. Every call has a timeout: 0 never waits (it tries once), a negative value is RUNTIME-INVALID-DURATION at the argument, and there is no wait-forever value. Values come out in order, and waiting tasks are served in the order they started waiting.

`closed?` is `true` once the channel is closed and every value was received, and then it stays `true`. After a `recv` error it tells the end of the stream (`true`) from a timeout (`false`). Do not match the error text.

The receive loop. It retries on a timeout and ends when the producer closed the channel:

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

The close rule: the producer closes the channel, on every path, and consumers never close it. If nobody closes it, the loop polls forever. Put the sending in its own function and close after it, as `produce` does, so a `try` that returns early still closes. A task that may crash should return a `Result`; a coordinator awaits it, gets an error if it crashed, and still closes.

A channel from `Channel.new` has no owner. `Task.spawn_owning(&produce, jobs)` makes the new task its owner (the first hand-off can come from any task), and when that task ends in any way (return, crash, cancel) the channel is closed as by `Channel.close`: the receive loop drains the values already sent, then gets `error("channel: closed")` at once, not after its timeouts. Use it for one producer that may die. Any task can still call `Channel.close` on an owned channel, plain `Task.spawn(&f, jobs)` gives no ownership, and only the owner can hand an owned channel on (RUNTIME-HANDLE-NOT-OWNED for any other task, or for a closed channel). For several producers keep the coordinator that awaits them all and then closes.

Pipeline: one producer, several workers that run the receive loop, and one collector. Pass several channels in a struct. The workers return how many items they handled. The collector sorts what it gets, so the output does not depend on timing:

```ruby
struct Lines
  jobs: Channel[Int]
  results: Channel[Int]
end

def work(lines: Lines) -> Int
  done = 0
  while true
    case lines.jobs.recv(1000)
      ok(n) ->
        lines.results.send(n * n, 1000)
        done += 1
      error(_) ->
        if lines.jobs.closed?
          break
        end
    end
  end
  return done
end
```

Fan-in: several sources send into one channel of an enum type, with one variant per source. A coordinator task awaits every source and then closes the channel, so the consumer's loop ends. There is no `select`.

```ruby
enum Event
  Item(String, Int)
  Failed(String)
end

struct Sources
  tasks: List[Task[Void]]
  events: Channel[Event]
end

def coordinate(sources: Sources) -> Void
  sources.tasks.each do |source|
    Task.await(source)
  end
  sources.events.close
end
```

State that several tasks update belongs to one owner task that receives messages on a channel and keeps the state in local variables. Others send it requests. There is no shared mutable state (the one exception is the `std/logger` registry: only the Logger functions reach it, and a program never holds a reference to it, unlike an `Agent`). There is no `Agent`, `Mutex`, `Thread`, `SizedQueue`, `Enumerator`, `Fiber` or lazy stream:

```ruby
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
```

A producer task that sends into a channel is the generator: its capacity gives backpressure, and `recv` is `next`.

One way for each job:

| Job | The one form |
|---|---|
| Change, select or combine the items of a list | `map`, `filter`, `reduce` and the other `List` methods (eager) |
| Keep a running total, or build a value in a loop | `reduce`, or a `for` or `while` loop that reassigns a local variable |
| Long-lived workers, producer and consumer, a flow of unknown length, results in the order they end | tasks and a `Channel` |
| State that several tasks update | one owner task that receives messages on a channel |
| Each line of a big file, in bounded memory | `File.each_line` |
| An endless sequence, or a source too big for a list | a `while` loop |

A channel wait holds a timer, so tasks that wait for each other through channels get timeout errors, not a hang. A file or socket sent over a channel stays owned by the task that opened it: it closes when that task ends or the run ends, so the task that opened it must outlive its users, or hand the handle to the worker with `Task.spawn_owning`.
