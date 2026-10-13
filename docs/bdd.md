# Executable BDD specifications

Agentica runs `.feature` files with predefined steps and optional steps written in Agentica. Matching is deterministic: unknown or ambiguous steps fail. Programs under test run as local processes. Everything runs on the bytecode VM: the step API is the standard module `std/bdd`, and the runner is a fixed Agentica program embedded in `agentica`.

## Run

```sh
make exe
dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc
dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc --json
dist/agentica --ai test tests/bdd/specs/json-lines.feature
make test-bdd
```

`make exe` builds the CLI. You can also run `racket src/main.rkt test tests/bdd/specs/ --steps tests/bdd/handlers.agc` directly from source after `make vm`. `make test-bdd` builds and checks the compiled CLI against the feature suite. Running `agentica test` does not install or build anything.

```text
agentica [--ai|--json] [--allow-run] [--seed N] test [PATH...] [--steps FILE] [--only TEXT] [--ai|--json] [--allow-run]
```

`agentica test` also runs unit test files, `*_test.agc` programs whose `main` calls `Test.run` (see [`grammar.md`](grammar.md), `Test`), in the same pass and the same report. With no paths it searches `specs/` and `test/`, and skips a default folder that does not exist; when neither exists, the run fails with `CHECK-BDD-EMPTY`, which names both. Directories are searched recursively for `.feature` and `*_test.agc` files; paths are made absolute and lexical, duplicates are removed and the files are sorted. Links to folders are not followed; a `.feature` link to a file is. A folder that cannot be read, a broken `.feature` link or a name that is not UTF-8 is a `RUNTIME-BDD-INFRA` file error, and the search goes on. Explicit files are also accepted. A feature file is at most 1 MiB; a larger one is a `RUNTIME-BDD-IO` file error. `--steps FILE` names the one step program; it can precede `test` or follow it, and it is only for features: with no feature to run, the step program is not started, but one that does not compile is still a file error. Without it, only the predefined steps are available. `--only TEXT` (once, and not empty: `RUNTIME-BDD-USAGE`) keeps the scenarios and tests whose name contains `TEXT`; the others are left out of the report, and when no name matches, the run fails with a `CHECK-BDD-EMPTY` file error. The run always has a seed: `--seed N`, or one the runner draws; it reaches every step program, test file and program under test, and the report shows it (`seed` in `--json`; in the text formats, at the end of the last line when the run failed), so `--seed N` replays a run. This is a change from 25a: a run without `--seed` used to leave each step program and program under test with its own unseeded `Random`; now they all get the seed the runner drew. A usage or infrastructure report has `seed` too: `--seed N` when given, else `null`. `--allow-run` lets the programs under test start programs; step handlers can always start them.

**Upgrading from 25a.** `*_test.agc` files are now discovered next to `.feature` files, in `specs/` too, and their `main` runs twice (once to list the tests, once to run them). A helper program with such a name that does not call `Test.run` now fails the suite with `RUNTIME-TEST-RUN`: rename it.

**Shared resources.** Test files and scenarios run one at a time, but each in a child VM of its own, next to other programs on the machine. A test or step that uses a fixed temporary file name or a fixed port can collide with another run; use port 0 and a fresh temporary directory.

Exit codes are 0 when every scenario passes and there is at least one, 1 for verification failures or an empty suite, and 2 for usage errors and when any error is `RUNTIME-BDD-INFRA` (a missing path, a step program that cannot be read, a missing VM). Plain, `--ai`, and `--json` give the same verdict. The JSON report has `ok`, `passed`, `failed`, `not_executed`, `file_errors`, `exit_code`, `seed`, and `files`; each file has `path`, `feature`, `kind` (`feature`, `tests`, `steps` for the step program, or `""`), `status`, `scenarios`, `error` and `output` (for a test file that failed outside its tests: what it printed and its stderr, else `""`), and each scenario its steps, locations, optional Examples row, duration, diagnostic and `output`. Errors of the step program itself are a file entry with its path and an empty `feature`. A test file is a file entry with an empty `feature` and `kind: "tests"`; each test is a scenario entry with `steps: []`, at its `Test.test` call. A test's `status` is `passed`, `failed` or `not_executed` (a test after one that ended the file's child VM: an exit, a step limit, a timeout); `not_executed` counts those. In the text formats a test is `PASS file / name`, `FAIL file / name` or `NOT RUN file / name`, and a failed test's captured stdout follows its diagnostic, indented by two spaces (`--ai`: ` | output "..."`); a file error's output follows it the same way. Only a failed test has `output`: the stdout lines it printed, plus its stderr when its child VM died during it, the last 64 Ki characters. Stdout that `main` prints before `Test.run` counts as the first test's output. A test that times out keeps the lines that arrived before the deadline; the VM buffers stdout, so call `IO.flush()` before a wait that may time out. Stdout counts 1 MiB per test (`RUNTIME-BDD-OUTPUT-LIMIT` on that test). Stderr is captured for the whole file, up to 1 MiB: past it, or when unread stdout passes 1 MiB, the file fails with `RUNTIME-BDD-OUTPUT-LIMIT` and the test then running is reported as not run, since it may not be the one that wrote the most. These limits and cuts count characters, not bytes. Reports contain no handler or program output other than diagnostic expected/actual values. A failed `then_*` check compares with `Test.eq` and reports `expected` and `actual` as `Test.eq` does, in the inspect form: a line or output in quotes, an exit code as a number, a JSON line as its canonical text (sorted keys). The text report prints them as they are; an undefined or ambiguous step's `actual` is the step text in quotes. A front-end error of the step program keeps its own `expected` and `actual`, the raw type names (`Int`, `String`), so in `--json` their form depends on the code. A text longer than 64 Ki characters is cut there and ends with `...` and the number of characters left out.

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

