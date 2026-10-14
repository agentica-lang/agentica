enum Event
  Item(String, Int)
  Failed(String)
end

struct Source
  name: String
  count: Int
  events: Channel[Event]
end

struct Coordinator
  sources: List[Task[Void]]
  events: Channel[Event]
end

def emit(source: Source) -> Void
  i = 1
  while i <= source.count
    source.events.send(Event.Item(source.name, i * 10), 5000)
    i += 1
  end
  if source.count == 0
    source.events.send(Event.Failed("#{source.name} has nothing"), 5000)
  end
end

def coordinate(c: Coordinator) -> Void
  c.sources.each do |source|
    Task.await(source)
  end
  c.events.close
end

def main() -> Void
  events: Channel[Event] = Channel.new(2)
  sources = [
    Task.spawn(&emit, Source(name: "a", count: 3, events: events)),
    Task.spawn(&emit, Source(name: "b", count: 0, events: events)),
    Task.spawn(&emit, Source(name: "c", count: 4, events: events))
  ]
  coordinator = Task.spawn(&coordinate, Coordinator(sources: sources, events: events))
  totals: Map[String, Int] = {}
  failures: List[String] = []
  while true
    case events.recv(5000)
      ok(event) ->
        case event
          Event.Item(name, value) -> totals = totals.put(name, totals.get(name, 0) + value)
          Event.Failed(text) -> failures = failures.append(text)
        end
      error(e) ->
        puts(e)
        break
    end
  end
  Task.await(coordinator)
  puts(totals)
  puts(failures)
end
