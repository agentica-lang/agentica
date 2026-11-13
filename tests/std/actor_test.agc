import Actor from "std/actor"

enum Msg
  Add(Int)
  Get(Channel[Int])
  Divide(Int)
  Nap(Int, Channel[Int])
  Down(TaskDown)
  Quit
  AskSelf(Channel[String])
  # Naps, then answers and counts in the probe whether the caller got the answer (key 2) or not (key 3).
  Offer(Int, Channel[Int])
  # Answers 1, then 2 after 30 ms, and counts each as Offer does.
  Twice(Channel[Int])
  # For the actors with a receive timeout: the wait from now on, and the ticks and messages seen.
  Wait(Optional[Int])
  Ticks(Channel[Timed])
end

# The state of an actor with a receive timeout: how long it waits, or the deadline it waits for (0: none), how often
# its timeout ran and how many messages came.
struct Timed
  after: Optional[Int]
  deadline: Int
  ticks: Int
  messages: Int
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
    Msg.Offer(ms, reply) ->
      if ms > 0
        Task.sleep(ms)
      end

      count_reply(p, Actor.reply(reply, ms))
      Actor.continue(count)
    Msg.Twice(reply) ->
      count_reply(p, Actor.reply(reply, 1))
      Task.sleep(30)
      count_reply(p, Actor.reply(reply, 2))
      Actor.continue(count)
    _ -> Actor.continue(count)
  end
end

def count_reply(p: Probe, delivered: Bool) -> Void
  if delivered
    p.seen.add(2, 1)
  else
    p.seen.add(3, 1)
  end
end

def timed(after: Optional[Int]) -> Actor.Ref[Timed, Msg] = start_timed(after, 0)

def start_timed(after: Optional[Int], deadline_in: Int) -> Actor.Ref[Timed, Msg]
  timeout: Actor.Timeout[Timed] = Actor.Timeout(after_ms: &wait, handle: &tick)
  behaviour: Actor.Behaviour[Timed, Msg] = Actor.Behaviour(
    init: -> { Timed(after: after, deadline: deadline_at(deadline_in), ticks: 0, messages: 0) },
    handle: &handle_timed,
    timeout: some(timeout),
  )

  Actor.start(behaviour)
end

def deadline_at(ms: Int) -> Int
  return 0 if ms == 0

  Time.monotonic_ms + ms
end

def wait(state: Timed) -> Optional[Int]
  return some(state.deadline - Time.monotonic_ms) if state.deadline > 0

  state.after
end

# A deadline fires once, and so does a wait of 0 or less, which would run the timeout again at once.
def tick(state: Timed) -> Actor.Step[Timed]
  ticked = state.with(ticks: state.ticks + 1, deadline: 0)
  case state.after
    some(ms) if ms <= 0 -> Actor.continue(ticked.with(after: none))
    _ -> Actor.continue(ticked)
  end
end

def handle_timed(state: Timed, msg: Msg) -> Actor.Step[Timed]
  seen = state.with(messages: state.messages + 1)
  case msg
    Msg.Wait(after) -> Actor.continue(seen.with(after: after))
    Msg.Ticks(reply) ->
      Actor.reply(reply, state)
      Actor.continue(state)
    Msg.Divide(by) -> Actor.continue(seen.with(ticks: state.ticks / by))
    Msg.Nap(ms, reply) ->
      Task.sleep(ms)
      Actor.reply(reply, ms)
      Actor.continue(seen)
    Msg.Quit -> Actor.done(seen)
    _ -> Actor.continue(seen)
  end
end

def ticks(address: Address[Msg]) -> Result[Timed] = Actor.call(address, 5000) do |reply| Msg.Ticks(reply) end

# Asks until the actor has ticked at least `n` times. Each question is a message, which starts the wait of the timeout
# again, so the questions are further apart than the waits of these tests (at most 20 ms).
def ticked(address: Address[Msg], n: Int) -> Result[Timed]
  for _ in 1..100
    state = try ticks(address)
    return ok(state) if state.ticks >= n

    Task.sleep(50)
  end

  ticks(address)
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
  try Test.eq(late, error("actor: timeout", kind: "channel.timeout"))
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
  try Test.eq(get(actor.address, 1000), error("address: gone", kind: "channel.gone"))
  try Test.eq(Actor.cast(actor.address, Msg.Add(1)), error("address: gone", kind: "channel.gone"))
  Test.eq(Actor.stop(actor, 1000), ok())
end

def test_a_handler_that_gives_done_ends_the_actor() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  try Actor.cast(actor.address, Msg.Add(3))
  try Actor.cast(actor.address, Msg.Quit)
  try Test.eq(Actor.stop(actor, 5000), ok())
  try Test.eq(p.seen.to_map, {0: 1, 1: 3})
  Test.eq(get(actor.address, 1000), error("address: gone", kind: "channel.gone"))
end

def test_a_crash_in_a_handler_ends_the_actor_and_stop_reports_it() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  try Actor.cast(actor.address, Msg.Divide(0))
  stopped = Actor.stop(actor, 5000)
  try Test.assert(stopped.to_s.include?("task crashed: RUNTIME-DIVISION-BY-ZERO"), stopped.to_s)
  try Test.eq(p.seen.to_map, {})
  Test.eq(get(actor.address, 1000), error("address: gone", kind: "channel.gone"))
end

