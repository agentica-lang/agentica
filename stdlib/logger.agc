## An Elixir-style logger with four levels, one global level and named handlers.
##
## Import it with `import Logger from "std/logger"`. The levels are the enum `Logger.Level`
## (`Debug < Info < Warning < Error`) and a handler receives the record `Logger.Event`. The first call of any
## function here installs a handler named `console` (`stderr_text`, level `info`). Handlers run in order,
## synchronously, in the task that logs, so a line is written when the call returns. A handler error is the error of
## the task that logged. The registry lives in the VM and belongs to one run.
##
## `Logger.Level` and `Logger.Event` are the builtin types `LogRegistry.Level` and `LogRegistry.Event`. The signatures
## below, a diagnostic, `help` and any printed value show `Logger.Level` and `Logger.Event`, as written.

import UTC from "std/utc"

export LogRegistry.Level
export LogRegistry.Event

struct JsonLine
  time: String
  level: String
  msg: String
  fields: Map[String, String]
  task: Int
end

# A level function reads the floor once and compares it once. The floor is the higher of the global level and the
# lowest handler level, so a call that no handler would accept is as cheap as a disabled one: one user call (the
# empty `fields` default is a constant the call site builds), one builtin call and one comparison. -1 (the default not
# installed yet) is below every threshold, so it takes the slow path, where ready() installs the default and the real
# global level is checked.

## Logs a `debug` message, with optional fields.
export def debug(message: String, fields: Map[String, String] = {}) -> Void
  if LogRegistry.floor() <= 0
    if ready() <= 0
      dispatch(LogRegistry.Level.Debug, 0, message, fields)
    end
  end
end

## Logs an `info` message, with optional fields.
export def info(message: String, fields: Map[String, String] = {}) -> Void
  if LogRegistry.floor() <= 1
    if ready() <= 1
      dispatch(LogRegistry.Level.Info, 1, message, fields)
    end
  end
end

## Logs a `warning` message, with optional fields.
export def warning(message: String, fields: Map[String, String] = {}) -> Void
  if LogRegistry.floor() <= 2
    if ready() <= 2
      dispatch(LogRegistry.Level.Warning, 2, message, fields)
    end
  end
end

## Logs an `error` message, with optional fields. The function is `err` because `error` is a reserved name; the output
## still says `error`.
export def err(message: String, fields: Map[String, String] = {}) -> Void
  if LogRegistry.floor() <= 3
    if ready() <= 3
      dispatch(LogRegistry.Level.Error, 3, message, fields)
    end
  end
end

## Logs a message, with optional fields, at a level given as a value.
export def log(level: LogRegistry.Level, message: String, fields: Map[String, String] = {}) -> Void
  rank = rank_of(level)
  if rank >= ready()
    dispatch(level, rank, message, fields)
  end
end

## Returns true only when a call at `level` would reach a handler: the level is at or above the global level and at or
## above the lowest level of the attached handlers. Guard costly fields with it.
export def enabled?(level: LogRegistry.Level) -> Bool
  rank = rank_of(level)
  rank >= ready() and rank >= LogRegistry.lowest()
end

## Returns the global level, `info` until `set_level` changes it.
export def level() -> LogRegistry.Level = level_of(ready())

## Sets the global level. A call below it makes no event at all.
export def set_level(level: LogRegistry.Level) -> Void
  _ = ready()
  LogRegistry.set_level(rank_of(level))
end

## Attaches a handler under a name, for events at `level` or above. The handler is a function (`&Logger.stderr_json`)
## or a block. A name already in use is an error result.
export def attach(name: String, level: LogRegistry.Level, handler: Fn[LogRegistry.Event, Void]) -> Result[Void]
  _ = ready()
  LogRegistry.attach(name, rank_of(level), handler)
end

## Detaches the handler with that name. A name not in use is an error result.
export def detach(name: String) -> Result[Void]
  _ = ready()
  LogRegistry.detach(name)
end

## Returns the names of the attached handlers, in attach order.
export def handlers() -> List[String]
  _ = ready()
  LogRegistry.names()
end

## Writes `format_text(event)` to stderr as one line.
export def stderr_text(event: LogRegistry.Event) -> Void
  IO.warn(format_text(event))
