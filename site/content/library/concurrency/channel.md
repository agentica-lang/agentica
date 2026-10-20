---
title: Channel
weight: 2
description: Send values from one task to another through a bounded queue.
---

A channel is a bounded queue. One task sends values into it, and another task receives them. The tour page [Tasks](/tour/tasks/) shows how tasks run.

- `Channel[T]` holds values of one type: any type a variable can have, except `Void`.
- A channel is a handle. Passing it to a function or a task shares the same channel.
- `Channel` is a reserved name. Channels run on the VM only.
- `send`, `recv`, `close` and `closed?` can be called as methods: `jobs.send(5, 1000)` is `Channel.send(jobs, 5, 1000)`. `Channel.new` has no channel to be called on.

## Channel.new

```text
Channel.new(capacity: Int) -> Channel[T]
```

Makes a channel that holds `capacity` values, from 1 to 1048576. A capacity outside that range stops the program with `RUNTIME-INVALID-COUNT`. A channel is always bounded: when it is full, a sender waits for a receiver.

`Channel.new` needs an expected type, from an annotation, a parameter, a field or a return type. Without one, the checker stops with `CHECK-EXPECTED-TYPE`.

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

Adds the value at the back and gives `ok()`. When the channel is full, the task waits for room, for a close, or for `timeout_ms`.

- `error("channel: closed")` when the channel is closed.
- `error("channel: timed out")` when the time ran out.
- In both cases the value is not added.
- `timeout_ms` is 0 or more. `0` never waits: the call tries once.
- A negative value stops the program with `RUNTIME-INVALID-DURATION`. No value waits forever.

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

Takes the oldest value and gives `ok(value)`. Values come out in the order they went in. When the channel is empty, the task waits for a value, for a close, or for `timeout_ms`.

- `error("channel: closed")` once the channel is closed and every value was taken.
- `error("channel: timed out")` when the time ran out.
- Waiting tasks are served in the order they started waiting. A value goes straight to the first task that waits for it.

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

Closes the channel. Closing again does nothing.

- Tasks that wait to send get the closed error.
- Tasks that wait to receive get the values left, then the closed error. Values sent before the close can still be received.
- The sending side should close the channel on every path. Receivers should not. If nobody closes it, a receive loop never ends.
- A channel that a task owns is also closed when that task ends. See [A producer that owns the channel](#a-producer-that-owns-the-channel). Any task can still call `close` on it.

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

Gives `true` when the channel is closed and every value was taken. Then it stays `true`. A closed channel that still holds values gives `false`.

After a `recv` error, `closed?` tells the end of the stream (`true`) from a timeout (`false`).

```agentica
def main() -> Void
  jobs: Channel[Int] = Channel.new(4)
  jobs.send(1, 0)
  jobs.close
  puts(jobs.closed?)
  jobs.recv(0)
  puts(jobs.closed?)
end
```

```output
false
true
```

## A producer and a consumer

This is the receive loop. On an error, `closed?` says whether the stream has ended. If not, the error was a timeout, and the loop receives again.

The producer closes the channel on every path. `produce` keeps the sending in its own function, so a `try` that leaves `send_all` early still reaches `jobs.close`.

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
        if jobs.closed?
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

## A producer that owns the channel

`Task.spawn_owning(&produce, jobs)` starts the task like `Task.spawn`, and makes it the owner of the channel. When that task ends in any way (returns, crashes or is cancelled), the channel closes as by `close`.

The receiver gets the values already sent, then the closed error at once. It does not wait for a timeout when the producer died.

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

- A channel that was never handed over has no owner. Only `close` closes it.
- A task that gets the channel from `Task.spawn(&f, jobs)` does not own it.
- The first `Task.spawn_owning` of a channel can come from any task. After that, only the owner can hand it on. Any other task, or any task once the channel is closed, stops with `RUNTIME-HANDLE-NOT-OWNED` at the channel.
- A channel has one owner. For several producers, use the next pattern: one coordinator awaits them all, then closes the channel.

## Several sources

There is no `select`. To merge several sources, send them into one channel of an enum type, with one variant for each kind of event. A coordinator task awaits every source, then closes the channel, so the receive loop ends.

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
        if events.closed?
          break
        end
    end
  end
  Task.await(coordinator)
  puts(totals)
end
```

```output
b has nothing
{"a": 60, "c": 30}
```

## State owned by one task

Values are immutable, and tasks share nothing. So state that several tasks update belongs to one owner task. The owner receives messages on a channel, and keeps the state in its own variables. The other tasks send it requests.

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

A task that waits on a channel always holds a timer. So tasks that wait for each other, with nothing ever sent, end with timeout errors instead of hanging.

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

A task can receive its own handle over a channel. Awaiting it would wait for itself, so the await stops with `RUNTIME-TASK-AWAIT-CYCLE` at the `Task.await`. When the task returns a `Result`, the waiting task gets the crash as an error.

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
