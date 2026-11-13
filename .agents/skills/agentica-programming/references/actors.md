# Actors and supervisors

Tasks, channels and `Address`: `tasks.md`.

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
