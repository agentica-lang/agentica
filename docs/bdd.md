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
agentica [--ai|--json] [--allow-run] [--seed N] test [PATH...] [--steps FILE] [--ai|--json] [--allow-run]
```

With no paths, `agentica test` searches `specs/`. Directories are searched recursively for `.feature` files; paths are made absolute and lexical, duplicates are removed and the files are sorted. Links to folders are not followed; a `.feature` link to a file is. A folder that cannot be read, a broken `.feature` link or a name that is not UTF-8 is a `RUNTIME-BDD-INFRA` file error, and the search goes on. Explicit files are also accepted. A feature file is at most 1 MiB; a larger one is a `RUNTIME-BDD-IO` file error. `--steps FILE` names the one step program; it can precede `test` or follow it. Without it, only the predefined steps are available. `--seed N` reaches every step program and every program under test. `--allow-run` lets the programs under test start programs; step handlers can always start them.

Exit codes are 0 when every scenario passes and there is at least one, 1 for verification failures or an empty suite, and 2 for usage errors and when any error is `RUNTIME-BDD-INFRA` (a missing path, a step program that cannot be read, a missing VM). Plain, `--ai`, and `--json` give the same verdict. The JSON report has `ok`, `passed`, `failed`, `not_executed` (always 0), `file_errors`, `exit_code`, and `files`; each file has `path`, `feature`, `status`, `scenarios` and `error`, and each scenario its steps, locations, optional Examples row, duration, and diagnostic. Errors of the step program itself are a file entry with its path and an empty `feature`. Reports contain no handler or program output other than diagnostic expected/actual values.

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

Each scenario has a 30-second wall-clock deadline from the start of its child. Program-driving calls without an explicit timeout get 5 seconds, and starting a program 30. A scenario child has 1,000,000 steps per step plus 1,000,000; the budget also pays for `std/bdd`'s own work in the child (decoding steps, the predefined steps, the JSON comparison), but builtins cost steps per call, not per byte. A program's stdout is kept up to 1 MiB unread and its stderr up to 1 MiB, checked after every step without waiting; handler output is bounded to 1 MiB per step. Output over a limit is `RUNTIME-BDD-OUTPUT-LIMIT`. When a scenario ends, its child is closed, and the child's VM stops the program under test; an interrupted `agentica test` stops the runner, which stops its children, and removes its temporary directory. On Linux the runner also ends when the driver is killed outright (`SIGKILL`), and stops its children the same way. Each run holds an exclusive lock on a `lock` file in its temporary directory; the next `agentica test` removes a directory of the same user whose lock it can take, so a killed run's directory goes and a live run's stays, even across PID namespaces or hosts. On a file system without `flock`, `agentica test` fails with `RUNTIME-BDD-INFRA` (exit 2). `agentica test` refuses a temporary directory without the sticky bit that other users can write to, or that its group can write to when another user owns it (`RUNTIME-BDD-INFRA`, exit 2): set `TMPDIR` to a private folder. These checks enforce the behaviors specified; they cannot prove coverage of requirements nobody expressed.

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
| programs under test ran on the legacy evaluator | they run like `agentica FILE`: on the VM, so seeded `Random` values follow the VM's generator, and a program that uses the `HTTP` builtins prints the fallback notice on stderr until HTTP 20d |
| handlers could call the `HTTP` builtins | the step program is compiled for the VM: an `HTTP` builtin call is a `LOWER-UNSUPPORTED` file error; use `std/http` |
| a missing or unreadable `--steps` file: `CHECK-IMPORT-IO`, exit 1, scenarios run as undefined | `RUNTIME-BDD-INFRA`, exit 2, no scenario runs |
| discovery followed links to folders | links to folders are skipped; an unreadable folder, a broken `.feature` link or a name that is not UTF-8 is a `RUNTIME-BDD-INFRA` file error |

## Diagnostics

`agentica test` reports the first problem of each kind with a stable code:

| Code | Meaning |
|---|---|
| `PARSE-GHERKIN-HEADER`, `PARSE-GHERKIN-STEP`, `PARSE-GHERKIN-ARGUMENT`, `PARSE-GHERKIN-TABLE`, `PARSE-GHERKIN-EXAMPLES`, `PARSE-GHERKIN-TAGS`, `PARSE-GHERKIN-EMPTY`, `PARSE-GHERKIN-PARAMETER`, `PARSE-GHERKIN-UNSUPPORTED` | the `.feature` file breaks the supported Gherkin subset (section order, a step outside a scenario, a Doc String or table in the wrong place, bad Examples, misplaced tags, a Feature without scenarios or a Background without steps, an Examples column missing for a `<parameter>`, a non-English keyword) |
| `CHECK-BDD-UNDEFINED`, `CHECK-BDD-AMBIGUOUS`, `CHECK-BDD-EMPTY` | no step pattern matches, more than one matches, or no `.feature` files were found |
| `RUNTIME-BDD-ASSERTION`, `RUNTIME-BDD-NO-ASSERTION` | an expectation failed, or a `Then` step or a whole scenario made no BDD assertion |
| `RUNTIME-BDD-TIMEOUT`, `RUNTIME-BDD-PREMATURE-EXIT` | an operation or the scenario passed its deadline, or got a bad timeout; a step called `System.exit` or its child ended without a diagnostic |
| `RUNTIME-BDD-CONTEXT`, `RUNTIME-BDD-PROGRAM`, `RUNTIME-BDD-JSON` | a missing Doc String or table, a stream call before a program started, a second program, a step program that never calls `BDD.run`; a missing `.agc` program; a JSON expectation that is not valid JSON |
| `RUNTIME-BDD-DUPLICATE`, `RUNTIME-BDD-PATTERN`, `RUNTIME-BDD-PENDING-TASKS` | a step pattern used twice, an invalid pattern, tasks left running by a handler or by `main` before `BDD.run` |
| `RUNTIME-BDD-OUTPUT-LIMIT`, `RUNTIME-BDD-IO`, `RUNTIME-BDD-INFRA`, `RUNTIME-BDD-USAGE` | program or handler output over 1 MiB; a stream I/O failure, a feature file or a step line over 1 MiB; a missing executable, VM or feature path, an unreadable folder or broken `.feature` link, a step program that cannot be read or that breaks the record protocol, or a runner failure; bad command-line usage, such as two `--steps` |

A step program that does not compile reports its own front-end or `LOWER-` diagnostic as a file error, and a crash in a step reports the VM's diagnostic (`RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-STEP-LIMIT`, ...) with its span in the step program.
