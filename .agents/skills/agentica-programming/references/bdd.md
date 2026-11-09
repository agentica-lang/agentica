# BDD feature specifications

`agentica test [PATH...]` runs `.feature` files and `*_test.agc` unit test files
(flags: `agentica --help`). It searches directories in sorted order (folder
links are not followed; a feature file is at most 1 MiB); the default paths are
`specs/` and `test/`. `--steps FILE` names the one step program (repeating it
is `RUNTIME-BDD-USAGE`); without it, a run with features uses the nearest
`steps.agc` in the folder of each path that holds a feature or above it, up to
the working directory (two different ones are `RUNTIME-BDD-USAGE`). Empty
discovery fails. Exit codes: 0 all pass, 1 verification fails, 2 infrastructure
or usage fails. Programs under test run as local processes on the VM. File and
output rules shared with unit tests: `testing.md`.

English syntax: `Feature`, one optional `Background` before scenarios,
`Scenario`/`Example`, `Scenario Outline` plus `Examples`, and
`Given`/`When`/`Then`/`And`/`But`. Each Examples row becomes a scenario,
substituting `<column>` in names, steps, Doc Strings and tables; its name ends
with ` (values)` of the columns the name does not show (`Name (sqlite, 42)`).
Any other `<...>` (`#include <stdio.h>`, HTML) stays as written, so a
misspelled column is not a parse error: the step is undefined.
Comments, tags and descriptions before steps are accepted; only `--tags` uses
tags. `Rule`, `*`, other keyword aliases and localized syntax fail explicitly.
`And`/`But` inherit the previous kind. Triple-quote Doc Strings are dedented;
include a final empty line to keep a trailing newline. Data Tables decode `\|`,
`\\`, `\n`. One argument per step.

Predefined step patterns (the keyword is irrelevant for matching):

```text
the environment variable {string} is {string}      env of the program, before it starts (a name again replaces)
the program argument {string}                      one more System.args entry, in order, before it starts
the Agentica program {string}                      candidate .agc path, relative to the feature
I send a line:                                     Doc String, then LF and flush
I send the line {string}                           quoted text, then LF and flush
I send input:                                      literal Doc String and flush
I close stdin                                      EOF (closing twice is fine)
I receive a line within {int} milliseconds:        expected Doc String
I receive the line {string} within {int} milliseconds   expected quoted text
I receive a JSON line within {int} milliseconds:   expected JSON Doc String; key order ignored
stdin remains open                                 input open and program active
the program exits with code {int} within {int} milliseconds   wait and check the exit code
stdout is: / stderr is:                            after exit: the stdout no line step read yet / all of stderr
stdout includes: / stderr includes:                after exit: the same text contains the Doc String (substring; empty is RUNTIME-BDD-CONTEXT)
```

## Step programs

A step program is a normal program: `main` builds a list of steps and passes it
to `BDD.run`. Other files are imported from it.

```ruby
import BDD from "std/bdd"

def remember(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, "count", JSON.from(args[0].to_i!))
end

def check_count(ctx: BDD.Context, args: List[String]) -> BDD.Context
  count = JSON.int(BDD.get(ctx, "count").unwrap!).unwrap!
  return BDD.assert(ctx, count == args[0].to_i!, "wrong count")
end

def main() -> Void
  limit = 5
  BDD.run([
    BDD.step("I remember {int}", &remember),
    BDD.step("the count is {int}", &check_count),
    BDD.step("{int} is small") do |ctx, args|
      BDD.assert(ctx, args[0].to_i! < limit, "too big")
    end,
  ])
end
```

```text
BDD.step(pattern: String, handler: Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step
BDD.run(steps: List[BDD.Step]) -> Void
BDD.doc_string(ctx: BDD.Context) -> String
BDD.table(ctx: BDD.Context) -> List[List[String]]
BDD.assert(ctx: BDD.Context, condition: Bool, message: String) -> BDD.Context
BDD.skip(ctx: BDD.Context, reason: String) -> BDD.Context
BDD.set(ctx: BDD.Context, name: String, value: Json) -> BDD.Context
BDD.get(ctx: BDD.Context, name: String) -> Result[Json]
BDD.keep(ctx: BDD.Context, name: String, service: Fn[Json, Result[Json]]) -> BDD.Context
BDD.call(ctx: BDD.Context, name: String, request: Json) -> Result[Json]
BDD.read_line(ctx: BDD.Context, timeout_ms: Int) -> Result[String]
BDD.after(ctx: BDD.Context, hook: Fn[BDD.Context, Result[Void]]) -> BDD.Context
BDD.given_env(ctx, name, value) / given_argument(ctx, value) / given_program(ctx, path)
BDD.when_line(ctx, text) / when_input(ctx, text) / when_eof(ctx)
BDD.then_line(ctx, expected, timeout_ms) / then_json_line(ctx, expected, timeout_ms)
BDD.then_stdin_open(ctx) / then_exit(ctx, code, timeout_ms)
BDD.then_stdout(ctx, expected) / then_stderr(ctx, expected)
BDD.then_stdout_includes(ctx, expected) / then_stderr_includes(ctx, expected)
```

