## 24. Logging and debugging

**Status:** partly built (14a, 14b); 14c planned (roadmap phase 14). Three
parts, each its own small PR, all on the VM only (the evaluator is gone by then,
or the part changes only VM code):

- 14a, **VM tracing** (24.4): a developer tool inside `agentica-vm`, not a
  language feature. It comes right after 7h processes and before TCP and TLS, to
  make the rest of 7h faster to debug.
- 14b, **stack traces on runtime errors** (24.3): after 7i, as roadmap row
  7.2.5, before the freeze of the Racket front end (row 7.2.7).
- 14c, **`std/logger`** (24.2): an Elixir-style logger in Agentica, after 7i.
  It needs no default parameter values (row 7.5a, which stays after the
  bootstrap) and no command-line flags. Its handler table is the first global
  state of the language, held by the VM runtime and limited to that registry
  (24.2). Its registration, its builtin rows and its two builtin types are data
  under the freeze (row 7.2.7).

No grammar change. 14c adds a `std/` module, the builtin record `LogEvent` and
the builtin enum `LogLevel`, and a std-only builtin module of nine functions
(`LogRegistry`); 14b changes only what the VM prints for a runtime diagnostic.

### 24.1 Today

Checked on the VM (`racket src/main.rkt --vm`, at `2e6da77`):

- Programs have no logging. `IO.warn(x)` writes `x.to_s` and a newline to
  stderr: no level, no time, no fields, and no way to turn debug lines off.
  `IO.inspect` writes to stdout, not stderr. `IO.warn("a\nb")` writes two lines,
  so one message can break into several lines.
- `IO.warn` on the VM makes one copy of the text and the newline into the stderr
  buffer (`put` in `vm/output.c`, row 7.2.1f), and the loop writes the buffer in
  order with `write(2)` calls, as the pipe takes it. Text and newline are next
  to each other in the buffer, and lines from different tasks never mix inside a
  line; a `write(2)` of the loop can still be cut short by a full pipe, so
  another process that shares the VM's stderr can write between the parts (not a
  `Process.spawn` child, whose stderr the VM forwards through a pipe,
  `docs/vm/10-io-processes.md` §10.4).
- `System.env(name)` reads one environment variable and gives a `Result` (row
  7.2.6). There is no call that lists all of them.
- At 2e6da77 a runtime diagnostic had one span and no call stack, in all three
  formats: a failure inside `pick`, called from `load`, called from `main`,
  showed only the line in `pick`. Section 24.3 (14b) adds the call stack.
- A tail call (`return f(...)`) replaces the caller's frame
  (`docs/vm/05-values-execution-builtins.md` §6.1), so 20,000 nested tail calls
  run and fail later with the frame of the last call only.
- What a stack trace needs is already there: each frame has its function index
  and saved `pc` (the next instruction, so the call is at `pc - 1`), each
  function has its name and one span index per instruction, and the spans table
  has file, line and column. Linked names look like `@2::push` for a function
  from an imported file, and blocks are named `block@file.agc:10:15`.
- `error` is a reserved name: a module cannot declare `def error`
  (`CHECK-REDEFINED-NAME`), so a log module cannot have `Logger.error`. A wrong
  imported name (`Logger.error` when the module has no `error`) is
  `CHECK-IMPORT-NAME` with no "did you mean" help.
- `JSON.encode` of a `Map[String, String]` keeps the map's order and escapes
  `"`, `\` and control characters; non-ASCII text stays as it is. `JSON.encode`
  of a `String` gives the quoted, escaped text.
- The VM reads two test-only environment variables at start-up into its runtime
  config (`AGENTICA_VM_TEST_NO_TURN_COST` and
  `AGENTICA_VM_TEST_BLOCKING_OUTPUT`), and `vm/` has no mutable global state
  (`docs/vm/10-io-multicore.md` §10.2.3). Debugging the scheduler, I/O jobs, the
  GC, processes or the loader means adding `fprintf` by hand.

### 24.2 `std/logger`

An Elixir-style logger, written in Agentica as `stdlib/logger.agc`. It has a
fixed set of levels, one global level, handlers that are attached and detached
while the program runs (each with its own level), a formatter for each output
form, and fields on each call. Nothing here is built yet: the examples are
planned syntax. They are checked against a stand-in module that has the same
signatures, and they run on the VM once `std/logger` lands.

```agentica
import "std/logger" as Logger

def expensive_dump() -> String
  return "..."
end

def main() -> Void
  Logger.set_level(LogLevel.Debug)
  _ = Logger.detach("console")
  _ = Logger.attach("console", LogLevel.Info, &Logger.stderr_json)
  _ = Logger.attach("audit", LogLevel.Warning) do |event|
    IO.warn("audit: #{event.message}")
  end

  Logger.info_meta("request done", {"path": "/items", "status": "200"})
  Logger.debug("not shown at the console level")
  if Logger.enabled?(LogLevel.Debug)
    Logger.debug_meta("state", {"dump": expensive_dump()})
  end
  Logger.err("cannot open the cache")
end
```

Its stderr, with the time values shown as examples:

```text
{"time":"2026-10-12T10:15:02.345Z","level":"info","msg":"request done","fields":{"path":"/items","status":"200"},"task":1}
{"time":"2026-10-12T10:15:02.346Z","level":"error","msg":"cannot open the cache","fields":{},"task":1}
audit: cannot open the cache
```

**API (planned):**

```text
Logger.debug(message: String) -> Void
Logger.debug_meta(message: String, fields: Map[String, String]) -> Void
Logger.info(message: String) -> Void
Logger.info_meta(message: String, fields: Map[String, String]) -> Void
Logger.warning(message: String) -> Void
Logger.warning_meta(message: String, fields: Map[String, String]) -> Void
Logger.err(message: String) -> Void
Logger.err_meta(message: String, fields: Map[String, String]) -> Void
Logger.log(level: LogLevel, message: String) -> Void
Logger.log_meta(level: LogLevel, message: String, fields: Map[String, String]) -> Void
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

