---
title: BDD
weight: 13
description: Test programs with Gherkin feature files and the agentica test command.
---

`agentica test` runs `.feature` files written in Gherkin. Each scenario starts
your program as a separate process, sends it input and checks its output.

## A first feature

Here is a program that greets the name it reads, saved as `greet.agc`:

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

And a feature file next to it, `specs/greet.feature`:

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

The exit code is `0` when every scenario passes, `1` when one fails, and `2`
when the tests could not run. `--ai` and `--json` change the report format.

## Built-in steps

These steps work without any code. `{string}` is text in double quotes and
`{int}` is a whole number.

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
| `stdout is:` / `stderr is:` | compares all the output after the program ends |

`Given`, `When`, `Then`, `And` and `But` all match the same steps.
`Background`, `Scenario Outline` with `Examples`, Doc Strings (`"""`) and
Data Tables are supported.

## Your own steps

Write steps in Agentica. A step file has a `main` that only registers steps
with `BDD.step`. Load it with `--steps`:

```sh
agentica test specs/ --steps steps.agc
```

```agentica {mode="check"}
def remember(args: List[String]) -> Void
  BDD.set("count", JSON.from(String.to_int!(args[0])))
end

def check_count(args: List[String]) -> Void
  count = JSON.int(BDD.get("count").unwrap!).unwrap!
  BDD.assert(count == String.to_int!(args[0]), "wrong count")
end

def main() -> Void
  BDD.step("I remember {int}", &remember)
  BDD.step("the count is {int}", &check_count)
end
```

```gherkin
Feature: Memory

  Scenario: Remember a number
    When I remember 3
    Then the count is 3
```

Every `Then` step must make at least one check with a `BDD` function.

## BDD.step

```text
BDD.step(pattern: String, handler: Fn[List[String], Void]) -> Void
```

Registers a step. The handler gets the `{string}` and `{int}` captures as
strings, in order. A block works too:

```agentica {mode="check"}
def main() -> Void
  BDD.step("the answer is {int}") do |args|
    BDD.assert(args[0] == "42", "wrong answer")
  end
end
```

## BDD.assert

```text
BDD.assert(condition: Bool, message: String) -> Void
```

Fails the scenario with the message when the condition is `false`.

## BDD.set and BDD.get

```text
BDD.set(name: String, value: Json) -> Void
BDD.get(name: String) -> Result[Json]
```

Keep JSON values between the steps of one scenario. Each scenario starts
empty; a missing name gives an error Result.

## BDD.doc_string and BDD.table

```text
BDD.doc_string() -> String
BDD.table() -> List[List[String]]
```

Read the Doc String or the Data Table under the current step.

```agentica {mode="check"}
def check_rows(args: List[String]) -> Void
  rows = BDD.table()
  BDD.assert(rows.size == 3, "expected a header and two rows")
end

def send_body(args: List[String]) -> Void
  BDD.when_line(BDD.doc_string())
end

def main() -> Void
  BDD.step("the table has two rows:", &check_rows)
  BDD.step("I send the record:", &send_body)
end
```

## Driving the program

```text
BDD.given_program(path: String) -> Void
BDD.when_line(text: String) -> Void
BDD.when_input(text: String) -> Void
BDD.when_eof() -> Void
BDD.then_line(expected: String, timeout_ms: Int) -> Void
BDD.then_json_line(expected: String, timeout_ms: Int) -> Void
BDD.then_stdin_open() -> Void
BDD.then_exit(code: Int, timeout_ms: Int) -> Void
BDD.then_stdout(expected: String) -> Void
BDD.then_stderr(expected: String) -> Void
```

These do what the built-in steps do, so your own steps can combine them:

```agentica {mode="check"}
def ask(args: List[String]) -> Void
  BDD.given_program("../greet.agc")
  BDD.when_line(args[0])
end

def greeted(args: List[String]) -> Void
  BDD.then_line("Hello, #{args[0]}!", 2000)
  BDD.then_exit(0, 2000)
end

def main() -> Void
  BDD.step("I greet {string}", &ask)
  BDD.step("{string} is greeted", &greeted)
end
```

## BDD.run

```text
BDD.run(feature_path: String, step_files: List[String]) -> Result[Json]
```

Runs features from a program and gives the report as JSON. The `ok` field of
the report says whether every test passed.

```agentica {mode="check"}
def main() -> Void
  report = BDD.run("specs", ["steps.agc"]).unwrap!
  passed = JSON.bool(report.get("ok").unwrap!).unwrap!
  puts(report.get("passed").unwrap!)
  if !passed
    System.exit(1)
  end
end
```
