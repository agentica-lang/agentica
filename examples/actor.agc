## An actor from std/actor: a counter that one task owns, reached by name through a constant table of addresses. Other
## tasks cast and call it; a Stop message ends it, so a holder of an address can stop it too.

import Actor from "std/actor"

module Counter
  NAMES: ATS[String, Address[Msg]] = ATS.new()

  export enum Msg
    Add(Int)
    Get(Channel[Int])
    Stop
  end

  export def start(name: String, initial: Int) -> Result[Actor.Ref[Int, Msg]]
    actor = Actor.start(Actor.Behaviour(init: -> { initial }, handle: &handle))
    return ok(actor) if NAMES.put_new(name, actor.address)

    _ = Actor.stop(actor, 1000)
    error("counter: #{name} is taken")
  end

  export def add(name: String, n: Int) -> Result[Void]
    address = try NAMES.get(name)
    Actor.cast(address, Msg.Add(n))
  end

  export def get(name: String) -> Result[Int]
    address = try NAMES.get(name)
    Actor.call(address, 1000) do |reply| Msg.Get(reply) end
  end

  export def stop(name: String) -> Result[Void]
    address = try NAMES.get(name)
    NAMES.delete(name)
    Actor.cast(address, Msg.Stop)
  end

  def handle(count: Int, msg: Msg) -> Actor.Step[Int]
    case msg
      Msg.Add(n) -> Actor.continue(count + n)
      Msg.Get(reply) ->
        Actor.reply(reply, count)
        Actor.continue(count)
      Msg.Stop -> Actor.done(count)
    end
  end
end

def visit(n: Int) -> Result[Void] = Counter.add("visits", n)

def main() -> Void
  actor = Counter.start("visits", 100).unwrap!
  case Counter.start("visits", 0)
    ok(_) -> puts("started twice")
    error(text) -> puts(text)
  end

  visitors = [1, 2, 3, 4].map do |n| Task.spawn(&visit, n) end
  for visitor in visitors
    _ = Task.await(visitor)
  end

  puts(Counter.get("visits"))
  puts(Counter.stop("visits"))
  puts(Counter.get("visits"))
  puts(Actor.stop(actor, 1000))
end