def test_stop_cancels_an_actor_that_does_not_end_in_time() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  try Actor.cast(actor.address, Msg.Nap(10_000, Channel.new(1)))
  try Test.eq(Actor.stop(actor, 50), error("actor: timeout", kind: "task.timeout"))
  try Test.eq(p.seen.to_map, {})
  Test.eq(get(actor.address, 1000), error("address: gone", kind: "channel.gone"))
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
  try Test.eq(answer, ok("error(\"actor: timeout\", kind: \"channel.timeout\")"))
  try Test.eq(get(actor.address, 5000), ok(1))
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_an_answer_is_taken_or_its_reply_gives_false_never_lost() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  taken = 0
  # Answers that come at about the time the call gives up: each one is taken by the call or refused to the actor. With
  # the coarse timers of Windows nearly every answer is refused there.
  for i in 1..200
    answer: Result[Int] = Actor.call(actor.address, 2) do |reply| Msg.Offer(1 + i % 3, reply) end
    if answer.ok?
      taken += 1
    else
      try Test.eq(answer, error("actor: timeout", kind: "channel.timeout"))
    end
  end

  try get(actor.address, 5000)
  try Test.eq(p.seen.get(2).unwrap_or(0), taken)
  try Test.eq(p.seen.get(2).unwrap_or(0) + p.seen.get(3).unwrap_or(0), 200)
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_a_reply_to_a_caller_that_ended_gives_false() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  caller = Task.spawn do
    answer: Result[Int] = Actor.call(actor.address, 50) do |reply| Msg.Offer(300, reply) end
    answer
  end

  try Test.eq(Task.await(caller), error("actor: timeout", kind: "channel.timeout"))
  try get(actor.address, 5000)
  try Test.eq(p.seen.to_map, {3: 1})
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_a_second_reply_after_the_first_was_taken_gives_false() -> Result[Void]
  p = probe()
  actor = counter(p, Actor.Options())
  first: Result[Int] = Actor.call(actor.address, 5000) do |reply| Msg.Twice(reply) end
  try Test.eq(first, ok(1))
  try get(actor.address, 5000)
  try Test.eq(p.seen.to_map, {2: 1, 3: 1})
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_the_timeout_runs_again_and_again_while_no_message_comes() -> Result[Void]
  actor = timed(some(10))
  state = try ticked(actor.address, 2)
  try Test.eq(state.messages, 0)
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_messages_at_the_time_of_the_timeout_are_all_handled_and_the_timeout_still_runs() -> Result[Void]
  actor = timed(some(5))
  for _ in 1..50
    try Actor.cast(actor.address, Msg.Add(1))
    Task.sleep(5)
  end

  state = try ticked(actor.address, 1)
  try Test.eq(state.messages, 50)
  try Test.assert(state.ticks >= 1, "no tick")
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_each_message_can_change_the_timeout() -> Result[Void]
  actor = timed(none)
  Task.sleep(50)
  try Test.eq((try ticks(actor.address)).ticks, 0)
  try Actor.cast(actor.address, Msg.Wait(some(10)))
  try ticked(actor.address, 2)
  try Actor.cast(actor.address, Msg.Wait(none))
  # A tick may still come before the message: read the count once it has settled.
  Task.sleep(30)
  before = try ticks(actor.address)
  Task.sleep(60)
  try Test.eq((try ticks(actor.address)).ticks, before.ticks)
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_a_timeout_of_zero_or_less_runs_the_timeout_at_once() -> Result[Void]
  for after in [0, -5]
    actor = timed(some(after))
    state = try ticked(actor.address, 1)
    try Test.eq(state.ticks, 1)
    try Test.eq(state.after, none)
    try Test.eq(Actor.stop(actor, 5000), ok())
  end

  ok()
end

def test_a_deadline_that_passed_while_a_message_was_handled_runs_the_timeout() -> Result[Void]
  actor = start_timed(none, 10)
  nap: Result[Int] = Actor.call(actor.address, 5000) do |reply| Msg.Nap(30, reply) end
  try Test.eq(nap, ok(30))
  state = try ticked(actor.address, 1)
  try Test.eq(state.ticks, 1)
  Test.eq(Actor.stop(actor, 5000), ok())
end

def test_stop_and_crash_with_a_timeout_pending_leave_no_task() -> Result[Void]
  base = Task.pending_count()
  stopped = timed(some(10_000))
  try Test.eq(Task.pending_count(), base + 1)
  try Test.eq(Actor.stop(stopped, 5000), ok())
  crashed = timed(some(10_000))
  try Actor.cast(crashed.address, Msg.Divide(0))
  result = Actor.stop(crashed, 5000)
  try Test.assert(result.to_s.include?("RUNTIME-DIVISION-BY-ZERO"), result.to_s)
  Test.eq(Task.pending_count(), base)
end

def test_a_thousand_actors_with_timeouts_need_no_more_tasks() -> Result[Void]
  base = Task.pending_count()
  actors: List[Actor.Ref[Timed, Msg]] = []
  for _ in 1..1000
    actors = actors.push(timed(some(200)))
  end

  try Test.eq(Task.pending_count(), base + 1000)
  Task.sleep(400)
  for actor in actors
    state = try ticks(actor.address)
    try Test.assert(state.ticks >= 1, "no tick")
  end

  try Test.eq(Task.pending_count(), base + 1000)
  for actor in actors
    try Actor.stop(actor, 5000)
  end

  Test.eq(Task.pending_count(), base)
end
