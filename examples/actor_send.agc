## Requests to several actors at once with std/actor: `Actor.send` to each shard first, then `Actor.await` the answers
## in order, so the waits overlap. `Actor.call` one by one would wait for each shard in turn.

import Actor from "std/actor"

WORK_MS = 300

enum Msg
  Work(Int, Channel[Int])
end

def handle(state: Int, message: Msg) -> Actor.Step[Int]
  case message
    Msg.Work(n, reply) ->
      Task.sleep(WORK_MS)
      Actor.reply(reply, n * 10)
  end

  Actor.continue(state)
end

def ask_all(shards: List[Actor.Ref[Int, Msg]]) -> Result[List[Int]]
  requests: List[Actor.Request[Int]] = []
  for i in 0...shards.size
    request = try Actor.send(shards[i].address) do |reply| Msg.Work(i + 1, reply) end
    requests = requests.push(request)
  end

  answers: List[Int] = []
  for request in requests
    answer = try Actor.await(request, 1000)
    answers = answers.push(answer)
  end

  ok(answers)
end

def main() -> Void
  behaviour: Actor.Behaviour[Int, Msg] = Actor.Behaviour(init: -> { 0 }, handle: &handle)
  shards = [Actor.start(behaviour), Actor.start(behaviour)]
  started = Time.monotonic_ms
  puts(ask_all(shards))
  puts("under two waits: #{Time.monotonic_ms - started < 2 * WORK_MS}")
  for shard in shards
    _ = Actor.stop(shard, 1000)
  end
end
