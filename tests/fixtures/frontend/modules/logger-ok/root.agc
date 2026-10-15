import "std/logger" as Logger
def main() -> Void
  Logger.err("x")
  level: LogLevel = Logger.level()
  event = LogEvent(level: level, message: "m", fields: {}, time_ms: 0, task: 1)
  Logger.stderr_text(event)
end