- The context rule: most BDD calls take the scenario's `ctx` first and return
  it; use the one they return. `BDD.doc_string`, `BDD.table`, `BDD.get`,
  `BDD.call` and `BDD.read_line` take it and return their value (`started =
  BDD.given_program(ctx, "../app.agc")`, then `BDD.when_line(started, "hi")`).
  A handler returns the context it ends with; the next step gets it. Only
  `set`, `keep`, `after`, `given_env`, `given_argument` and `given_program`
  change it, but any BDD call can end a
  handler or block. `BDD.Context` can be named, not built.
- State that is not JSON (an open connection) goes in a service: `BDD.keep(ctx,
  "db", service)` with a block `do |request| ... end` that captures the value
  and answers a JSON request with a `Result[Json]`; a later step runs it with
  `BDD.call(ctx, "db", request)` (an error for a missing name). Services start
  empty in each scenario. Keeping a name again replaces the service; the old
  handle lives until the scenario ends (or close it in a `BDD.after` hook).
- `BDD.after(ctx, hook)` registers a cleanup that runs when the scenario ends,
  also after a failure or `BDD.skip`, last registered first, in the scenario's
  child before its program is stopped. Register it in the step that makes the
  thing to clean. The hook gets the final context (use it for `BDD` calls) and
  returns `ok()` or `error(message)`; a hook that returns an error, crashes or
  fails a `BDD` check (on any context) fails a passing scenario
  (`RUNTIME-BDD-AFTER`) or is added to the message of a failing one, and the
  other hooks still run. No hook runs when the child itself ends: a step that
  crashes (`.unwrap!` on an error), `System.exit`, the 30 s limit. Hooks run
  before the program under test stops (Windows may not remove a folder it still
  holds). A hook lives in the context `BDD.after` returns: a failure on an older
  context does not run it.
- `BDD.given_env` and `BDD.given_argument` (or the steps) come before
  `BDD.given_program` (`RUNTIME-BDD-CONTEXT` after): the variable and arguments
  reach only that scenario's program. A scenario starts one program; a peer (an
  SMTP server the program sends to) is started by a step with
  `Process.spawn_captured` in the handler itself (not in a `Task.spawn`: a
  program stops with the task that started it), kept with `BDD.keep` and read
  through `BDD.call`; it stops with the scenario, also a failed one, and a read
  that times out kills it. What the program needs from it goes in
  `BDD.given_env` before `BDD.given_program`. A NUL
  byte or a name the VM owns (`AGENTICA_CHANNEL`, `AGENTICA_VM_METRICS`,
  `AGENTICA_VM_METRICS_FILE`, `UV_USE_IO_URING`) is `RUNTIME-BDD-CONTEXT`; on
  Windows `Path` and `PATH` are one name, so the second replaces the first,
  but `Ä` and `ä` make `BDD.given_program` fail (`RUNTIME-BDD-IO`).
- `BDD.read_line(ctx, timeout_ms)` returns the program's next output line as a
  `Result[String]` (an error at the end of the output or a timeout). A timeout
  stops the program: later reads, sends and exit checks fail with
  `RUNTIME-BDD-IO`, so it must be its last use.
- `BDD` is not a builtin: without the import `BDD.step` is `CHECK-UNKNOWN-NAME`
  with the import as help. `BDD.run` adds the predefined steps in front and
  never returns; run directly, a step program exits 2 with a hint.
- `main` runs once to list the steps and once in each scenario's child: only
  build the list there; its output goes nowhere.
- Patterns are literal text plus `{string}` and `{int}`; unknown captures and
  duplicate patterns (predefined ones too) are file errors of the step program,
  and no scenario runs. Ambiguous or undefined steps fail their scenario.
  Captures are strings in order; quoted strings lose delimiters and unescape
  backslash-prefixed characters; decimal integers may have a minus sign.
- The `then_*` checks compare with `Test.eq`: a failure shows `expected` and
  `actual` in the inspect form, each cut at 64 Ki characters.
- Missing Doc Strings/tables fail (`RUNTIME-BDD-CONTEXT`); absent state returns
  an error Result. Every `Then` (And/But included) and every scenario must
  perform a BDD assertion. A BDD failure ends the step at once. `BDD.skip` ends
  it at once too: the scenario is `skipped` with the reason, its later steps are
  `not_executed`, and the exit code stays 0, even when every scenario is
  skipped (CI should check the `skipped` count).
- Each scenario runs in its own child VM with empty state and no program,
  running Background again. A crash, `System.exit` (even 0,
  `RUNTIME-BDD-PREMATURE-EXIT`), step limit or loop fails only that scenario;
  remaining steps are `not_executed`; other scenarios and files continue.
