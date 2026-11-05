---
title: BDD
weight: 2
description: Test programs with Gherkin feature files and the agentica test command.
---

`agentica test` runs Gherkin `.feature` files. Each scenario starts your program as a separate process, sends it input and checks its output.

## A first feature

`greet.agc` greets the name it reads:

```agentica
def main() -> Void
  name = gets!.strip
  puts("Hello, #{name}!")
end
```

```input
Ana
```

```output
Hello, Ana!
```

`specs/greet.feature`:

```gherkin
Feature: Greeting

  Scenario: Greet by name
    Given the Agentica program "../greet.agc"
    When I send the line "Ana"
    Then I receive the line "Hello, Ana!" within 5000 milliseconds
    And the program exits with code 0 within 5000 milliseconds
```

Run it:

```sh
agentica test specs/
```

Exit code `0`: every scenario passes or is skipped (also when all are skipped, so a CI job should check that the `skipped` count is the one it expects). `1`: one fails. `2`: the tests could not run (also a shared temporary directory without the sticky bit: set `TMPDIR` to a private folder).

- `--ai` and `--json` change the report format. `--only TEXT` keeps scenarios and tests whose name contains `TEXT`.
- `--tags EXPR` keeps the scenarios whose tags match: `@a`, `not @a`, joined with `and` and `or` (`not` binds tighter than `and`, and `and` tighter than `or`; no parentheses), as in `--tags "@db and not @slow"`. A scenario has the tags of its Feature and itself, and a `Scenario Outline` row also those of its `Examples` block. Unit test files have no tags, so they are left out. A bad expression exits with `2`.
- `--jobs N` (1 to 1024, default 1) runs up to `N` test files at the same time, each in its own process. Scenarios of one file still run one after another, and the report lists the files in the same order as without it. Files that share a port, a path or a database need `--jobs 1`. A bad value exits with `2`.
- A failed step is reported at its line and column in the feature file.
- Each row of a `Scenario Outline` is named with the outline name and the row's values in the columns the name does not show, such as `Name (sqlite, 42)`, so `--only "(sqlite, 42)"` selects one row. Identical rows keep one name; `--json` has each row's line in `example`.
- `--seed N` makes `Random` repeat in steps and programs. Without it, the runner draws one seed for every step program and program under test, and shows it when the run fails.
- It also runs `*_test.agc` unit test files ([Test](/library/testing/test/)) in the same report. With no paths it searches `specs/` and `test/`.

## Built-in steps

No code needed. `{string}` is text in double quotes, `{int}` a whole number.

| Step | Does |
|---|---|
| `the environment variable {string} is {string}` | sets a variable for the program, before it starts |
| `the program argument {string}` | adds a command-line argument for the program, before it starts |
| `the Agentica program {string}` | starts the program, a path relative to the feature file |
| `I send the line {string}` | sends the text and a new line |
| `I send a line:` | sends the Doc String below and a new line |
| `I send input:` | sends the Doc String below as it is |
| `I close stdin` | closes the program's input |
| `I receive the line {string} within {int} milliseconds` | checks the next output line |
| `I receive a line within {int} milliseconds:` | checks the next line against the Doc String |
| `I receive a JSON line within {int} milliseconds:` | compares the next line as JSON, in any key order |
| `stdin remains open` | checks that the program still runs |
| `the program exits with code {int} within {int} milliseconds` | waits for the exit code |
| `stdout is:` / `stderr is:` | after the program ends, compares the stdout that no line step has read yet, or all of stderr |
| `stdout includes:` / `stderr includes:` | after the program ends, checks that the same text contains the Doc String as a substring |

`Given`, `When`, `Then`, `And` and `But` match the same steps. `Background`, `Scenario Outline` with `Examples`, Doc Strings (`"""`) and Data Tables work. A `<...>` in an outline is replaced when it names an `Examples` column; any other `<...>` is `PARSE-GHERKIN-PARAMETER` unless it holds `=`, a quote or `/`, as `<input type="text">` and `<br/>` do, and then it stays as written (a bare tag such as `<br>` or `<p>` still fails: write `<br/>`, or put the tag in a column).