LogLevel                              # builtin enum: Debug < Info < Warning < Error
LogEvent                              # builtin record: what a handler receives
  level: LogLevel
  message: String
  fields: Map[String, String]
  time_ms: Int                        # Time.now_ms() when the event is made
  task: Int                           # the VM task number (main is 1)
```

**Levels.** There are four, in this order: `debug`, `info`, `warning` and
`error`, the variants `LogLevel.Debug`, `LogLevel.Info`, `LogLevel.Warning` and
`LogLevel.Error`. Elixir has eight. The other four (notice, critical, alert,
emergency) only add names, and every variant is a `case` arm that user code must
list or cover with `_`, so a level added later would break matches. The function
for the last level is `err`, because `error` is a reserved name: a module that
declares `def error` is `CHECK-REDEFINED-NAME` (24.1). The output still says
`error`. `warning` is Elixir's name. `IO.warn` keeps its own name.

**Two thresholds.** The global level (`set_level`, `info` by default) is checked
first, by every call. Each handler has its own level and gets an event only when
the event is at or above it. With the global level at `debug` and a console
handler at `info`, a `debug` call writes nothing to the console.

`enabled?(level)` is true only if some attached handler would accept that level:
the level is at or above the global level, and at or above the lowest level of
the attached handlers. The registry keeps that lowest level
(`LogRegistry.lowest` in the table below; a level above `error` when no handler
is attached). With the global level at `debug` and handlers at `info` and
`warning`, `enabled?(LogLevel.Debug)` is false, so the guard in the example
skips the dump. The global level alone does not decide it.

**Types.** `LogEvent` and `LogLevel` are builtins, not declared in `std/logger`
(decided on 2026-10-15). `LogEvent` is a builtin record, an entry in
`builtin-records` in `src/builtin-types.rkt`, like `HttpRequest`. `LogLevel` is
a builtin enum, an entry in `builtin-enum-declarations`, like `Await`. Handlers
have type `Fn[LogEvent, Void]`, and the `LogRegistry` rows use the same concrete
types, so no type variable is needed. Both names are reserved in every program:
a program that declares a struct or an enum with either name gets
`CHECK-REDEFINED-NAME`. This is a small breaking change for a program that
already uses either name. Once the checker is in Agentica (§35), the two could
move into `std/logger`; that would rename them for callers.

**Rejected options for the handler types.**

- B: a registry typed `Fn[Map[String, String], Void]` or `Fn[Json, Void]`, with
  a conversion in `logger.agc`. Rejected: every event is converted on the hot
  path, and the types are weaker.
- C: a new generic checker rule for the registry. Rejected: the freeze (row
  7.2.7) forbids new checker rules, so it would wait for the Agentica checker
  (§35, step 4).
- A `String` level (the level's name). Rejected: a misspelled level name
  compiles silently.
- An `Int` level (the rank). Rejected: the numbers read badly in a handler.

**Handlers.** A handler is a named function (`&Logger.stderr_json`) or a block
given to `attach`, which follows the call as the block rule requires. Handlers
run in attach order, synchronously, in the task that makes the event. A line is
written by the time its log call returns, so nothing waits in a queue and
nothing is lost when a task crashes or `main` returns. Attach and detach take
effect for the next event. An event takes its list of handlers when it is made,
so a handler that detaches another does not change the list of the event in
progress. `attach` with a name in use, and `detach` with a name not in use,
return `error(...)`; they do not halt. A handler stays attached after the task
that attached it ends. A handler that captures a handle (a file, a socket) finds
it closed when the task that opened the handle ends
(`docs/grammar/06c-tasks-and-tests.md`).

**Failures.** A handler's runtime error is the error of the task that made the
event: that task crashes, or the run ends when the task is `main`, as for any
runtime error. The registry does not catch it (D4). A handler that logs calls
itself, and recurses until `RUNTIME-STACK-OVERFLOW`; v1 has no guard against it
(D5).

**Decided: the handler table is the first global state of the language.** Values
never change, and the language has no module state or global variables
(`references/modules.md` of the programming skill), so the handler table and the
global level are kept by the VM runtime, next to the task counter (`vm->rt`),
not by any Agentica value. This is the first global mutable state in the
language, and it is limited to this registry. No other module, value or builtin
gets it. It differs from the `Agent` rejected in §27: a program never holds a
reference to the registry, and only the Logger functions read or change it.
`vm/` keeps its own rule that no `static` or global variable lives there, so the
table is a field of the runtime (`docs/vm/10-io-multicore.md`). Its rules:

- Nine native builtins in a std-only module, `LogRegistry`, read and write the
  table (below). None of them calls a handler. `Logger.log_meta` reads the
  handler list and calls each handler itself, in the logging task.
- One scheduler runs today, so a table call does not interleave with another.
  When multicore lands (row 11, gated), the table needs a lock, the same lock as
  the stderr buffer. That PR owns the change.
- The table holds function values, so the GC must keep them alive. The runtime
  reaches them the way it reaches the other values it keeps.
- The table belongs to one run. A child from `Process.spawn` is a separate VM
  with its own table.

**Alternatives for the global state.**

- A logger built only from a task and a `Channel`, which every caller reaches.
  **Rejected.** Every task would need the channel as an argument, or the channel
  would need a global name, which is the state this design adds anyway. Lines
  still in the channel are lost when the logger task crashes and when `main`
  returns without awaiting it (checked on the VM for this section). Each call
  costs a channel send and a task switch, and a full channel holds every
  producer behind a slow handler. Attach and detach would become request
  messages with replies.
- A logger value passed to every function that logs. **Rejected.** Each function
  and each task argument gets a parameter, agents forget to pass it, and two
  loggers in one run can disagree about the level.
- Configuration at start-up only, from `--log-*` flags (the earlier draft of
  this section). **Rejected for v1.** It needs no state, but a program cannot
  add a handler function, and the flags need a change to `src/main.rkt` under
  the freeze.

**Async handlers (planned, never the default).** A handler that is slow, such as
one that writes a file or calls the network, can hand each event to a task that
owns that work. The handler is a block that sends into a `Channel`. `main`
starts the writer with `Task.spawn_owning`, so the writer owns the channel and
closes it when it ends. Any task that holds the channel can still send to it
until the owner closes it, so the handler may run in any task. The run ends in
this order: detach the handler, close the channel, await the writer. Returning
from `main` ends the run, and pending tasks never run again
(`docs/grammar/06c-tasks-and-tests.md`), so without the await the queued lines
are lost. A full channel makes the send wait up to its timeout, and then the
send returns an error that the handler decides about. The example drops the
event. If the writer crashes first, its owned channel closes by itself, later
sends return an error at once, and `Task.await(writer)` returns that error for a
`Result` task. An event that another task made before the detach can reach the
channel after `close`; its `send` then returns an error, which the example
drops. A program that must keep those events waits for those tasks before it
closes the channel.

```agentica
import "std/logger" as Logger

