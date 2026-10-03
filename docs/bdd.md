# Executable BDD specifications

Agentica runs `.feature` files with predefined steps and optional step definitions written in Agentica. Matching is deterministic: unknown or ambiguous steps fail. Specs and handlers are trusted verifier code and must remain outside the candidate's control.

## Run

```sh
make bdd-prepare
dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc
dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc --json
dist/agentica --ai test tests/bdd/specs/json-lines.feature
make test-bdd
```

`bdd-prepare` builds the CLI, uses `raco distribute` to bundle its runtime, and prepares the existing eval Docker image. `test` itself does not install or build anything. Docker is required when a scenario starts a candidate; pure Agentica handlers can run without Docker.

With no paths, `agentica test` searches `specs/`. Directories are searched recursively for `.feature` files, with duplicate paths removed and files sorted. Explicit files are also accepted. `--steps FILE` is repeatable. `--docker-image IMAGE` defaults to `agentica-eval:local`; `--runtime-dir PATH` defaults to `dist/runtime`. These options can precede `test` or follow it. Leading image/runtime options also configure `BDD.run` in an ordinary `.agc` program.

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

Paths to candidate programs are relative to the feature file. CLI paths, handler files, and runtime directories are relative to the working directory.

## Predefined steps

Step keywords do not affect matching. These exact patterns are available without handler files:

| Pattern | Argument / effect |
| --- | --- |
| `the Agentica program {string}` | Start one `.agc` candidate in Docker |
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

```ruby
def submit_record(args: List[String]) -> Nil
  BDD.when_line(BDD.doc_string())
end

def main() -> Nil
  BDD.step("I submit a score record", &submit_record)
end
```

Load this file explicitly with `--steps FILE`. Its `main() -> Nil` registers callbacks once; the callback runs for each matching step. Callback functions have type `Fn[List[String], Nil]`. Patterns support literal text, `{string}` for single/double quoted strings, and `{int}` for decimal digits with an optional minus sign. Captures arrive as strings in order; quoted captures remove delimiters and unescape backslash-prefixed characters. This is a small pattern language, not the full Cucumber Expressions syntax.

```text
BDD.step(pattern: String, handler: Fn[List[String], Nil]) -> Nil
BDD.doc_string() -> String
BDD.table() -> List[List[String]]
BDD.assert(condition: Bool, message: String) -> Nil
BDD.set(name: String, value: Json) -> Nil
BDD.get(name: String) -> Result[Json]
BDD.given_program(path: String) -> Nil
BDD.when_line(text: String) -> Nil
BDD.when_input(text: String) -> Nil
BDD.when_eof() -> Nil
BDD.then_line(expected: String, timeout_ms: Int) -> Nil
BDD.then_json_line(expected: String, timeout_ms: Int) -> Nil
BDD.then_stdin_open() -> Nil
BDD.then_exit(code: Int, timeout_ms: Int) -> Nil
BDD.then_stdout(expected: String) -> Nil
BDD.then_stderr(expected: String) -> Nil
```

Only registration allows `BDD.step`; actions, state, and assertions require a running scenario. Missing Doc Strings/tables fail; missing state returns an error Result. A second program start, an unknown pattern, or multiple matching definitions fail. Every `Then` step, including its following `And`/`But`, must perform at least one BDD assertion; every scenario must perform a check. Handler calls to `System.exit`, including code zero, fail. Calling `BDD.run` recursively from handlers is unavailable.

## Run from Agentica

```ruby
def main() -> Nil
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

## Isolation and failure handling

Scenarios run sequentially with fresh JSON state and a fresh container. A failure stops only the current scenario; remaining steps are reported as `not_executed`, then the next scenario runs. Step definitions are resolved before starting a scenario. Syntax errors fail their file and leave other files runnable; a failing handler file contributes a file error while other valid handlers remain available.

The candidate sees only its copied source and the distributed runtime, mounted read-only. It runs as UID/GID 65534, without network or capabilities, with no provider credentials, 256 PIDs, 2 GiB memory, 2 CPUs, and bounded temporary storage. Specs and handlers are never mounted.

Each scenario has a 30-second wall-clock deadline. Operations without an explicit timeout get 5 seconds; every evaluator invocation gets one million steps. Stdout and stderr are drained concurrently and each capped at 1 MiB; handler output is also bounded. Containers are removed after success, failure, timeout, or interruption. These checks enforce the behaviors specified; they cannot prove coverage of requirements nobody expressed.
