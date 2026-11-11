import Logger from "std/logger"

def name_of(level: Logger.Level) -> String
  case level
    Logger.Level.Debug -> return "debug"
    Logger.Level.Info -> return "info"
    Logger.Level.Warning -> return "warning"
    Logger.Level.Error -> return "error"
  end
end

def fixed(event: Logger.Event) -> Logger.Event
  return Logger.Event(level: event.level, message: event.message, fields: event.fields, time_ms: 1760523302345, task: event.task)
end

def text(event: Logger.Event) -> Void
  Logger.stderr_text(fixed(event))
end

def json(event: Logger.Event) -> Void
  Logger.stderr_json(fixed(event))
end

def attach_all() -> Void
  _ = Logger.attach("at-debug", Logger.Level.Debug) do |event|
    IO.warn("  at-debug got #{name_of(event.level)}: #{event.message}")
  end
  _ = Logger.attach("at-info", Logger.Level.Info) do |event|
    IO.warn("  at-info got #{name_of(event.level)}: #{event.message}")
  end
  _ = Logger.attach("at-warning", Logger.Level.Warning) do |event|
    IO.warn("  at-warning got #{name_of(event.level)}: #{event.message}")
  end
  _ = Logger.attach("at-error", Logger.Level.Error) do |event|
    IO.warn("  at-error got #{name_of(event.level)}: #{event.message}")
  end
end

def log_each() -> Void
  Logger.debug("d")
  Logger.info("i")
  Logger.warning("w")
  Logger.err("e")
  Logger.log(Logger.Level.Debug, "log d")
  Logger.log(Logger.Level.Error, "log e", {"k": "v"})
end

def show_enabled() -> Void
  IO.warn("  enabled: #{Logger.enabled?(Logger.Level.Debug)} #{Logger.enabled?(Logger.Level.Info)} #{Logger.enabled?(Logger.Level.Warning)} #{Logger.enabled?(Logger.Level.Error)}")
end

def main() -> Void
  IO.warn("handlers at start: #{Logger.handlers()}")
  IO.warn("level at start: #{name_of(Logger.level())}")
  puts(Logger.detach("console").ok?)
  puts(Logger.detach("console").message)
  IO.warn("handlers after detach: #{Logger.handlers()}")
  attach_all()
  IO.warn("handlers: #{Logger.handlers()}")
  for level in [Logger.Level.Debug, Logger.Level.Info, Logger.Level.Warning, Logger.Level.Error]
    Logger.set_level(level)
    IO.warn("global level #{name_of(Logger.level())}")
    show_enabled()
    log_each()
  end

  IO.warn("handlers at info and warning only")
  _ = Logger.detach("at-debug")
  _ = Logger.detach("at-error")
  Logger.set_level(Logger.Level.Debug)
  show_enabled()
  Logger.debug("d")
  Logger.info("i")
  _ = Logger.detach("at-info")
  _ = Logger.detach("at-warning")
  show_enabled()
  Logger.err("nobody listens")

  IO.warn("attach errors")
  puts(Logger.attach("again", Logger.Level.Info, &text).ok?)
  again = Logger.attach("again", Logger.Level.Info, &json)
  puts(again.ok?)
  puts(again.message)
  puts(Logger.detach("missing").message)
  IO.warn("handlers: #{Logger.handlers()}")

  IO.warn("the built-in handlers, one per format")
  _ = Logger.detach("again")
  _ = Logger.attach("text", Logger.Level.Info, &text)
  _ = Logger.attach("json", Logger.Level.Warning, &json)
  Logger.info("request done", {"path": "/items", "status": "200"})
  Logger.warning("slow", {"ms": "1500"})
  Logger.debug("below every handler")

  IO.warn("a handler that detaches another does not change the event in progress")
  _ = Logger.detach("text")
  _ = Logger.detach("json")
  _ = Logger.attach("first", Logger.Level.Info) do |event|
    IO.warn("  first: #{event.message}")
    _ = Logger.detach("second")
  end
  _ = Logger.attach("second", Logger.Level.Info) do |event|
    IO.warn("  second: #{event.message}")
  end
  Logger.info("one")
  Logger.info("two")
  IO.warn("handlers: #{Logger.handlers()}")
end
