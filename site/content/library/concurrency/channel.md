---
title: Channel
weight: 2
description: Send values from one task to another through a bounded queue.
---

A channel is a bounded queue: one task sends values, another receives them. See also [Tasks](/tour/tasks/).

- `Channel[T]` holds values of one type, any type a variable can have: a task handle, a socket, a file or another channel is allowed, and `Channel[Void]` is `CHECK-VOID-TYPE`.
- A channel is a handle: passing it to a function or task shares it. `Channel` is a reserved name: a user `struct`, `enum` or import alias named `Channel` is `CHECK-REDEFINED-NAME`.
- `puts`, `print`, interpolation and `==` on a channel are `CHECK-TYPE-MISMATCH`, `.to_s` is `CHECK-UNKNOWN-METHOD`, and a struct with a channel field is `CHECK-NOT-ENCODABLE` as JSON. `IO.inspect` prints `<Channel>`.
- `send`, `recv` and `close` carry the `concurrency` effect; `new`, `closed?` and `empty?` carry none.
- There is no `select`, no `for x in channel`, and no unbounded or unbuffered channel.
- `send`, `recv`, `close`, `closed?` and `empty?` also work as methods: `jobs.send(5, 1000)` is `Channel.send(jobs, 5, 1000)`.

## Channel.new

```text
Channel.new(capacity: Int) -> Channel[T]
```

Holds `capacity` values, 1 to 1048576, else `RUNTIME-INVALID-COUNT`. It is always bounded: a full channel makes the sender wait. It needs an expected type (annotation, parameter, field or return type), else `CHECK-EXPECTED-TYPE`.

```agentica {expect="CHECK-EXPECTED-TYPE"}
def main() -> Void
  jobs = Channel.new(4)
end
```

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  puts(jobs.closed?)
end
```

```output
false
```

## Channel.send

```text
Channel.send(channel: Channel[T], value: T, timeout_ms: Int) -> Result[Void]
```

Adds the value at the back and gives `ok()`. When full, the task waits for room, a close or `timeout_ms`. The value is not added on:

- `error("channel: closed")`, or `error("channel: timed out")`.

`timeout_ms` is 0 or more; `0` tries once and never waits. A negative value is `RUNTIME-INVALID-DURATION`. Nothing waits forever.

```agentica
def main() -> Void
  jobs: Channel[String] = Channel.new(2)
  puts(jobs.send("a", 0).ok?)
  puts(jobs.send("b", 0).ok?)
  puts(jobs.send("c", 0).message)
end
```

```output
true
true
channel: timed out
```

## Channel.recv

```text
Channel.recv(channel: Channel[T], timeout_ms: Int) -> Result[T]
```

Takes the oldest value (first in, first out) and gives `ok(value)`. When empty, the task waits for a value, a close or `timeout_ms`. Waiting tasks are served in the order they started waiting, and so are waiting senders, with no barging: a sent value goes straight to the first waiting receiver. A waiter that leaves before it runs, because it was cancelled or its timeout came first, passes what it was given to the next waiter. A receiver that was given a value returns it even if its deadline passes before it runs. No value is lost or added twice. Errors:

- `error("channel: closed")` once closed and every value was taken, or `error("channel: timed out")`.

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  jobs.send(10, 0)
  jobs.send(20, 0)
  puts(jobs.recv(0).unwrap!)
  puts(jobs.recv(0).unwrap!)
  puts(jobs.recv(0).message)
end
```

```output
10
20
channel: timed out
```

## Channel.close

```text
Channel.close(channel: Channel[T]) -> Void
```

Closing again does nothing. Waiting senders get the closed error, and so do woken senders that have not run yet. Receivers get the values left, then the closed error.