A step accepts one `"""` Doc String, optionally with a media type, or one rectangular Data Table. Doc Strings are dedented relative to their opening delimiter and joined with LF. To expect a final newline, include an empty line before the closing delimiter. Table cells trim surrounding whitespace and decode `\|`, `\\`, and `\n`. A feature file is at most 1 MiB.

Paths to programs under test are relative to the feature file. CLI paths and the step program are relative to the working directory. Programs run with the feature's directory as their working directory.

## Predefined steps

Step keywords do not affect matching. These exact patterns are available without a step program:

| Pattern | Argument / effect |
| --- | --- |
| `the Agentica program {string}` | Start one local `.agc` process |
| `I send a line:` | Doc String; append LF and flush |
| `I send the line {string}` | Append LF and flush |
| `I send input:` | Doc String; send literally and flush |
| `I close stdin` | Send EOF; closing twice is allowed |
| `I receive a line within {int} milliseconds:` | Doc String; compare next line without its terminator |
| `I receive the line {string} within {int} milliseconds` | Compare next line |
| `I receive a JSON line within {int} milliseconds:` | Doc String; structured JSON comparison |
| `stdin remains open` | Check input is open and the process active |
| `the program exits with code {int} within {int} milliseconds` | Wait for and compare exit code |
| `stdout is:` | Doc String; compare the stdout no line step has read yet, after exit |
| `stderr is:` | Doc String; compare all of stderr after exit |

Object key order does not affect JSON equality: both lines are compared by their canonical text, `JSON.encode(JSON.parse(line))`. Arrays retain order; value kinds remain distinct. Timeouts must be positive integers.

## Step programs

A step program is a normal program. Its `main` builds the list of steps and passes it to `BDD.run`; other files are imported from it.

