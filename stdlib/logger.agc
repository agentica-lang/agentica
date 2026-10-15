## An Elixir-style logger with four levels, one global level and named handlers.
##
## Import it with `import "std/logger" as Logger`. The levels are the builtin enum `LogLevel` (`Debug < Info < Warning < Error`) and a handler receives the builtin record `LogEvent`.
## The first call of any function here installs a handler named `console` (`stderr_text`, level `info`). Handlers run in order, synchronously, in the task that logs, so a line is written when the call returns.
## A handler error is the error of the task that logged. The registry lives in the VM and belongs to one run.

# The ranks are the order of LogLevel: debug 0, info 1, warning 2, error 3. LogRegistry stores ranks, not enums,
# so its rows need no enum type.

struct JsonLine
  time: String
  level: String
  msg: String
  fields: Map[String, String]
  task: Int
end

def rank_of(level: LogLevel) -> Int
  case level
    LogLevel.Debug -> return 0
    LogLevel.Info -> return 1
    LogLevel.Warning -> return 2
    LogLevel.Error -> return 3
  end
end

def level_of(rank: Int) -> LogLevel
  case rank
    0 -> return LogLevel.Debug
    1 -> return LogLevel.Info
    2 -> return LogLevel.Warning
    _ -> return LogLevel.Error
  end
end

def level_name(level: LogLevel) -> String
  case level
    LogLevel.Debug -> return "debug"
    LogLevel.Info -> return "info"
    LogLevel.Warning -> return "warning"
    LogLevel.Error -> return "error"
  end
end

# The install is one native call that checks for -1 itself, so two tasks that log for the first time together
# install the console handler once, and a later detach("console") stays in effect.
def ready() -> Int
  current = LogRegistry.level()
  if current < 0
    LogRegistry.install_default(&stderr_text)
    return LogRegistry.level()
  end
  return current
end

# The event takes its handlers here, so a handler that attaches or detaches another does not change this event.
# The event is made only when some handler accepts it.
def dispatch(level: LogLevel, rank: Int, message: String, fields: Map[String, String]) -> Void
  accepting = LogRegistry.handlers(rank)
  if accepting.size == 0
    return
  end
  event = LogEvent(level: level, message: message, fields: fields, time_ms: Time.now_ms(), task: LogRegistry.task_id())
  for handler in accepting
    handler.call(event)
  end
end

# A level function reads the level once and compares it once: -1 (the default not installed yet) is below every
# threshold, so it takes the slow path, and a disabled call costs one user call, one builtin call and one comparison.

## Logs a `debug` message.
export def debug(message: String) -> Void
  if LogRegistry.level() <= 0
    if ready() <= 0
      dispatch(LogLevel.Debug, 0, message, {})
    end
  end
end

## Logs a `debug` message with fields.
export def debug_meta(message: String, fields: Map[String, String]) -> Void
  if LogRegistry.level() <= 0
    if ready() <= 0
      dispatch(LogLevel.Debug, 0, message, fields)
    end
  end
end

## Logs an `info` message.
export def info(message: String) -> Void
  if LogRegistry.level() <= 1
    if ready() <= 1
      dispatch(LogLevel.Info, 1, message, {})
    end
  end
end

## Logs an `info` message with fields.
export def info_meta(message: String, fields: Map[String, String]) -> Void
  if LogRegistry.level() <= 1
    if ready() <= 1
      dispatch(LogLevel.Info, 1, message, fields)
    end
  end
end

## Logs a `warning` message.
export def warning(message: String) -> Void
  if LogRegistry.level() <= 2
    if ready() <= 2
      dispatch(LogLevel.Warning, 2, message, {})
    end
  end
end

## Logs a `warning` message with fields.
export def warning_meta(message: String, fields: Map[String, String]) -> Void
  if LogRegistry.level() <= 2
    if ready() <= 2
      dispatch(LogLevel.Warning, 2, message, fields)
    end
  end
end

## Logs an `error` message. The function is `err` because `error` is a reserved name; the output still says `error`.
export def err(message: String) -> Void
  if LogRegistry.level() <= 3
    if ready() <= 3
      dispatch(LogLevel.Error, 3, message, {})
    end
  end
end

## Logs an `error` message with fields.
export def err_meta(message: String, fields: Map[String, String]) -> Void
  if LogRegistry.level() <= 3
    if ready() <= 3
      dispatch(LogLevel.Error, 3, message, fields)
    end
  end
end

## Logs a message at a level given as a value.
export def log(level: LogLevel, message: String) -> Void
  return log_meta(level, message, {})
end

