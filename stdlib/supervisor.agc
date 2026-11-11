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
# Room in the inbox for the end notices of the children, which are dropped when it is full.
NOTICES_PER_CHILD = 4
MIN_CAPACITY = 64

# A Down names the child and its run, the count of its starts, so the end notice of an older run is told apart.
enum Msg
  Down(Int, Int, TaskDown)
  Stop(Int)
end

## A child of a supervisor; `child` makes one.
export struct Child
  name: String
  start: Fn[Channel[Msg], Int, Int, Result[Fn[Int, Result[Void]]]]
end

## What `start` takes besides the children.
export struct Options
  ## A child that crashes more than this many times within `within_ms` makes the supervisor give up. Counted per child.
  max_restarts: Int = 3
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

## A child that runs `behaviour` and calls `register` with the address of each new actor, in a task of its own. A child
## that nobody reaches by name gives `do |_address| nil end`.
export def child[S, M](name: String, behaviour: Actor.Behaviour[S, M], register: Fn[Address[M], Void]) -> Child
  begin: Fn[Channel[Msg], Int, Int, Result[Fn[Int, Result[Void]]]] = block3() do |inbox, index, run|
    launch(behaviour, register, inbox, index, run)
  end

  Child(name: name, start: begin)
end

## Starts the supervisor in a task of its own, a child of the calling task, and returns once every child has started
## once (or the supervisor gave up).
export def start(children: List[Child], options: Options = Options()) -> Ref
  capacity = MIN_CAPACITY + NOTICES_PER_CHILD * children.size
  inbox: Channel[Msg] = Channel.new(capacity)
  ready: Channel[Bool] = Channel.new(1)
  plan = Plan(children: children, options: options, inbox: inbox, ready: ready)
  task = Task.spawn_owning(&run, plan)
  _ = ready.recv(READY_MS)
  Ref(address: inbox.address, task: task)
end

## Stops the children in reverse order, each as `Actor.stop` does, then the supervisor, all within `timeout_ms`. A
## supervisor still running then is cancelled, with its children, and `stop` gives `supervisor: timeout`. A supervisor
## that gave up gives `supervisor: NAME crashed N times in M ms`.
export def stop(supervisor: Ref, timeout_ms: Int) -> Result[Void]
  _ = supervisor.address.send(Msg.Stop(timeout_ms), timeout_ms)
  case Task.await(supervisor.task, timeout_ms)
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
# block is the caller's code: it runs in a task, so its crash is a failed start of the child, not a crash of the
# supervisor.
def launch[S, M](
  behaviour: Actor.Behaviour[S, M],
  register: Fn[Address[M], Void],
  inbox: Channel[Msg],
  index: Int,
  run: Int,
) -> Result[Fn[Int, Result[Void]]]
  actor = Actor.start(behaviour)
  Task.monitor(actor.task, inbox) do |down| Msg.Down(index, run, down) end
  registering = Task.spawn do registered(register, actor.address) end
  if not Task.await(registering).ok?
    _ = Actor.stop(actor, 1000)
    return error("register crashed")
  end

  ok(stopper(actor))
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
          Msg.Stop(timeout_ms) -> return stop_all(state, timeout_ms)
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

# Starts a child, again after each failed start, which counts as a crash.
def bring_up(plan: Plan, state: State, index: Int) -> State
  current = state
  while true
    run = current.runs[index] + 1
    current = current.with(runs: current.runs.set(index, run))
    case plan.children[index].start.call(plan.inbox, index, run)
      ok(stop_child) -> return current.with(stops: current.stops.set(index, some(stop_child)))
      error(_) -> current = crashed(plan, current, index)
    end
  end

  current
end

# Counts a crash of a child; past the limit the supervisor gives up.
def crashed(plan: Plan, state: State, index: Int) -> State
  now = Time.monotonic_ms
  recent = state.crashes[index].select do |at| now - at < plan.options.within_ms end.push(now)
  stopped = state.with(stops: state.stops.set(index, none), crashes: state.crashes.set(index, recent))
  if recent.size > plan.options.max_restarts
    _ = stop_all(stopped, plan.options.within_ms)
    name = plan.children[index].name
    give_up("supervisor: #{name} crashed #{recent.size} times in #{plan.options.within_ms} ms")
  end

  stopped
end

# Stops the running children in reverse order, sharing the time between them.
def stop_all(state: State, timeout_ms: Int) -> Result[Void]
  deadline = Time.monotonic_ms + timeout_ms
  for found in state.stops.reverse
    case found
      some(stop_child) -> _ = stop_child.call(max_of(deadline - Time.monotonic_ms, 1))
      none -> nil
    end
  end

  ok()
end

def max_of(a: Int, b: Int) -> Int
  return a if a > b

  b
end

# A supervisor that gives up crashes, so that it is never silent: the diagnostic prints, a give-up nobody observes
# fails the run, and a monitor sees the crash. There is no other way to halt with a message.
def give_up(text: String) -> Void
  failed: Result[Int] = error(text)
  _ = failed.unwrap!
end
