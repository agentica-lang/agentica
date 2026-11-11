---
title: Actor (std)
weight: 5
description: The std/actor module, a task that owns its state and handles the messages of one inbox, with cast, call and stop.
---

`std/actor` is written in Agentica, on top of [Task](/library/concurrency/task/) and [Channel](/library/concurrency/channel/): `import Actor from "std/actor"`. An actor is a task that owns its state and handles the messages of one inbox, one at a time, so its state needs no lock and no `ATS` table.

- An `Actor.Behaviour[S, M]` is a struct of functions, the contract of an actor, since Agentica has no traits: `init` makes the first state and `handle` takes the state and a message and gives the next step. `S` is the state and `M` the message type, an enum of your own.
- `Actor.start` runs it in a task of its own and gives an `Actor.Ref[S, M]`. Its `address` is the `Address[M]` of the inbox: data that a table, a message or a struct can hold. `cast` and `call` take that address; `stop` takes the `Ref`.
- A module usually hides the message enum behind its own functions (`Counter.add`, `Counter.get`), and keeps the addresses of its actors by name in a constant table, one per message type. There is no registry inside the library.
- There are no methods: call `Actor.cast(address, message)`.

## Actor.start

```signature
Actor.start(behaviour: Actor.Behaviour[S, M], options: Actor.Options = Actor.Options()) -> Actor.Ref[S, M]
Actor.Behaviour(init: Fn[S], handle: Fn[S, M, Actor.Step[S]], terminate: Optional[Fn[S, Void]] = none)
Actor.Options(capacity: Int = 1024)
Actor.continue(state: S) -> Actor.Step[S]
Actor.done(state: S) -> Actor.Step[S]
```

Starts the actor in a task of its own. The task runs `init`, then takes the messages of the inbox in the order they came and gives each to `handle` with the state. The handler ends with `Actor.continue(state)` to keep going with that state, or `Actor.done(state)` to end the actor: it then handles no more messages and runs `terminate` with the last state. `capacity` is how many messages the inbox holds before `cast` and `call` wait for room (1 to 1048576, else `RUNTIME-INVALID-COUNT`).

The task owns the inbox, so the inbox closes when the actor ends in any way: it stopped, gave `done`, crashed or was cancelled. A runtime error in a handler is a crash of the actor's task (see [Task](/library/concurrency/task/)): its diagnostic prints at once, `terminate` does not run, and the messages left in the inbox are lost.

A `Ref` has three fields: `address`, `inbox` (the `Channel[M]`) and `task`. Send through `address`. The `inbox` is there only for `Task.monitor`: never receive from it, which would take a message from the actor.

## Actor.cast and Actor.call

```signature
Actor.cast(address: Address[M], message: M, timeout_ms: Int = 5000) -> Result[Void]
Actor.call(address: Address[M], timeout_ms: Int, make: Fn[Channel[R], M]) -> Result[R]
Actor.reply(channel: Channel[R], value: R) -> Void
```

`cast` puts a message in the inbox and returns; it waits at most `timeout_ms` for room when the inbox is full. `call` makes a reply channel, builds the message around it with the block, sends it and waits for the answer, all within `timeout_ms`. The handler answers with `Actor.reply(channel, value)`, which never waits. Each call has its own reply channel, so an answer that comes after its call timed out never reaches a later call.

Errors: `error("actor: timeout")` when the inbox stays full or the answer does not come in time, and `error("address: gone")` when the actor has ended. A call whose actor crashes or ends before it answers waits for its timeout. A call to the actor's own address from its handler, or two actors that call each other, wait for their timeouts too, since an actor handles one message at a time; send the work to another task instead.

The type of the answer comes from the expected type: the result type of the function that returns the call, or an annotation. Where there is none (inside `puts` or an interpolation), write the type of the block's parameter: `do |reply: Channel[Int]| Msg.Get(reply) end`.

```agentica
import Actor from "std/actor"

enum Msg
  Add(Int)
  Get(Channel[Int])
end

def handle(count: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Add(n) -> Actor.continue(count + n)
    Msg.Get(reply) ->
      Actor.reply(reply, count)
      Actor.continue(count)
  end
end

def zero() -> Int = 0

def total(address: Address[Msg]) -> Result[Int] = Actor.call(address, 1000) do |reply| Msg.Get(reply) end

def main() -> Void
  actor = Actor.start(Actor.Behaviour(init: &zero, handle: &handle))
  for n in 1..4
    _ = Actor.cast(actor.address, Msg.Add(n))
  end

  puts(total(actor.address))
  puts(Actor.stop(actor, 1000))
  puts(total(actor.address))
end
```

