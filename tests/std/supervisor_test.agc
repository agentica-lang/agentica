import Actor from "std/actor"
import Supervisor from "std/supervisor"

enum Msg
  Add(Int)
  Get(Channel[Int])
  Divide(Int)
  Quit
end

struct World
  names: ATS[String, Address[Msg]]
  # How often each child was registered, and when each child stopped, as a count of the stops.
  starts: ATS[String, Int]
  stopped: ATS[String, Int]
end

def world() -> World
  names: ATS[String, Address[Msg]] = ATS.new()
  starts: ATS[String, Int] = ATS.new()
  stopped: ATS[String, Int] = ATS.new()
  World(names: names, starts: starts, stopped: stopped)
end

def counter(w: World, name: String) -> Supervisor.Child
  behaviour: Actor.Behaviour[Int, Msg] = Actor.Behaviour(
    init: block0() do 0 end,
    handle: &handle,
    terminate: some(block1() do |_count| w.stopped.put(name, w.stopped.add("", 1)) end),
  )

  Supervisor.child(name, behaviour) do |address| register(w, name, address) end
end

def register(w: World, name: String, address: Address[Msg]) -> Void
  w.starts.add(name, 1)
  w.names.put(name, address)
end

def handle(count: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Add(n) -> Actor.continue(count + n)
    Msg.Get(reply) ->
      Actor.reply(reply, count)
      Actor.continue(count)
    Msg.Divide(by) -> Actor.continue(count / by)
    Msg.Quit -> Actor.done(count)
  end
end

def get(w: World, name: String) -> Result[Int]
  address = try w.names.get(name)
  Actor.call(address, 5000) do |reply| Msg.Get(reply) end
end

def cast(w: World, name: String, msg: Msg) -> Result[Void]
  address = try w.names.get(name)
  Actor.cast(address, msg)
end

# A restart comes from the supervisor's task: wait until the child was registered `count` times.
def started(w: World, name: String, count: Int) -> Result[Void]
  for _ in 1..500
    return ok() if w.starts.get(name).unwrap_or(0) >= count

    Task.sleep(10)
  end

  error("#{name} was registered #{w.starts.get(name).unwrap_or(0)} times, not #{count}")
end

# A call queued behind the message that ends an actor gets no answer: wait until its terminate ran.
def ended(w: World, name: String) -> Result[Void]
  for _ in 1..500
    return ok() if w.stopped.has_key?(name)

    Task.sleep(10)
  end

  error("#{name} did not end")
end

def block0[R](f: Fn[R]) -> Fn[R] = f

def block1[A, R](f: Fn[A, R]) -> Fn[A, R] = f

def test_a_crash_restarts_the_child_and_its_name_points_to_the_new_actor() -> Result[Void]
  w = world()
  sup = Supervisor.start([counter(w, "visits")])
  try cast(w, "visits", Msg.Add(5))
  try Test.eq(get(w, "visits"), ok(5))
  old = try w.names.get("visits")
  try cast(w, "visits", Msg.Divide(0))
  try started(w, "visits", 2)
  try Test.eq(get(w, "visits"), ok(0))
  try Test.eq(Actor.cast(old, Msg.Add(1)), error("address: gone"))
  Test.eq(Supervisor.stop(sup, 5000), ok())
end

def test_a_child_that_ends_without_a_crash_stays_down() -> Result[Void]
  w = world()
  sup = Supervisor.start([counter(w, "once"), counter(w, "other")])
  try cast(w, "once", Msg.Quit)
  try cast(w, "other", Msg.Add(2))
  try Test.eq(get(w, "other"), ok(2))
  try ended(w, "once")
  try Test.eq(get(w, "once"), error("address: gone"))
  try Test.eq(w.starts.get("once"), ok(1))
  Test.eq(Supervisor.stop(sup, 5000), ok())
end

def test_stop_stops_the_children_in_reverse_order() -> Result[Void]
  w = world()
  sup = Supervisor.start([counter(w, "a"), counter(w, "b"), counter(w, "c")])
  try Test.eq(Supervisor.stop(sup, 5000), ok())
  try Test.eq(w.stopped.to_map, {"": 3, "c": 1, "b": 2, "a": 3})
  Test.eq(get(w, "a"), error("address: gone"))
end

def test_the_restart_limit_makes_the_supervisor_give_up_and_crash() -> Result[Void]
  w = world()
  options = Supervisor.Options(max_restarts: 2, within_ms: 60_000)
  sup = Supervisor.start([counter(w, "loop"), counter(w, "other")], options)
  downs: Channel[TaskDown] = Channel.new(1)
  Task.monitor(sup.task, downs) do |down| down end
  for run in 1..3
    try started(w, "loop", run)
    try cast(w, "loop", Msg.Divide(0))
  end

  down = try downs.recv(5000)
  try Test.eq([down.reason.to_s, down.code], ["TaskExit.Crashed", "RUNTIME-UNWRAP-ERROR"])
  try Test.eq(down.message, "supervisor: loop crashed 3 times in 60000 ms")
  try Test.eq(w.stopped.get("other"), ok(1))
  try Test.eq(get(w, "other"), error("address: gone"))
  Test.eq(Supervisor.stop(sup, 5000), error("supervisor: loop crashed 3 times in 60000 ms"))
end

def test_a_failed_start_counts_as_a_crash() -> Result[Void]
  w = world()
  behaviour: Actor.Behaviour[Int, Msg] = Actor.Behaviour(init: block0() do 0 end, handle: &handle)
  failing = Supervisor.child("failing", behaviour) do |_address| w.starts.add("failing", 1 / 0) end
  sup = Supervisor.start([failing], Supervisor.Options(max_restarts: 1, within_ms: 60_000))
  Test.eq(Supervisor.stop(sup, 5000), error("supervisor: failing crashed 2 times in 60000 ms"))
end
