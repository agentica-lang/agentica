# Logging (`std/logger`)

```ruby
import Logger from "std/logger"
```

```text
Logger.debug(message: String, fields: Map[String, String] = {}) -> Void
Logger.info(message: String, fields: Map[String, String] = {}) -> Void
Logger.warning(message: String, fields: Map[String, String] = {}) -> Void
Logger.err(message: String, fields: Map[String, String] = {}) -> Void
Logger.log(level: LogLevel, message: String, fields: Map[String, String] = {}) -> Void
Logger.enabled?(level: LogLevel) -> Bool
Logger.level() -> LogLevel
Logger.set_level(level: LogLevel) -> Void
Logger.attach(name: String, level: LogLevel, handler: Fn[LogEvent, Void]) -> Result[Void]
Logger.detach(name: String) -> Result[Void]
Logger.handlers() -> List[String]
Logger.stderr_text(event: LogEvent) -> Void
Logger.stderr_json(event: LogEvent) -> Void
Logger.format_text(event: LogEvent) -> String
Logger.format_json(event: LogEvent) -> String
Logger.time_text(ms: Int) -> String
```

- `LogLevel` is a builtin enum, `LogLevel.Debug < Info < Warning < Error`.
  `LogEvent` is a builtin record: `level: LogLevel`, `message: String`, `fields:
  Map[String, String]`, `time_ms: Int`, `task: Int` (main is 1). Both names are
  reserved (`CHECK-REDEFINED-NAME`) and neither is JSON-decodable.
- The function for the last level is `err`: `Logger.error` is
  `CHECK-IMPORT-NAME` because `error` is reserved. Each level has one function
  and `fields` is optional: `Logger.info("started")`, `Logger.info("done",
  {"path": "/items"})`.
- No setup is needed. The first call of any `Logger` function attaches a handler
  named `console` (`stderr_text`, level `info`), so `Logger.info("started")`
  writes `2026-10-12T10:15:02.345Z INFO started` on stderr. Change the setup at
  the start of `main`: `Logger.set_level(LogLevel.Debug)`, `_ =
  Logger.detach("console")`, `_ = Logger.attach("console", LogLevel.Info,
  &Logger.stderr_json)`.
- Two levels apply. A call below the global level (`info` by default) makes no
  event. A handler gets an event only at or above its own level.
  `Logger.enabled?(level)` is true only when a call would reach a handler, so
  put a costly message inside `if Logger.enabled?(LogLevel.Debug)`.
- A handler is `&Logger.stderr_json` or a block: `Logger.attach("audit",
  LogLevel.Warning) do |event| IO.warn("audit: #{event.message}") end`. A name
  in use for `attach`, or not in use for `detach`, is an `error` result; inside
  a block discard it with `_ = Logger.detach("x")`.
- Handlers run in attach order, synchronously, in the task that logs, so a line
  is written when the call returns. A handler error is that task's error. A
  handler that logs recurses until `RUNTIME-STACK-OVERFLOW`.
- Text lines are `TIME LEVEL MESSAGE key=value ...`; a message, key or value is
  written as a JSON string when it is empty, has `=`, a quote, a backslash or a
  control character, or (key or value) a space. JSON lines have the keys `time`,
  `level`, `msg`, `fields` (nested) and `task`.
- There is no file handler. Write one: `_ = File.append_text(path,
  Logger.format_json(event) + "\n", 1000)` in a block. For a slow handler, send
  each event into a `Channel[LogEvent]` read by a writer task started with
  `Task.spawn_owning`; detach the handler, close the channel and await the
  writer before `main` returns.
- The handlers and the level belong to one run (the registry is the language's
  one global state); a `Process.spawn` child has its own. Log calls count
  against `--max-steps`.
