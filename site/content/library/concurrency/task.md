---
title: Task
weight: 1
description: Start, await (with or without a timeout), pause, cancel and count lightweight tasks, map a block over a list with bounded concurrency, hand a handle to a task, and find their crashes.
---

Tasks run functions at the same time. See the tour page [Tasks](/tour/tasks/).

## Task.spawn

```text
Task.spawn(function: Fn[R]) -> Task[R]
Task.spawn(function: Fn[A, R], argument: A) -> Task[R]
```

Starts `function(argument)` in a new task and returns its `Task` handle. Without an argument, the function takes no parameter: `Task.spawn(&work)` starts `work()`.

A block is the function too: `Task.spawn do ... end` runs the block as a task, like Ruby's `Thread.new { }`, and it may capture locals. Give a block or a function reference, not both (`CHECK-BLOCK-TARGET`). `Task.spawn_owning` always takes the handle.

- A file, socket, listener, process or server belongs to the task that opened it and closes when that task ends (returns, crashes or is cancelled). So open a long-lived handle in the task that keeps it, not in a helper.
- `Task.spawn` moves nothing: a handle in the argument, or in a struct or list in it, stays with the caller. To give it away, use `Task.spawn_owning`.

```agentica
def greet(name: String) -> String
  return "hi #{name}"
end

def main() -> Void
  task = Task.spawn(&greet, "Ana")
  puts(Task.await(task))
end
```

```output
hi Ana
```

## Task.spawn_owning

```text
Task.spawn_owning(function: Fn[A, R], handle: A) -> Task[R]
```

Starts `function(handle)` like `Task.spawn` and gives `handle` to the new task in the same call.

