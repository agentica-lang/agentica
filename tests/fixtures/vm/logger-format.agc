import "std/logger" as Logger

def event(level: LogLevel, message: String, fields: Map[String, String]) -> LogEvent
  return LogEvent(level: level, message: message, fields: fields, time_ms: 1760523302345, task: 7)
end

def show(e: LogEvent) -> Void
  Logger.stderr_text(e)
  Logger.stderr_json(e)
end

def main() -> Void
  none: Map[String, String] = {}
  show(event(LogLevel.Debug, "plain message", none))
  show(event(LogLevel.Info, "request done", {"path": "/items", "status": "200"}))
  show(event(LogLevel.Warning, "disk almost full", {"free": "3 GB", "mount": "/"}))
  show(event(LogLevel.Error, "cannot open the cache", none))
  show(event(LogLevel.Info, "", none))
  show(event(LogLevel.Info, " leading space", none))
  show(event(LogLevel.Info, "trailing space ", none))
  show(event(LogLevel.Info, "a=b", none))
  show(event(LogLevel.Info, "say \"hi\"", none))
  show(event(LogLevel.Info, "back\\slash", none))
  show(event(LogLevel.Info, "two\nlines", none))
  show(event(LogLevel.Info, "tab\there", none))
  show(event(LogLevel.Info, "del" + String.from_code(127) + "char", none))
  show(event(LogLevel.Info, "café 世界", none))
  show(event(LogLevel.Info, "fields in map order", {"z": "1", "a": "2", "m": "3"}))
  show(event(LogLevel.Info, "keys that look like fixed keys", {"level": "x", "msg": "y", "time": "z", "task": "9"}))
  show(event(LogLevel.Info, "values that need quotes", {"empty": "", "space": "a b", "eq": "a=b", "quote": "\"q\"", "newline": "a\nb", "slash": "a\\b"}))
  show(event(LogLevel.Info, "keys that need quotes", {"": "empty", "a b": "space", "a=b": "eq", "a\"b": "quote"}))
  show(event(LogLevel.Info, "non-ascii", {"name": "niño", "city": "东京"}))
  puts(Logger.format_text(event(LogLevel.Error, "to stdout", {"k": "v"})))
  puts(Logger.format_json(event(LogLevel.Error, "to stdout", {"k": "v"})))
  puts(Logger.time_text(0))
  puts(Logger.time_text(1760523302345))
end
