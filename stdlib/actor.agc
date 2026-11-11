## Actors: a task that owns its state and handles the messages of one inbox, one at a time.
##
## A `Behaviour` is a struct of functions, the contract of an actor, since Agentica has no traits: `init` makes the
## first state, `handle` takes the state and a message and gives the next step. `start` runs it in a task of its own
## and gives a `Ref`; its `address` is the `Address[M]` of the inbox, which is data, so a table of names can hold it.
## `cast` sends a message, `call` sends one that carries a reply channel and waits for the answer, and `stop` ends the
## actor after the messages already in its inbox.

# How long the loop waits for a message before it waits again: a receive always has a timeout.
IDLE_MS = 60_000

## The contract of an actor with state `S` and messages `M`.
export struct Behaviour[S, M]
  ## Makes the first state, in the actor's task.
  init: Fn[S]
  handle: Fn[S, M, Step[S]]
  ## Runs with the last state when the actor stops, not when it crashes or is cancelled.
  terminate: Optional[Fn[S, Void]] = none
end

## What `start` takes besides the behaviour.
export struct Options
  ## How many messages the inbox holds before `cast` and `call` wait for room (1 to 1048576).
  capacity: Int = 1024
end

## What a handler gives: the next state, or the last one.
export enum Step[S]
  Continue(S)
  Done(S)
end

## A running actor. Send through `address`; `inbox` is only the channel for `Task.monitor`: never receive from it.
export struct Ref[S, M]
  address: Address[M]
  inbox: Channel[M]
  task: Task[Result[Void]]
end

struct Setup[S, M]
  behaviour: Behaviour[S, M]
  inbox: Channel[M]
end

## Starts the actor in a task of its own, which owns the inbox: the inbox closes when the actor ends in any way.
export def start[S, M](behaviour: Behaviour[S, M], options: Options = Options()) -> Ref[S, M]
  inbox: Channel[M] = Channel.new(options.capacity)
  body: Fn[Setup[S, M], Result[Void]] = &run
  task = Task.spawn_owning(body, Setup(behaviour: behaviour, inbox: inbox))
  Ref(address: inbox.address, inbox: inbox, task: task)
end

## The step that keeps the actor running with `state`.
export def continue[S](state: S) -> Step[S] = Step.Continue(state)

## The step that ends the actor with `state`: it runs `terminate` and handles no more messages.
export def done[S](state: S) -> Step[S] = Step.Done(state)

## Answers a `call`. It never waits: the answer to a caller that gave up stays in a channel nobody reads, and a second
## answer to one call finds the channel full and is dropped.
export def reply[R](channel: Channel[R], value: R) -> Void
  _ = channel.send(value, 0)
end

## Sends a message, waiting at most `timeout_ms` for room in the inbox. Errors: `actor: timeout` when the inbox stays
## full, `address: gone` when the actor has ended.
export def cast[M](address: Address[M], message: M, timeout_ms: Int = 5000) -> Result[Void]
  case address.send(message, timeout_ms)
    ok(_) -> ok()
    error(text) -> error(reason(text))
  end
end

## Sends the message that `make` builds around a new reply channel and returns the answer, all within `timeout_ms`.
## Errors as `cast`; a call whose actor ends or crashes before it answers ends with `actor: timeout`.
export def call[M, R](address: Address[M], timeout_ms: Int, make: Fn[Channel[R], M]) -> Result[R]
  answer: Channel[R] = Channel.new(1)
  started = Time.monotonic_ms
  try cast(address, make.call(answer), timeout_ms)
  left = timeout_ms - (Time.monotonic_ms - started)
  return error("actor: timeout") if left <= 0

  case answer.recv(left)
    ok(value) -> ok(value)
    error(_) -> error("actor: timeout")
  end
end

## Stops the actor: it handles the messages already in its inbox, runs `terminate` and ends, and `stop` waits for that
## at most `timeout_ms`. An actor still running then is cancelled and `stop` gives `actor: timeout`; an actor that
## crashed gives its `task crashed: ...` error. Stopping an ended actor gives how it ended.
export def stop[S, M](actor: Ref[S, M], timeout_ms: Int) -> Result[Void]
  actor.inbox.close
  case Task.await(actor.task, timeout_ms)
    Await.Done(result) -> result
    Await.TimedOut ->
      Task.cancel(actor.task)
      error("actor: timeout")
  end
end

# A closed inbox and a collected one both mean that the actor has ended.
def reason(text: String) -> String
  return "actor: timeout" if text == "channel: timed out"

  "address: gone"
end

def run[S, M](setup: Setup[S, M]) -> Result[Void]
  behaviour = setup.behaviour
  inbox = setup.inbox
  state = behaviour.init.call()
  while true
    case inbox.recv(IDLE_MS)
      ok(message) ->
        case behaviour.handle.call(state, message)
          Step.Continue(next_state) -> state = next_state
          Step.Done(last) ->
            state = last
            break
        end
      error(_) -> break if inbox.closed? and inbox.empty?
    end
  end

  case behaviour.terminate
    some(finish) -> finish.call(state)
    none -> nil
  end
  ok()
end