- The argument must be a `FileHandle`, `Socket`, `Listener`, `Process`, `HttpServer`, `Channel[T]`, or a [native resource or owned buffer](/library/io-and-system/native/types/). Anything else (an `Int`, a struct that holds a socket, an `HttpClient`) is `CHECK-NOT-A-HANDLE`.
- The caller must own the handle, and can still use it while the new task runs. Otherwise (not owned, already handed over, closed) the caller stops with `RUNTIME-HANDLE-NOT-OWNED` and no task is made.
- A server loop can give each accepted connection to its own task, so a crash closes only that connection. A handed-over server takes its listener along and keeps serving after its creator ends.
- A [Channel](/library/concurrency/channel/) has no opener, so any task can make the first hand-off. The ownership rules are in [a producer that owns the channel](/library/concurrency/channel/#a-producer-that-owns-the-channel).

```agentica
def echo(socket: Socket) -> Result[String]
  line = try TCP.read_line(socket, 2000)
  try TCP.send(socket, "echo: #{line}\n", 2000)
  return ok(line)
end

def main() -> Void
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  client = TCP.connect("127.0.0.1", TCP.local_port(listener), 2000).unwrap!
  connection = TCP.accept(listener, 2000).unwrap!
  worker = Task.spawn_owning(&echo, connection)
  sent = TCP.send(client, "hello\n", 2000)
  puts(TCP.read_line(client, 2000))
  puts(Task.await(worker))
  puts(TCP.read_line(client, 2000))
  TCP.close(client)
  TCP.close_listener(listener)
end
```

```output
ok("echo: hello")
ok("hello")
error("network: end of input")
```

`echo` never closes the connection. Its end does, so the client reads the end of the input.

## Task.await

```text
Task.await(task: Task[R]) -> R
```

Waits for the task and gives its result. Waiting again gives the same value.

- A runtime error in a task other than `main` is a crash. It ends only that task: the error goes to stderr, the task's own tasks are cancelled and its handles close.
- Awaiting a crashed task that returns a `Result` gives `error("task crashed: CODE at FILE:LINE:COLUMN: MESSAGE")`. For any other type the waiting task stops with `RUNTIME-TASK-CRASHED`.
- A crash that no await sees makes the run exit with code 1 when `main` returns.
- Awaiting yourself, directly or through other tasks (a handle can arrive over a [Channel](/library/concurrency/channel/)), stops with `RUNTIME-TASK-AWAIT-CYCLE`.

```agentica
def parse(text: String) -> Result[Int]
  return ok(100 / text.to_i!)
end

def main() -> Void
  task = Task.spawn(&parse, "0")
  case Task.await(task)
    ok(n) -> puts(n)
    error(e) -> puts(e.starts_with?("task crashed: RUNTIME-DIVISION-BY-ZERO"))
  end
  puts("still running")
end
```

```output
true
still running
```

## Task.await with a timeout

```text
Task.await(task: Task[R], timeout_ms: Int) -> Await[R]
```

Waits at most `timeout_ms` milliseconds.

- `Await[R]` is a builtin enum: `Await.Done(value)` holds the result, `Await.TimedOut` (no payload, no parentheses) means time ran out first.
- A `case` must match both variants, or use `_`. `Await` is reserved (no struct, enum or import alias may use it), and `try` does not apply to it.
- `timeout_ms` must be above 0, otherwise `RUNTIME-INVALID-DURATION`. Call it once with the total time you can spare; do not poll.
- A timeout does not cancel the task. It keeps running, and a later await gives its result. An ended task never times out.
- If the task crashes or is cancelled first, you get the plain await's outcome: `Await.Done(error(text))` for a `Result` task, otherwise `RUNTIME-TASK-CRASHED` or `RUNTIME-TASK-CANCELLED`. A crash after `Await.TimedOut` does not reach the caller.
- A timed await skips the cycle check: a task awaiting itself with a timeout gets `Await.TimedOut`, and a plain await of a task that waits with a timeout is not `RUNTIME-TASK-AWAIT-CYCLE`.

The worker waits on a [Channel](/library/concurrency/channel/). The first wait runs out of time, the worker keeps waiting, and the second wait gets its result:

```agentica
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

```output
still working
done 42
```

For a `Result` task, `Await.Done` holds the `Result`: match it in a second `case`.

```agentica
def parse(text: String) -> Result[Int]
  return ok(100 / text.to_i!)
end

def main() -> Void
  task = Task.spawn(&parse, "4")
  case Task.await(task, 1000)
    Await.Done(result) ->
      case result
        ok(n) -> puts("parsed #{n}")
        error(e) -> puts(e)
      end
    Await.TimedOut -> puts("timed out")
  end
  IO.inspect(Task.await(task, 1))
end
```

```output
parsed 25
Await.Done(ok(25))
```

A `Void` task gives `Await[Void]`: match its payload with `_` (`Await.Done(_)`). A name there is `CHECK-VOID-TYPE`.

## Task.map

```text
Task.map(items: List[A], limit: Int, timeout_ms: Int, function: Fn[A, Result[R]]) -> List[Result[R]]
```

Runs the function for each item in its own task, at most `limit` at a time. It gives one `Result` per item, in the order of `items`.

- It is never a method: `xs.map` stays the sequential `List.map`.
- The function is usually the trailing block. It gives a `Result[R]` (`try` works in it; end a block that cannot fail with `ok(x)`). Any other last value is `CHECK-TYPE-MISMATCH`.

```agentica
def slow_double(n: Int) -> Result[Int]
  Task.sleep(100)
  return ok(n * 2)
end

def main() -> Void
  results = Task.map([1, 2, 3, 4], 2, 1000) do |n|
    slow_double(n)
  end
  puts(results)
end
```

```output
[ok(2), ok(4), ok(6), ok(8)]
```

About 200 ms, not 400: a sliding window of two, not batches. Items start in input order.

- An item's `error(...)` does not stop the others. A runtime error (`RUNTIME-DIVISION-BY-ZERO`) crashes only that item: its slot is `error("task crashed: ...")`.
- The call waits for every item. To use results as they come, send them over a [Channel](/library/concurrency/channel/).

```agentica
def main() -> Void
  results = Task.map(["30", "x", "10"], 3, 1000) do |text|
    n = try String.to_int(text)
    Task.sleep(40 - n)
    ok(n * 2)
  end
  for result in results
    case result
      ok(n) -> puts("value #{n}")
      error(message) -> puts("failed: #{message}")
    end
  end
end
```

```output
value 60
failed: cannot convert "x" to Int
value 20
```

`R` comes from the expected type of the call, else from the block's first value. If that is `error(...)`, the checker says `CHECK-RESULT-TYPE`: annotate the variable (`results: List[Result[Int]] = Task.map(...)`). A function value works too: `Task.map(ids, 8, 5000, &fetch)`.

`timeout_ms` is per item, from the start of its task to its end, including time spent waiting to run. A slow item is cancelled and its slot is `error("task: timed out")`. There is no total timeout: a call takes at most about `ceil(items / limit) * timeout_ms`.

```agentica
def fetch(n: Int) -> Result[String]
  if n == 2
    Task.sleep(10000)
  end
  return ok("page #{n}")
end

def main() -> Void
  pages = Task.map([1, 2, 3], 3, 200, &fetch)
  puts(pages)
end
```

```output
[ok("page 1"), error("task: timed out"), ok("page 3")]
```

Limits, checked before any item starts (also for an empty list, which gives `[]`):

- `limit` is 1 to 1024, otherwise `RUNTIME-INVALID-COUNT`. A `limit` above the list size starts every item at once.
- `timeout_ms` above 0, otherwise `RUNTIME-INVALID-DURATION`.

Cancellation (a timed-out item):

- It runs no more code, nor do the tasks it started, even a grandchild whose parent already ended (a `Task.map` it called starts no more items). Its handles close.
- Its slot settles at the deadline, and the call does not wait for its files. A normal item counts as ended only after its regular files are written and closed.
- I/O in progress finishes or times out on its own and its result is dropped. It never closes a handle other items share. A `TCP.accept` or socket read that has taken nothing yet is dropped at once instead, so the next connection or the later bytes go to the next call. A timed-out `HTTP.get` connection closes and does not go back to the pool.
- Awaiting a task cancelled with the item, wherever its handle went, stops with `RUNTIME-TASK-CANCELLED`, or gives `error("task: cancelled")` for a `Result` task.

Tips:

- `limit` is mostly for I/O. CPU work runs on at most one item per scheduler at a time, and a `limit` above the number of schedulers makes timeouts likelier.
- Open handles inside the item. A handle shared by items makes them run in turn (its lock). Many tasks needing one handle: give it to one owner task and talk to it over a [Channel](/library/concurrency/channel/).
- Items, captured variables and results are immutable and shared without copies. An item may call `Task.map`; the limits multiply.
- Starting an item costs one `--max-steps` step, plus the block's own. With `--seed`, each item gets its own random generator, split in input order.

## Task.sleep

```text
Task.sleep(milliseconds: Int) -> Void
```

Pauses the current task. `0` lets other tasks run; a negative value stops the program.

```agentica
def late(label: String) -> String
  Task.sleep(30)
  puts(label)
  return label
end

def main() -> Void
  task = Task.spawn(&late, "second")
  puts("first")
  done = Task.await(task)
end
```

```output
first
second
```

A block can run in a task too, when you pass it through a function parameter:

```agentica
def start(f: Fn[Int, Int]) -> Task[Int]
  return Task.spawn(f, 20)
end

def main() -> Void
  task = start() do |n| n + 1 end
  puts(Task.await(task))
end
```

```output
21
```

## Task.cancel

```text
Task.cancel(task: Task[R]) -> Void
```

Stops a task you no longer need, and every task it started. It does not wait: the task is marked and the call returns.

- The task runs at most the rest of its current turn. A sleep, a channel wait, an await or an I/O wait ends at once; a task busy on another scheduler, such as in a loop, stops at the end of its current turn. So a task in its last turn there may end as cancelled even though it reached its return.
- Its handles close as when any task ends, so a channel it owns (from `Task.spawn_owning`) is closed and its receivers get `error("channel: closed")`.
- Awaiting it gives `error("task: cancelled")` for a `Result` task, and otherwise stops the program with `RUNTIME-TASK-CANCELLED`.
- Cancelling a task that already ended, or cancelling twice, does nothing.
- Any task that holds the handle may cancel it, also one it got from a channel. A task that cancels itself, or a task that started it, stops right after the call.
- A cancel is not a crash: there is no crash report and the exit code does not change.

```agentica
def keep(inbox: Channel[Int]) -> Result[Int]
  total = 0
  while true
    total += try inbox.recv(60000)
  end
  return ok(total)
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(4)
  keeper = Task.spawn(&keep, inbox)
  inbox.send(5, 1000)
  Task.cancel(keeper)
  puts(Task.await(keeper))
end
```

```output
error("task: cancelled")
```

## Task.pending_count

```text
Task.pending_count() -> Int
```

Gives how many tasks have not ended yet, not counting `main`.

- Waiting, sleeping and awaiting tasks count, and so does the asker unless it is `main`. Returned or crashed tasks do not, awaited or not.
- The tasks `std/http` starts for an `HttpClient` never count.

```agentica
def wait_for(task: Task[Int]) -> Int
  return Task.await(task)
end

def nap(ms: Int) -> Int
  Task.sleep(ms)
  return ms
end

def main() -> Void
  puts(Task.pending_count())
  first = Task.spawn(&nap, 20)
  second = Task.spawn(&wait_for, first)
  puts(Task.pending_count())
  puts(Task.await(second))
  puts(Task.pending_count())
end
```

```output
0
2
20
0
```

## Task.unobserved_crash

```text
Task.unobserved_crash() -> Result[String]
```

Gives `ok(text)` with the first crash that no `Task.await` has seen, else an error. Asking does not count as seeing.

```agentica
def boom(n: Int) -> Int
  return 10 / n
end

def main() -> Void
  puts(Task.unobserved_crash().ok?)
  task = Task.spawn(&boom, 0)
  while !Task.unobserved_crash().ok?
    Task.sleep(1)
  end
  puts(Task.unobserved_crash().ok?)
  System.exit(0)
end
```

```output
false
true
```
