---
title: Logger
weight: 6
description: Levels, named handlers and text or JSON lines on stderr with std/logger.
---

`std/logger` is an Elixir-style logger written in Agentica. Import it with `import Logger from "std/logger"`.

The first call of any `Logger` function attaches a handler named `console`. It writes text lines to stderr at level `info`. A program that only logs needs no setup.

## Levels

```text
Logger.debug(message: String, fields: Map[String, String] = {}) -> Void
Logger.info(message: String, fields: Map[String, String] = {}) -> Void
Logger.warning(message: String, fields: Map[String, String] = {}) -> Void
Logger.err(message: String, fields: Map[String, String] = {}) -> Void
Logger.log(level: LogLevel, message: String, fields: Map[String, String] = {}) -> Void
Logger.level() -> LogLevel
Logger.set_level(level: LogLevel) -> Void
Logger.enabled?(level: LogLevel) -> Bool
```

- The levels are the builtin enum `LogLevel`: `LogLevel.Debug < LogLevel.Info < LogLevel.Warning < LogLevel.Error`.
- The function for the last level is `err`, because `error` is reserved. The output still says `error`.
- `fields` is optional and defaults to `{}`. So `Logger.info("started")` and `Logger.info("request done", {"path": "/items"})` are both calls.
- The global level starts at `info`, and `set_level` changes it. Every call checks it first, and a call below it makes no event.
- Each handler has its own level, and gets only the events at or above it.
- `enabled?` is true only when the level is at or above the global level and some handler accepts it. Put a costly message inside an `if` on `enabled?`.

In the example, the console handler is at `info`. So `enabled?` is false for `debug` until a handler at `debug` is attached.

```agentica
import Logger from "std/logger"

def count_lines() -> Int
  return 3
end

def main() -> Void
  Logger.set_level(LogLevel.Debug)
  puts(Logger.enabled?(LogLevel.Debug))
  _ = Logger.attach("trace", LogLevel.Debug, &Logger.stderr_text)
  puts(Logger.enabled?(LogLevel.Debug))
  if Logger.enabled?(LogLevel.Debug)
    Logger.debug("lines", {"count": count_lines().to_s})
  end

  Logger.set_level(LogLevel.Info)
  puts(Logger.enabled?(LogLevel.Debug))
end
```

```output
false
true
false
```

## Handlers

```text
Logger.attach(name: String, level: LogLevel, handler: Fn[LogEvent, Void]) -> Result[Void]
Logger.detach(name: String) -> Result[Void]
Logger.handlers() -> List[String]
```

A handler is a function (such as `&Logger.stderr_json`) or a block. It takes a `LogEvent`, with these fields:

- `level: LogLevel`
- `message: String`
- `fields: Map[String, String]`
- `time_ms: Int`: when the event was made
- `task: Int`: the task that logged. `main` is 1

`attach` with a name in use, and `detach` with a name not in use, return an error.

- Handlers run in the order they were attached, synchronously, in the task that logs. So a line is written when the log call returns.
- An event keeps the handlers it started with. A handler that detaches another does not change the event in progress.
- A handler stays attached when the task that attached it ends.
- A handler error is the error of the task that logged.

```agentica
import Logger from "std/logger"

def main() -> Void
  _ = Logger.detach("console")
  _ = Logger.attach("audit", LogLevel.Warning) do |event|
    puts("audit: #{event.message}")
  end

  Logger.info("not for the audit handler")
  Logger.err("cannot open the cache")
  puts(Logger.attach("audit", LogLevel.Info, &Logger.stderr_text).message)
  puts(Logger.handlers())
end
```

```output
audit: cannot open the cache
a handler named "audit" is already attached
["audit"]
```

## Formats

```text
Logger.stderr_text(event: LogEvent) -> Void
Logger.stderr_json(event: LogEvent) -> Void
Logger.format_text(event: LogEvent) -> String
Logger.format_json(event: LogEvent) -> String
Logger.time_text(ms: Int) -> String
```

