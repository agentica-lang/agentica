---
title: Task
weight: 1
description: Start, await (with or without a timeout), pause and count lightweight tasks, hand a handle to a task, and find their crashes.
---

Tasks run functions at the same time in one program. The tour page
[Tasks](/tour/tasks/) shows how to use them.

## Task.spawn

```text
Task.spawn(function: Fn[A, R], argument: A) -> Task[R]
```

Starts `function(argument)` in a new task and returns the `Task` handle of the new task. A file, socket, listener, process or server belongs to the task that opened it, and it is closed when that task ends, whether the task returns, crashes or is cancelled. `Task.await` of an ended task returns after the regular files it owned are written and closed; it does not wait for a flush to a FIFO or a pipe. `Task.spawn` moves nothing: when the argument is such a handle, or holds one in a struct or a list, the caller still owns it. The new task can use it, and it is closed when the caller ends. Because nothing goes to the parent, a handle that a helper task opens and returns through `Task.await` is closed when the helper ends, so open a long-lived handle in the task that keeps it. To give a handle to the new task, use `Task.spawn_owning`.

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

Starts `function(handle)` like `Task.spawn`, and in the same call gives `handle` to the new task. The calling task must own the handle. From then on the new task owns it, so it is closed when the new task ends, even if that task crashes, and nobody else can close it in between. The caller can still use the handle while the new task runs. A server loop uses it to give each accepted connection to its own task, so a crash while serving one connection closes only that connection. A server handed over this way takes its listener with it, and goes on serving after the task that made it has ended.

The argument must be a `FileHandle`, `Socket`, `Listener`, `Process` or `HttpServer`; any other type, such as an `Int`, a struct that holds a socket or an `HttpClient`, is `CHECK-NOT-A-HANDLE` at the argument. If the calling task does not own the handle, if it was already handed over, or if it is closed, the caller stops with `RUNTIME-HANDLE-NOT-OWNED` at the handle and no task is made.

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

The last line shows the rule: `echo` returned without closing the connection, and its end closed it, so the client reads the end of the input.

## Task.await

```text
Task.await(task: Task[R]) -> R
```

Waits for the task and gives its result. Waiting again gives the same value.

A runtime error in a task other than `main` is a crash: it ends only that task. The error is printed on stderr, the task's own tasks are cancelled, and the handles it owns are closed, as for any task that ends. When the task returns a `Result`, awaiting it gives `error("task crashed: CODE at FILE:LINE:COLUMN: MESSAGE")`. Otherwise the waiting task stops with `RUNTIME-TASK-CRASHED`. A crash that no await sees makes the run exit with code 1 when `main` returns.

An await that would wait for the awaiting task itself, directly or through other tasks, stops with `RUNTIME-TASK-AWAIT-CYCLE` at the `Task.await`. A task can get such a handle through a [Channel](/library/concurrency/channel/).

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

Waits for the task for at most `timeout_ms` milliseconds. `Await[R]` is a builtin enum with two variants: `Await.Done(value)` holds the task's result, and `Await.TimedOut` means the time ran out first. `TimedOut` has no payload and is written without parentheses. Match both variants with `case`, or add `_`; the checker rejects a `case` that misses one. `Await` is a reserved name, so a struct, enum or import alias cannot use it. `try` does not apply to an `Await`.

A timeout does not cancel the task and does not stop the caller. The task keeps running, and a later `Task.await(task)` or timed await gives its result. A task that has already ended never times out, however short the timeout. `timeout_ms` must be above 0; `0` or a negative value stops the program with `RUNTIME-INVALID-DURATION` at the argument. Call it once with the total time you can spare instead of polling in a loop.

If the task crashes or is cancelled before the timeout, the outcome is the one of the plain await: for a task that returns a `Result` you get `Await.Done(error(text))`, and for any other result type the caller stops with `RUNTIME-TASK-CRASHED` or `RUNTIME-TASK-CANCELLED` at the call. A crash after the caller got `Await.TimedOut` does not reach the caller. A timed await cannot wait forever, so it takes no part in the await-cycle check: a task that awaits its own handle with a timeout, or two tasks that await each other with timeouts, get `Await.TimedOut`, and a plain `Task.await` of a task that waits with a timeout does not stop with `RUNTIME-TASK-AWAIT-CYCLE`.

In this program the worker waits for a number from a [Channel](/library/concurrency/channel/). The first wait runs out of time, the worker keeps waiting, and the second wait gets its result:

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

For a task that returns `Void` the result is `Await[Void]`, and the payload is matched with `_`, as `Result.Ok(_)` is. A name there is `CHECK-VOID-TYPE`.

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

## Task.sleep

```text
Task.sleep(milliseconds: Int) -> Void
```

Pauses the current task. `0` lets other tasks run. A negative value stops the
program.

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

Gives how many tasks of this run have not ended yet, not counting `main`. A
task that waits to run, sleeps or waits for another task counts; so does the
task that asks, unless it is `main`. A task that has returned or crashed no
longer counts, even when nothing awaited it. `std/bdd` uses it to fail a [BDD](/library/testing/bdd/) step that leaves tasks
running.

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

Gives `ok(text)` with the first crash of this run that no `Task.await` has
seen, or an error when there is none. Asking does not count as seeing it.
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