- The sending side should close on every path, receivers should not. If nobody closes it, a receive loop never ends.
- An owned channel also closes when its owner ends ([A producer that owns the channel](#a-producer-that-owns-the-channel)).

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  jobs.send(1, 0)
  jobs.close
  puts(jobs.send(2, 0).message)
  puts(jobs.recv(0).unwrap!)
  puts(jobs.recv(0).message)
end
```

```output
channel: closed
1
channel: closed
```

## Channel.closed?

```text
Channel.closed?(channel: Channel[T]) -> Bool
```

`true` once the channel is closed, even while it still holds values, as Ruby's `Queue#closed?`, and it stays `true`. A producer that is busy between sends (decoding the next token, reading the next piece of a file) reads it to learn that the reader has closed the channel before its next `send` fails. A receiver asks [`closed? and empty?`](#channelempty) to learn that the stream ended.

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  jobs.send(1, 0)
  jobs.close
  puts(jobs.closed?)
  puts(jobs.empty?)
  puts(jobs.recv(0).unwrap!)
  puts(jobs.empty?)
end
```

```output
true
false
1
true
```

## Channel.empty?

```text
Channel.empty?(channel: Channel[T]) -> Bool
```

`true` when no value is left to receive: the buffer is empty and no value is reserved for a woken receiver. Once a channel is closed no value arrives, so `closed? and empty?` says the stream ended, and it stays `true`. Ask `closed?` first: a value and the close can both come between an `empty?` that is `true` and a `closed?` after it. After a `recv` error, `closed? and empty?` tells the end of the stream from a timeout.

## A producer and a consumer

The receive loop: on an error, `closed? and empty?` says whether the stream ended, else it was a timeout and the loop receives again. The producer closes on every path: `send_all` holds the `try`s, so `produce` always reaches `jobs.close`.

```agentica
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
        if jobs.closed? and jobs.empty?
          break
        end
    end
  end

  puts(total)
  puts(Task.await(producer).ok?)
end
```

```output
15
true
```

The same consumer as a [`Lazy`](/library/data-structures/lazy/#chlazy) needs no loop: `jobs.lazy(1000).reduce(0) do |total, n| total + n end` is `ok(15)`.

## A producer that owns the channel

`Task.spawn_owning(&produce, jobs)` makes the task the owner. When it ends in any way (returns, crashes, cancelled) the channel closes. The receiver gets the values already sent, then the closed error at once, with no timeout wait when the producer died.

```agentica
def produce(jobs: Channel[Int]) -> Result[Void]
  try jobs.send(1, 1000)
  try jobs.send(2, 1000)
  zero = 0
  try jobs.send(100 / zero, 1000)
  return ok()
end

def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  producer = Task.spawn_owning(&produce, jobs)
  while true
    case jobs.recv(5000)
      ok(n) -> puts(n)
      error(e) ->
        puts(e)
        break
    end
  end

  puts(Task.await(producer).ok?)
end
```

```output
1
2
channel: closed
false
```

Ownership rules:

- A channel never handed over has no owner: only `close` closes it. `Task.spawn(&f, jobs)` does not make an owner.
- The first `Task.spawn_owning` can come from any task. After that only the owner can hand it on; any other task, or any task once it is closed, stops with `RUNTIME-HANDLE-NOT-OWNED`. Any task can still call `Channel.close`.
- There is one owner. For several producers, use the next pattern.

## Several sources

There is no `select`. Merge sources into one channel of an enum, one variant per kind of event. A coordinator awaits every source, then closes the channel, so the receive loop ends.

```agentica
enum Event
  Item(String, Int)
  Failed(String)
end

struct Source
  name: String
  count: Int
  events: Channel[Event]
end

struct Coordinator
  sources: List[Task[Void]]
  events: Channel[Event]
end

def emit(source: Source) -> Void
  i = 1
  while i <= source.count
    source.events.send(Event.Item(source.name, i * 10), 1000)
    i += 1
  end

  if source.count == 0
    source.events.send(Event.Failed("#{source.name} has nothing"), 1000)
  end
end

def coordinate(c: Coordinator) -> Void
  c.sources.each do |source|
    Task.await(source)
  end

  c.events.close
end

def main() -> Void
  events: Channel[Event] = Channel.new(2)
  sources = [
    Task.spawn(&emit, Source(name: "a", count: 3, events: events)),
    Task.spawn(&emit, Source(name: "b", count: 0, events: events)),
    Task.spawn(&emit, Source(name: "c", count: 2, events: events))
  ]
  coordinator = Task.spawn(&coordinate, Coordinator(sources: sources, events: events))
  totals: Map[String, Int] = {}
  while true
    case events.recv(1000)
      ok(event) ->
        case event
          Event.Item(name, value) -> totals = totals.put(name, totals.get(name, 0) + value)
          Event.Failed(text) -> puts(text)
        end

      error(_) ->
        if events.closed? and events.empty?
          break
        end
    end
  end

  Task.await(coordinator)
  totals.keys.sort.each do |name|
    puts("#{name}: #{totals.get(name, 0)}")
  end
end
```

```output
b has nothing
a: 60
c: 30
```

## State owned by one task

Tasks share no mutable values except [ATS](/library/concurrency/ats/) tables, so state that several tasks update with more than one table call belongs to one owner task that receives messages on a channel and keeps the state in its own variables.

```agentica
def count(inbox: Channel[Int]) -> Int
  total = 0
  while true
    case inbox.recv(1000)
      ok(n) -> total += n
      error(_) ->
        if inbox.closed? and inbox.empty?
          break
        end
    end
  end

  return total
end

def send_three(inbox: Channel[Int]) -> Void
  inbox.send(1, 1000)
  inbox.send(2, 1000)
  inbox.send(3, 1000)
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(4)
  counter = Task.spawn(&count, inbox)
  sender = Task.spawn(&send_three, inbox)
  Task.await(sender)
  inbox.close
  puts(Task.await(counter))
end
```

```output
6
```

## Waiting on each other

A task waiting on a channel always holds a timer, so tasks waiting for each other end with timeout errors instead of hanging.

```agentica
def wait_for(inbox: Channel[Int]) -> Result[Int]
  return inbox.recv(20)
end

def main() -> Void
  inbox: Channel[Int] = Channel.new(1)
  task = Task.spawn(&wait_for, inbox)
  puts(Task.await(task).message)
end
```

```output
channel: timed out
```

A task that receives its own handle over a channel and awaits it stops with `RUNTIME-TASK-AWAIT-CYCLE`; for a `Result` task the waiter gets the crash as an error.

```agentica
def follow(inbox: Channel[Task[Result[Int]]]) -> Result[Int]
  me = inbox.recv(1000).unwrap!
  return Task.await(me)
end

def main() -> Void
  inbox: Channel[Task[Result[Int]]] = Channel.new(1)
  task = Task.spawn(&follow, inbox)
  inbox.send(task, 1000)
  puts(Task.await(task).message.starts_with?("task crashed: RUNTIME-TASK-AWAIT-CYCLE"))
end
```

```output
true
```