def write_events(events: Channel[LogEvent]) -> Result[Void]
  while true
    case events.recv(1000)
      ok(event) ->
        try File.append_text("app.log", Logger.format_json(event) + "\n", 1000)
      error(_) ->
        if events.closed?
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

A channel adds one send and one task switch to every event, so a handler takes
this path only when its work is slow.

**Calls and names.** Default parameter values stay after the bootstrap (row
7.5a), and there is no overloading. A second `def info` is
`CHECK-REDEFINED-NAME`, and an overload would complicate checking and the
messages of errors. Agentica follows Ruby, which has defaults and not
overloading. So v1 has two functions per level: `info(msg)` and `info_meta(msg,
fields)`, and the same pair for `debug`, `warning` and `err`. When row 7.5a
lands, the API becomes `info(msg, fields = {})`. That is a breaking change,
which the owner accepts, because the language has no outside users. The `_meta`
functions then go away.

**Metadata.** Left out of v1 (D1 below). Elixir's
`Logger.metadata/1` is per process: the context that every later call of the
process carries. Agentica has no task-local storage, so v1 passes `fields` on
each call. A later minimal form would be one `Map[String, String]` slot in each
task (`agc_task`), set by a builtin, read when an event is made, and merged in
front of the call's fields. A spawned task would start empty, as Elixir metadata
is not inherited. The VM would need that slot, which the GC traces with the
task.

**Configuration.** Handlers and levels are set from code, at the start of
`main`, as in the example. The run's command line does not change, so there are
no `--log-*` flags. A later optional `--log-level` flag would be a `System`
builtin that sets the global level at start-up. It is future work and not in v1
(D7).

**Default console handler.** The first call of any `Logger` function installs
`console`: `stderr_text` at level `info`, as if the program had attached it. It
is an ordinary handler, so `detach("console")` removes it. Until that install,
`LogRegistry.level()` returns `-1`. Each entry point reads the level first; on
`-1` it calls `LogRegistry.install_default(&Logger.stderr_text)` and reads the
level again (D3). That native call checks for `-1` and only then attaches the
entry and sets the level to `info`, in one step with no yield. So two tasks that
make their first calls together install it once, and a later `detach("console")`
stays in effect, because the level is no longer `-1`.

**Built-in handlers and formatters.**

- `stderr_text(event)` writes `format_text(event)`, and `stderr_json(event)`
  writes `format_json(event)`. Each makes one `IO.warn` call, so each line is
  one write (24.1: `IO.warn` copies the text and the newline together).
- `format_text` and `format_json` are pure functions from `LogEvent` to
  `String`. A custom formatter has that shape, and a custom handler calls it.
  There is no formatter registry: a handler is the formatter and the sink
  together.
- No built-in file handler (D6). A block that appends one line per event does
  the job: `_ = File.append_text(path, Logger.format_json(event) + "\n", 1000)`.
  It opens and closes the file for every line, and the `_ =` drops a write
  error; a program that must stop on one writes its own handler. A built-in file
  handler would keep a `FileHandle` in the table, and a handle belongs to the
  task that opened it and is closed when that task ends
  (`docs/grammar/06c-tasks-and-tests.md`). Rotation is not planned (24.5).

**Formats.** Both write one line per event.

- **Text:** `TIME LEVEL MESSAGE key=value ...`, for example
  `2026-10-12T10:15:02.345Z INFO request done path=/items status=200`. The time
  is UTC in ISO 8601 with milliseconds. The level is in capitals: `DEBUG`,
  `INFO`, `WARNING` or `ERROR`. The task is not shown in text, since a flat
  `task=` would clash with a user field of that name. The message is written as
  it is, unless it is empty, starts or ends with a space, or contains `=`, `"`,
  `\` or a control character (DEL included). Then it is written in its JSON
  form, quoted and escaped. So a message with a newline still takes one line,
  and a message never looks like a field. A key or value is quoted the same way
  when it is empty or contains a space, `=`, `"`, `\` or a control character.
  The test "as it is" is `JSON.encode(s) == "\"#{s}\""`, plus checks for empty
  text, spaces and `=`. Fields come in map order. Every text line can be read
  back: the message is a JSON string or ends before the first ` key=`.
