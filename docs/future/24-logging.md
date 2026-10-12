## 24. Logging and debugging

**Status:** planned (roadmap phase 14). Three parts, each its own small PR, all on the VM only (the evaluator is gone by then, or the part changes only VM code):

- 14a, **VM tracing** (24.4): a developer tool inside `agentica-vm`, not a language feature. It comes right after 7h processes and before TCP and TLS, to make the rest of 7h faster to debug.
- 14b, **stack traces on runtime errors** (24.3): after 7i.
- 14c, **`std/log`** with the `--log-*` flags (24.2): after 7i and after default parameter values (15a, [section 25.1](25-ruby-typed-idioms.md#251-default-parameter-values)), which land first in the same order step.

No grammar change. 14c adds three `System` builtins and a `std/` module; 14b changes only what the VM prints for a runtime diagnostic.

### 24.1 Today

Checked on the VM (`racket src/main.rkt --vm`, at `2e6da77`):

- Programs have no logging. `IO.warn(x)` writes `x.to_s` and a newline to stderr: no level, no time, no fields, and no way to turn debug lines off. `IO.inspect` writes to stdout, not stderr. `IO.warn("a\nb")` writes two lines, so one message can break into several lines.
- `IO.warn` on the VM makes two `fwrite` calls on the unbuffered stderr, the text and then `"\n"` (`write_text` in `vm/builtins.c`), so two `write(2)` calls. With one scheduler no other task runs between them, since a builtin is never cut by a task switch; another process that shares the VM's stderr can still write between them (not a `Process.spawn` child, whose stderr the VM forwards through a pipe, `docs/vm/10-io-tls-processes-http.md` §10.4).
- There is no `System.env`: `System.env("HOME")` is `CHECK-UNKNOWN-NAME`.
- A runtime diagnostic has one span and no call stack, in all three formats. A failure inside `pick`, called from `load`, called from `main`, shows only the line in `pick`.
- A tail call (`return f(...)`) replaces the caller's frame (`docs/vm/05-values-execution-builtins.md` §6.1), so 20,000 nested tail calls run and fail later with the frame of the last call only.
- What a stack trace needs is already there: each frame has its function index and saved `pc` (the next instruction, so the call is at `pc - 1`), each function has its name and one span index per instruction, and the spans table has file, line and column. Linked names look like `@2::push` for a function from an imported file, and blocks are named `block@file.agc:10:15`.
- `error` is a reserved name: a module cannot declare `def error` (`CHECK-REDEFINED-NAME`), so a log module cannot have `Log.error`. A wrong imported name (`Log.error` when the module has no `error`) is `CHECK-IMPORT-NAME` with no "did you mean" help.
- `JSON.encode` of a `Map[String, String]` keeps the map's order and escapes `"`, `\` and control characters; non-ASCII text stays as it is. `JSON.encode` of a `String` gives the quoted, escaped text.
- The VM reads one environment variable at start-up into its runtime config (`AGENTICA_VM_TEST_NO_TURN_COST`), and `vm/` has no mutable global state (`docs/vm/10-io-multicore.md` §10.2.3). Debugging the scheduler, I/O jobs, the GC, processes or the loader means adding `fprintf` by hand.

### 24.2 `std/log`

```agentica
import "std/log.agc" as Log

def expensive_dump() -> String
  return "..."
end

def main() -> Void
  Log.info("server started")
  Log.info("request done", {"path": "/items", "status": "200"})
  Log.debug("not shown at the default level")
  if Log.debug?()
    Log.debug("state: #{expensive_dump()}")
  end
  Log.err("cannot open the cache")
end
```

With `agentica --log-time none app.agc`, stderr gets:

```text
INFO server started
INFO request done path=/items status=200
ERROR cannot open the cache
```

and with `--log-format json --log-time none`:

```text
{"level":"info","msg":"server started"}
{"level":"info","msg":"request done","fields":{"path":"/items","status":"200"}}
{"level":"error","msg":"cannot open the cache"}
```

**API:**

```text
Log.debug(message: String, fields: Map[String, String] = {}) -> Void
Log.info(message: String, fields: Map[String, String] = {}) -> Void
Log.warn(message: String, fields: Map[String, String] = {}) -> Void
Log.err(message: String, fields: Map[String, String] = {}) -> Void
Log.debug?() -> Bool
Log.time_text(ms: Int) -> String
```

- **Levels** are `debug`, `info`, `warn` and `error`, in that order. A line is written when its level is at or above the run's level. The default level is `info`.
- **Names.** `error` is reserved (24.1), so the error function is `err`; the level is still called `error` in the output and in `--log-level`. Fields are an optional second parameter with the default `{}` ([section 25.1](25-ruby-typed-idioms.md#251-default-parameter-values), 15a, which lands before 14c), so there is one function per level and no separate `_with` form. The 14c PR also adds a "did you mean" help to `CHECK-IMPORT-NAME`, made from the module's exported names, so `Log.error(...)` suggests `Log.err`.
- **Fields** are `Map[String, String]`. A map literal is short (`{"path": p, "status": "#{code}"}`), the text format needs strings anyway, and the map keeps its order, so the output order is the order the program wrote. `Json` was the other option: it keeps numbers as numbers in JSON lines, but every value needs `JSON.from`, and the text format has to turn it back into text. Numbers are strings in JSON lines; tools that need a number convert it.
- **`Log.debug?()`** says whether debug lines are on. Only `debug` has one: it is the level that is off by default and where building the message costs most.
- **`Log.time_text(ms)`** turns milliseconds since the Unix epoch into the text the log uses (`2026-10-12T10:15:02.345Z`). It is exported because programs need it too, and so that tests can check it with fixed inputs.

**How the level and format are set.** Three flags of the run, read through three small builtins:

```text
--log-level debug|info|warn|error|off    (default info)
--log-format text|json                   (default text)
--log-time wall|none                     (default wall)

System.log_level() -> String     # "debug", "info", "warn", "error" or "off"
System.log_format() -> String    # "text" or "json"
System.log_time?() -> Bool       # false under --log-time none
```

- `agentica` takes the flags before the file and passes them to the VM, as it does `--seed`; `agentica-vm` takes them too. A bad value exits 2 (`agentica: --log-level needs debug, info, warn, error or off`), and a flag given twice exits 2, like the other options (`docs/vm/08-loader-and-cli.md` §9). `agentica test` passes them to the programs under test, as it does `--seed`. A child started with `Process.spawn` does not get them; the parent passes them in the child's arguments when it wants to.
- The settings are read once at start-up into the runtime, and never change during the run. A builtin that reads them is like `System.args`: it reads the run's command line, so there is no mutable state anywhere, and every task and every module sees the same settings. Each log call costs one builtin call to read the level.
- They are builtins under exception 1 of the roadmap rule "New library features: `std/` first" (they read the run's command line, which a program cannot do itself). They go in `System`, never in a builtin module named `Log`, since `Log` is the documented import alias of `std/log`. Everything else (filtering, the time text, the formats, escaping) is Agentica code in `stdlib/log.agc`.
- **Why flags.** Every other setting of a run is a flag (`--seed`, `--max-steps`, `--allow-run`), and a flag is visible in the command an agent runs and in `agentica --help`. An environment variable would need a `System.env` builtin first, and it leaks into every child program; `System.env` stays a separate item for when a real program needs it. A logger value that the program builds (`Log.new(level, format)`) and passes around was the third option: it needs no builtin, but it adds a parameter to every function that logs and to every task argument, agents forget to pass it, and the level still has to come from somewhere outside the program. A program that wants its own filter (per part of the program) can still wrap `std/log` in its own functions.

**Formats.** Both write one line per call to stderr.

- **Text:** `TIME LEVEL MESSAGE key=value ...`, for example `2026-10-12T10:15:02.345Z INFO request done path=/items status=200`. The time is UTC in ISO 8601 with milliseconds, from `Time.now_ms()`; `Log.time_text` turns the number into a date with integer arithmetic only (days since 1970 to year, month and day), so it is plain `std/` code. The level is in capitals. The message is written as it is, unless it is empty, starts or ends with a space, or contains `=`, `"`, `\` or a control character (DEL included): then it is written in its JSON form (quoted and escaped). So a message with a newline still takes one line, and a message never looks like a field. A field is `key=value`; the key and the value are written as they are unless they are empty or contain a space, `=`, `"`, `\` or a control character, and then in their JSON form. "As it is" is tested with `JSON.encode(s) == "\"#{s}\""` (the encoder escapes `"`, `\`, control characters and DEL) plus checks for empty, spaces and `=`, a few builtin calls per part, so there is no loop over characters in Agentica. Fields come in map order. With these rules every text line can be read back: the message is a JSON string or ends before the first ` key=` (a bare message has no `=`, and a bare key has no space).
- **JSON lines:** one object per line, with `time` (the same text), `level` (lower case), `msg`, and `fields` (an object, left out when there are no fields). The fields are nested, so a field called `level` or `msg` never clashes with the fixed keys. The line is built with `JSON.object` and `JSON.from` and written with `JSON.encode`, so all escaping is the JSON encoder's.
- **`--log-time none`** leaves the time out in both formats. Tests use it, so their expected stderr never changes. It is also useful in production when a supervisor (journald, a container runtime) already adds its own time. A fixed fake clock under a test flag was the other option; it was not chosen because it would also change what `Time.now_ms` returns to the program, and `none` is simpler.

**One line, one write.** `std/log` builds the whole line and calls `IO.warn` once. The 14c PR changes `IO.warn` on the VM to write the text and the newline with one `write(2)` (today two, 24.1). With one scheduler, lines from different tasks already never mix inside a line, since a builtin runs to its end before another task runs. One write also keeps the line whole against other writers to the same descriptor: another process that shares the VM's stderr (POSIX makes a write of up to `PIPE_BUF`, 4096 bytes on Linux, to a pipe atomic; longer lines may still mix with another process's output), and multicore schedulers, if they land, where one `fwrite` on one `FILE` is atomic. It does not cover a `Process.spawn` child's stderr: the VM forwards it in chunks as they arrive, not by line (`src/process.rkt` does the same), so a log line of the parent can still land in the middle of a child's line.

**Cost of a debug line that is off.** Agentica has no lazy arguments, so in `Log.debug("state: #{dump()}")` the message is built before the call, and then `Log.debug` reads the level and returns: about ten steps plus the cost of the message. This is accepted. When the message is costly, the program writes `if Log.debug?() ... end`. A block form (`Log.debug_lazy do "..." end`) was not chosen: a block that captures variables makes a closure on every call, even when debug is off, and it would be a second way to do the same thing. Log calls are normal Agentica code, so they count against `--max-steps`.

**Tests**, with fixed expected output on the VM (exit code, stdout, stderr, diagnostic code):

- Fixtures run with `--log-time none` and compare stderr exactly: each level against each `--log-level`, `off`, both formats, messages and fields that need quoting (space, `=`, `"`, `\`, newline, empty, non-ASCII), no fields, field order, a field named `level`.
- Lines from several tasks (`Task.spawn`, each logging in a loop) are each whole. In text, every stderr line must match, as a whole, `LEVEL SP MESSAGE (SP KEY "=" VALUE)*` (with `--log-time none`), where `LEVEL` is `DEBUG`, `INFO`, `WARN` or `ERROR`, `SP` is one space, `MESSAGE` is a JSON string or one or more characters that are not `=`, `"`, `\` or control characters and do not start or end with a space, and `KEY` and `VALUE` are each a JSON string or one or more characters that are not space, `=`, `"`, `\` or control characters; every JSON string must decode with `string->jsexpr`, and the decoded message, keys and values must equal what the task logged. In json, every line must decode to an object with exactly the keys `level`, `msg` and, when there are fields, `fields`, with the logged values.
- `--log-time wall`: every line starts with a time that matches the format and lies between `Time.now_ms()` read before and after it.
- `Log.time_text` against vectors from a checked-in Python script (standard library `datetime` only, as in §23.7): the epoch, leap days, 2000-02-29, 2100-03-01, the end of a year, a negative time, and large values.
- Bad flag values and repeated flags exit 2.

**Docs in the 14c PR:** `grammar.md` (the `System` builtins and the flags; the advice "logs go to stderr with `IO.warn`" points to `std/log`), the programming skill (a `references/log.md` file and its row in the "When to read a reference" table; the stdio advice in `SKILL.md`), `site/content/library/log.md` with runnable examples (`--log-time none`), and `docs/vm/08-loader-and-cli.md` §9 for the flags.

### 24.3 Stack traces on runtime errors

**Always on, in all three formats.** A runtime diagnostic shows the call stack of the task that failed. There is no flag: agents read the default output and would not know to pass one, and the cost is paid only when the run fails. The stack is shown when the failing task has more than one frame, or when the failing task is not `main`; a failure directly in `main` looks as it does today.

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

`--ai` adds the same lines after `source:`, under `  stack:`. `--json` adds a `stack` array of `{"column":13,"file":"nested.agc","function":"pick","line":2}` objects, innermost first, with keys sorted like the other keys.

- **Each frame** is one line: the function's name and the place it was running, `file:line:column`. The innermost frame is the place of the error (the diagnostic's span start). For a caller frame it is the call it is waiting on: the span of the instruction at its saved `pc - 1`.
- **Names:** the declared name; the linker's `@N::` prefix is cut, and the file shows where the function lives. A block shows as `block`. Native frames (a `List.map` running a block, `docs/vm/03-ir-and-bytecode.md` §4.3) are skipped: the line of the frame below already points at the `xs.map` call.
- **Prelude frames:** when the compiler prelude lands ([section 25.6](25-ruby-typed-idioms.md#256-more-enumerable-methods)), its frames are skipped like native frames, so `xs.each_slice(0)` shows the user's call, and a block called from a prelude function shows the block frame and then the user's call.
- **Tail calls:** a frame that a tail call replaced is gone, as in Lua or Scheme. The frame left after one or more tail calls ends with `(after a tail call)` (JSON: `"tail":true`), so a reader knows that callers are missing there. `TAIL_CALL` sets a flag in the frame, and `CALL` clears it.
- **Repeats:** neighbouring frames with the same function and the same place are one line with a count: `walk at tree.agc:9:12 (9998 times)` (JSON: `"repeat":9998`). Deep recursion that ends in `RUNTIME-STACK-OVERFLOW` takes a few lines, not 10,000.
- **Cap:** after repeats are merged, at most 20 lines: the 15 innermost, a line `... 312 frames not shown ...`, and the 5 outermost (JSON: the same frames and a top-level `"stack_omitted":312`). Two functions that call each other a thousand times do not merge, so this is what keeps them short.
- **Tasks:** the stack is the failing task's own, and its last frame is the task's function. A line `task spawned at file:line:column` follows (JSON: `"spawned_at"`): the span of the `Task.spawn` call, kept in the task when it is spawned. The parent's stack at that time is not kept.
- **Which diagnostics:** every `RUNTIME-` diagnostic raised while a task runs, `RUNTIME-STEP-LIMIT` and `RUNTIME-STACK-OVERFLOW` included (the stack shows where a runaway loop is). Not: `System.exit`, the out-of-memory exit 70 (its handler allocates nothing, `docs/vm/05-values-execution-builtins.md` §6.3), front-end and `LOWER-` diagnostics, and failures outside any task: the stall check `every task is waiting and nothing can wake them` (`RUNTIME-INTERNAL`, raised by the scheduler between turns, `vm/task.c`) and a failed flush of stdout at the end of the run. Today `vm->task` still points to the last task after its turn ends, so the scheduler clears it when a turn ends (or, if code between turns still needs it, keeps a `running` flag that is set and cleared around each turn), and `agc_fail` copies a stack only while a task is running.

A bigger `--json` example. A task runs `worker`, spawned at `app.agc:30:7`. `worker` calls `walk`, which calls itself 50 times from the same place. Then `walk` calls `ping`, and `ping` and `pong` call each other 400 frames deep (not as tail calls). The last `pong` calls `step`, which tail-calls `leaf`, which fails. So `leaf` has the tail mark, the innermost `pong` shows its call to `step` (line 13), and the other `pong` frames show their call to `ping` (line 15). The VM prints one line; it is shown here across lines. The stack has 20 entries: the 15 innermost, then the 5 outermost, and `stack_omitted` counts the 384 `ping` and `pong` frames between them. There are 51 `walk` frames: the 50 that wait on the self-call merge into one entry with `repeat`, and the innermost one waits on its call to `ping` (line 18), a different place, so it is its own entry. A frame object has `column`, `file`, `function` and `line`, plus `repeat` when it stands for more than one frame and `tail` when a tail call removed callers there. `spawned_at` is an object with the same place keys:

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

The plain and `--ai` formats show the same 20 lines, with `... 384 frames not shown ...` after the 15th, `(50 times)` and `(after a tail call)` at the end of their lines, and `task spawned at app.agc:30:7` last.

- `grammar.md` §7 says diagnostics never show host exceptions or tracebacks; that stays true, since these frames are Agentica functions.

**Cost.** While the program runs: `TAIL_CALL` stores one flag, and `Task.spawn` stores one span index. Nothing else: frames, names and spans already exist. On failure: `agc_fail` copies the failing task's frames (function, `pc`, tail flag) into the outcome before cleanup runs, O(depth), at most about 10,000; `vm/diag.c` merges, cuts and formats them; and only `vm/main.c` prints (`docs/vm/05-values-execution-builtins.md` §6.2).

**Tests:** a fixture set with fixed expected stderr in all three formats: nested calls, a function from an imported file, a block run by `List.map`, a failing task (spawn line), a tail call (the flag), deep non-tail recursion to `RUNTIME-STACK-OVERFLOW` (repeats), two functions that call each other deeply (the cap), and a failure in `main` alone (no stack). Expected outputs of other fixtures that end in a runtime diagnostic are regenerated in the same PR, with a reviewed diff. Docs: `grammar.md` §7, `docs/vm/02-reference-behavior.md` §2.5 and `docs/vm/05-values-execution-builtins.md` §6.1, and the programming skill's `references/diagnostics.md`.

### 24.4 VM tracing

A developer tool for `agentica-vm`, for debugging the scheduler, I/O jobs, processes, TLS, the loader and the GC without adding `fprintf` by hand. It is not part of the language: not in `grammar.md` or the programming skill, only in `docs/vm/` and the development skill.

**Turning it on:** `AGENTICA_VM_TRACE=sched,io,proc` (a comma list), or `all`. An environment variable, not a flag, because:

- it reaches the VM however it is started (`agentica --vm`, the test harnesses, BDD, a VM started by a program with `Process.spawn`) without adding a flag to each driver's pass-through list;
- it is not a setting of the program, so it does not belong next to `--seed` and `--max-steps`;
- the VM already reads a test variable once at start-up into its config (24.1).

Unset or empty means off. An unknown name writes one line `agc-trace unknown category "x"` (to the trace file when `AGENTICA_VM_TRACE_FILE` is set) and is ignored, so a typo never changes the exit code. A child started with `Process.spawn` inherits the variable (children inherit the environment), so a child VM traces too.

**Where the lines go:** descriptor 2 (stderr) by default. `AGENTICA_VM_TRACE_FILE=path` sends them to a file instead: `vm/main.c` opens it once at start-up with `O_WRONLY|O_APPEND|O_CREAT|O_CLOEXEC|O_NOFOLLOW` (mode 0600), takes it only when it is a regular file owned by the VM's user, and keeps the descriptor in the `agc_trace` struct. If it cannot be opened, the VM writes one line `agc-trace cannot open PATH` to stderr and traces nothing. A child VM inherits both variables and opens the same file; `O_APPEND` puts each of its lines after the others.

**Line format:** one line per event:

```text
agc-trace +0.012345 sched spawn task=2 parent=1 fn=worker
agc-trace +0.013002 io start job=7 kind=read task=2 timeout_ms=-1
agc-trace +0.013950 io done job=7 us=948 result=ok
```

`agc-trace`, the time since the VM started in seconds with microseconds (`CLOCK_MONOTONIC`), the category, the event, then `key=value` pairs. Numbers are written in decimal. A text value (a path, a function name, a kind) is written as it is, unless it is empty or contains a space, `=`, `"`, `\`, a control character or a byte that is not valid UTF-8: then it is written in its JSON form, quoted and escaped, the same rule as the fields of `std/log` (24.2), with each invalid UTF-8 byte written as `\u00XX`. `agc_trace_emit` formats numbers with `vsnprintf`, and text values go through a small escaper into the same buffer; an `agc_string` is passed as its bytes and byte length (`%.*s` when it needs no escaping), since it is not NUL-terminated. Each line is formatted into a 512-byte buffer on the C stack (longer lines are cut and end with `...`) and written with one `write(2)` to the trace descriptor, never through the `FILE *` stderr, so it does not touch the stdio buffer. A failed trace write is ignored: it never ends the run (unlike `agc_write`, which fails with `RUNTIME-INTERNAL`).

One write keeps a trace line whole against other whole-line writers. On stderr that is not enough to keep it apart from everything: the VM forwards a `Process.spawn` child's stderr in chunks, so a trace line can follow a partial line from a child, and then `rg '^agc-trace '` misses it. Use `AGENTICA_VM_TRACE_FILE` when the program runs children, or when the trace must be read by a tool; in a file, every line starts with `agc-trace`.

**Cost when off:** one load, one test and one well-predicted branch per trace point: `AGC_TRACE(rt, AGC_TRACE_SCHED, "spawn task=%" PRIu64 ...)` expands to `if (AGC_TRACE_BUILD && (rt->trace & AGC_TRACE_SCHED)) agc_trace_emit(...)`. Trace points are at events (a spawn, a turn end, a job), never per instruction. `make vm TRACE=0` sets `AGC_TRACE_BUILD` to 0, so the compiler drops every trace point but still type-checks it; the flag goes in the `build/vm/flags` stamp like `SANITIZE`. Release, sanitizer and GC-stress builds keep tracing in, so a user can send a trace. `agentica-vm --version` says `trace off` in a `TRACE=0` build.

**It never changes what the program sees**, except for the added trace lines on stderr (none when they go to a file):

- Trace code reads state and never changes it: no GC allocation (only the stack buffer, numbers and bytes that already exist, such as a function's name), no steps, no turn cost, no change to when tasks switch.
- No mutable globals (`docs/vm/10-io-multicore.md` §10.2.3): `vm/main.c` reads the variable before loading, into an `agc_trace` struct (category mask and start time), passes it to `agc_load`, and stores it in `agc_runtime`. Each task gets an id from `_Atomic uint64_t next_task_id` in the runtime, with `atomic_fetch_add` at spawn, so it stays safe with N schedulers (`main` is 1). Ids are given whether tracing is on or not, one atomic add per spawn, so a task's id never depends on which categories are on. They are for trace lines only; programs never see them.
- **Signals:** nothing traces from a real signal handler (the out-of-memory and GC abort handlers of `docs/vm/05-values-execution-builtins.md` §6.3, or any `sigaction` handler); those paths may call only `write(2)` with a fixed text, and they already do. libuv's `uv_signal_t` callbacks run on the loop thread, not in the handler, so they may trace.
- **Thread-pool threads** do not trace: the `work` half of a job has no runtime pointer. The `done` half, on the loop thread, traces the job with the time it spent in the pool (the start time is saved in the job only when `io` is on).
- **Tests run with tracing off:** `AGENTICA_VM_TRACE` and `AGENTICA_VM_TRACE_FILE` are removed in one place for the whole run: `unexport AGENTICA_VM_TRACE AGENTICA_VM_TRACE_FILE` in the Makefile covers `make test` and every other target, and for a direct `raco test`, `tests/vm-diff-common.rkt`, `tests/cli-in-process.rkt` and `tests/vm-latency-test.rkt` (which starts `dist/agentica-vm` directly) remove both from the environment when they load. Any later test file that starts the VM itself removes them the same way; a developer's exported variable cannot change expected output. Only `tests/vm-trace-test.rkt` sets them: it runs a few fixtures (tasks, files and stdin, processes with a child that writes to stderr, a runtime failure) with `AGENTICA_VM_TRACE=all` and `AGENTICA_VM_TRACE_FILE` in a temporary directory, and checks that exit code, stdout and stderr are byte for byte the same as without tracing, that every line of the trace file matches the format, and that each category it expects appears; an allocation-heavy fixture (`map-large`) must write `gc` lines, except on a sanitizer build, which has no collector. The `vm-sanitizers` job runs `make vm vm-test TRACE=0` and checks `--version` on a manual CI run and on a pull request that changes `vm/trace.*` or `vm/tests/trace_test.c`; other pull requests skip it.

**Where the code goes:** `vm/trace.h` (the `agc_trace` struct, the category bits, the `AGC_TRACE` macro) and `vm/trace.c` (`agc_trace_parse` for the variable, `agc_trace_emit` with `vsnprintf` and `write`), under the C rules of the development skill (file order, no static prototypes, `agc_` names). The Makefile adds `vm/trace.c`. `vm/` is already in the `ci.yml` path list.

**First version** (14a, right after 7h processes): the categories `sched`, `io`, `proc`, `tls`, `loader` and `gc`. `tls` is defined in 14a, and the TCP and TLS PR adds its trace points as it lands; later PRs add their own categories in the same way (`net`, `http`). First trace points:

- **`sched`:** task spawn (id, parent, function name), turn end (task, steps used, turn cost, why: yield, park or done), wake (task, by what), the cancel of pending tasks when `main` returns (how many), the stall check, a task failure (code).
- **`io`:** job start (job, kind, task, timeout), job done (job, time in the pool, ok or error), job timeout, handle lock wait and hand-off (handle, task), stdin read (bytes, EOF), each `uv_run` that waits, or that finds finished jobs without waiting (mode, time blocked), end-of-run close (jobs left, and the `_exit` path).
- **`proc`:** spawn (pid, path, argument count), exit (pid, status or signal), kill and reap on close, EOF on each pipe, stderr bytes passed on; and the signal watchers of the process guard (start, stop, a signal seen in its loop callback, cleanup, raise again).
- **`tls`:** handshake start and end (result, protocol version), the `want read`/`want write` waits, alerts and errors (with the TCP and TLS PR).
- **`loader`:** file size and format version, the size of each table (sources, spans, constants, builtins, functions, structs, types, enums, variants), the reason a file is rejected (the same text as the error), and the load time.
- **`gc`:** at the end of a turn and at the end of the run, when `GC_get_gc_no()` has changed since the last line: the collection count, heap size, free bytes, and bytes allocated since the last collection, all from Boehm's getters. Not a collection callback: `GC_set_on_collection_event` has no user data, so it would need a global. Boehm's own `GC_PRINT_STATS=1` gives more detail. Under `AGC_NO_GC` (ASan builds) this category writes nothing.

**Tracing and metrics.** Tracing writes every event of one run for a developer to read. Totals and gauges that Prometheus scrapes and Grafana graphs (GC collections and heap, tasks, run-queue delay, I/O) are VM metrics, planned in [section 28](28-vm-metrics.md) (roadmap phase 18). Metrics share tracing's rules and its trace points: a hook sits at a trace point and shares its one test (§28.4, §28.10).

### 24.5 Not planned

- Log files, rotation, syslog, sampling, per-module levels, `Json` field values, and log configuration through environment variables.
- Lazy log arguments or a block form (24.2).
- A flag to turn stack traces off, and a stack of the parent task at spawn time.
- VM tracing as a language feature, or trace lines on stdout.
- Totals or counters in the tracer: those are metrics (§28).