```ruby
import "std/bdd" as BDD

def submit_record(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.when_line(ctx, BDD.doc_string(ctx))
end

def main() -> Void
  limit = 5
  BDD.run([
    BDD.step("I submit a score record", &submit_record),
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
BDD.set(ctx: BDD.Context, name: String, value: Json) -> BDD.Context
BDD.get(ctx: BDD.Context, name: String) -> Result[Json]
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

Patterns support literal text, `{string}` for single or double quoted strings, and `{int}` for decimal digits with an optional minus sign. Captures arrive as strings in order; quoted captures remove delimiters and unescape backslash-prefixed characters. This is a small pattern language, not the full Cucumber Expressions syntax. A pattern used twice (predefined ones included) is `RUNTIME-BDD-DUPLICATE`, and any other `{...}` or a stray brace is `RUNTIME-BDD-PATTERN`; both are errors of the step program at its first line, with the pattern in the message.

**The context.** A handler gets the scenario's context and returns the context it ends with; the next step gets it, with its own Doc String and table. Every BDD call takes the context first and returns it: use the one it returns. Only `BDD.set` and `BDD.given_program` change it. `BDD.Context` can be named but not built, so a context exists only inside a step. The program under test lives in the context: a handler that drops the context `BDD.given_program` returned loses the program.

**Rules.** `BDD.doc_string` and `BDD.table` without an argument on the step fail with `RUNTIME-BDD-CONTEXT`; `BDD.get` of a missing name is `error("missing scenario state")`. Stream calls before `BDD.given_program` and a second program in a scenario are `RUNTIME-BDD-CONTEXT`. Every `Then` step, including its following `And`/`But`, must perform at least one BDD assertion; every scenario must perform one. A BDD failure ends the step at once; the value after it is never used.

**`main`.** `BDD.run` adds the predefined steps in front of the list and never returns. The step program's `main` runs once to list the steps and again in every scenario, so it should only build the list and call `BDD.run`; whatever else it does is repeated, and its output goes nowhere. A step program that never calls `BDD.run` is `RUNTIME-BDD-CONTEXT`. Run directly (`agentica steps.agc`), a step program prints "run this step program with agentica test --steps FILE" on stderr and exits 2.

**Tasks.** Handlers may use `Task.spawn` and `Task.await`, and may pass `ctx` to tasks inside a struct. Assertions made in tasks count for the step. A context changed in a task is lost unless the handler takes it back from `Task.await`. Tasks must end before the handler returns; otherwise the step fails with `RUNTIME-BDD-PENDING-TASKS`, and so does a step program whose `main` leaves tasks running when it calls `BDD.run`.

**Stdin.** A handler's standard input is the runner's protocol pipe: handlers must not read it.

## Isolation and process lifetime

`agentica test` compiles the step program and the runner to bytecode in a private temporary directory, then runs the runner on the VM. The runner lists the steps in one child VM, then runs **each scenario in its own child VM**, which runs the step program again in scenario mode. A step that crashes, calls `System.exit` (even with 0), passes its step limit or loops forever fails only its scenario: a crash keeps its own diagnostic and span in the step program, an exit is `RUNTIME-BDD-PREMATURE-EXIT`. BDD failures are located at the feature step. Remaining steps are reported as `not_executed`, then the next scenario runs. Steps are resolved before a scenario starts. Syntax errors fail their file and leave other files runnable; a step program that does not compile, does not list its steps or has a bad pattern is one file error, and then no scenario runs.

Each scenario child runs with `--allow-run`, so step handlers can always call `Process.spawn`. BDD gives no isolation from the host: programs run with the host user's permissions and inherited environment. Programs under test are started with the same `agentica` command as the run (Racket and `src/main.rkt` from source, or the packaged executable), with `--allow-run` only when `agentica test` has it, and `--max-steps 1000000`.

Each scenario has a 30-second wall-clock deadline from the start of its child. Program-driving calls without an explicit timeout get 5 seconds, and starting a program 30. A scenario child has 1,000,000 steps per step plus 1,000,000; the budget also pays for `std/bdd`'s own work in the child (decoding steps, the predefined steps, the JSON comparison), but builtins cost steps per call, not per byte. A program's stdout is kept up to 1 MiB unread and its stderr up to 1 MiB, checked after every step without waiting; handler output is bounded to 1 MiB per step. Output over a limit is `RUNTIME-BDD-OUTPUT-LIMIT`. When a scenario ends, its child is closed, and the child's VM stops the program under test; an interrupted `agentica test` stops the runner, which stops its children, and removes its temporary directory. On Linux the runner also ends when the driver is killed outright (`SIGKILL`), and stops its children the same way. Each run holds an exclusive lock on a `lock` file in its temporary directory; the next `agentica test` removes a directory of the same user whose lock it can take, so a killed run's directory goes and a live run's stays, even across PID namespaces or hosts. On a file system without `flock`, `agentica test` fails with `RUNTIME-BDD-INFRA` (exit 2). `agentica test` refuses a temporary directory without the sticky bit that other users can write to, or that its group can write to unless it belongs to your own user and group and has no setgid bit (`RUNTIME-BDD-INFRA`, exit 2): set `TMPDIR` to a private folder. These checks enforce the behaviors specified; they cannot prove coverage of requirements nobody expressed.

## Changes from the Racket BDD

`agentica test` ran on the legacy evaluator until roadmap 21f. These changes break step files written for it. Feature files keep their syntax, but the rows on programs under test, file size and discovery can change their results:

| Before | Now |
|---|---|
| `BDD` is a builtin module and a reserved name | `import "std/bdd" as BDD`; `BDD` is free as a name and an alias |
| `BDD.run(feature_path, step_files) -> Result[Json]` | Removed. From a program, start `agentica test --json` with `Process.spawn` (needs `--allow-run`) |
| `BDD.step(pattern, Fn[List[String], Void]) -> Void`, registered in `main` | `BDD.step(pattern, Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step`, collected in a list passed to `BDD.run(steps)` |
| `BDD.doc_string()`, `BDD.table()`, `BDD.get(name)` | the same with `ctx` first |
| `BDD.assert`, `BDD.set` and the program-driving calls return `Void` | `ctx` first; each returns the context |
| `--steps FILE` repeatable; each file's `main` only registers | one `--steps` program with `main`; other files are imported; `main` runs again in each scenario |
| handlers spawn only with `--allow-run` | handlers can always spawn; `--allow-run` on `test` only reaches programs under test |
| one million steps per handler call | one million per step plus one million for the whole scenario child, library work included |
| handlers read an empty stdin | stdin is the protocol pipe; handlers must not read it |
| `stdout is:` compares all of stdout | it compares the stdout no line step has read yet |
| program output: 1 MiB per stream in total | 1 MiB of unread stdout and 1 MiB of stderr; a program that writes more stdout while the test reads lines passes |
| handler output over 1 MiB: `RUNTIME-INTERNAL` | `RUNTIME-BDD-OUTPUT-LIMIT` |
| `I close stdin` twice: `RUNTIME-BDD-CONTEXT` | allowed |
| BDD failures located at the `BDD.*` call | located at the feature step; crashes keep their span in the step program |
| `RUNTIME-BDD-PATTERN` and `RUNTIME-BDD-DUPLICATE` at the `BDD.step` call | at the step program's first line, with the pattern in the message |
| a bad step file leaves the other files' steps usable | one step program: a bad one is a file error and no scenario runs |
| BDD calls outside a scenario: `RUNTIME-BDD-CONTEXT` | impossible to write; a step program that never calls `BDD.run` is `RUNTIME-BDD-CONTEXT` |
| feature files of any size | at most 1 MiB; a larger one is a `RUNTIME-BDD-IO` file error, exit 1 |
| programs under test ran on the legacy evaluator | they run like `agentica FILE`: on the VM, so seeded `Random` values follow the VM's generator; the builtin `HTTP` module is gone since 7i, so such a program fails with `CHECK-UNKNOWN-NAME` and must import `std/http` as `HTTP` |
| handlers could call the `HTTP` builtins | the builtin `HTTP` module is gone since 7i: an `HTTP.` call without an import is a `CHECK-UNKNOWN-NAME` file error whose help shows `import "std/http" as HTTP` |
| a missing or unreadable `--steps` file: `CHECK-IMPORT-IO`, exit 1, scenarios run as undefined | `RUNTIME-BDD-INFRA`, exit 2, no scenario runs |
| discovery followed links to folders | links to folders are skipped; an unreadable folder, a broken `.feature` link or a name that is not UTF-8 is a `RUNTIME-BDD-INFRA` file error |

## Diagnostics

`agentica test` reports the first problem of each kind with a stable code:

| Code | Meaning |
|---|---|
| `PARSE-GHERKIN-HEADER`, `PARSE-GHERKIN-STEP`, `PARSE-GHERKIN-ARGUMENT`, `PARSE-GHERKIN-TABLE`, `PARSE-GHERKIN-EXAMPLES`, `PARSE-GHERKIN-TAGS`, `PARSE-GHERKIN-EMPTY`, `PARSE-GHERKIN-PARAMETER`, `PARSE-GHERKIN-UNSUPPORTED` | the `.feature` file breaks the supported Gherkin subset (section order, a step outside a scenario, a Doc String or table in the wrong place, bad Examples, misplaced tags, a Feature without scenarios or a Background without steps, an Examples column missing for a `<parameter>`, a non-English keyword) |
| `CHECK-BDD-UNDEFINED`, `CHECK-BDD-AMBIGUOUS`, `CHECK-BDD-EMPTY` | no step pattern matches, more than one matches, or no `.feature` or `*_test.agc` files were found (or no name matches `--only`) |
| `RUNTIME-BDD-ASSERTION`, `RUNTIME-BDD-NO-ASSERTION` | an expectation failed, or a `Then` step or a whole scenario made no BDD assertion |
| `RUNTIME-BDD-TIMEOUT`, `RUNTIME-BDD-PREMATURE-EXIT` | an operation or the scenario passed its deadline, or got a bad timeout; a step called `System.exit` or its child ended without a diagnostic |
| `RUNTIME-BDD-CONTEXT`, `RUNTIME-BDD-PROGRAM`, `RUNTIME-BDD-JSON` | a missing Doc String or table, a stream call before a program started, a second program, a step program that never calls `BDD.run`; a missing `.agc` program; a JSON expectation that is not valid JSON |
| `RUNTIME-BDD-DUPLICATE`, `RUNTIME-BDD-PATTERN`, `RUNTIME-BDD-PENDING-TASKS` | a step pattern used twice, an invalid pattern, tasks left running by a handler or by `main` before `BDD.run` |
| `RUNTIME-BDD-OUTPUT-LIMIT`, `RUNTIME-BDD-IO`, `RUNTIME-BDD-INFRA`, `RUNTIME-BDD-USAGE` | program or handler output over 1 MiB; a stream I/O failure, a feature file or a step line over 1 MiB; a missing executable, VM or feature path, an unreadable folder or broken `.feature` link, a step program that cannot be read or that breaks the record protocol, or a runner failure; bad command-line usage, such as two `--steps` |

A step program that does not compile reports its own front-end or `LOWER-` diagnostic as a file error, and a crash in a step reports the VM's diagnostic (`RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-STEP-LIMIT`, ...) with its span in the step program.