- **JSON lines:** one object per line, with `time` (the same text), `level`
  (`debug`, `info`, `warning` or `error`), `msg`, `fields` (always present, `{}`
  when there are none; the earlier draft left it out), and `task` (a number).
  The fields are nested, so a field named `level`, `msg`, `time` or `task` never
  clashes with a fixed key. The line is built with `JSON.object` and
  `JSON.from`, and written with `JSON.encode`, so all escaping belongs to the
  JSON encoder.

**Time text.** `Logger.time_text(ms)` turns milliseconds since the Unix epoch
into the text above (`2026-10-12T10:15:02.345Z`). It is exported so that
programs and tests can use it. Until §41 lands it is integer arithmetic on the
calendar, written in Agentica. With §41 it is
`Time.format(Time.from_unix_ms(ms).unwrap!)`, one native call, and the log and
the `Time` functions share one formatter.

**Cost of a disabled call.** Each level function reads the level once and
compares the threshold before it calls the shared code. A disabled `debug` call
is then one user call, one builtin read (`LogRegistry.level()`), and two Int
comparisons: the check for `-1` (the default not yet installed) and the
threshold. The rank of each level is a constant in the module. Agentica has no
lazy arguments, so the message and any fields map are built before the call. A
costly one goes inside `if Logger.enabled?(LogLevel.Debug)`, as in the example.
Plan for the PR, not measured here: a benchmark in `benchmarks/` with 1,000,000
disabled `debug` calls, against an empty loop and against a loop that calls an
empty user function. The PR description records the times. The target is a
disabled call no more than an empty user call plus one builtin call. Log calls
are normal code, so they count against `--max-steps`.

**The freeze (row 7.2.7).** The Racket parts are data under row 7.2.7, which
lists the same items:

- nine rows in `src/builtins.rkt` for `LogRegistry`, each using an existing
  checker rule tag or none, and their nine names in the `vm-builtins` list of
  `src/lower.rkt`;
- two entries in `src/builtin-types.rkt`: `LogEvent` in `builtin-records` and
  `LogLevel` in `builtin-enum-declarations`, and the name `LogEvent` in the
  record list of `src/lower.rkt` (`builtin-structs`). Their types are data once
  the checker, lowering and bytecode writer handle them; the enum field of
  `LogEvent` needs the two-line change in `src/lower.rkt` decided below, which
  relaxes this list for those lines;
- one line in `src/stdlib.rkt` that registers `std/logger`;
- `LogRegistry` in `std-only-modules` in `src/builtins.rkt`, so user code cannot
  call it (`CHECK-UNKNOWN-NAME`, with a help that names the `std/logger`
  import);
- `LogRegistry` in the reserved type names of `src/checker.rkt`, as `HttpWire`
  is. `LogEvent` and `LogLevel` are reserved by their builtin entries
  (`src/checker.rkt` lines 12 to 14), so nothing is added by hand for them;
- the std-only help in `src/modules.rkt`, generalized so that it names the std
  module of the name: `std/http` for `HttpWire`, `std/logger` for `LogRegistry`
  (a message fix, which row 7.2.7 allows).

Not data: a new checker rule, tag or construction rule, and new syntax. The "did
you mean" help for `CHECK-IMPORT-NAME` is not part of this PR. It is a separate
small PR (D9) that only changes message text, which the freeze allows.

**The stdlib registry and the VM table.** The nine native functions of
`LogRegistry` are:

```text
# -1 until the default is installed; then the global level's rank
LogRegistry.level() -> Int
LogRegistry.set_level(rank: Int) -> Void
# the lowest handler rank; 4 when no handler is attached
LogRegistry.lowest() -> Int
# only while the level is -1: attaches "console" at info, sets info
LogRegistry.install_default(handler: Fn[LogEvent, Void]) -> Void
LogRegistry.attach(name: String, rank: Int, handler: Fn[LogEvent, Void]) -> Result[Void]
LogRegistry.detach(name: String) -> Result[Void]
LogRegistry.names() -> List[String]                # in attach order
# handlers at or below the rank, in attach order
LogRegistry.handlers(rank: Int) -> List[Fn[LogEvent, Void]]
LogRegistry.task_id() -> Int                       # the running task's number
```

A rank is a level's position: `debug` 0, `info` 1, `warning` 2, `error` 3. The
registry keeps the lowest rank of its attached handlers and updates it on each
attach and detach; `lowest` is the input of `enabled?` with the global level
(see "Two thresholds"). `handlers(rank)` returns the handlers whose own level is
at or below the event's rank. The VM adds one table for them in
`vm/builtin_tables.c`, with an extern in `vm/services.h`, as every library does,
and the functions live in one C file. Their storage is the runtime field of the
decision above.

**Implementation (where the code goes).**

- `stdlib/logger.agc`: the level functions, `log`, `log_meta`, `enabled?`, the
  formatters, `time_text`, the default install and the two built-in handlers.
  `LogEvent` and `LogLevel` are builtins, so the module declares neither. Every
  export has a `##` doc (`tests/stdlib-docs-test.rkt`).
- `vm/builtin_tables.c`, `vm/services.h` and one new C file for the nine
  functions and the runtime field.
- `src/builtin-types.rkt`, `src/builtins.rkt`, `src/lower.rkt`,
  `src/stdlib.rkt`, `src/checker.rkt` and `src/modules.rkt`: the data and the
  help above.
- Tests: `tests/vm-logger-test.rkt`, goldens under
  `tests/fixtures/vm/logger-*.agc`, and a Python peer,
  `tests/fixtures/logger-peer.py`.