## Environment and arguments

The two steps before `the Agentica program` give the program its environment and its `System.args`:

```gherkin
Scenario Outline: Greet in a language
  Given the environment variable "GREETING" is "<greeting>"
  And the program argument "--name"
  And the program argument "<name>"
  And the Agentica program "../greet.agc"
  Then I receive the line "<line>" within 5000 milliseconds

  Examples:
    | greeting | name | line      |
    | Hola     | Ana  | Hola, Ana |
```

- A variable is added to the environment `agentica test` runs in; the program sees the others as they are. Setting a name again replaces its value. The variable reaches only the program of that scenario: not the runner, and no other scenario.
- Each `the program argument` adds one argument, in order, with no splitting on spaces: `"a b"` is one argument. The program reads them with `System.args`.
- Both come before `the Agentica program`; after it they fail with `RUNTIME-BDD-CONTEXT`, since the program has already started. A variable name must be nonempty and cannot contain `=`, a name or value cannot contain a NUL byte, and `AGENTICA_CHANNEL`, `AGENTICA_VM_METRICS`, `AGENTICA_VM_METRICS_FILE` and `UV_USE_IO_URING`, which the VM owns, cannot be set: each is `RUNTIME-BDD-CONTEXT`. On Windows names ignore case, so `Path` and then `PATH` set one variable, to the second value; two names that differ only in the case of a letter outside ASCII, such as `Ä` and `ä`, make `the Agentica program` fail with `RUNTIME-BDD-IO`.
- A scenario starts one program. To run it again with other values, write another scenario (an outline row is one). For a peer that runs beside the program, see [A peer program](#a-peer-program).

## Your own steps

A step program builds a list with `BDD.step` in `main` and passes it to `BDD.run`. Most `BDD.*` functions take the context first and return it. `BDD.Context` can be named but not built: a context exists only inside a step, so use the context that a call returns. The modules `std/bdd/gherkin`, `std/bdd/match`, `std/bdd/tags`, `std/test/report` and `std/test/runner` are internal to `agentica test` and unsupported. Load the steps with `--steps`:

```sh
agentica test specs/ --steps steps.agc
```

Without `--steps`, `agentica test` uses the nearest `steps.agc` found in the folder of each path that holds a `.feature` file (the path itself if it is a folder) or above it, up to the working directory, so `specs/steps.agc` needs no flag, also for `specs/auth/` or `specs/a.feature`. It applies only to a run with `.feature` files. If the paths lead to two different `steps.agc` files, the run fails with `RUNTIME-BDD-USAGE`; pass `--steps`. `--steps` overrides it.

```agentica {mode="check"}
import BDD from "std/bdd"

def remember(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, "count", JSON.from(String.to_int!(args[0])))
end

def check_count(ctx: BDD.Context, args: List[String]) -> BDD.Context
  count = JSON.int(BDD.get(ctx, "count").unwrap!).unwrap!
  return BDD.assert(ctx, count == String.to_int!(args[0]), "wrong count")
end

def main() -> Void
  BDD.run([BDD.step("I remember {int}", &remember), BDD.step("the count is {int}", &check_count)])
end
```

```gherkin
Feature: Memory

  Scenario: Remember a number
    When I remember 3
    Then the count is 3
```

- A step gets the scenario's context `ctx` and returns it; the next step gets what the previous one returned. Most `BDD` calls take and return the context: keep the one returned. `BDD.doc_string`, `BDD.table`, `BDD.get`, `BDD.call` and `BDD.read_line` return their value instead. Every `Then` step must make at least one `BDD` check.
- Each scenario runs in its own process, so a crash, `System.exit` or an endless loop fails only its scenario. A step must finish the tasks it starts (`RUNTIME-BDD-PENDING-TASKS`); an unawaited crash fails it with `RUNTIME-TASK-CRASHED`.
- `main` runs again for each scenario, so it should only build the list and call `BDD.run`. Run alone, a step program prints how to run it and exits with code 2.
- A step may import files and use `Process.spawn`. Its standard input is empty (`IO.gets` gives the end-of-input error). It must not call `Process.parent_read_line` or `Process.parent_send`: they belong to the runner.

## BDD.step and BDD.run

```signature
BDD.step(pattern: String, handler: Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step
BDD.run(steps: List[BDD.Step]) -> Void
```

The handler gets the context and the `{string}` and `{int}` captures as strings, in order. A block works too and sees the variables around it:

```agentica {mode="check"}
import BDD from "std/bdd"

def main() -> Void
  answer = "42"
  BDD.run([BDD.step("the answer is {int}") do |ctx, args| BDD.assert(ctx, args[0] == answer, "wrong answer") end])
end
```

`BDD.run` puts the built-in steps in front of the list, runs what `agentica test` asks for, and never returns.

## BDD.assert

```signature
BDD.assert(ctx: BDD.Context, condition: Bool, message: String) -> BDD.Context
```

Fails the scenario with the message when the condition is `false`.

## BDD.skip

```signature
BDD.skip(ctx: BDD.Context, reason: String) -> BDD.Context
```

Ends the step and its scenario as skipped, with the reason in the report: the later steps do not run, and the run still passes. Use it when a scenario needs something the machine lacks.

```agentica {mode="check"}
import BDD from "std/bdd"

def need_postgres(ctx: BDD.Context, args: List[String]) -> BDD.Context
  if System.env("POSTGRES_URL").ok?
    return ctx
  end

  return BDD.skip(ctx, "POSTGRES_URL is not set")
end

def main() -> Void
  BDD.run([BDD.step("a PostgreSQL server", &need_postgres)])
end
```

The report shows `SKIP`, the summary counts `skipped`, and `--json` gives `"status": "skipped"` and the `reason`. Combine it with a tag, such as `@postgres`, and `--tags "not @postgres"` leaves those scenarios out altogether.

## BDD.set and BDD.get

```signature
BDD.set(ctx: BDD.Context, name: String, value: Json) -> BDD.Context
BDD.get(ctx: BDD.Context, name: String) -> Result[Json]
```

Keep JSON values between the steps of one scenario (each starts empty). `BDD.get` gives an error for a missing name.

## BDD.keep and BDD.call

```signature
BDD.keep(ctx: BDD.Context, name: String, service: Fn[Json, Result[Json]]) -> BDD.Context
BDD.call(ctx: BDD.Context, name: String, request: Json) -> Result[Json]
```

Keep a value that is not JSON between the steps of one scenario, such as an open connection. The service is a function from a request to a result, both JSON, and it captures the value. `BDD.call` runs the service kept under `name`, or gives an error when there is none. Each scenario starts with no services. Keeping a name again replaces the service, and the old handle is not closed until the scenario's process ends (use [BDD.after](#bddafter) to close it sooner). A step cannot leave a task running, so the service does its work in the calling step.

```agentica {mode="check"}
import BDD from "std/bdd"

def open_pair(ctx: BDD.Context, args: List[String]) -> BDD.Context
  listener = TCP.listen("127.0.0.1", 0).unwrap!
  client = TCP.connect("127.0.0.1", TCP.local_port(listener), 5000).unwrap!
  server = TCP.accept(listener, 5000).unwrap!
  return BDD.keep(ctx, "pair") do |request|
    try TCP.send(client, JSON.encode(request) + "\n", 5000)
    JSON.parse(try TCP.read_line(server, 5000))
  end
end

def check_echo(ctx: BDD.Context, args: List[String]) -> BDD.Context
  reply = BDD.call(ctx, "pair", JSON.from(args[0])).unwrap!
  return BDD.assert(ctx, JSON.string(reply).unwrap! == args[0], "wrong reply")
end

def main() -> Void
  BDD.run([BDD.step("a connected pair", &open_pair), BDD.step("the pair echoes {string}", &check_echo)])
end
```

## A peer program

`BDD.given_program` starts one program, and every step that sends, reads or checks talks to it. A second named program would need a name in each of those steps, and a peer needs its own steps anyway (to learn its port, or to read what it received). So a step starts the peer itself with [Process.spawn_captured](/library/io-and-system/process/#processspawn_captured) and keeps the handle with `BDD.keep`. A program started by a step belongs to the scenario and stops when it ends, so no cleanup is needed. Start the peer first, then pass what the program needs from it with `BDD.given_env` or `BDD.given_argument`:

```agentica {mode="check"}
import BDD from "std/bdd"

# ./peer prints the port it listens on, then one line for each message it receives.
def start_peer(ctx: BDD.Context, args: List[String]) -> BDD.Context
  peer = Process.spawn_captured("./peer", [], ".", 5000).unwrap!
  port = Process.read_line(peer, 5000).unwrap!
  kept = BDD.keep(ctx, "peer") do |_request| ok(JSON.from(Process.read_line(peer, 5000).unwrap_or(""))) end
  return BDD.given_env(kept, "PEER_PORT", port)
end

def check_received(ctx: BDD.Context, args: List[String]) -> BDD.Context
  line = JSON.string(BDD.call(ctx, "peer", JSON.null()).unwrap!).unwrap!
  return BDD.assert(ctx, line == args[0], "the peer received #{line.inspect}")
end

def main() -> Void
  BDD.run([BDD.step("a peer", &start_peer), BDD.step("the peer received {string}", &check_received)])
end
```

```gherkin
Scenario: The program talks to the peer
  Given a peer
  And the Agentica program "../app.agc"
  When I send the line "hello"
  Then the peer received "hello"
```

The peer's handle lives in the closure of the service, so a later step reads from it through `BDD.call`, and the read has a timeout so a silent peer fails the step. A read that times out kills the peer, as it does a program under test (see [Process](/library/io-and-system/process/)), so make it the last use. Start the peer in the step handler itself: a program belongs to the task that started it, so one started in a `Task.spawn` stops when that task ends, and a step may not leave a task running.

## BDD.after

```signature
BDD.after(ctx: BDD.Context, hook: Fn[BDD.Context, Result[Void]]) -> BDD.Context
```

Registers a cleanup that runs when the scenario ends, whether it passed, failed or was skipped. A step registers it right after it makes what needs cleaning, so the hook exists only when there is something to clean.

- Hooks run in the reverse order of registration, in the process of the scenario. A hook gets the context the scenario ended with, and returns `ok()` or `error(message)`. Use that context for any `BDD` call in the hook.
- A hook that returns an `error`, crashes or fails a `BDD` check is a failed hook, and the other hooks still run. That holds for a check on any context, also one the hook captured when it was registered. A failed hook fails a scenario that passed, with the code `RUNTIME-BDD-AFTER` at the scenario line. For a scenario that failed, the failure stays the one reported and the message of the hook is added to it.
- Hooks do **not** run when the process of the scenario itself ends: a step that crashes (an `.unwrap!` on an `error`, a division by zero), a step or hook that calls `System.exit`, or the 30 second limit. A scenario that fails by a crash still leaves what it made, so keep a cleanup of stale folders for that case, or make steps return `error` and check it with `BDD.assert` instead of `.unwrap!`.
- Hooks run before the program under test is stopped, and no `BDD` call stops it first. On Windows a folder the program still holds open may not be removable by a hook.
- A hook is kept in the context that `BDD.after` returns. A step that registers a hook and then fails on an older context (`BDD.assert(ctx, ...)` with the `ctx` from before) does not run it: pass on the context that `BDD.after` returned.
- A hook cannot call `BDD.skip`. A hook that fails after `BDD.skip` turns the skipped scenario into a failed one (`RUNTIME-BDD-AFTER`). A hook that never ends is reported when the 30 second limit of the scenario passes.

```agentica {mode="check"}
import BDD from "std/bdd"

def remove(path: String) -> Result[Void]
  return Path.remove(path, 5000)
end

def make_folder(ctx: BDD.Context, args: List[String]) -> BDD.Context
  path = args[0]
  Dir.mkdir(path, 5000).unwrap!
  return BDD.after(ctx) do |_| remove(path) end
end

def main() -> Void
  BDD.run([BDD.step("a folder {string} for this scenario", &make_folder)])
end
```

## BDD.doc_string and BDD.table

```signature
BDD.doc_string(ctx: BDD.Context) -> String
BDD.table(ctx: BDD.Context) -> List[List[String]]
```

Read the Doc String or the Data Table under the current step.

```agentica {mode="check"}
import BDD from "std/bdd"

def check_rows(ctx: BDD.Context, args: List[String]) -> BDD.Context
  rows = BDD.table(ctx)
  return BDD.assert(ctx, rows.size == 3, "expected a header and two rows")
end

def send_body(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.when_line(ctx, BDD.doc_string(ctx))
end

def main() -> Void
  BDD.run([BDD.step("the table has two rows:", &check_rows), BDD.step("I send the record:", &send_body)])
end
```

## Driving the program

```signature
BDD.given_env(ctx: BDD.Context, name: String, value: String) -> BDD.Context
BDD.given_argument(ctx: BDD.Context, value: String) -> BDD.Context
BDD.given_program(ctx: BDD.Context, path: String) -> BDD.Context
BDD.when_line(ctx: BDD.Context, text: String) -> BDD.Context
BDD.when_input(ctx: BDD.Context, text: String) -> BDD.Context
BDD.when_eof(ctx: BDD.Context) -> BDD.Context
BDD.read_line(ctx: BDD.Context, timeout_ms: Int) -> Result[String]
BDD.then_line(ctx: BDD.Context, expected: String, timeout_ms: Int) -> BDD.Context
BDD.then_json_line(ctx: BDD.Context, expected: String, timeout_ms: Int) -> BDD.Context
BDD.then_stdin_open(ctx: BDD.Context) -> BDD.Context
BDD.then_exit(ctx: BDD.Context, code: Int, timeout_ms: Int) -> BDD.Context
BDD.then_stdout(ctx: BDD.Context, expected: String) -> BDD.Context
BDD.then_stderr(ctx: BDD.Context, expected: String) -> BDD.Context
BDD.then_stdout_includes(ctx: BDD.Context, expected: String) -> BDD.Context
BDD.then_stderr_includes(ctx: BDD.Context, expected: String) -> BDD.Context
```

The built-in steps as functions, to combine in your own steps. Pass on the context `BDD.given_program` returns: it holds the program. `BDD.given_env` and `BDD.given_argument` come before `BDD.given_program` and return the context to pass to it.

`BDD.read_line` gives the next output line instead of comparing it, so a step can use it. It is an error when the output ended or no line came within `timeout_ms`; a timeout stops the program under test, as for `BDD.then_line`: every later read, send or exit check fails with `RUNTIME-BDD-IO`, so make it the last use of the program.

`stdout is:` compares the output that no line step has read yet. `stdout includes:` and `stderr includes:` check the same text for a substring, as `String.contains?` does (an empty text is `RUNTIME-BDD-CONTEXT`), so a log scenario can assert one line of a noisy stderr; a failure shows the whole stream as `actual`. All four need the program to have exited. Output is kept up to 1 MiB per stream.

A failed `then_*` check reports `expected` and `actual` in the inspect form, as `Test.eq` does: a line or output in quotes, an exit code as a number, a JSON line as its sorted-key text. An undefined or ambiguous step's `actual` is the step text in quotes. Text over 64 Ki characters is cut and ends with `...` and the count left out. A front-end error of the step program keeps the raw type names (`Int`, `String`), so its `--json` form depends on the code.

## Running tests from a program

No function runs features from a program. Start `agentica test --json` with `Process.spawn` and read its report.
