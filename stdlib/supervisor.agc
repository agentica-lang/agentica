## A supervisor: a task that starts actors (`std/actor`) and starts again one that crashes (one for one).
##
## Each child is an actor with a name, and a block that the supervisor runs with the address of each new actor, so a
## module can register it in its table of names: a caller that looks the name up on each call reaches the actor that
## runs now. A child that ends without a crash stays down. A child that crashes more than `max_restarts` times within
## `within_ms` makes the supervisor give up: it stops the other children in reverse order and crashes.

import Actor from "std/actor"

# How long the loop waits for a message before it waits again: a receive always has a timeout.
IDLE_MS = 60_000
# How long `start` waits for the first start of every child, which runs the register blocks.
READY_MS = 60_000
# How long a register block may run; one still running then is cancelled, and the start failed.
REGISTER_MS = 5000
# How long a supervisor that gives up waits for the other children to stop.
GIVE_UP_STOP_MS = 5000
# Room in the inbox for the end notices of the children, which are dropped when it is full. Only a start that succeeded
# is monitored, and a failed one sends a Retry instead, so a child has at most one message waiting.
NOTICES_PER_CHILD = 2
MIN_CAPACITY = 64

# A Down names the child and its run, the count of its starts, so the end notice of an older run is told apart. A Retry
# starts a child again after a failed start: it goes through the inbox so that a Stop is read between two starts. A
# Stop carries the monotonic time by which the stop must be over.
enum Msg
  Down(Int, Int, TaskDown)
  Retry(Int)
  Stop(Int)
end

## A child of a supervisor; `child` makes one.
export struct Child
  name: String
  start: Fn[Channel[Msg], Int, Int, Result[Fn[Int, Result[Void]]]]
end

## What `start` takes besides the children.
export struct Options
  ## A child that crashes more than this many times within `within_ms` makes the supervisor give up. Counted per child;
  ## 0 or more.
  max_restarts: Int = 3
  ## Above 0.
  within_ms: Int = 5000
end

## A running supervisor.
export struct Ref
  address: Address[Msg]
  task: Task[Result[Void]]
end

struct Plan
  children: List[Child]
  options: Options
  inbox: Channel[Msg]
  ready: Channel[Bool]
end

# The running children by position: how to stop each one (none when it is down), which start it is, and when it
# crashed lately.
struct State
  stops: List[Optional[Fn[Int, Result[Void]]]]
  runs: List[Int]
  crashes: List[List[Int]]
end

## A child that runs `behaviour` and calls `register` with the address of each new actor, in a task of its own, for at
## most 5 s. A child that nobody reaches by name gives `do |_address| nil end`.
export def child[S, M](name: String, behaviour: Actor.Behaviour[S, M], register: Fn[Address[M], Void]) -> Child
  begin: Fn[Channel[Msg], Int, Int, Result[Fn[Int, Result[Void]]]] = block3() do |inbox, index, run|
    launch(behaviour, register, inbox, index, run)
  end

  Child(name: name, start: begin)
end

## Starts the supervisor in a task of its own, a child of the calling task, and returns once the first start of every
## child has run (a failed one is tried again later), the supervisor gave up, or 60 s passed. Options out of range
## halt with `RUNTIME-UNWRAP-ERROR`.
export def start(children: List[Child], options: Options = Options()) -> Ref
  if options.max_restarts < 0
    halt("supervisor: max_restarts must be 0 or more, not #{options.max_restarts}")
  end
  if options.within_ms <= 0
    halt("supervisor: within_ms must be above 0, not #{options.within_ms}")
  end

  capacity = MIN_CAPACITY + NOTICES_PER_CHILD * children.size
  inbox: Channel[Msg] = Channel.new(capacity)
  ready: Channel[Bool] = Channel.new(1)
  plan = Plan(children: children, options: options, inbox: inbox, ready: ready)
  task = Task.spawn_owning(&run, plan)
  _ = ready.recv(READY_MS)
  Ref(address: inbox.address, task: task)
end

## Stops the children in reverse order, each as `Actor.stop` does, then the supervisor, all within `timeout_ms`, and
## gives the first error of a child's stop. A child still running when the time is over is cancelled, and so are the
## ones after it, without `terminate`; a supervisor still running then is cancelled with its children, and `stop` gives
## `supervisor: timeout`. A supervisor that gave up gives `supervisor: NAME crashed N times in M ms`.
export def stop(supervisor: Ref, timeout_ms: Int) -> Result[Void]
  deadline = Time.monotonic_ms + timeout_ms
  _ = supervisor.address.send(Msg.Stop(deadline), timeout_ms)
  case Task.await(supervisor.task, max_of(deadline - Time.monotonic_ms, 1))
    Await.Done(result) -> reason(result)
    Await.TimedOut ->
      Task.cancel(supervisor.task)
      error("supervisor: timeout")
  end
end

# A supervisor that gave up crashed with its reason as the message: give the reason alone.
def reason(result: Result[Void]) -> Result[Void]
  return result if result.ok?

  text = result.message
  case text.index_of(": supervisor: ")
    some(at) -> error(text.slice(at + 2, text.length - at - 2))
    none -> result
  end
end