- Docs in the PR: `references/logger.md` of the programming skill with its row
  in the "When to read a reference" table;
  `site/content/library/io-and-system/logger.md` with runnable examples; the VM
  notes on the runtime field; the development skill's notes; and the CHANGELOG
  entry (the PR that builds it, not this one).

**Tests**, with fixed expected output on the VM (exit code, stdout, stderr, and
the diagnostic code):

- Goldens compare stderr exactly. They cover each level against each global
  level and each handler level, both formats, and messages and fields that need
  quoting (space, `=`, `"`, `\`, newline, empty, non-ASCII, DEL), field order,
  and a field named `level`, `msg`, `time` or `task`. The formatter tests build
  `LogEvent` values with fixed `time_ms`, so no clock is involved.
- Tasks: `main` attaches a handler, workers log in loops, `main` detaches, and
  the workers log again with no output. A task whose handler halts crashes
  alone, and `main` goes on. Lines from several tasks are each whole, and their
  `task` values match the spawn order.
- The tests that change the registry live in one file of their own, because the
  registry is shared by the tests of a file, which run one at a time in one VM
  (`docs/future/36-unit-tests.md` §36.6). Each restores the registry before it
  ends.
- The async example runs end to end: the file holds every event in order, and it
  is complete when `main` returns, because `main` awaits the writer.
- A run with no setup prints one line on stderr whose time matches the format (a
  regular expression, not an exact line).
- The Python peer (standard library `json` and `datetime` only) decodes every
  JSON line, checks that the keys are exactly `time`, `level`, `msg`, `fields`
  and `task`, and checks that the values equal what the task logged.
- `Logger.time_text` against vectors from `datetime`: the epoch, leap days,
  2000-02-29, 2100-03-01, a year end, a negative time, and large values.
- Hermetic: no network, and the async example writes to a path that the test
  passes in.

**Decided (2026-10-15).** The owner decided these points. The sections above
state them as the plan.

- **Handler types.** `LogEvent` is a builtin record and `LogLevel` a builtin
  enum, and handlers have type `Fn[LogEvent, Void]` (see "Types").
- **Level field.** `LogEvent.level` is the `LogLevel` enum (decided on
  2026-10-15). The two-line change in `src/lower.rkt` gives a builtin struct
  with an enum field no JSON types (`types` `#f`, as for a user struct that
  cannot be decoded), and `decodable-structs` skips such a struct. With that
  change the program compiles, with no bytecode or VM change. The change relaxes
  the data list of row 7.2.7 for those lines, and the 14c PR states that and
  why.
- **Handler table.** The first global state of the language, held by the VM
  runtime and limited to the registry (see "Decided: the handler table ...").
- **Async handlers.** An option, never the default (see "Async handlers").
- **Channel-only logger.** Rejected (see "Alternatives for the global state").
- **Calls.** Two functions per level until default parameter values land; the
  `_meta` functions then go away (see "Calls and names").
- **Enabled check.** `enabled?(level)` is true only if the level is at or above
  the global level and some attached handler accepts it (see "Two thresholds").
- **D1 Metadata per task.** Left out of v1. A task slot can come later.
- **D2 Levels.** Four: debug, info, warning and error.
- **D3 Default console handler.** Installed by the first call of a `Logger`
  function.
- **D4 Handler errors.** Not caught. A handler's error is the error of the
  logging task.
- **D5 Re-entrancy.** No guard in v1. A handler that logs recurses until
  `RUNTIME-STACK-OVERFLOW`.
- **D6 File output.** The block recipe, with no built-in file handler.
- **D7 Flags.** No `--log-*` flags in v1; configuration is in code. An optional
  `--log-level` flag can come later.
- **D8 The freeze.** The data list in "The freeze" above. `std/logger` may land
  before, during or after row 7.2.7.
- **D9 "Did you mean" help.** A separate small PR, not part of 14c, that only
  changes the message text of `CHECK-IMPORT-NAME`, which the freeze allows.
- **D10 The `task` field.** In the event and in JSON lines, not in the text
  form.

### 24.3 Stack traces on runtime errors

**Always on, in all three formats.** A runtime diagnostic shows the call stack
of the task that failed. There is no flag: agents read the default output and
would not know to pass one, and the cost is paid only when the run fails. The
stack is shown when the failing task has more than one frame, or when the
failing task is not `main`; a failure directly in `main` looks as it does today.

Plain format:

```text
nested.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]
index 5 is outside a list of length 3

2 |   return xs[i] + 1
  |             ^
  = stack, innermost first:
    pick at nested.agc:2:13
    load at nested.agc:7:11
    main at nested.agc:14:8
```

`--ai` adds the same lines after `source:`, under `  stack:`. `--json` adds a
`stack` array of `{"column":13,"file":"nested.agc","function":"pick","line":2}`
objects, innermost first, with keys sorted like the other keys.

