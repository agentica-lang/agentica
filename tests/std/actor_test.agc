import Actor from "std/actor"

enum Msg
  Add(Int)
  Get(Channel[Int])
  Divide(Int)
  Nap(Int, Channel[Int])
  Down(TaskDown)
  Quit
  AskSelf(Channel[String])
end

struct Probe
  # Counts what terminate saw: key 0 is how often it ran, key 1 the last state.
  seen: ATS[Int, Int]
  # The address of the actor, for a handler that calls its own actor.
  me: ATS[Int, Address[Msg]]
end

def probe() -> Probe
  seen: ATS[Int, Int] = ATS.new()
  me: ATS[Int, Address[Msg]] = ATS.new()
  Probe(seen: seen, me: me)
end

def counter(p: Probe, options: Actor.Options) -> Actor.Ref[Int, Msg]
  behaviour: Actor.Behaviour[Int, Msg] = Actor.Behaviour(
    init: -> { 0 },
    handle: ->(count, msg) { handle(p, count, msg) },
    terminate: some(->(count) { finish(p, count) }),
  )

  actor = Actor.start(behaviour, options)
  p.me.put(0, actor.address)
  actor
end

def handle(p: Probe, count: Int, msg: Msg) -> Actor.Step[Int]
  case msg
    Msg.Add(n) -> Actor.continue(count + n)
    Msg.Get(reply) ->
      Actor.reply(reply, count)
      Actor.continue(count)
    Msg.Divide(by) -> Actor.continue(count / by)
    # A nap answers its length, not the count, so a late answer that reached a later call would show.
    Msg.Nap(ms, reply) ->
      Task.sleep(ms)
      Actor.reply(reply, ms)
      Actor.continue(count)
    Msg.Down(_) -> Actor.continue(count + 1)
    Msg.Quit -> Actor.done(count)
    Msg.AskSelf(reply) ->
      Actor.reply(reply, get(p.me.get(0).unwrap!, 100).to_s)
      Actor.continue(count)
  end
end

def finish(p: Probe, count: Int) -> Void
  p.seen.add(0, 1)
  p.seen.put(1, count)
end

def get(address: Address[Msg], timeout_ms: Int) -> Result[Int]
  Actor.call(address, timeout_ms) do |reply| Msg.Get(reply) end
end

# The notices of a monitor come from tasks of their own, so they may arrive after the await: read until they are in.
def count_at_least(address: Address[Msg], n: Int) -> Result[Int]
  for _ in 1..500
    count = try get(address, 5000)
    return ok(count) if count >= n

    Task.sleep(10)
  end

  get(address, 5000)
end

def test_casts_change_the_state_that_a_call_reads() -> Result[Void]
  actor = counter(probe(), Actor.Options())
  for n in 1..10
    try Actor.cast(actor.address, Msg.Add(n))
  end

  try Test.eq(get(actor.address, 5000), ok(55))
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_a_flood_of_casts_waits_for_room_in_a_small_inbox() -> Result[Void]
  actor = counter(probe(), Actor.Options(capacity: 4))
  for _ in 1..3000
    try Actor.cast(actor.address, Msg.Add(1))
  end

  try Test.eq(get(actor.address, 5000), ok(3000))
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_a_call_times_out_and_the_next_call_gets_its_own_answer() -> Result[Void]
  actor = counter(probe(), Actor.Options())
  try Actor.cast(actor.address, Msg.Add(7))
  late: Result[Int] = Actor.call(actor.address, 50) do |reply| Msg.Nap(1000, reply) end
  try Test.eq(late, error("actor: timeout"))
  try Test.eq(get(actor.address, 5000), ok(7))
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_stop_handles_the_inbox_runs_terminate_and_the_address_is_gone() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  for _ in 1..5
    try Actor.cast(actor.address, Msg.Add(2))
  end

  try Test.eq(Actor.stop(actor, 5000), ok())
  try Test.eq(p.seen.to_map, {0: 1, 1: 10})
  try Test.eq(get(actor.address, 1000), error("address: gone"))
  try Test.eq(Actor.cast(actor.address, Msg.Add(1)), error("address: gone"))
  Test.eq(Actor.stop(actor, 1000), ok())
end

def test_a_handler_that_gives_done_ends_the_actor() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  try Actor.cast(actor.address, Msg.Add(3))
  try Actor.cast(actor.address, Msg.Quit)
  try Test.eq(Actor.stop(actor, 5000), ok())
  try Test.eq(p.seen.to_map, {0: 1, 1: 3})
  Test.eq(get(actor.address, 1000), error("address: gone"))
end

def test_a_crash_in_a_handler_ends_the_actor_and_stop_reports_it() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  try Actor.cast(actor.address, Msg.Divide(0))
  stopped = Actor.stop(actor, 5000)
  try Test.assert(stopped.to_s.include?("task crashed: RUNTIME-DIVISION-BY-ZERO"), stopped.to_s)
  try Test.eq(p.seen.to_map, {})
  Test.eq(get(actor.address, 1000), error("address: gone"))
end

def test_stop_cancels_an_actor_that_does_not_end_in_time() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  try Actor.cast(actor.address, Msg.Nap(10_000, Channel.new(1)))
  try Test.eq(Actor.stop(actor, 50), error("actor: timeout"))
  try Test.eq(p.seen.to_map, {})
  Test.eq(get(actor.address, 1000), error("address: gone"))
end

def test_a_monitor_sends_its_notice_into_the_inbox() -> Result[Void]
  actor = counter(probe(), Actor.Options())
  for _ in 1..3
    worker = Task.spawn do 1 end
    Task.monitor(worker, actor.inbox) do |down| Msg.Down(down) end
    _ = Task.await(worker)
  end

  try Test.eq(count_at_least(actor.address, 3), ok(3))
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_an_actor_that_calls_itself_times_out_and_keeps_running() -> Result[Void]
  actor = counter(probe(), Actor.Options())
  try Actor.cast(actor.address, Msg.Add(1))
  answer: Result[String] = Actor.call(actor.address, 5000) do |reply| Msg.AskSelf(reply) end
  try Test.eq(answer, ok("error(\"actor: timeout\")"))
  try Test.eq(get(actor.address, 5000), ok(1))
  Test.eq(Actor.stop(actor, 5000), ok())
end