## Logs a message with fields at a level given as a value.
export def log_meta(level: LogLevel, message: String, fields: Map[String, String]) -> Void
  rank = rank_of(level)
  if rank >= ready()
    dispatch(level, rank, message, fields)
  end
end

## Returns true only when a call at `level` would reach a handler: the level is at or above the global level and at or above the lowest level of the attached handlers. Guard costly fields with it.
export def enabled?(level: LogLevel) -> Bool
  rank = rank_of(level)
  return rank >= ready() and rank >= LogRegistry.lowest()
end

## Returns the global level, `info` until `set_level` changes it.
export def level() -> LogLevel
  return level_of(ready())
end

## Sets the global level. A call below it makes no event at all.
export def set_level(level: LogLevel) -> Void
  _ = ready()
  LogRegistry.set_level(rank_of(level))
end

## Attaches a handler under a name, for events at `level` or above. The handler is a function (`&Logger.stderr_json`) or a block. A name already in use is an error result.
export def attach(name: String, level: LogLevel, handler: Fn[LogEvent, Void]) -> Result[Void]
  _ = ready()
  return LogRegistry.attach(name, rank_of(level), handler)
end

## Detaches the handler with that name. A name not in use is an error result.
export def detach(name: String) -> Result[Void]
  _ = ready()
  return LogRegistry.detach(name)
end

## Returns the names of the attached handlers, in attach order.
export def handlers() -> List[String]
  _ = ready()
  return LogRegistry.names()
end

## Writes `format_text(event)` to stderr as one line.
export def stderr_text(event: LogEvent) -> Void
  IO.warn(format_text(event))
end

## Writes `format_json(event)` to stderr as one line.
export def stderr_json(event: LogEvent) -> Void
  IO.warn(format_json(event))
end

# JSON.encode(s) is the quoted, escaped text, so it equals "\"" + s + "\"" exactly when s has no quote, backslash
# or control character (DEL included).
def plain?(text: String) -> Bool
  return text.length > 0 and !text.contains?("=") and JSON.encode(text) == "\"" + text + "\""
end

def message_token(message: String) -> String
  if plain?(message) and !message.starts_with?(" ") and !message.ends_with?(" ")
    return message
  end
  return JSON.encode(message)
end

def field_token(text: String) -> String
  if plain?(text) and !text.contains?(" ")
    return text
  end
  return JSON.encode(text)
end

## Returns the text line of an event: `TIME LEVEL MESSAGE key=value ...`, with the time in UTC.
## A message or field that is empty, has a space (for a field), `=`, a quote, a backslash or a control character is written as a JSON string, so a line is always one line.
export def format_text(event: LogEvent) -> String
  parts = [time_text(event.time_ms), level_name(event.level).upcase, message_token(event.message)]
  for key in event.fields.keys
    parts = parts.push(field_token(key) + "=" + field_token(event.fields.get(key, "")))
  end
  return parts.join(" ")
end

## Returns the JSON line of an event: the keys `time`, `level`, `msg`, `fields` and `task`. The fields are nested, so a field named `level` never clashes with a fixed key.
export def format_json(event: LogEvent) -> String
  return JSON.encode(JsonLine(time: time_text(event.time_ms), level: level_name(event.level), msg: event.message,
                              fields: event.fields, task: event.task))
end

def floor_div(a: Int, b: Int) -> Int
  q = a / b
  if q * b > a
    return q - 1
  end
  return q
end

def pad(n: Int, width: Int) -> String
  text = n.to_s
  while text.length < width
    text = "0" + text
  end
  return text
end

## Returns milliseconds since the Unix epoch as UTC text, such as `2026-10-12T10:15:02.345Z`.
## A year outside 0 to 9999 is written with its sign and at least four digits.
export def time_text(ms: Int) -> String
  days = floor_div(ms, 86400000)
  rest = ms - days * 86400000
  # Days to a calendar date by eras of 400 years, counted from 0000-03-01 so the leap day ends the year.
  z = days + 719468
  era = floor_div(z, 146097)
  doe = z - era * 146097
  yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  shifted = (5 * doy + 2) / 153
  day = doy - (153 * shifted + 2) / 5 + 1
  month = shifted + 3
  year = yoe + era * 400
  if shifted >= 10
    month = shifted - 9
    year += 1
  end
  sign = ""
  if year < 0
    sign = "-"
    year = 0 - year
  end
  hour = rest / 3600000
  minute = rest % 3600000 / 60000
  second = rest % 60000 / 1000
  milli = rest % 1000
  return "#{sign}#{pad(year, 4)}-#{pad(month, 2)}-#{pad(day, 2)}T#{pad(hour, 2)}:#{pad(minute, 2)}:#{pad(second, 2)}.#{pad(milli, 3)}Z"
end
