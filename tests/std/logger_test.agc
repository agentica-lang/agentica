import Logger from "std/logger"

def reset() -> Void
  for name in Logger.handlers()
    _ = Logger.detach(name)
  end
  _ = Logger.attach("console", Logger.Level.Info, &Logger.stderr_text)
  Logger.set_level(Logger.Level.Info)
end

def collect(events: Channel[Logger.Event]) -> Result[Void]
  attached = Logger.attach("collect", Logger.Level.Debug) do |event| _ = events.send(event, 0) end
  attached
end

def drain(events: Channel[Logger.Event]) -> List[String]
  seen: List[String] = []
  while true
    case events.recv(0)
      ok(event) -> seen = seen.push(event.message)
      error(_) -> break
    end
  end
  seen
end

def main() -> Void
  Test.run([
    Test.test("the console handler is attached at info") do
      reset()
      try Test.eq(Logger.handlers(), ["console"])
      Test.eq(Logger.level(), Logger.Level.Info)
    end,
    Test.test("a handler gets the event with its level, fields, time and task") do
      reset()
      events: Channel[Logger.Event] = Channel.new(8)
      try collect(events)
      before = Time.now_ms()
      Logger.warning("disk", {"free": "3 GB"})
      event = try events.recv(0)
      reset()
      try Test.eq(event.level, Logger.Level.Warning)
      try Test.eq(event.message, "disk")
      try Test.eq(event.fields, {"free": "3 GB"})
      try Test.assert(event.time_ms >= before, "the time is when the event was made")
      Test.assert(event.task >= 2, "the test runs in a task of its own")
    end,
    Test.test("the global level and each handler level are checked") do
      reset()
      events: Channel[Logger.Event] = Channel.new(16)
      try collect(events)
      Logger.debug("d1")
      Logger.set_level(Logger.Level.Debug)
      Logger.debug("d2")
      Logger.info("i")
      _ = Logger.attach("warn", Logger.Level.Warning) do |event|
        _ = events.send(
          Logger.Event(
            level: event.level,
            message: "warn " + event.message,
            fields: event.fields,
            time_ms: 0,
            task: 0,
          ),
          0,
        )
      end

      Logger.info("i2")
      Logger.err("e")
      Logger.set_level(Logger.Level.Error)
      Logger.warning("w")
      Logger.err("e2")
      seen = drain(events)
      reset()
      Test.eq(seen, ["d2", "i", "i2", "e", "warn e", "e2", "warn e2"])
    end,
    Test.test("enabled? needs the global level and a handler") do
      reset()
      Logger.set_level(Logger.Level.Debug)
      try Test.eq(Logger.enabled?(Logger.Level.Debug), false)
      try Test.eq(Logger.enabled?(Logger.Level.Info), true)
      try Test.ok?(Logger.attach("warn", Logger.Level.Warning, &Logger.stderr_text))
      Logger.set_level(Logger.Level.Error)
      try Test.eq(Logger.enabled?(Logger.Level.Warning), false)
      try Test.eq(Logger.enabled?(Logger.Level.Error), true)
      for name in Logger.handlers()
        _ = Logger.detach(name)
      end
      try Test.eq(Logger.enabled?(Logger.Level.Error), false)
      reset()
      Test.eq(Logger.enabled?(Logger.Level.Info), true)
    end,
    Test.test("attach and detach report names in use and names not in use") do
      reset()
      try Test.error?(Logger.attach("console", Logger.Level.Info, &Logger.stderr_json))
      try Test.error?(Logger.detach("missing"))
      try Test.ok?(Logger.attach("extra", Logger.Level.Info, &Logger.stderr_json))
      try Test.eq(Logger.handlers(), ["console", "extra"])
      try Test.ok?(Logger.detach("console"))
      try Test.eq(Logger.handlers(), ["extra"])
      Logger.info("the console stays detached")
      try Test.eq(Logger.handlers(), ["extra"])
      reset()
      Test.eq(Logger.handlers(), ["console"])
    end,
    Test.test("an event keeps its handlers when one detaches another") do
      reset()
      events: Channel[Logger.Event] = Channel.new(8)
      _ = Logger.attach("first", Logger.Level.Info) do |event|
        _ = events.send(event, 0)
        _ = Logger.detach("second")
      end

      _ = Logger.attach("second", Logger.Level.Info) do |event| _ = events.send(event, 0) end
      Logger.info("one")
      Logger.info("two")
      seen = drain(events)
      reset()
      Test.eq(seen, ["one", "one", "two"])
    end,
    Test.test("a handler stays attached when the task that attached it ends") do
      reset()
      events: Channel[Logger.Event] = Channel.new(8)
      task = Task.spawn(&collect, events)
      try Test.ok?(Task.await(task))
      Logger.info("from the test")
      seen = drain(events)
      reset()
      Test.eq(seen, ["from the test"])
    end,
    Test.test("time_text formats UTC milliseconds") do
      try Test.eq(Logger.time_text(0), "1970-01-01T00:00:00.000Z")
      try Test.eq(Logger.time_text(-1), "1969-12-31T23:59:59.999Z")
      try Test.eq(Logger.time_text(951782400000), "2000-02-29T00:00:00.000Z")
      try Test.eq(Logger.time_text(4107542400000), "2100-03-01T00:00:00.000Z")
      try Test.eq(Logger.time_text(253402300799999), "9999-12-31T23:59:59.999Z")
      try Test.assert(Logger.time_text(0 - 9223372036854775807 - 1).ends_with?("Z"), "Int.min does not overflow")
      Test.assert(Logger.time_text(9223372036854775807).ends_with?("Z"), "Int.max does not overflow")
    end,
  ])
end
