# BDD feature specifications

`agentica test [PATH...] [--steps FILE] [--ai|--json]` executes `.feature` files, recursively searching directories in sorted order; default path is `specs/`. `--steps` is repeatable and loads explicit `.agc` handlers. Empty discovery fails. Exit codes: 0 all pass, 1 verification fails, 2 infrastructure/usage fails. Programs under test run as local processes. Use `make exe` to build the CLI or run `racket src/main.rkt test ...` directly; `make test` includes process integration tests and `make test-bdd` checks the compiled CLI against the feature suite. `make test JOBS=N` controls parallel test workers.

English syntax: `Feature`, one optional `Background` before scenarios, `Scenario`/`Example`, `Scenario Outline` plus `Examples`, and `Given`/`When`/`Then`/`And`/`But`. Each Examples row becomes a scenario, substituting `<column>` in names, steps, Doc Strings and tables. Comments, tags and descriptions before steps are accepted. Tags never skip tests. `Rule`, `*`, other keyword aliases and localized syntax fail explicitly. `And`/`But` inherit the previous kind. Triple-quote Doc Strings are dedented; include a final empty line to retain a trailing newline. Data Tables decode `\|`, `\\`, `\n`. One argument per step.

Predefined step patterns (keyword is irrelevant for matching):

| Text | Argument |
| --- | --- |
| `the Agentica program {string}` | candidate `.agc` path relative to the feature |
| `I send a line:` | Doc String, then LF and flush |
| `I send the line {string}` | quoted text, then LF and flush |
| `I send input:` | literal Doc String and flush |
| `I close stdin` | EOF |
| `I receive a line within {int} milliseconds:` | expected Doc String |
| `I receive the line {string} within {int} milliseconds` | expected quoted text |
| `I receive a JSON line within {int} milliseconds:` | expected JSON Doc String; object key order ignored |
| `stdin remains open` | input open and program active |
| `the program exits with code {int} within {int} milliseconds` | wait and check exit code |
| `stdout is:` / `stderr is:` | complete Doc String after exit |

Custom handler files register in `main() -> Void`: `BDD.step("I submit a record:", &submit)`. `submit(args: List[String]) -> Void` can use `BDD.when_line(BDD.doc_string())`. Patterns are literal text plus `{string}` and `{int}`; unknown captures and duplicate/ambiguous patterns fail. Captures are strings in order; quoted strings lose delimiters and unescape backslash-prefixed characters. Decimal integers may have a minus sign.

```text
BDD.run(feature_path: String, step_files: List[String]) -> Result[Json]
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

`BDD.run` accepts a file or directory. An infrastructure failure returns an error Result. A completed evaluation returns JSON containing `ok`, `passed`, `failed`, `not_executed`, `file_errors`, `exit_code`, and detailed `files`. A successful Result can contain failed tests: inspect `JSON.bool(Result.unwrap!(JSON.get(report, "ok")))` and choose `System.exit(1)` when false. The CLI enforces this automatically. `BDD.run` is unavailable recursively inside handlers.

Only registration permits `BDD.step`; actions/state/assertions require a running scenario. Missing Doc Strings/tables halt; absent state returns an error Result. Every `Then` (including its And/But) must perform a BDD assertion. Premature System.exit, even zero, fails. Failure stops only that scenario's remaining steps, marked `not_executed`; other scenarios/files continue. Each scenario starts with empty state and a fresh local process, executing Background again. Programs run with host permissions and environment, with the feature directory as their working directory; BDD provides no filesystem or network isolation. Timeouts are positive; each scenario has 30 seconds, operations without explicit deadlines 5 seconds, each callback one million evaluator steps, each stream 1 MiB. Scenario cleanup terminates processes and closes their ports on all outcomes.
