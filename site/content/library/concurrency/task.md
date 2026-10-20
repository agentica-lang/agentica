---
title: Task
weight: 1
description: Start, await (with or without a timeout), pause and count lightweight tasks, map a block over a list with bounded concurrency, hand a handle to a task, and find their crashes.
---

Tasks run functions at the same time in one program. The tour page [Tasks](/tour/tasks/) shows how to use them.

## Task.spawn

```text
Task.spawn(function: Fn[A, R], argument: A) -> Task[R]
```

Starts `function(argument)` in a new task and returns its `Task` handle.

- A file, socket, listener, process or server belongs to the task that opened it. It closes when that task ends: returns, crashes or is cancelled.
- `Task.await` of an ended task returns after its regular files are written and closed. It does not wait for a flush to a FIFO or a pipe.
- `Task.spawn` moves nothing. A handle in the argument, or in a struct or list in it, stays with the caller.
- A handle that a helper opens and returns through `Task.await` closes when the helper ends. Open a long-lived handle in the task that keeps it.
- To give a handle to the new task, use `Task.spawn_owning`.

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

Starts `function(handle)` like `Task.spawn`, and gives `handle` to the new task in the same call.

- The caller must own the handle. It can still use the handle while the new task runs.
- A server loop gives each accepted connection to its own task, so a crash closes only that connection. A server handed over this way takes its listener along and keeps serving after the task that made it has ended.
- A [Channel](/library/concurrency/channel/) can be handed over too. A channel has no opener, so its first hand-off can come from any task. The channel closes when the new task ends (see [a producer that owns the channel](/library/concurrency/channel/#a-producer-that-owns-the-channel)). Until then, only the new task can hand it on. Any task can still call `Channel.close`.
- The argument must be a `FileHandle`, `Socket`, `Listener`, `Process`, `HttpServer` or `Channel[T]`. Any other type, such as an `Int`, a struct that holds a socket or an `HttpClient`, is `CHECK-NOT-A-HANDLE` at the argument.
- If the caller does not own the handle, it was already handed over, or it is closed, the caller stops with `RUNTIME-HANDLE-NOT-OWNED` at the handle. No task is made.

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

The last line shows the rule: `echo` returned without closing the connection. Its end closed it, so the client reads the end of the input.

## Task.await

```text
Task.await(task: Task[R]) -> R
```

Waits for the task and gives its result. Waiting again gives the same value.

- A runtime error in a task other than `main` is a crash. It ends only that task. The error goes to stderr, the task's own tasks are cancelled, and the handles it owns are closed.
- If the task returns a `Result`, awaiting it gives `error("task crashed: CODE at FILE:LINE:COLUMN: MESSAGE")`. Otherwise the waiting task stops with `RUNTIME-TASK-CRASHED`.
- A crash that no await sees makes the run exit with code 1 when `main` returns.
- An await that would wait for the awaiting task itself, directly or through other tasks, stops with `RUNTIME-TASK-AWAIT-CYCLE` at the `Task.await`. A task can get such a handle through a [Channel](/library/concurrency/channel/).

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

```agentica
def add_one(n: Int) -> Int
  return n + 1
end

def main() -> Void
  task = Task.spawn(&add_one, 1)
  puts(Task.await(task))
  puts(Task.await(task))
end
```

```output
2
2
```

## Task.await with a timeout

```text
Task.await(task: Task[R], timeout_ms: Int) -> Await[R]
```

Waits for the task for at most `timeout_ms` milliseconds.

- `Await[R]` is a builtin enum. `Await.Done(value)` holds the result. `Await.TimedOut` means the time ran out first. It has no payload, so write it without parentheses.
- A `case` must match both variants, or use `_`. The checker rejects a `case` that misses one.
- `Await` is a reserved name. A struct, enum or import alias cannot use it. `try` does not apply to an `Await`.
- `timeout_ms` must be above 0. `0` or a negative value stops the program with `RUNTIME-INVALID-DURATION` at the argument.
- Call it once with the total time you can spare. Do not poll in a loop.

A timeout does not cancel the task or stop the caller. The task keeps running, and a later `Task.await(task)` or timed await gives its result. A task that has already ended never times out.

- If the task crashes or is cancelled before the timeout, you get the plain await's outcome. For a task that returns a `Result`, that is `Await.Done(error(text))`. For any other type, the caller stops with `RUNTIME-TASK-CRASHED` or `RUNTIME-TASK-CANCELLED` at the call.
- A crash after the caller got `Await.TimedOut` does not reach the caller.
- A timed await skips the cycle check, since it cannot wait forever. A task that awaits its own handle with a timeout gets `Await.TimedOut`, and so do two tasks that await each other with timeouts. A plain `Task.await` of a task that waits with a timeout does not stop with `RUNTIME-TASK-AWAIT-CYCLE`.

In this program the worker waits for a number from a [Channel](/library/concurrency/channel/). The first wait runs out of time. The worker keeps waiting, and the second wait gets its result:

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

When the task returns a `Result`, `Await.Done` holds that `Result`, so match it in a second `case`. `IO.inspect` shows an `Await` as `Await.Done(ok(25))` or `Await.TimedOut`.

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

A task that returns `Void` gives an `Await[Void]`. Match its payload with `_`, as `Result.Ok(_)` is. A name there is `CHECK-VOID-TYPE`.

```agentica
def finish(inbox: Channel[Int]) -> Void
  n = inbox.recv(10000).unwrap!
  puts("finished #{n}")
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&finish, inbox)
  IO.inspect(Task.await(task, 20))
  inbox.send(7, 1000)
  case Task.await(task, 10000)
    Await.Done(_) -> puts("done")
    Await.TimedOut -> puts("timed out")
  end
end
```

```output
Await.TimedOut
finished 7
done
```

## Task.map

```text
Task.map(items: List[A], limit: Int, timeout_ms: Int, function: Fn[A, Result[R]]) -> List[Result[R]]
```

Runs the function for each item in its own task, at most `limit` at a time. It gives one `Result` per item, in the order of `items`, whatever order the items end in.

- Always write `Task.map(...)`. It is never a method, so `xs.map` stays the sequential `List.map`.
- The function is usually the trailing block. It gives a `Result[R]`, because HTTP requests, files and processes already return `Result`. `try` works in the block, and a block that cannot fail ends with `ok(x)`.
- A block whose last expression is not a `Result` is `CHECK-TYPE-MISMATCH`. The help shows `ok(...)`.

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

This takes about 200 ms, not 400. Two items run at a time, and each new item starts when one ends (a sliding window, not batches). Items start in input order.

- An item's `error(...)` does not stop the others.
- The call waits for every item. To use each result as soon as it is ready, send it over a [Channel](/library/concurrency/channel/).
- A runtime error in an item, such as `RUNTIME-DIVISION-BY-ZERO`, crashes only that item. Its slot is `error("task crashed: ...")`.

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

`R` comes from the expected type of the call, or else from the block's first value. If that value is `error(...)`, the checker says `CHECK-RESULT-TYPE`. Then annotate the variable: `results: List[Result[Int]] = Task.map(...)`. A function value works too: `Task.map(ids, 8, 5000, &fetch)`.

`timeout_ms` is the time one item may take, from the start of its task to its end. It includes the time the item waits to run while other tasks use the CPU. An item that runs out of time is cancelled, and its slot is `error("task: timed out")`. There is no total timeout. A call takes at most about the number of items divided by `limit`, rounded up, times `timeout_ms`.

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

Cancellation:

- A cancelled item runs no more code, and neither do the tasks it started, even a grandchild whose parent has ended. A `Task.map` it called starts no more items. Its handles close, as for any task that ends.
- An item counts as ended only after its regular files are written and closed. So a file it wrote is on disk when the call returns. A timed-out item is the exception: its slot settles at its deadline, and the call does not wait for its files.
- I/O in progress is not abandoned. It finishes or times out on its own, and its result is dropped. It never closes the handle, so a timed-out item cannot close a handle that other items share. The connection of a timed-out `HTTP.get` closes when its request ends. It does not go back to the pool.
- Awaiting a handle to a cancelled task, passed out of an item through a channel, stops with `RUNTIME-TASK-CANCELLED`. If that task returns a `Result`, it gives `error("task: cancelled")`.

Limits: `limit` is 1 to 1024, otherwise `RUNTIME-INVALID-COUNT` at the argument. `timeout_ms` must be above 0, otherwise `RUNTIME-INVALID-DURATION` at the argument. Both are checked before any item starts, even for an empty list, which gives `[]`. A `limit` above the list size starts every item at once.

Tips:

- `limit` is for I/O. On one core, CPU work gets no faster. A large `limit` makes timeouts likelier, since an item's clock includes its wait to run.
- Open handles inside the item. Do not share one handle across items: calls on it wait for its lock, so the items run in turn. A handle that many tasks need belongs to one owner task, which the items talk to over a [Channel](/library/concurrency/channel/).
- Items, captured variables and results are immutable, so they are shared without copies. An item may call `Task.map` too. Each call has its own limit, so the limits multiply.
- Starting an item costs one `--max-steps` step, and the block costs its own. With `--seed`, each item has its own random generator, split in input order.

## Task.sleep

```text
Task.sleep(milliseconds: Int) -> Void
```

Pauses the current task. `0` lets other tasks run. A negative value stops the program.

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

## Task.pending_count

```text
Task.pending_count() -> Int
```

Gives how many tasks of this run have not ended yet, not counting `main`.

- A task that waits to run, sleeps or waits for another task counts. The task that asks counts too, unless it is `main`.
- A task that has returned or crashed no longer counts, even when nobody awaited it.
- The tasks that `std/http` starts for an `HttpClient` never count. `Test.test` does not see them as leftovers.
- `std/bdd` uses it to fail a [BDD](/library/testing/bdd/) step that leaves tasks running.

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

Gives `ok(text)` with the first crash of this run that no `Task.await` has seen. When there is none, it gives an error. Asking does not count as seeing a crash.

`std/bdd` uses it to fail a [BDD](/library/testing/bdd/) step whose task crashed.

```agentica
def boom(n: Int) -> Int
  return 10 / n
end

def main() -> Void
  task = Task.spawn(&boom, 0)
  puts(Task.unobserved_crash().ok?)
  Task.sleep(0)
  puts(Task.unobserved_crash().ok?)
  System.exit(0)
end
```

```output
false
true
```