end

## Writes `format_json(event)` to stderr as one line.
export def stderr_json(event: LogRegistry.Event) -> Void
  IO.warn(format_json(event))
end

## Returns the text line of an event: `TIME LEVEL MESSAGE key=value ...`, with the time in UTC.
## A message or field that is empty, has a space (for a field), `=`, a quote, a backslash or a control character is
## written as a JSON string, so a line is always one line.
export def format_text(event: LogRegistry.Event) -> String
  parts = [time_text(event.time_ms), level_name(event.level).upcase, message_token(event.message)]
  for key in event.fields.keys
    parts = parts.push("#{field_token(key)}=#{field_token(event.fields.get(key, ""))}")
  end
  parts.join(" ")
end

## Returns the JSON line of an event: the keys `time`, `level`, `msg`, `fields` and `task`. The fields are nested, so a
## field named `level` never clashes with a fixed key.
export def format_json(event: LogRegistry.Event) -> String
  one_line(
    JSON.encode(
      JsonLine(
        time: time_text(event.time_ms),
        level: level_name(event.level),
        msg: event.message,
        fields: event.fields,
        task: event.task,
      ),
    ),
  )
end

## Returns milliseconds since the Unix epoch as UTC text, such as `2026-10-12T10:15:02.345Z`.
## A year outside 0 to 9999 is written with its sign and at least four digits.
export def time_text(ms: Int) -> String = UTC.iso8601(ms, 3)

# The ranks are the order of Level: debug 0, info 1, warning 2, error 3. LogRegistry stores ranks, not enums,
# so its rows need no enum type.
def rank_of(level: LogRegistry.Level) -> Int
  case level
    LogRegistry.Level.Debug -> 0
    LogRegistry.Level.Info -> 1
    LogRegistry.Level.Warning -> 2
    LogRegistry.Level.Error -> 3
  end
end

def level_of(rank: Int) -> LogRegistry.Level
  case rank
    0 -> LogRegistry.Level.Debug
    1 -> LogRegistry.Level.Info
    2 -> LogRegistry.Level.Warning
    _ -> LogRegistry.Level.Error
  end
end

def level_name(level: LogRegistry.Level) -> String
  case level
    LogRegistry.Level.Debug -> "debug"
    LogRegistry.Level.Info -> "info"
    LogRegistry.Level.Warning -> "warning"
    LogRegistry.Level.Error -> "error"
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
  current
end

# The event takes its handlers here, so a handler that attaches or detaches another does not change this event.
# The event is made only when some handler accepts it.
def dispatch(level: LogRegistry.Level, rank: Int, message: String, fields: Map[String, String]) -> Void
  accepting = LogRegistry.handlers(rank)
  return if accepting.size == 0
  event = LogRegistry.Event(
    level: level,
    message: message,
    fields: fields,
    time_ms: Time.now_ms(),
    task: LogRegistry.task_id(),
  )

  for handler in accepting
    handler.call(event)
  end
end

# JSON.encode(s) is the quoted, escaped text, so it equals "\"" + s + "\"" exactly when s has no quote, backslash
# or control character (DEL included). The three line breaks above are not escaped by it, so they are checked apart.
def plain?(text: String) -> Bool
  text.length > 0 and !text.include?("=") and !line_break?(text) and JSON.encode(text) == "\"#{text}\""
end

# JSON.encode leaves U+0085, U+2028 and U+2029 as they are, but splitlines() and some viewers break lines there.
# Escaping them keeps one event on one line.
def one_line(text: String) -> String
  (
    text.replace(String.from_code(133), "\\u0085")
      .replace(String.from_code(8232), "\\u2028")
      .replace(String.from_code(8233), "\\u2029")
  )
end

def line_break?(text: String) -> Bool
  (
    text.include?(String.from_code(133)) or
    text.include?(String.from_code(8232)) or
    text.include?(String.from_code(8233))
  )
end

def message_token(message: String) -> String
  return message if plain?(message) and !message.start_with?(" ") and !message.end_with?(" ")
  one_line(JSON.encode(message))
end

def field_token(text: String) -> String
  return text if plain?(text) and !text.include?(" ")
  one_line(JSON.encode(text))
end