- Handlers may spawn tasks and pass `ctx` in a struct; tasks must end before the
  handler returns (`RUNTIME-BDD-PENDING-TASKS`; `std/bdd` checks
  `Task.pending_count()` after each handler). Assertions in tasks count. A
  context changed in a task is lost unless taken back from `Task.await`. A task
  that crashed unawaited fails the step with `RUNTIME-TASK-CRASHED`, the crash
  text as its message.
- Handlers and programs under test can call `Process.spawn`. A handler's stdin
  is an empty pipe the runner closes at once (reading it gives the end of
  input); the protocol runs on a channel of its own, so a handler may print
  anything (but must not call `Process.parent_read_line` or
  `Process.parent_send`).
- Programs run with host permissions and environment, with the feature directory
  as working directory; BDD gives no filesystem or network isolation. Timeouts
  are positive; a scenario has 30 seconds, program-driving calls without a
  timeout 5 seconds, each scenario child one million steps per step plus one
  million; output is limited to 1 MiB each of unread stdout, stderr and handler
  output per step.
- `--only TEXT` (once, not empty) keeps scenarios and tests whose name contains
  `TEXT`; no match is `CHECK-BDD-EMPTY`. `--tags EXPR` (once) keeps the
  scenarios whose tags match: `@a`, `not @a`, joined with `and` and `or` (`not`
  before `and` before `or`; no parentheses). A scenario has its Feature's tags,
  its own and its `Examples` block's; unit tests have none, so `--tags` leaves
  them out. A bad expression is `RUNTIME-BDD-USAGE`; none kept is
  `CHECK-BDD-EMPTY`. `--jobs N` (once, 1 to 1024, default 1; else
  `RUNTIME-BDD-USAGE`) runs up to `N` files at once, never the scenarios of
  one file; the report keeps the file order. Files that share a port, a path
  or a database need `--jobs 1`; a high `N` makes per-test timeouts likelier
  under CPU load. `--timing` adds the time of each file and of the 5 slowest
  scenarios. `--coverage` writes the line coverage to `coverage/lcov.info`
  (LCOV), without the test files, the step programs and the programs that a
  step starts, and prints a summary; a failing run still writes it, and a
  report that cannot be written fails the run (`RUNTIME-INTERNAL`). Without
  `--seed N` every child shares the seed the runner drew
  (`testing.md`). A `*_test.agc` file in `specs/` is a
  test file: a helper with that name fails with `RUNTIME-TEST-RUN`. Use port 0
  and fresh temporary directories, not fixed names.
- To run a suite from a program, start `agentica test --json` with
  `Process.spawn` and parse its report.

## Diagnostics

`agentica test` reports the first problem of each kind with a stable code:

- `PARSE-GHERKIN-*`: the `.feature` file breaks the supported Gherkin subset
  (section order, a step outside a scenario, a misplaced Doc String, table or
  tag, bad Examples, an empty Feature or Background, a non-English keyword).
- `CHECK-BDD-UNDEFINED`, `CHECK-BDD-AMBIGUOUS`, `CHECK-BDD-EMPTY`: no step
  pattern matches; more than one matches; no `.feature` or `*_test.agc` files
  found (or no name matches `--only`).
- `RUNTIME-BDD-ASSERTION`, `RUNTIME-BDD-NO-ASSERTION`: an expectation failed; a
  `Then` step or a whole scenario made no BDD assertion.
- `RUNTIME-BDD-TIMEOUT`, `RUNTIME-BDD-PREMATURE-EXIT`: a deadline passed, or a
  bad timeout; a step called `System.exit` or its child ended without a
  diagnostic.
- `RUNTIME-BDD-AFTER`: an after hook failed.
- `RUNTIME-BDD-CONTEXT`, `RUNTIME-BDD-PROGRAM`, `RUNTIME-BDD-JSON`: a missing
  Doc String or table, a stream call before a program started, a second program,
  an environment variable or argument set after it started, a step program that
  never calls `BDD.run`; a missing `.agc` program; a JSON expectation that is
  not valid JSON.
- `RUNTIME-BDD-DUPLICATE`, `RUNTIME-BDD-PATTERN`, `RUNTIME-BDD-PENDING-TASKS`: a
  pattern used twice, an invalid pattern; tasks left running by a handler or by
  `main` before `BDD.run`.
- `RUNTIME-BDD-OUTPUT-LIMIT`, `RUNTIME-BDD-IO`, `RUNTIME-BDD-INFRA`,
  `RUNTIME-BDD-USAGE`: output over 1 MiB; a stream I/O failure; a missing
  executable, VM or feature path or an unreadable step program; bad
  command-line usage, such as two `--steps`.

A step program that does not compile is a file error with its own diagnostic. A
crash in a step keeps the VM's code and its span in the step program; BDD
failures are located at the feature step.