```output
ok(10)
ok()
error("address: gone")
```

## Actor.stop

```signature
Actor.stop(actor: Actor.Ref[S, M], timeout_ms: Int) -> Result[Void]
```

Closes the inbox and waits at most `timeout_ms` for the actor to end: it handles the messages already in its inbox (so a call that is waiting there gets its answer), runs `terminate` and ends. A `cast` or `call` after the close gives `error("address: gone")`. An actor still running after `timeout_ms` is cancelled and `stop` gives `error("actor: timeout")`. An actor that crashed gives its `task crashed: ...` error, and stopping it observes the crash. Stopping an actor that has ended gives how it ended.

Only the holder of the `Ref` can stop the actor. To stop it through an address, give the message enum a `Stop` variant whose handler gives `Actor.done(state)`.

## Names and addresses

A module keeps the addresses of its actors in a constant `ATS` table and wraps the messages in its own functions, so callers never see the enum. A caller that looks the name up on each call reaches the actor that holds the name now.

```agentica
import Actor from "std/actor"

module Counter
  NAMES: ATS[String, Address[Msg]] = ATS.new()

  enum Msg
    Add(Int)
    Get(Channel[Int])
    Stop
  end

  export def start(name: String, initial: Int) -> Result[Void]
    actor = Actor.start(Actor.Behaviour(init: block0() do initial end, handle: &handle))
    return ok() if NAMES.put_new(name, actor.address)

    Actor.stop(actor, 1000)
  end

  export def add(name: String, n: Int) -> Result[Void]
    address = try NAMES.get(name)
    Actor.cast(address, Msg.Add(n))
  end

  export def get(name: String) -> Result[Int]
    address = try NAMES.get(name)
    Actor.call(address, 1000) do |reply| Msg.Get(reply) end
  end

  export def stop(name: String) -> Result[Void]
    address = try NAMES.get(name)
    NAMES.delete(name)
    Actor.cast(address, Msg.Stop)
  end

  def handle(count: Int, msg: Msg) -> Actor.Step[Int]
    case msg
      Msg.Add(n) -> Actor.continue(count + n)
      Msg.Get(reply) ->
        Actor.reply(reply, count)
        Actor.continue(count)
      Msg.Stop -> Actor.done(count)
    end
  end

  def block0[R](f: Fn[R]) -> Fn[R] = f
end

def main() -> Void
  _ = Counter.start("visits", 100)
  _ = Counter.add("visits", 5)
  puts(Counter.get("visits"))
  puts(Counter.stop("visits"))
  puts(Counter.get("visits").ok?)
end
```

```output
ok(105)
ok()
false
```

## Monitors and timers

There is no `select`: whatever an actor waits for comes in as a variant of its message enum. `Task.monitor(task, actor.inbox) do |down| Msg.Down(down) end` sends a notice into the inbox when the task ends. A timer is a task that sleeps, then casts to the address.

```agentica
import Actor from "std/actor"

enum Msg
  Down(TaskDown)
  Tick
  Seen(Channel[Int])
end

def handle(seen: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Down(_) -> Actor.continue(seen + 1)
    Msg.Tick -> Actor.continue(seen + 10)
    Msg.Seen(reply) ->
      Actor.reply(reply, seen)
      Actor.continue(seen)
  end
end

def zero() -> Int = 0

def tick(address: Address[Msg]) -> Result[Void]
  Task.sleep(10)
  Actor.cast(address, Msg.Tick)
end

# The notice and the tick come from tasks of their own: ask until both are in.
def seen(address: Address[Msg]) -> Result[Int]
  for _ in 1..100
    count: Int = try Actor.call(address, 1000) do |reply| Msg.Seen(reply) end
    return ok(count) if count == 11

    Task.sleep(10)
  end

  error("not seen")
end

def main() -> Void
  actor = Actor.start(Actor.Behaviour(init: &zero, handle: &handle))
  worker = Task.spawn do 42 end
  Task.monitor(worker, actor.inbox) do |down| Msg.Down(down) end
  timer = Task.spawn(&tick, actor.address)
  _ = Task.await(worker)
  _ = Task.await(timer)
  puts(seen(actor.address))
  puts(Actor.stop(actor, 1000))
end
```

```output
ok(11)
ok()
```
