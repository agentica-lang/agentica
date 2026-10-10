# Executable BDD specifications

Agentica runs `.feature` files with predefined steps and optional step definitions written in Agentica. Matching is deterministic: unknown or ambiguous steps fail. Programs under test run as local processes.

## Run

```sh
make exe
dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc
dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc --json
dist/agentica --ai test tests/bdd/specs/json-lines.feature
make test-bdd
```

`make exe` builds the CLI. You can also run `racket src/main.rkt test tests/bdd/specs/ --steps tests/bdd/handlers.agc` directly from source. `make test` compiles the CLI modules before running local process integration tests and supports parallel workers with `JOBS=N`; this keeps initial module compilation outside BDD response deadlines. `make test-bdd` builds and checks the compiled CLI against the feature suite. Running `agentica test` does not install or build anything.

With no paths, `agentica test` searches `specs/`. Directories are searched recursively for `.feature` files, with duplicate paths removed and files sorted. Explicit files are also accepted. `--steps FILE` is repeatable and can precede `test` or follow it.

Exit codes are 0 when everything passes, 1 for verification failures or an empty suite, and 2 for missing paths or unavailable infrastructure. Plain, `--ai`, and `--json` expose the same verdict. The JSON report includes `ok`, `passed`, `failed`, `not_executed`, `file_errors`, `exit_code`, and `files`; each scenario includes its steps, locations, optional Examples row, duration, and diagnostic. Reports contain no candidate or handler output other than diagnostic expected/actual values. Handler output is suppressed and bounded.

## Feature files

```gherkin
Feature: JSON Lines replies

  Background:
    Given the Agentica program "../examples/json-lines.agc"

  Scenario: Reply before stdin closes
    When I send a line:
      """
      {"name":"Ana","score":80,"active":true}
      """
    Then I receive a JSON line within 1000 milliseconds:
      """
      {"name":"Ana","passed":true}
      """
    And stdin remains open
    When I close stdin
    Then the program exits with code 0 within 5000 milliseconds
```

The parser supports English `Feature`, `Background`, `Scenario`/`Example`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And`, and `But`. `And`/`But` inherit the preceding step kind. One Background runs before each scenario. Each Examples row becomes an independent scenario, replacing `<column>` in the name, step text, Doc Strings, and tables. Missing columns, empty scenarios, or outlines without rows fail.

Comments start with `#`; `# language: en` is accepted. Tags on features, scenarios, and Examples are preserved in reports and never skip tests. Descriptions before steps are accepted. `Rule`, `*`, localized keywords, backtick Doc Strings, and the other keyword aliases are unsupported and fail explicitly. No tag filtering or pending scenarios are provided.

A step accepts one `"""` Doc String, optionally with a media type, or one rectangular Data Table. Doc Strings are dedented relative to their opening delimiter and joined with LF. To expect a final newline, include an empty line before the closing delimiter. Table cells trim surrounding whitespace and decode `\|`, `\\`, and `\n`.

Paths to programs under test are relative to the feature file. CLI paths and handler files are relative to the working directory. Programs run with the feature's directory as their working directory.

## Predefined steps

Step keywords do not affect matching. These exact patterns are available without handler files:

| Pattern | Argument / effect |
| --- | --- |
| `the Agentica program {string}` | Start one local `.agc` process |
| `I send a line:` | Doc String; append LF and flush |
| `I send the line {string}` | Append LF and flush |
| `I send input:` | Doc String; send literally and flush |
| `I close stdin` | Send EOF |
| `I receive a line within {int} milliseconds:` | Doc String; compare next line without its terminator |
| `I receive the line {string} within {int} milliseconds` | Compare next line |
| `I receive a JSON line within {int} milliseconds:` | Doc String; structured JSON comparison |
| `stdin remains open` | Check input is open and the process active |
| `the program exits with code {int} within {int} milliseconds` | Wait for and compare exit code |
| `stdout is:` | Doc String; compare complete stdout after exit |
| `stderr is:` | Doc String; compare complete stderr after exit |

Object key order does not affect JSON equality. Arrays retain order; value kinds remain distinct. Timeouts must be positive integers.

## Custom steps

