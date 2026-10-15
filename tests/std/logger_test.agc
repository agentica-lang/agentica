import "std/logger" as Logger

def reset() -> Void
  for name in Logger.handlers()
    gone = Logger.detach(name)
  end
  back = Logger.attach("console", LogLevel.Info, &Logger.stderr_text)
  Logger.set_level(LogLevel.Info)
end

def collect(events: Channel[LogEvent]) -> Result[Void]
  attached = Logger.attach("collect", LogLevel.Debug) do |event|
    sent = events.send(event, 0)
  end
  return attached
end

def drain(events: Channel[LogEvent]) -> List[String]
  seen: List[String] = []
  while true
    case events.recv(0)
      ok(event) -> seen = seen.push(event.message)
      error(_) -> break
    end
  end
  return seen
end

def main() -> Void
  Test.run([
    Test.test("the console handler is attached at info") do
      reset()
      try Test.eq(Logger.handlers(), ["console"])
      Test.eq(Logger.level(), LogLevel.Info)
    end,
    Test.test("a handler gets the event with its level, fields, time and task") do
      reset()
      events: Channel[LogEvent] = Channel.new(8)
      try collect(events)
      before = Time.now_ms()
      Logger.warning_meta("disk", {"free": "3 GB"})
      event = try events.recv(0)
      reset()
      try Test.eq(event.level, LogLevel.Warning)
      try Test.eq(event.message, "disk")
      try Test.eq(event.fields, {"free": "3 GB"})
      try Test.assert(event.time_ms >= before, "the time is when the event was made")
      Test.assert(event.task >= 2, "the test runs in a task of its own")
    end,
    Test.test("the global level and each handler level are checked") do
      reset()
      events: Channel[LogEvent] = Channel.new(16)
      try collect(events)
      Logger.debug("d1")
      Logger.set_level(LogLevel.Debug)
      Logger.debug("d2")
      Logger.info("i")
      back = Logger.attach("warn", LogLevel.Warning) do |event|
        sent = events.send(LogEvent(level: event.level, message: "warn " + event.message, fields: event.fields, time_ms: 0, task: 0), 0)
      end
      Logger.info("i2")
      Logger.err("e")
      Logger.set_level(LogLevel.Error)
      Logger.warning("w")
      Logger.err("e2")
      seen = drain(events)
      reset()
      Test.eq(seen, ["d2", "i", "i2", "e", "warn e", "e2", "warn e2"])
    end,
    Test.test("enabled? needs the global level and a handler") do
      reset()
      Logger.set_level(LogLevel.Debug)
      try Test.eq(Logger.enabled?(LogLevel.Debug), false)
      try Test.eq(Logger.enabled?(LogLevel.Info), true)
      try Test.ok?(Logger.attach("warn", LogLevel.Warning, &Logger.stderr_text))
      Logger.set_level(LogLevel.Error)
      try Test.eq(Logger.enabled?(LogLevel.Warning), false)
      try Test.eq(Logger.enabled?(LogLevel.Error), true)
      for name in Logger.handlers()
        gone = Logger.detach(name)
      end
      try Test.eq(Logger.enabled?(LogLevel.Error), false)
      reset()
      Test.eq(Logger.enabled?(LogLevel.Info), true)
    end,
    Test.test("attach and detach report names in use and names not in use") do
      reset()
      try Test.error?(Logger.attach("console", LogLevel.Info, &Logger.stderr_json))
      try Test.error?(Logger.detach("missing"))
      try Test.ok?(Logger.attach("extra", LogLevel.Info, &Logger.stderr_json))
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
      events: Channel[LogEvent] = Channel.new(8)
      back = Logger.attach("first", LogLevel.Info) do |event|
        sent = events.send(event, 0)
        gone = Logger.detach("second")
      end
      later = Logger.attach("second", LogLevel.Info) do |event|
        sent = events.send(event, 0)
      end
      Logger.info("one")
      Logger.info("two")
      seen = drain(events)
      reset()
      Test.eq(seen, ["one", "one", "two"])
    end,
    Test.test("a handler stays attached when the task that attached it ends") do
      reset()
      events: Channel[LogEvent] = Channel.new(8)
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
    end
  ])
end
