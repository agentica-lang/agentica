import Logger from "std/logger"

def event(level: Logger.Level, message: String, fields: Map[String, String]) -> Logger.Event
  return Logger.Event(level: level, message: message, fields: fields, time_ms: 1760523302345, task: 7)
end

def show(e: Logger.Event) -> Void
  Logger.stderr_text(e)
  Logger.stderr_json(e)
end

def main() -> Void
  no_items: Map[String, String] = {}
  show(event(Logger.Level.Debug, "plain message", no_items))
  show(event(Logger.Level.Info, "request done", {"path": "/items", "status": "200"}))
  show(event(Logger.Level.Warning, "disk almost full", {"free": "3 GB", "mount": "/"}))
  show(event(Logger.Level.Error, "cannot open the cache", no_items))
  show(event(Logger.Level.Info, "", no_items))
  show(event(Logger.Level.Info, " leading space", no_items))
  show(event(Logger.Level.Info, "trailing space ", no_items))
  show(event(Logger.Level.Info, "a=b", no_items))
  show(event(Logger.Level.Info, "say \"hi\"", no_items))
  show(event(Logger.Level.Info, "back\\slash", no_items))
  show(event(Logger.Level.Info, "two\nlines", no_items))
  show(event(Logger.Level.Info, "tab\there", no_items))
  show(event(Logger.Level.Info, "del" + String.from_code(127) + "char", no_items))
  show(event(Logger.Level.Info, "next" + String.from_code(133) + "line" + String.from_code(8232) + "and" + String.from_code(8233) + "more", {"k" + String.from_code(8232): "v" + String.from_code(133)}))
  show(event(Logger.Level.Info, "café 世界", no_items))
  show(event(Logger.Level.Info, "fields in map order", {"z": "1", "a": "2", "m": "3"}))
  show(event(Logger.Level.Info, "keys that look like fixed keys", {"level": "x", "msg": "y", "time": "z", "task": "9"}))
  show(event(Logger.Level.Info, "values that need quotes", {"empty": "", "space": "a b", "eq": "a=b", "quote": "\"q\"", "newline": "a\nb", "slash": "a\\b"}))
  show(event(Logger.Level.Info, "keys that need quotes", {"": "empty", "a b": "space", "a=b": "eq", "a\"b": "quote"}))
  show(event(Logger.Level.Info, "non-ascii", {"name": "niño", "city": "东京"}))
  puts(Logger.format_text(event(Logger.Level.Error, "to stdout", {"k": "v"})))
  puts(Logger.format_json(event(Logger.Level.Error, "to stdout", {"k": "v"})))
  puts(Logger.time_text(0))
  puts(Logger.time_text(1760523302345))
end
