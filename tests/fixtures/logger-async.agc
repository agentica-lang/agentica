import Logger from "std/logger"

def write_events(events: Channel[LogEvent]) -> Result[Void]
  while true
    case events.recv(1000)
      ok(event) ->
        try File.append_text("app.log", Logger.format_json(event) + "\n", 1000)
      error(_) ->
        if events.closed?
          break
        end
    end
  end
  return ok()
end

def main() -> Void
  events: Channel[LogEvent] = Channel.new(64)
  writer = Task.spawn_owning(&write_events, events)
  _ = Logger.attach("file", LogLevel.Info) do |event|
    _ = events.send(event, 1000)
  end
  Logger.info("server started")
  Logger.info("request done", {"path": "/items", "status": "200"})
  Logger.debug("below the handler")
  Logger.err("cannot open the cache")
  _ = Logger.detach("file")
  events.close
  done = Task.await(writer)
  if !done.ok?
    IO.warn(done.message)
  end
end