`stderr_text` and `stderr_json` are the built-in handlers. Each writes one line with one `IO.warn` call. `format_text` and `format_json` build the line without writing it, for your own handler.

- Text: `TIME LEVEL MESSAGE key=value ...`, with the time in UTC and the level in capitals.
- A message, key or value is written as a JSON string when it is empty, or has `=`, a quote, a backslash or a control character. A key or value with a space is also written as a JSON string. So a line is always one line, and a value never looks like a field.
- JSON: one object per line, with the keys `time`, `level` (`debug`, `info`, `warning` or `error`), `msg`, `fields` and `task`. The fields are nested, so a field named `level` never clashes with a fixed key.
- `time_text` turns milliseconds since the Unix epoch into text such as `2026-10-12T10:15:02.345Z`. A year outside 0 to 9999 is written with its sign and at least four digits.

```agentica
import Logger from "std/logger"

def main() -> Void
  event = LogEvent(level: LogLevel.Info, message: "request done", fields: {"path": "/items", "status": "200"}, time_ms: 1760523302345, task: 1)
  puts(Logger.format_text(event))
  puts(Logger.format_json(event))
  odd = LogEvent(level: LogLevel.Error, message: "a=b", fields: {"note": "two words"}, time_ms: 0, task: 2)
  puts(Logger.format_text(odd))
end
```

```output
2025-10-15T10:15:02.345Z INFO request done path=/items status=200
{"time":"2025-10-15T10:15:02.345Z","level":"info","msg":"request done","fields":{"path":"/items","status":"200"},"task":1}
1970-01-01T00:00:00.000Z ERROR "a=b" note="two words"
```

## File output and slow handlers

There is no built-in file handler. A block that appends one line per event does the job. The `_ =` drops a write error:

```agentica {mode="check"}
import Logger from "std/logger"

def main() -> Void
  _ = Logger.attach("file", LogLevel.Info) do |event|
    _ = File.append_text("app.log", Logger.format_json(event) + "\n", 1000)
  end

  Logger.info("server started")
end
```

A slow handler can hand each event to a task over a `Channel`. The writer is started with `Task.spawn_owning`, so it owns the channel. The run ends in this order: detach the handler, close the channel, await the writer. Without the await, returning from `main` ends the run and the queued lines are lost.

```agentica {mode="check"}
import Logger from "std/logger"

def write_events(events: Channel[LogEvent]) -> Result[Void]
  while true
    case events.recv(1000)
      ok(event) ->
        try File.append_text("app.log", Logger.format_json(event) + "\n", 1000)
      error(_) ->
        if events.closed? and events.empty?
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
  _ = Logger.detach("file")
  events.close
  done = Task.await(writer)
  if !done.ok?
    IO.warn(done.message)
  end
end
```

## Rules

- `LogEvent` and `LogLevel` are builtin types. Their names are reserved: a struct or enum with either name is `CHECK-REDEFINED-NAME`.
- Handlers and the global level live in the VM, and belong to one run. A child started with `Process.spawn` has its own. This registry is the language's only global state; `std/logger` reaches it through the internal module `LogRegistry`, which no other module can name (`CHECK-UNKNOWN-NAME`).
- Not planned for `std/logger`: log files and rotation, syslog, sampling, per-module levels, `Json` field values, configuration through environment variables, and lazy log arguments (a block given to `attach` is a handler, not a lazy message). Not planned for tracing: a language-level trace, trace lines on stdout, counters inside the tracer, a flag to turn stack traces off, and a stack of the parent task at spawn time; VM tracing is a developer tool of the VM, not a language feature.
- There are no flags and no per-task metadata. Pass `fields` on each call, as the optional second argument.
- Log calls are normal code, and count against `--max-steps`.
- A call below the global level, or one that no handler accepts, costs one function call, one builtin call and one comparison. A call without `fields` also passes an empty map.