# A block is a value only when it is passed to a call: these hand one back.
def block3[A, B, C, R](f: Fn[A, B, C, R]) -> Fn[A, B, C, R] = f

def stopper[S, M](actor: Actor.Ref[S, M]) -> Fn[Int, Result[Void]]
  f: Fn[Int, Result[Void]] = block1() do |ms| Actor.stop(actor, ms) end
  f
end

def block1[A, R](f: Fn[A, R]) -> Fn[A, R] = f

# Starts one run of a child in the supervisor's task, so the actor is a descendant of the supervisor. The register
# block is the caller's code: it runs in a task, so its crash or a hang is a failed start of the child, not a crash or
# a hang of the supervisor. Only a start that succeeded is monitored, so a failed one leaves no notice in the inbox; a
# monitor of an actor that already ended (its init crashed) sends its notice at once.
def launch[S, M](
  behaviour: Actor.Behaviour[S, M],
  register: Fn[Address[M], Void],
  inbox: Channel[Msg],
  index: Int,
  run: Int,
) -> Result[Fn[Int, Result[Void]]]
  actor = Actor.start(behaviour)
  registering = Task.spawn do registered(register, actor.address) end
  if not registered?(registering)
    _ = Actor.stop(actor, 1000)
    return error("register failed")
  end

  Task.monitor(actor.task, inbox) do |down| Msg.Down(index, run, down) end
  ok(stopper(actor))
end

# Whether the register block ended well within its time; one still running is cancelled.
def registered?(registering: Task[Result[Void]]) -> Bool
  case Task.await(registering, REGISTER_MS)
    Await.Done(result) -> result.ok?
    Await.TimedOut ->
      Task.cancel(registering)
      false
  end
end

def registered[M](register: Fn[Address[M], Void], address: Address[M]) -> Result[Void]
  register.call(address)
  ok()
end

def run(plan: Plan) -> Result[Void]
  stops: List[Optional[Fn[Int, Result[Void]]]] = []
  runs: List[Int] = []
  crashes: List[List[Int]] = []
  for _ in plan.children
    stops = stops.push(none)
    runs = runs.push(0)
    crashes = crashes.push([])
  end

  state = State(stops: stops, runs: runs, crashes: crashes)
  for index in 0...plan.children.size
    state = bring_up(plan, state, index)
  end

  _ = plan.ready.send(true, 0)
  while true
    case plan.inbox.recv(IDLE_MS)
      ok(message) ->
        case message
          Msg.Down(index, run, down) -> state = ended(plan, state, index, run, down)
          Msg.Retry(index) -> state = bring_up(plan, state, index)
          Msg.Stop(deadline) -> return stop_all(state, deadline)
        end
      error(_) -> nil
    end
  end

  ok()
end

# The end of a run of a child. Only a crash of its current run starts it again.
def ended(plan: Plan, state: State, index: Int, run: Int, down: TaskDown) -> State
  return state if run != state.runs[index]

  case down.reason
    TaskExit.Crashed -> bring_up(plan, crashed(plan, state, index), index)
    _ -> state.with(stops: state.stops.set(index, none))
  end
end

# Starts a child. A failed start counts as a crash, and a Retry in the inbox tries again.
def bring_up(plan: Plan, state: State, index: Int) -> State
  run = state.runs[index] + 1
  current = state.with(runs: state.runs.set(index, run))
  case plan.children[index].start.call(plan.inbox, index, run)
    ok(stop_child) -> current.with(stops: current.stops.set(index, some(stop_child)))
    error(_) ->
      failed = crashed(plan, current, index)
      _ = plan.inbox.send(Msg.Retry(index), 0)
      failed
  end
end

# Counts a crash of a child; past the limit the supervisor gives up.
def crashed(plan: Plan, state: State, index: Int) -> State
  now = Time.monotonic_ms
  recent = state.crashes[index].select do |at| now - at < plan.options.within_ms end.push(now)
  stopped = state.with(stops: state.stops.set(index, none), crashes: state.crashes.set(index, recent))
  if recent.size > plan.options.max_restarts
    _ = stop_all(stopped, Time.monotonic_ms + GIVE_UP_STOP_MS)
    name = plan.children[index].name
    halt("supervisor: #{name} crashed #{times(recent.size)} in #{plan.options.within_ms} ms")
  end

  stopped
end

# Stops the running children in reverse order by the monotonic `deadline` and gives the first error. Once the time is
# used up, each child left gets 1 ms, so it is cancelled.
def stop_all(state: State, deadline: Int) -> Result[Void]
  first: Result[Void] = ok()
  for found in state.stops.reverse
    case found
      some(stop_child) ->
        stopped = stop_child.call(max_of(deadline - Time.monotonic_ms, 1))
        if first.ok? and not stopped.ok?
          first = stopped
        end
      none -> nil
    end
  end

  first
end

def times(count: Int) -> String
  return "1 time" if count == 1

  "#{count} times"
end

def max_of(a: Int, b: Int) -> Int
  return a if a > b

  b
end

# Halts the task with `text`. A supervisor that gives up crashes this way, so that it is never silent: the diagnostic
# prints, a give-up nobody observes fails the run, and a monitor sees the crash. There is no other way to halt with a
# message.
def halt(text: String) -> Void
  failed: Result[Int] = error(text)
  _ = failed.unwrap!
end
