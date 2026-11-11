---
title: Supervisor (std)
weight: 6
description: The std/supervisor module, a task that starts actors and starts again one that crashes, one for one, within a restart limit.
---

`std/supervisor` is written in Agentica, on top of [Actor](/library/concurrency/actor/): `import Supervisor from "std/supervisor"`. A supervisor is a task that starts actors, its children, and starts again a child that crashes; the other children keep running (one for one).

- A child is an actor with a name and a register block. The supervisor runs the block with the address of each new actor, so a module puts it in its table of names. After a restart the actor has a new inbox, so a new address: a caller that looks the name up on each call reaches the new actor, and one that kept the old address gets `error("address: gone")`.
- Only a crash starts a child again. A child that ends without a crash (its handler gave `Actor.done`) stays down.
- A call that is waiting when its actor crashes ends with its timeout, and the messages in the old inbox are lost.
- The supervisor is a child of the task that calls `Supervisor.start`: a crash or cancel of that task cancels the supervisor and its actors. Start it from `main`.

## Supervisor.child

```signature
Supervisor.child(name: String, behaviour: Actor.Behaviour[S, M], register: Fn[Address[M], Void]) -> Supervisor.Child
```

A child that runs `behaviour` (see [Actor](/library/concurrency/actor/)) and calls `register` with the address of each new actor. The block runs in a task of its own, before the supervisor goes on, for at most 5 seconds: a block that crashes, or still runs then (it is cancelled), is a failed start. The block is required: a child that nobody reaches by name gives `do |_address| nil end`. A `List[Supervisor.Child]` holds children of any state and message type.

## Supervisor.start

```signature
Supervisor.start(children: List[Supervisor.Child], options: Supervisor.Options = Supervisor.Options()) -> Supervisor.Ref
Supervisor.Options(max_restarts: Int = 3, within_ms: Int = 5000)
```

Starts the supervisor in a task of its own, which starts the children in list order, and returns once the first start of each one has run, or after 60 seconds. A start fails when the actor's `init` crashes or the register block fails; a failed start counts as a crash of that child, and the supervisor tries again within the limit, after it has read the messages that came before (so a `Supervisor.stop` is not held up by a child that keeps failing). `max_restarts` must be 0 or more and `within_ms` above 0, else `start` halts with `RUNTIME-UNWRAP-ERROR` (`supervisor: within_ms must be above 0, not 0`).

The limit is per child: a child that crashes more than `max_restarts` times within `within_ms` milliseconds, or fails to start more than `max_restarts` times in a row (whatever the time between them; a start that succeeds ends the row), makes the supervisor give up. It stops the other children in reverse order, within 5 seconds, and then crashes, so a give-up is never silent: its diagnostic is `RUNTIME-UNWRAP-ERROR` with the message `supervisor: NAME crashed N times in M ms` (`1 time` for one) or `supervisor: NAME failed to start N times in a row`, a `Task.monitor` of `sup.task` sees `TaskExit.Crashed` with that code and message, and a give-up that nothing observes (`Supervisor.stop`, `Task.await(sup.task)` or a monitor) fails the run when `main` returns.

## Supervisor.stop

```signature
Supervisor.stop(supervisor: Supervisor.Ref, timeout_ms: Int) -> Result[Void]
```

Stops the children in reverse order, each as `Actor.stop` does (it handles its inbox and runs `terminate`), then the supervisor, all within `timeout_ms`, which must be above 0, and gives the first error of a child's stop (`task crashed: ...` for a child that crashed in `terminate` or while it handled the messages left in its inbox). The children share the time in turn: once one has used it up, each child left gets 1 ms, so it is usually cancelled without `terminate`. A supervisor still running at the end is cancelled with its children, and `stop` gives `error("supervisor: timeout")`; a supervisor busy with a start waits for it (each start takes at most about 6 seconds: the 5 of its register block, then up to 1 more to stop the actor of a failed start). A supervisor that gave up gives its reason (`error("supervisor: NAME crashed N times in M ms")`), and stopping it observes the crash.

```agentica
import Actor from "std/actor"
import Supervisor from "std/supervisor"

NAMES: ATS[String, Address[Msg]] = ATS.new()

enum Msg
  Add(Int)
  Get(Channel[Int])
  Divide(Int)
end

def handle(count: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Add(n) -> Actor.continue(count + n)
    Msg.Get(reply) ->
      Actor.reply(reply, count)
      Actor.continue(count)
    Msg.Divide(n) -> Actor.continue(count / n)
  end
end

def zero() -> Int = 0

def counter(name: String) -> Supervisor.Child
  behaviour: Actor.Behaviour[Int, Msg] = Actor.Behaviour(init: &zero, handle: &handle)
  Supervisor.child(name, behaviour) do |address| NAMES.put(name, address) end
end

def get(name: String) -> Result[Int]
  address = try NAMES.get(name)
  Actor.call(address, 1000) do |reply| Msg.Get(reply) end
end

# The restart comes from the supervisor's task: wait until the name holds a new address.
def restarted(name: String, old: Address[Msg]) -> Result[Int]
  for _ in 1..100
    address = try NAMES.get(name)
    return get(name) if address != old

    Task.sleep(10)
  end

  error("#{name} was not restarted")
end

def main() -> Void
  sup = Supervisor.start([counter("visits"), counter("errors")])
  visits = NAMES.get("visits").unwrap!
  _ = Actor.cast(visits, Msg.Add(5))
  puts(get("visits"))
  _ = Actor.cast(visits, Msg.Divide(0))
  puts(restarted("visits", visits))
  puts(Actor.cast(visits, Msg.Add(1)))
  puts(Supervisor.stop(sup, 1000))
end
```

```output
ok(5)
ok(0)
error("address: gone")
ok()
```

The crash of `visits` prints its `RUNTIME-DIVISION-BY-ZERO` diagnostic on stderr; the supervisor observes it, so the run exits 0.
