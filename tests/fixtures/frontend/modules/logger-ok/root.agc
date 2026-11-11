import Logger from "std/logger"
def main() -> Void
  Logger.err("x")
  level: Logger.Level = Logger.level()
  event = Logger.Event(level: level, message: "m", fields: {}, time_ms: 0, task: 1)
  Logger.stderr_text(event)
end

