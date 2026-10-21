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

Exit code `0`: every scenario passes. `1`: one fails. `2`: the tests could not run (also a shared temporary directory without the sticky bit: set `TMPDIR` to a private folder).

- `--ai` and `--json` change the report format. `--only TEXT` keeps scenarios and tests whose name contains `TEXT`.
- `--seed N` makes `Random` repeat in steps and programs. Without it, the runner draws one seed for every step program and program under test, and shows it when the run fails.
- It also runs `*_test.agc` unit test files ([Test](/library/testing/test/)) in the same report. With no paths it searches `specs/` and `test/`.

## Built-in steps

No code needed. `{string}` is text in double quotes, `{int}` a whole number.

| Step | Does |
|---|---|
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

`Given`, `When`, `Then`, `And` and `But` match the same steps. `Background`, `Scenario Outline` with `Examples`, Doc Strings (`"""`) and Data Tables work.

## Your own steps

A step program builds a list with `BDD.step` in `main` and passes it to `BDD.run`. Load it with `--steps`:

```sh
agentica test specs/ --steps steps.agc
```

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
  BDD.run([
    BDD.step("I remember {int}", &remember),
    BDD.step("the count is {int}", &check_count),
  ])
end
```

```gherkin
Feature: Memory

  Scenario: Remember a number
    When I remember 3
    Then the count is 3
```

- A step gets the scenario's context `ctx` and returns it; the next step gets what the previous one returned. Most `BDD` calls take and return the context: keep the one returned. `BDD.doc_string`, `BDD.table` and `BDD.get` return their value instead. Every `Then` step must make at least one `BDD` check.
- Each scenario runs in its own process, so a crash, `System.exit` or an endless loop fails only its scenario. A step must finish the tasks it starts (`RUNTIME-BDD-PENDING-TASKS`); an unawaited crash fails it with `RUNTIME-TASK-CRASHED`.
- `main` runs again for each scenario, so it should only build the list and call `BDD.run`. Run alone, a step program prints how to run it and exits with code 2.
- A step may import files and use `Process.spawn`. Its standard input is empty (`IO.gets` gives the end-of-input error). It must not call `Process.parent_read_line` or `Process.parent_send`: they belong to the runner.

## BDD.step and BDD.run

```text
BDD.step(pattern: String, handler: Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step
BDD.run(steps: List[BDD.Step]) -> Void
```

The handler gets the context and the `{string}` and `{int}` captures as strings, in order. A block works too and sees the variables around it:

```agentica {mode="check"}
import BDD from "std/bdd"

def main() -> Void
  answer = "42"
  BDD.run([
    BDD.step("the answer is {int}") do |ctx, args|
      BDD.assert(ctx, args[0] == answer, "wrong answer")
    end,
  ])
end
```

`BDD.run` puts the built-in steps in front of the list, runs what `agentica test` asks for, and never returns.

## BDD.assert

```text
BDD.assert(ctx: BDD.Context, condition: Bool, message: String) -> BDD.Context
```

Fails the scenario with the message when the condition is `false`.

## BDD.set and BDD.get

```text
BDD.set(ctx: BDD.Context, name: String, value: Json) -> BDD.Context
BDD.get(ctx: BDD.Context, name: String) -> Result[Json]
```

Keep JSON values between the steps of one scenario (each starts empty). `BDD.get` gives an error for a missing name.

## BDD.doc_string and BDD.table

```text
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
  BDD.run([
    BDD.step("the table has two rows:", &check_rows),
    BDD.step("I send the record:", &send_body),
  ])
end
```

## Driving the program

```text
BDD.given_program(ctx: BDD.Context, path: String) -> BDD.Context
BDD.when_line(ctx: BDD.Context, text: String) -> BDD.Context
BDD.when_input(ctx: BDD.Context, text: String) -> BDD.Context
BDD.when_eof(ctx: BDD.Context) -> BDD.Context
BDD.then_line(ctx: BDD.Context, expected: String, timeout_ms: Int) -> BDD.Context
BDD.then_json_line(ctx: BDD.Context, expected: String, timeout_ms: Int) -> BDD.Context
BDD.then_stdin_open(ctx: BDD.Context) -> BDD.Context
BDD.then_exit(ctx: BDD.Context, code: Int, timeout_ms: Int) -> BDD.Context
BDD.then_stdout(ctx: BDD.Context, expected: String) -> BDD.Context
BDD.then_stderr(ctx: BDD.Context, expected: String) -> BDD.Context
```

The built-in steps as functions, to combine in your own steps. Pass on the context `BDD.given_program` returns: it holds the program.

`stdout is:` compares the output that no line step has read yet. Output is kept up to 1 MiB per stream.

A failed `then_*` check reports `expected` and `actual` in the inspect form, as `Test.eq` does: a line or output in quotes, an exit code as a number, a JSON line as its sorted-key text. An undefined or ambiguous step's `actual` is the step text in quotes. Text over 64 Ki characters is cut and ends with `...` and the count left out. A front-end error of the step program keeps the raw type names (`Int`, `String`), so its `--json` form depends on the code.

## Running tests from a program

No function runs features from a program. Start `agentica test --json` with `Process.spawn` and read its report.