Use `agentica --allow-run test ...` or `agentica test ... --allow-run` when
handlers or programs under test call `Process.spawn`. The allowance reaches
both; the BDD runner's existing program launch does not itself grant it.

```ruby
def submit_record(args: List[String]) -> Void
  BDD.when_line(BDD.doc_string())
end

def main() -> Void
  BDD.step("I submit a score record", &submit_record)
end
```

Load this file explicitly with `--steps FILE`. Its `main() -> Void` registers callbacks once; the callback runs for each matching step. Callback functions have type `Fn[List[String], Void]`. Patterns support literal text, `{string}` for single/double quoted strings, and `{int}` for decimal digits with an optional minus sign. Captures arrive as strings in order; quoted captures remove delimiters and unescape backslash-prefixed characters. This is a small pattern language, not the full Cucumber Expressions syntax.

```text
BDD.step(pattern: String, handler: Fn[List[String], Void]) -> Void
BDD.doc_string() -> String
BDD.table() -> List[List[String]]
BDD.assert(condition: Bool, message: String) -> Void
BDD.set(name: String, value: Json) -> Void
BDD.get(name: String) -> Result[Json]
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

A step can also be a block: `BDD.step("{int} is small") do |args| ... end`. The block runs in each scenario's own evaluation, so it should capture data only (strings, numbers, lists), not files, processes or connections opened during registration.

Only registration allows `BDD.step`; actions, state, and assertions require a running scenario. Missing Doc Strings/tables fail; missing state returns an error Result. A second program start, an unknown pattern, or multiple matching definitions fail. Every `Then` step, including its following `And`/`But`, must perform at least one BDD assertion; every scenario must perform a check. Handler calls to `System.exit`, including code zero, fail. Calling `BDD.run` recursively from handlers is unavailable.

## Run from Agentica

Registration and step handlers support Task.spawn and Task.await. Every invocation supervises its tasks with one shared million-step budget. Finish pending work before returning; otherwise RUNTIME-BDD-PENDING-TASKS fails that handler. A child diagnostic or System.exit stops the evaluation and later scenarios continue. Child assertions count toward the current Then step; Doc Strings and tables belong to that same step.

Registration duplicate checks, scenario state and assertion counters are atomic. Stdin writes/close and stdout reads use independent locks, so a receive task can wait while another sends. Operations on the same stream serialize; timeout includes waiting for the lock. Startup serializes; streams used before it completes fail with RUNTIME-BDD-CONTEXT. Operation workers stay inside the task/timeout scope and are cancelled before the next step. Handler output remains suppressed and bounded across tasks.

```ruby
def main() -> Void
  result = BDD.run("specs/", ["steps.agc"])
  if not Result.ok?(result)
    IO.warn(Result.message(result))
    System.exit(2)
  end
  report = Result.unwrap!(result)
  puts(JSON.encode(report))
  passed = Result.unwrap!(JSON.bool(Result.unwrap!(JSON.get(report, "ok"))))
  if not passed
    System.exit(1)
  end
end
```

`BDD.run(feature_path: String, step_files: List[String]) -> Result[Json]` accepts a file or directory. Verification failures return a successful Result containing `ok: false`; infrastructure failures return an error Result. Inspect the report's `ok`, not only `Result.ok?`. The CLI always enforces the report's exit code.

## Process lifetime and failure handling

Scenarios run sequentially with fresh JSON state and a fresh process. A failure stops only the current scenario; remaining steps are reported as `not_executed`, then the next scenario runs. Step definitions are resolved before starting a scenario. Syntax errors fail their file and leave other files runnable; a failing handler file contributes a file error while other valid handlers remain available.

Programs run with the host user's permissions and inherited environment, using the same Agentica executable as the verifier. Source execution launches Racket with `src/main.rkt`. BDD does not provide filesystem, environment or network isolation.

Each scenario has a 30-second wall-clock deadline. Operations without an explicit timeout get 5 seconds; every evaluator invocation gets one million steps. Stdout and stderr are drained concurrently and each capped at 1 MiB; handler output is also bounded. Processes, ports and stream workers are cleaned up after success, failure, timeout, or interruption. These checks enforce the behaviors specified; they cannot prove coverage of requirements nobody expressed.