- **Each frame** is one line: the function's name and the place it was running,
  `file:line:column`. The innermost frame is the place of the error (the
  diagnostic's span start). For a caller frame it is the call it is waiting on:
  the span of the instruction at its saved `pc - 1`.
- **Names:** the declared name; the linker's `@N::` prefix is cut, and the file
  shows where the function lives. A block shows as `block`. Native frames (a
  `List.map` running a block, `docs/vm/03-ir-and-bytecode.md` §4.3) are skipped:
  the line of the frame below already points at the `xs.map` call.
- **Prelude frames:** when the compiler prelude lands ([section
  25.6](25-ruby-typed-idioms.md#256-more-enumerable-methods)), its frames are
  skipped like native frames, so `xs.each_slice(0)` shows the user's call, and a
  block called from a prelude function shows the block frame and then the user's
  call.
- **Tail calls:** a frame that a tail call replaced is gone, as in Lua or
  Scheme. The frame left after one or more tail calls ends with
  `(after a tail call)` (JSON: `"tail":true`), so a reader knows that callers
  are missing there. `TAIL_CALL` sets a flag in the frame, and `CALL` clears it.
- **Repeats:** neighbouring frames with the same function and the same place are
  one line with a count: `walk at tree.agc:9:12 (9998 times)` (JSON:
  `"repeat":9998`). Deep recursion that ends in `RUNTIME-STACK-OVERFLOW` takes a
  few lines, not 10,000.
- **Cap:** after repeats are merged, at most 20 lines: the 15 innermost, a line
  `... 312 frames not shown ...`, and the 5 outermost (JSON: the same frames and
  a top-level `"stack_omitted":312`). Two functions that call each other a
  thousand times do not merge, so this is what keeps them short.
- **Tasks:** the stack is the failing task's own, and its last frame is the
  task's function. A line `task spawned at file:line:column` follows (JSON:
  `"spawned_at"`): the span of the `Task.spawn` call, kept in the task when it
  is spawned. The parent's stack at that time is not kept.
- **Which diagnostics:** every `RUNTIME-` diagnostic raised while a task runs,
  `RUNTIME-STEP-LIMIT` and `RUNTIME-STACK-OVERFLOW` included (the stack shows
  where a runaway loop is). Not: `System.exit`, the out-of-memory exit 70 (its
  handler allocates nothing, `docs/vm/05-values-execution-builtins.md` §6.3),
  front-end and `LOWER-` diagnostics, and failures outside any task: the stall
  check `every task is waiting and nothing can wake them` (`RUNTIME-INTERNAL`,
  raised by the scheduler between turns, `vm/task.c`) and a failed flush of
  stdout at the end of the run. Today `vm->task` still points to the last task
  after its turn ends, so the scheduler clears it when a turn ends (or, if code
  between turns still needs it, keeps a `running` flag that is set and cleared
  around each turn), and `agc_fail` copies a stack only while a task is running.

A bigger `--json` example. A task runs `worker`, spawned at `app.agc:30:7`.
`worker` calls `walk`, which calls itself 50 times from the same place. Then
`walk` calls `ping`, and `ping` and `pong` call each other 400 frames deep (not
as tail calls). The last `pong` calls `step`, which tail-calls `leaf`, which
fails. So `leaf` has the tail mark, the innermost `pong` shows its call to
`step` (line 13), and the other `pong` frames show their call to `ping` (line
15). The VM prints one line; it is shown here across lines. The stack has 20
entries: the 15 innermost, then the 5 outermost, and `stack_omitted` counts the
384 `ping` and `pong` frames between them. There are 51 `walk` frames: the 50
that wait on the self-call merge into one entry with `repeat`, and the innermost
one waits on its call to `ping` (line 18), a different place, so it is its own
entry. A frame object has `column`, `file`, `function` and `line`, plus `repeat`
when it stands for more than one frame and `tail` when a tail call removed
callers there. `spawned_at` is an object with the same place keys:

```text
{"code":"RUNTIME-DIVISION-BY-ZERO","file":"app.agc","message":"division by zero",
 "range":{"end":{"column":14,"line":2},"start":{"column":13,"line":2}},
 "spawned_at":{"column":7,"file":"app.agc","line":30},
 "stack":[
  {"column":13,"file":"app.agc","function":"leaf","line":2,"tail":true},
  {"column":9,"file":"app.agc","function":"pong","line":13},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":9,"file":"app.agc","function":"pong","line":15},
  {"column":9,"file":"app.agc","function":"ping","line":9},
  {"column":5,"file":"app.agc","function":"walk","line":18},
  {"column":9,"file":"app.agc","function":"walk","line":20,"repeat":50},
  {"column":3,"file":"app.agc","function":"worker","line":25}],
 "stack_omitted":384}
```

The plain and `--ai` formats show the same 20 lines, with
`... 384 frames not shown ...` after the 15th, `(50 times)` and
`(after a tail call)` at the end of their lines, and
`task spawned at app.agc:30:7` last.

- `grammar.md` §7 says diagnostics never show host exceptions or tracebacks;
  that stays true, since these frames are Agentica functions.

**Cost.** While the program runs: `TAIL_CALL` stores one flag, and `Task.spawn`
stores one span index. Nothing else: frames, names and spans already exist. On
failure: `agc_fail` copies the failing task's frames (function, `pc`, tail flag)
into the outcome before cleanup runs, O(depth), at most about 10,000;
`vm/diag.c` merges, cuts and formats them; and only `vm/main.c` prints
(`docs/vm/05-values-execution-builtins.md` §6.2).

**Tests:** a fixture set with fixed expected stderr in all three formats: nested
calls, a function from an imported file, a block run by `List.map`, a failing
task (spawn line), a tail call (the flag), deep non-tail recursion to
`RUNTIME-STACK-OVERFLOW` (repeats), two functions that call each other deeply
(the cap), and a failure in `main` alone (no stack). Expected outputs of other
fixtures that end in a runtime diagnostic are regenerated in the same PR, with a
reviewed diff. Docs: `grammar.md` §7, `docs/vm/02-reference-behavior.md` §2.5
and `docs/vm/05-values-execution-builtins.md` §6.1, and the programming skill's
`references/diagnostics.md`.

**As built (14b).** The walk is `agc_stack_capture` in `vm/diag.c`, called by
`agc_fail` and `agc_fail_text` while `vm->in_turn` is true (the flag that
already picks the `longjmp` target, so the scheduler needs no new one). Where
the text above is silent:

- The stack is not copied frame by frame. The walk merges and cuts while it
  copies, into a fixed array of 20 lines in `outcome.stack`, so it allocates
  nothing and a stack of 10,000 frames costs two passes over the frames.
- Native frames do not count for "more than one frame"; the frames that
  count are the visible ones, before merging.
- `... N frames not shown ...` counts frames (a merged run counts its
  repeats), and reads `... 1 frame not shown ...` for one.
- Neighbouring frames merge only when they also have the same tail flag.
- Plain: the `  = stack, innermost first:` line follows the caret line, and the
  frame lines, the cut line and `task spawned at` all have four spaces, for any
  width of the line number. `--ai`: the same lines under `  stack:`.
- Any task that was started by a spawn builtin has `task spawned at`, including
  the connection tasks of `std/http` (the place is the `HttpWire` call in
  `std/http.agc`) and the tests of `Test.run`.
- A line break in a function or file name is written as `\n` or `\r` in the
  plain and `--ai` lines.

### 24.4 VM tracing

A developer tool for `agentica-vm`, for debugging the scheduler, I/O jobs,
processes, TLS, the loader and the GC without adding `fprintf` by hand. It is
not part of the language: not in `grammar.md` or the programming skill, only in
`docs/vm/` and the development skill.

**Turning it on:** `AGENTICA_VM_TRACE=sched,io,proc` (a comma list), or `all`.
An environment variable, not a flag, because:

- it reaches the VM however it is started (`agentica --vm`, the test harnesses,
  BDD, a VM started by a program with `Process.spawn`) without adding a flag to
  each driver's pass-through list;
- it is not a setting of the program, so it does not belong next to `--seed` and
  `--max-steps`;
- the VM already reads a test variable once at start-up into its config (24.1).

Unset or empty means off. An unknown name writes one line
`agc-trace unknown category "x"` (to the trace file when
`AGENTICA_VM_TRACE_FILE` is set) and is ignored, so a typo never changes the
exit code. A child started with `Process.spawn` inherits the variable (children
inherit the environment), so a child VM traces too.

**Where the lines go:** descriptor 2 (stderr) by default.
`AGENTICA_VM_TRACE_FILE=path` sends them to a file instead: `vm/main.c` opens it
once at start-up with `O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC|O_NOFOLLOW` (mode
0600), takes it only when it is a regular file owned by the VM's user, and keeps
the descriptor in the `agc_trace` struct. If it cannot be opened, the VM writes
one line `agc-trace cannot open PATH` to stderr and traces nothing. A child VM
inherits both variables and opens the same file; `O_APPEND` puts each of its
lines after the others.

**Line format:** one line per event:

```text
agc-trace +0.012345 sched spawn task=2 parent=1 fn=worker
agc-trace +0.013002 io start job=7 kind=read task=2 timeout_ms=-1
agc-trace +0.013950 io done job=7 us=948 result=ok
```

A task spawned in an HTTP server's group (20c) is written `parent=group:N`, N
the id of the task that owns the group, since a group has no id of its own.

`agc-trace`, the time since the VM started in seconds with microseconds
(`CLOCK_MONOTONIC`), the category, the event, then `key=value` pairs. Numbers
are written in decimal. A text value (a path, a function name, a kind) is
written as it is, unless it is empty or contains a space, `=`, `"`, `\`, a
control character or a byte that is not valid UTF-8: then it is written in its
JSON form, quoted and escaped, the same rule as the fields of `std/logger`
(24.2), with each invalid UTF-8 byte written as `\u00XX`. `agc_trace_emit`
formats numbers with `vsnprintf`, and text values go through a small escaper
into the same buffer; an `agc_string` is passed as its bytes and byte length
(`%.*s` when it needs no escaping), since it is not NUL-terminated. Each line is
formatted into a 512-byte buffer on the C stack (longer lines are cut and end
with `...`) and written with one `write(2)` to the trace descriptor, never
through the `FILE *` stderr, so it does not touch the stdio buffer. A failed
trace write is ignored: it never ends the run (unlike `agc_write`, which fails
with `RUNTIME-INTERNAL`).

One write keeps a trace line whole against other whole-line writers. On stderr
that is not enough to keep it apart from everything: the VM forwards a
`Process.spawn` child's stderr in chunks, so a trace line can follow a partial
line from a child, and then `rg '^agc-trace '` misses it. Use
`AGENTICA_VM_TRACE_FILE` when the program runs children, or when the trace must
be read by a tool; in a file, every line starts with `agc-trace`.

**Cost when off:** one load, one test and one well-predicted branch per trace
point: `AGC_TRACE(rt, AGC_TRACE_SCHED, "spawn task=%" PRIu64 ...)` expands to
`if (AGC_TRACE_BUILD && (rt->trace & AGC_TRACE_SCHED)) agc_trace_emit(...)`.
Trace points are at events (a spawn, a turn end, a job), never per instruction.
`make vm TRACE=0` sets `AGC_TRACE_BUILD` to 0, so the compiler drops every trace
point but still type-checks it; the flag goes in the `build/vm/flags` stamp like
`SANITIZE`. Release, sanitizer and GC-stress builds keep tracing in, so a user
can send a trace. `agentica-vm --version` says `trace off` in a `TRACE=0` build.

**It never changes what the program sees**, except for the added trace lines on
stderr (none when they go to a file):

- Trace code reads state and never changes it: no GC allocation (only the stack
  buffer, numbers and bytes that already exist, such as a function's name), no
  steps, no turn cost, no change to when tasks switch.
- No mutable globals (`docs/vm/10-io-multicore.md` §10.2.3): `vm/main.c` reads
  the variable before loading, into an `agc_trace` struct (category mask and
  start time), passes it to `agc_load`, and stores it in `agc_runtime`. Each
  task gets an id from `_Atomic uint64_t next_task_id` in the runtime, with
  `atomic_fetch_add` at spawn, so it stays safe with N schedulers (`main` is 1).
  Ids are given whether tracing is on or not, one atomic add per spawn, so a
  task's id never depends on which categories are on. The same ids are the
  `task` numbers of log events (24.2), so a handler reads a task's number from
  `event.task`.
- **Signals:** nothing traces from a real signal handler (the out-of-memory and
  GC abort handlers of `docs/vm/05-values-execution-builtins.md` §6.3, or any
  `sigaction` handler); those paths may call only `write(2)` with a fixed text,
  and they already do. libuv's `uv_signal_t` callbacks run on the loop thread,
  not in the handler, so they may trace.
- **Thread-pool threads** do not trace: the `work` half of a job has no runtime
  pointer. The `done` half, on the loop thread, traces the job with the time it
  spent in the pool (the start time is saved in the job only when `io` is on).
- **Tests run with tracing off:** `AGENTICA_VM_TRACE` and
  `AGENTICA_VM_TRACE_FILE` are removed in one place for the whole run:
  `unexport AGENTICA_VM_TRACE AGENTICA_VM_TRACE_FILE` in the Makefile covers
  `make test` and every other target, and for a direct `raco test`,
  `tests/vm-diff-common.rkt`, `tests/cli-in-process.rkt` and
  `tests/vm-latency-test.rkt` (which starts `dist/agentica-vm` directly) remove
  both from the environment when they load. Any later test file that starts the
  VM itself removes them the same way; a developer's exported variable cannot
  change expected output. Only `tests/vm-trace-test.rkt` sets them: it runs a
  few fixtures (tasks, files and stdin, processes with a child that writes to
  stderr, a runtime failure) with `AGENTICA_VM_TRACE=all` and
  `AGENTICA_VM_TRACE_FILE` in a temporary directory, and checks that exit code,
  stdout and stderr are byte for byte the same as without tracing, that every
  line of the trace file matches the format, and that each category it expects
  appears; an allocation-heavy fixture (`map-large`) must write `gc` lines,
  except on a sanitizer build, which has no collector. The `vm-sanitizers` job
  runs `make vm vm-test TRACE=0` and checks `--version` on a manual CI run and
  on a pull request that changes `vm/trace.*` or `vm/tests/trace_test.c`; other
  pull requests skip it.

**Where the code goes:** `vm/trace.h` (the `agc_trace` struct, the category
bits, the `AGC_TRACE` macro) and `vm/trace.c` (`agc_trace_parse` for the
variable, `agc_trace_emit` with `vsnprintf` and `write`), under the C rules of
the development skill (file order, no static prototypes, `agc_` names). The
Makefile adds `vm/trace.c`. `vm/` is already in the `ci.yml` path list.

**First version** (14a, right after 7h processes): the categories `sched`, `io`,
`proc`, `tls`, `loader` and `gc`. `tls` is defined in 14a, and the TCP and TLS
PR adds its trace points as it lands; later PRs add their own categories in the
same way (`net`, `http`). First trace points:

- **`sched`:** task spawn (id, parent, function name), turn end (task, steps
  used, turn cost, why: yield, park or done), wake (task, by what), the cancel
  of pending tasks when `main` returns (how many), the stall check, a task
  failure (code).
- **`io`:** job start (job, kind, task, timeout), job done (job, time in the
  pool, ok or error), job timeout, handle lock wait and hand-off (handle, task),
  stdin read (bytes, EOF), each `uv_run` that waits, or that finds finished jobs
  without waiting (mode, time blocked), end-of-run close (jobs left, and the
  `_exit` path).
- **`proc`:** spawn (pid, path, argument count), exit (pid, status or signal),
  kill and reap on close, EOF on each pipe, stderr bytes passed on; and the
  signal watchers of the process guard (start, stop, a signal seen in its loop
  callback, cleanup, raise again).
- **`tls`:** handshake start and end (protocol version and cipher), handshake,
  setup and read errors, and close (as built with the TLS PR,
  `docs/vm/08-loader-and-cli.md` §9; the `want read`/`want write` waits and
  alerts are not traced, the `io` events show the reads and writes).
- **`loader`:** file size and format version, the size of each table (sources,
  spans, constants, builtins, functions, structs, types, enums, variants), the
  reason a file is rejected (the same text as the error), and the load time.
- **`gc`:** at the end of a turn and at the end of the run, when
  `GC_get_gc_no()` has changed since the last line: the collection count, heap
  size, free bytes, and bytes allocated since the last collection, all from
  Boehm's getters. Not a collection callback: `GC_set_on_collection_event` has
  no user data, so it would need a global. Boehm's own `GC_PRINT_STATS=1` gives
  more detail. Under `AGC_NO_GC` (ASan builds) this category writes nothing.

**Tracing and metrics.** Tracing writes every event of one run for a developer
to read. Totals and gauges that Prometheus scrapes and Grafana graphs (GC
collections and heap, tasks, run-queue delay, I/O) are VM metrics, planned in
[section 28](28-vm-metrics.md) (roadmap phase 18). Metrics share tracing's rules
and its trace points: a hook sits at a trace point and shares its one test
(§28.4, §28.10).

### 24.5 Not planned

- Built-in log files and rotation (a block that appends each event does the
  job, 24.2), syslog, sampling, per-module levels, `Json` field values, and log
  configuration through environment variables.
- Lazy log arguments. A block given to `attach` is a handler, not a lazy
  message (24.2).
- A flag to turn stack traces off, and a stack of the parent task at spawn time.
- VM tracing as a language feature, or trace lines on stdout.
- Totals or counters in the tracer: those are metrics (§28).
