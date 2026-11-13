## Actors: a task that owns its state and handles the messages of one inbox, one at a time.
##
## A `Behaviour` is a struct of functions, the contract of an actor, since Agentica has no traits: `init` makes the
## first state, `handle` takes the state and a message and gives the next step. `start` runs it in a task of its own
## and gives a `Ref`; its `address` is the `Address[M]` of the inbox, which is data, so a table of names can hold it.
## `cast` sends a message, `call` sends one that carries a reply channel and waits for the answer, and `stop` ends the
## actor after the messages already in its inbox. A `Timeout` wakes the actor when no message came in time.

## The contract of an actor with state `S` and messages `M`.
struct Behaviour[S, M]
  ## Makes the first state, in the actor's task.
  init: Fn[S]
  handle: Fn[S, M, Step[S]]
  ## Runs with the last state when the actor stops, not when it crashes or is cancelled.
  terminate: Optional[Fn[S, Void]] = none
  ## The receive timeout, if any.
  timeout: Optional[Timeout[S]] = none
end

## A receive timeout. After `init` and after each message, `after_ms` gives how long the actor waits for the next
## one in that state (0 or less: only a message already waiting; none: no limit). When none comes in that time,
## `handle` runs with the state, in place of a message. The actor's own loop waits: there is no timer task.
struct Timeout[S]
  after_ms: Fn[S, Optional[Int]]
  handle: Fn[S, Step[S]]
end

## What `start` takes besides the behaviour.
struct Options
  ## How many messages the inbox holds before `cast` and `call` wait for room (1 to 1048576).
  capacity: Int = 1024
end

## What a handler gives: the next state, or the last one.
enum Step[S]
  Continue(S)
  Done(S)
end

## A running actor. Send through `address`; `inbox` is only the channel for `Task.monitor`: never receive from it.
struct Ref[S, M]
  address: Address[M]
  inbox: Channel[M]
  task: Task[Result[Void]]
end

## Starts the actor in a task of its own, which owns the inbox: the inbox closes when the actor ends in any way.
def start[S, M](behaviour: Behaviour[S, M], options: Options = Options()) -> Ref[S, M]
  inbox: Channel[M] = Channel.new(options.capacity)
  body: Fn[Setup[S, M], Result[Void]] = &run
  task = Task.spawn_owning(body, Setup(behaviour: behaviour, inbox: inbox))
  Ref(address: inbox.address, inbox: inbox, task: task)
end

## The step that keeps the actor running with `state`.
def continue[S](state: S) -> Step[S] = Step.Continue(state)

## The step that ends the actor with `state`: it runs `terminate` and handles no more messages.
def done[S](state: S) -> Step[S] = Step.Done(state)

## Answers a `call` and says whether the caller gets the value. It never waits, and it closes the channel: a call
## has one answer. A caller that gave up closed the channel, and a second answer finds it closed: both give false, and
## the value is still the actor's. A closed channel still gives its caller the answer it holds.
def reply[R](channel: Channel[R], value: R) -> Bool
  sent = channel.send(value, 0).ok?
  channel.close
  sent
end

## Sends a message, waiting at most `timeout_ms` for room in the inbox. Errors: `actor: timeout` when the inbox stays
## full, `address: gone` when the actor has ended.
def cast[M](address: Address[M], message: M, timeout_ms: Int = 5000) -> Result[Void]
  case address.send(message, timeout_ms)
    ok(_) -> ok()
    error(e) -> gone_or_timeout(e)
  end
end

## Sends the message that `make` builds around a new reply channel and returns the answer, all within `timeout_ms`.
## Errors as `cast`; a call whose actor ends or crashes before it answers ends with `actor: timeout`. A call that gives
## up closes its reply channel, so a later `reply` gives false; an answer that came just before is returned.
def call[M, R](address: Address[M], timeout_ms: Int, make: Fn[Channel[R], M]) -> Result[R]
  answer: Channel[R] = Channel.new(1)
  started = Time.monotonic_ms
  try cast(address, make.call(answer), timeout_ms)
  left = timeout_ms - (Time.monotonic_ms - started)
  return given_up(answer) if left <= 0

  case answer.recv(left)
    ok(value) -> ok(value)
    error(_) -> given_up(answer)
  end
end

## Stops the actor: it handles the messages already in its inbox, runs `terminate` and ends, and `stop` waits for that
## at most `timeout_ms`. An actor still running then is cancelled and `stop` gives `actor: timeout`; an actor that
## crashed gives its `task crashed: ...` error. Stopping an ended actor gives how it ended.
def stop[S, M](actor: Ref[S, M], timeout_ms: Int) -> Result[Void]
  actor.inbox.close
  case Task.await(actor.task, timeout_ms)
    Await.Done(result) -> result
    Await.TimedOut ->
      Task.cancel(actor.task)
      error("actor: timeout", kind: "task.timeout")
  end
end

private

# How long the loop waits for a message before it waits again: a receive always has a timeout.
IDLE_MS = 60_000

struct Setup[S, M]
  behaviour: Behaviour[S, M]
  inbox: Channel[M]
end

# Closed first, so the actor's `reply` either fails (it sees that nobody took the value) or came before: then the value
# is in the channel and is taken here. Either way no answer is lost.
def given_up[R](answer: Channel[R]) -> Result[R]
  answer.close
  case answer.recv(0)
    ok(value) -> ok(value)
    error(_) -> error("actor: timeout", kind: "channel.timeout")
  end
end

# A closed inbox and a collected one both mean that the actor has ended: `channel.gone`.
def gone_or_timeout(e: Error) -> Result[Void]
  return error(e.with(message: "actor: timeout")) if e.is_a?("channel.timeout")

  error("address: gone", kind: "channel.gone")
end

def run[S, M](setup: Setup[S, M]) -> Result[Void]
  behaviour = setup.behaviour
  inbox = setup.inbox
  state = behaviour.init.call()
  while true
    wait = waiting(behaviour.timeout, state)
    step = Step.Continue(state)
    case inbox.recv(wait.unwrap_or(IDLE_MS))
      ok(message) -> step = behaviour.handle.call(state, message)
      error(_) ->
        break if inbox.closed? and inbox.empty?

        # A wait without a timeout only ends to wait again.
        case behaviour.timeout
          some(timeout) if wait.some? -> step = timeout.handle.call(state)
          _ -> nil
        end
    end

    case step
      Step.Continue(next_state) -> state = next_state
      Step.Done(last) ->
        state = last
        break
    end
  end

  # Closed now, not when the task ends after terminate: a send in between would wait for an answer that never comes.
  inbox.close
  case behaviour.terminate
    some(finish) -> finish.call(state)
    none -> nil
  end
  ok()
end

# How long the actor waits for a message in `state`: none without a timeout. A wait of 0 or less takes only a message
# that is already waiting (`recv(0)`), as Erlang's `after 0`: a deadline kept in the state may have passed.
def waiting[S](timeout: Optional[Timeout[S]], state: S) -> Optional[Int]
  case timeout
    some(t) ->
      case t.after_ms.call(state)
        some(ms) -> some([ms, 0].max.unwrap!)
        none -> none
      end
    none -> none
  end
end
