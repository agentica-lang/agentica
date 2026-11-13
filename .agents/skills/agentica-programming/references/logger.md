# Logging (`std/logger`)

```ruby
import Logger from "std/logger"
```

```text
Logger.debug(message: String, fields: Map[String, String] = {}) -> Void
Logger.info(message: String, fields: Map[String, String] = {}) -> Void
Logger.warning(message: String, fields: Map[String, String] = {}) -> Void
Logger.err(message: String, fields: Map[String, String] = {}) -> Void
Logger.log(level: Logger.Level, message: String, fields: Map[String, String] = {}) -> Void
Logger.enabled?(level: Logger.Level) -> Bool
Logger.level() -> Logger.Level
Logger.set_level(level: Logger.Level) -> Void
Logger.attach(name: String, level: Logger.Level, handler: Fn[Logger.Event, Void]) -> Result[Void]
Logger.detach(name: String) -> Result[Void]
Logger.handlers() -> List[String]
Logger.stderr_text(event: Logger.Event) -> Void
Logger.stderr_json(event: Logger.Event) -> Void
Logger.format_text(event: Logger.Event) -> String
Logger.format_json(event: Logger.Event) -> String
Logger.time_text(time_ms: Int) -> String
```

- `Logger.Level` is an enum, `Logger.Level.Debug < Info < Warning < Error`.
  `Logger.Event` is a record: `level: Logger.Level`, `message: String`,
  `fields: Map[String, String]`, `time_ms: Int`, `task: Int` (main is 1).
  `import {Event, Level} from "std/logger"` binds them by name. A printed value
  shows these names: `Logger.Level.Info`, `Logger.Event(...)`.
- The function for the last level is `err`: `Logger.error` is
  `CHECK-IMPORT-NAME` because `error` is reserved. `fields` is optional:
  `Logger.info("done", {"path": "/items"})`.
- No setup is needed. The first call of any `Logger` function attaches a handler
  named `console` (`stderr_text`, level `info`), so `Logger.info("started")`
  writes `2026-10-12T10:15:02.345Z INFO started` on stderr. Change the setup at
  the start of `main`: `Logger.set_level(Logger.Level.Debug)`, `_ =
  Logger.detach("console")`, `_ = Logger.attach("console", Logger.Level.Info,
  &Logger.stderr_json)`.
- Two levels apply. A call below the global level (`info` by default) makes no
  event. A handler gets an event only at or above its own level.
  `Logger.enabled?(level)` is true only when a call would reach a handler, so
  put a costly message inside `if Logger.enabled?(Logger.Level.Debug)`.
- A handler is `&Logger.stderr_json` or a block: `Logger.attach("audit",
  Logger.Level.Warning) do |event| IO.warn("audit: #{event.message}") end`. A
  name in use for `attach`, or not in use for `detach`, is an `error` result;
  inside a block discard it with `_ = Logger.detach("x")`.
- Handlers run in attach order, synchronously, in the task that logs, so a line
  is written when the call returns. A handler error is that task's error. A
  handler that logs recurses until `RUNTIME-STACK-OVERFLOW`.
- Text lines are `TIME LEVEL MESSAGE key=value ...`. JSON lines have the keys
  `time`, `level`, `msg`, `fields` (nested) and `task`.
- There is no file handler. Write one: `_ = File.append_text(path,
  Logger.format_json(event) + "\n", 1000)` in a block. For a slow handler, send
  each event into a `Channel[Logger.Event]` read by a writer task started with
  `Task.spawn_owning`; detach the handler, close the channel and await the
  writer before `main` returns.
- The handlers and the level belong to one run; a `Process.spawn` child has its
  own.
