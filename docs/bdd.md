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

`agentica test` also runs unit test files, `*_test.agc` programs whose `main` calls `Test.run` (see [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md#unit-tests-test)), in the same pass and the same report. With no paths it searches `specs/` and `test/`, and skips a default folder that does not exist; when neither exists, the run fails with `CHECK-BDD-EMPTY`, which names both. Directories are searched recursively for `.feature` and `*_test.agc` files; paths are made absolute and lexical, duplicates are removed and the files are sorted. Links to folders are not followed; a `.feature` link to a file is. A folder that cannot be read, a broken `.feature` link or a name that is not UTF-8 is a `RUNTIME-BDD-INFRA` file error, and the search goes on. Explicit files are also accepted. A feature file is at most 1 MiB; a larger one is a `RUNTIME-BDD-IO` file error. `--steps FILE` names the one step program; it can precede `test` or follow it, and it is only for features: with no feature to run, the step program is not started, but one that does not compile is still a file error. Without it, only the predefined steps are available. `--only TEXT` (once, and not empty: `RUNTIME-BDD-USAGE`) keeps the scenarios and tests whose name contains `TEXT`; the others are left out of the report, and when no name matches, the run fails with a `CHECK-BDD-EMPTY` file error. The run always has a seed: `--seed N`, or one the runner draws; it reaches every step program, test file and program under test, and the report shows it (`seed` in `--json`; in the text formats, at the end of the last line when the run failed), so `--seed N` replays a run. This is a change from 25a: a run without `--seed` used to leave each step program and program under test with its own unseeded `Random`; now they all get the seed the runner drew. A usage or infrastructure report has `seed` too: `--seed N` when given, else `null`. `--allow-run` lets the programs under test start programs; step handlers can always start them.

**Upgrading from 25a.** `*_test.agc` files are now discovered next to `.feature` files, in `specs/` too, and their `main` runs twice (once to list the tests, once to run them). A helper program with such a name that does not call `Test.run` now fails the suite with `RUNTIME-TEST-RUN`: rename it.

**Shared resources.** Test files and scenarios run one at a time, but each in a child VM of its own, next to other programs on the machine. A test or step that uses a fixed temporary file name or a fixed port can collide with another run; use port 0 and a fresh temporary directory.

Exit codes are 0 when every scenario passes and there is at least one, 1 for verification failures or an empty suite, and 2 for usage errors and when any error is `RUNTIME-BDD-INFRA` (a missing path, a step program that cannot be read, a missing VM). Plain, `--ai`, and `--json` give the same verdict. The JSON report has `ok`, `passed`, `failed`, `not_executed`, `file_errors`, `exit_code`, `seed`, and `files`; each file has `path`, `feature`, `kind` (`feature`, `tests`, `steps` for the step program, or `""`), `status`, `scenarios`, `error` and `output` (for a test file that failed outside its tests: what it printed and its stderr, else `""`), and each scenario its steps, locations, optional Examples row, duration, diagnostic and `output`. Errors of the step program itself are a file entry with its path and an empty `feature`. A test file is a file entry with an empty `feature` and `kind: "tests"`; each test is a scenario entry with `steps: []`, at its `Test.test` call. A test's `status` is `passed`, `failed` or `not_executed` (a test after one that ended the file's child VM: an exit, a step limit, a timeout); `not_executed` counts those. In the text formats a test is `PASS file / name`, `FAIL file / name` or `NOT RUN file / name`, and a failed test's captured stdout follows its diagnostic, indented by two spaces (`--ai`: ` | output "..."`); a file error's output follows it the same way. Only a failed test has `output`: the stdout lines it printed, plus its stderr when its child VM died during it, the last 64 Ki characters. Stdout that `main` prints before `Test.run` counts as the first test's output. A test that times out keeps the lines that arrived before the deadline; the VM buffers stdout, so call `IO.flush()` before a wait that may time out. Stdout counts 1 MiB per test (`RUNTIME-BDD-OUTPUT-LIMIT` on that test). When unread stdout passes 1 MiB (many short lines written faster than the runner reads them), the running test fails the same way. Stderr is captured for the whole file, up to 1 MiB: past it, the file fails with `RUNTIME-BDD-OUTPUT-LIMIT`, shows the end of the stderr, and the test then running is reported as not run, since it may not be the one that wrote the most. These limits and cuts count characters, not bytes. Reports contain no handler or program output other than diagnostic expected/actual values. A failed `then_*` check compares with `Test.eq` and reports `expected` and `actual` as `Test.eq` does, in the inspect form: a line or output in quotes, an exit code as a number, a JSON line as its canonical text (sorted keys). The text report prints them as they are; an undefined or ambiguous step's `actual` is the step text in quotes. A front-end error of the step program keeps its own `expected` and `actual`, the raw type names (`Int`, `String`), so in `--json` their form depends on the code. A text longer than 64 Ki characters is cut there and ends with `...` and the number of characters left out.

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

### Gherkin rules

`std/bdd/gherkin` parses the subset above and returns a `Feature` or the first error, with the same codes, first error and locations as the Racket parser it replaced:

- **Lines.** Empty lines and `#` comment lines are skipped. `# language: en` is accepted; any other `# language:` line is `PARSE-GHERKIN-UNSUPPORTED` ("only English Gherkin is supported").
- **Tags.** A line that starts with `@` is tags separated by spaces or tabs, each `@` followed by at least one non-space character (`PARSE-GHERKIN-TAGS`, "invalid tags"). They wait for the next `Feature`, `Scenario`, `Example`, `Scenario Outline` or `Examples`. Tags before a step are `PARSE-GHERKIN-TAGS` ("tags must precede a section"), and tags left at the end of the file too ("tags without a section", at line 1). They are copied into the report and never skip anything.
- **Headings.** `Feature:`, `Background:`, `Scenario Outline:`, `Scenario:`, `Example:` and `Examples:` at the start of the trimmed line, then spaces or tabs, then the name. A name is required except for `Background` and `Examples` (`PARSE-GHERKIN-HEADER`, "a section needs a name"). One `Feature` per file, first (`PARSE-GHERKIN-HEADER`); a missing one is "missing Feature" at line 1.
- **Background.** At most once, before any scenario, without tags (`PARSE-GHERKIN-HEADER`). Its steps run before each scenario's own steps. A Background without steps is `PARSE-GHERKIN-EMPTY`.
- **Scenarios.** `Scenario` and `Example` are the same. A scenario without steps is `PARSE-GHERKIN-EMPTY`; a Feature without scenarios too.
- **Outlines.** `Scenario Outline` needs at least one `Examples`, and `Examples` outside an outline is an error (`PARSE-GHERKIN-EXAMPLES`). After `Examples:`, blank and comment lines are skipped and a table follows, with a header row and at least one row; header cells are not empty and are unique (`PARSE-GHERKIN-EXAMPLES`). Several `Examples` blocks add rows; tags before an `Examples` apply to its rows. Each row becomes a scenario: `<name>` is replaced in the scenario name, the step text, the Doc String and the table cells; a name that is not a column is `PARSE-GHERKIN-PARAMETER` at the row. A scenario's tags are the Feature's, then the scenario's, then the Examples block's.
- **Steps.** `Given`, `When`, `Then`, `And`, `But`, then spaces or tabs, then the text. A step outside a Background or scenario, or after `Examples`, is `PARSE-GHERKIN-STEP`. `And` and `But` take the kind of the step before them in the same section; with none before, `PARSE-GHERKIN-STEP`. The keyword does not matter for matching; the kind matters only for the `Then` assertion rule.
- **Doc Strings.** A line that is `"""`, optionally followed by a media type of letters, digits and `_ . / + -` (ignored); anything else after the quotes is `PARSE-GHERKIN-ARGUMENT`. Content lines run to the next line whose trimmed text is `"""`; without one, `PARSE-GHERKIN-ARGUMENT` at the opening line. Each content line loses as many leading spaces or tabs as the opening line's indentation, at most; lines are joined with LF, so a final empty line keeps a final newline.
- **Data Tables.** Rows are lines that start with `|`, read while they do. A row ends with an unescaped `|`; cells are trimmed; `\|`, `\\` and `\n` are decoded, any other escape or a final lone `\` is an error; every row has the same width; a row has at least one cell. All of these are `PARSE-GHERKIN-TABLE`.
- **One argument per step.** A Doc String or table must follow a step in a Background or scenario, with no tags waiting, and a step takes at most one (`PARSE-GHERKIN-ARGUMENT`).
- **Not supported**, each `PARSE-GHERKIN-UNSUPPORTED`: `Rule:`, `Scenario Template:`, `Scenarios:`, `* ` steps, backtick Doc Strings, and a step keyword followed by a colon (`Then: ...`).
- **Descriptions.** Free text is allowed after a heading as long as the section has no steps yet, no tags are waiting, and it is not after `Examples`; otherwise `PARSE-GHERKIN-STEP` ("unexpected text after steps").
- **Locations.** Every scenario, step and Examples row keeps its line; a location's column is 1, and a diagnostic's range runs from column 1 to the end of the raw line. File names in locations are the feature file's absolute path.

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

**How the predefined steps work.** They are handlers in `std/bdd` over the context API:

| Call | How |
|---|---|
| `given_program(path)` | The path resolves against the feature's directory; it must exist and end in `.agc`, else `RUNTIME-BDD-PROGRAM`. Starts `agentica [--allow-run] [--seed N] --max-steps 1000000 PATH` with `Process.spawn_captured` in the feature's directory, with a 30-second start timeout; a missing `agentica` is `RUNTIME-BDD-INFRA`. |
| `when_line(text)`, `when_input(text)` | `Process.send` with or without LF, 5 seconds. `process: stdin is closed` is `RUNTIME-BDD-CONTEXT` ("stdin is already closed"); a timeout is `RUNTIME-BDD-TIMEOUT`; other errors `RUNTIME-BDD-IO`. |
| `when_eof()` | `Process.close_stdin`, 5 seconds; idempotent. |
| `then_line(expected, ms)` | `ms` must be positive (`RUNTIME-BDD-TIMEOUT`). `Process.read_line(p, ms)`: equal is an assertion record, different is `RUNTIME-BDD-ASSERTION` with expected and actual; `network: operation timed out` is `RUNTIME-BDD-TIMEOUT`; `process: end of input` is `RUNTIME-BDD-ASSERTION` ("stdout ended before the expected line"); the output limit is `RUNTIME-BDD-OUTPUT-LIMIT`. |
| `then_json_line(expected, ms)` | As `then_line`, then both lines through `JSON.parse` (either invalid: `RUNTIME-BDD-JSON`), compared by their canonical texts. |
| `then_stdin_open()` | `Process.send(p, "", 5000)` succeeds (stdin open) and `Process.wait(p, 1)` times out (still running); otherwise `RUNTIME-BDD-ASSERTION`. |
| `then_exit(code, ms)` | `Process.wait(p, ms)`; a timeout is `RUNTIME-BDD-TIMEOUT`; then `Process.output` must not be truncated (`RUNTIME-BDD-OUTPUT-LIMIT`); then the code is compared. |
| `then_stdout(expected)`, `then_stderr(expected)` | The program must have exited (`Process.wait(p, 1)`), else `RUNTIME-BDD-CONTEXT` ("complete output requires program exit"). `Process.output(p, 5000)`: stdout is what no line step has read yet; stderr is all of it. |

The VM stores a parsed object's members sorted by key bytes, with a duplicate key keeping its last value, and encodes them in that order (`vm/json.c`), so `JSON.encode(JSON.parse(x))` is canonical and the JSON comparison is one line in `std/bdd`; no JSON parser or sort is written in Agentica. The Gherkin and pattern scanners run in the runner, which has no step limit; what runs in the scenario child (the predefined steps, the JSON comparison) spends the child's step budget, and builtins such as `JSON.parse` and `JSON.encode` cost steps per call, not per byte, so a long JSON line stays cheap.

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

**Matching.** `std/bdd/match` compiles and matches patterns by hand, with no regular expressions. A pattern is literal text and placeholders; `{string}` and `{int}` are the only placeholders. Any other `{...}` is `RUNTIME-BDD-PATTERN` ("only {string} and {int} are supported") and a leftover `{` or `}` is `RUNTIME-BDD-PATTERN` ("unmatched pattern braces"). A match is whole-text, tried piece by piece with backtracking: a literal must appear exactly at the current position; `{int}` is an optional `-` and one or more ASCII digits, tried from the longest to the shortest; `{string}` is a double- or single-quoted string in which a backslash escapes the next character, and it ends at the first unescaped closing quote; the match succeeds only at the end of the text. An int capture is the digits as written (`"-3"`). Every step of a scenario is matched against every definition, predefined steps first, before the scenario starts. No match is `CHECK-BDD-UNDEFINED` and two or more is `CHECK-BDD-AMBIGUOUS`, both with the step text (in quotes) as `actual`. The first unresolved step is reported as failed and every other step of that scenario as `not_executed`, and no child starts.

**The context.** A handler gets the scenario's context and returns the context it ends with; the next step gets it, with its own Doc String and table. Most BDD calls take the context first and return it: use the one it returns. `BDD.doc_string`, `BDD.table` and `BDD.get` take it and return their value. Only `BDD.set` and `BDD.given_program` change it. `BDD.Context` can be named but not built, so a context exists only inside a step. The program under test lives in the context: a handler that drops the context `BDD.given_program` returned loses the program.

**Rules.** `BDD.doc_string` and `BDD.table` without an argument on the step fail with `RUNTIME-BDD-CONTEXT`; `BDD.get` of a missing name is `error("missing scenario state")`. Stream calls before `BDD.given_program` and a second program in a scenario are `RUNTIME-BDD-CONTEXT`. Every `Then` step, including its following `And`/`But`, must perform at least one BDD assertion; every scenario must perform one. A BDD failure ends the step at once; the value after it is never used.

**`main`.** `BDD.run` adds the predefined steps in front of the list and never returns. The step program's `main` runs once to list the steps and again in every scenario, so it should only build the list and call `BDD.run`; whatever else it does is repeated, and its output goes nowhere. A step program that never calls `BDD.run` is `RUNTIME-BDD-CONTEXT`. Run directly (`agentica steps.agc`), a step program prints "run this step program with agentica test --steps FILE" on stderr and exits 2.

**Tasks.** Handlers may use `Task.spawn` and `Task.await`, and may pass `ctx` to tasks inside a struct. Assertions made in tasks count for the step. A context changed in a task is lost unless the handler takes it back from `Task.await`. Tasks must end before the handler returns; otherwise the step fails with `RUNTIME-BDD-PENDING-TASKS`, and so does a step program whose `main` leaves tasks running when it calls `BDD.run`.

**Stdin.** A handler's standard input is the runner's protocol pipe: handlers must not read it.

## Isolation and process lifetime

`agentica test` compiles the step program and the runner to bytecode in a private temporary directory, then runs the runner on the VM. The runner lists the steps in one child VM, then runs **each scenario in its own child VM**, which runs the step program again in scenario mode. A step that crashes, calls `System.exit` (even with 0), passes its step limit or loops forever fails only its scenario: a crash keeps its own diagnostic and span in the step program, an exit is `RUNTIME-BDD-PREMATURE-EXIT`. BDD failures are located at the feature step. Remaining steps are reported as `not_executed`, then the next scenario runs. Steps are resolved before a scenario starts. Syntax errors fail their file and leave other files runnable; a step program that does not compile, does not list its steps or has a bad pattern is one file error, and then no scenario runs.

Each scenario child runs with `--allow-run`, so step handlers can always call `Process.spawn`. BDD gives no isolation from the host: programs run with the host user's permissions and inherited environment. Programs under test are started with the same `agentica` command as the run (Racket and `src/main.rkt` from source, or the packaged executable), with `--allow-run` only when `agentica test` has it, and `--max-steps 1000000`.

Each scenario has a 30-second wall-clock deadline from the start of its child. Program-driving calls without an explicit timeout get 5 seconds, and starting a program 30. A scenario child has 1,000,000 steps per step plus 1,000,000; the budget also pays for `std/bdd`'s own work in the child (decoding steps, the predefined steps, the JSON comparison), but builtins cost steps per call, not per byte. A program's stdout is kept up to 1 MiB unread and its stderr up to 1 MiB, checked after every step without waiting; handler output is bounded to 1 MiB per step. Output over a limit is `RUNTIME-BDD-OUTPUT-LIMIT`. When a scenario ends, its child is closed, and the child's VM stops the program under test; an interrupted `agentica test` stops the runner, which stops its children, and removes its temporary directory. On Linux the runner also ends when the driver is killed outright (`SIGKILL`), and stops its children the same way. Each run holds an exclusive lock on a `lock` file in its temporary directory; the next `agentica test` removes a directory of the same user whose lock it can take, so a killed run's directory goes and a live run's stays, even across PID namespaces or hosts. On a file system without `flock`, `agentica test` fails with `RUNTIME-BDD-INFRA` (exit 2). `agentica test` refuses a temporary directory without the sticky bit that other users can write to, or that its group can write to unless it belongs to your own user and group and has no setgid bit (`RUNTIME-BDD-INFRA`, exit 2): set `TMPDIR` to a private folder. These checks enforce the behaviors specified; they cannot prove coverage of requirements nobody expressed.

Every scenario runs in its own child VM, so a step that crashes, exits or loops fails only its scenario; failure stops its remaining steps and execution continues with the next scenario.

## How a run works

```text
agentica test [PATH...] [--steps FILE]          (Racket driver, src/bdd-driver.rkt)
  compiles std/test/runner (embedded root) and the step program to two .agcb
  in a private temporary directory, then runs:
  agentica-vm --allow-run [--seed N] -- runner.agcb config.jsonl
    runner (Agentica, our code only):
      1. list child:     agentica-vm --allow-run --json --max-steps 1000000 [--seed N]
                           -- steps.agcb --agentica-bdd list
                         -> the patterns, in order
      2. per .feature:   parse, expand, match
      3. per scenario:   agentica-vm --allow-run --json --max-steps M [--seed N]
                           -- steps.agcb --agentica-bdd scenario
                         <- one init line, then one line per step (stdin)
                         -> records: assert, end, fail (stdout)
                         -> on a crash: the --json diagnostic (last stderr line)
           a step may start the program under test:
             agentica [--allow-run] [--seed N] --max-steps 1000000 FILE.agc
             (cwd = the feature's directory)
      4. the report: plain, --ai or --json on stdout; System.exit(0, 1 or 2)
```

- **The runner is a separate, fixed program**, not the user's step program. User code never runs in the process that writes the report: the user's `main` runs only in children, always under a step limit, a deadline and captured output. So a step program that prints, loops or crashes in `main` still gives a clean report with a file error.
- **The step program is both the list child and the scenario child**: one `.agcb`, two modes chosen by `System.args`. Patterns, predefined steps and user steps come from the same `BDD.run(steps)` call in both modes, so the step numbers the runner sends match the ones the child runs.
- Scenarios run one at a time. A VM starts in about a millisecond, so a child per scenario is cheap next to what most scenarios already pay: each `the Agentica program "..."` step starts the `agentica` CLI.
- **Starting a scenario child.** `M` is 1,000,000 times (the number of steps + 1). `--json` makes the child's last stderr line its diagnostic. `--allow-run` is always given, because the child starts the program under test. The child's working directory is the runner's. The list child is the same command with `list`, `--max-steps 1000000` and a 30-second limit; how it ends is read as for a step, and any failure is a file error of the step program, and then no scenario runs.
- **Protocol.** One record per line of JSON. A record that the child writes starts with the marker U+001E followed by `agentica-bdd ` and the JSON; the runner looks for the marker anywhere in a line, and treats everything else on the child's stdout as handler output. The child reads its stdin with `IO.gets` and writes records with `IO.print` and `IO.flush`. The runner sends a step only after the previous one ended.

| Direction | Line | Meaning |
|---|---|---|
| runner to child, first | `{"base":"/abs/dir/of/feature","agentica":["/usr/bin/racket","/abs/src/main.rkt"],"allow_run":false,"seeded":true,"seed":9}` | Scenario settings: where program paths resolve and programs run, how to start `agentica`, and what to pass to programs under test |
| runner to child | `{"index":2,"definition":14,"pattern":"I remember {int}","captures":["7"],"has_doc":true,"doc":"{\"value\":7}","has_table":false,"table":[]}` | Run step 2 with definition 14 (in `BDD.run`'s order, predefined steps first). The child checks that `pattern` is the pattern of its definition 14; a mismatch (a step program that builds its list differently from run to run) is a `fail` record with `RUNTIME-BDD-INFRA`. `has_*` stand in for optional fields |
| runner to child | end of stdin | No more steps: `BDD.run` ends the child with `System.exit(0)` (it never returns) |
| child to runner | `{"event":"assert"}` | One passing assertion, from any task |
| child to runner | `{"event":"end","index":2}` | The handler returned, with no task left running |
| child to runner | `{"event":"fail","code":"RUNTIME-BDD-ASSERTION","message":"...","expected":"...","actual":"..."}` | A BDD failure (`expected` and `actual` only when known); the child then exits 1 |
| list child to runner | `{"event":"step","pattern":"..."}`, then `{"event":"ready"}` | The definitions in order, then done |

**How the runner reads a step's outcome.** After sending step `i` it reads the child's stdout with `Process.read_line`, up to the scenario deadline:

| What happens | Step `i` | Scenario error |
|---|---|---|
| `end` and step `i` is a `Then` (or its `And`/`But`) with no `assert` since it was sent | failed | `RUNTIME-BDD-NO-ASSERTION` ("Then must perform a BDD assertion"); the runner closes the child |
| `end` otherwise | passed | none; the next step is sent |
| `fail` record | failed | that record's code, message, expected and actual, located at the step |
| end of stdout, and the last stderr line is a JSON diagnostic | failed | that diagnostic as it is (`RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-STEP-LIMIT`, `RUNTIME-UNWRAP-ERROR`, ...), with its own span in the step program |
| end of stdout otherwise (a `System.exit`, even 0, or an exit without a diagnostic) | failed | `RUNTIME-BDD-PREMATURE-EXIT` ("step exited prematurely", with the exit code in the message) |
| the deadline passes | failed | `RUNTIME-BDD-TIMEOUT`; the read times out, which closes the child |
| handler output over 1 MiB (non-record stdout, or stderr) | failed | `RUNTIME-BDD-OUTPUT-LIMIT`. Stdout is counted by the runner as it reads. Stderr needs no wait: once either captured stream is truncated, every stdout read of that child fails with the truncation error, a read already waiting wakes with it, and a zero-byte `Process.read_bytes` returns it at once. So a child that floods stderr fails the step it is in, and the runner also probes after every `end` |

Every step after a failed one is `not_executed`. After the last step passes, the runner closes the child's stdin, waits for exit 0, and fails the scenario with `RUNTIME-BDD-NO-ASSERTION` ("scenario performed no BDD assertions") when no step asserted. The runner closes the child (`Process.close`) on every path.

- **Pending tasks.** On entry, `BDD.run` checks `Task.pending_count() == 0`: a `main` that leaves tasks running gets a `fail` record with `RUNTIME-BDD-PENDING-TASKS`, which the runner reports as a file error of the step program. After a handler returns, the child calls `Task.pending_count()`; above zero is a `fail` record with `RUNTIME-BDD-PENDING-TASKS`. Without this check, a task left running would be cancelled silently when the child exits, and an assertion it would have failed would never be reported. Assertions made by tasks that ended before the handler returned count for that step. Then, if a program under test is running, the child probes it with a zero-byte `Process.read_bytes`; a truncated stream is a `fail` record with `RUNTIME-BDD-OUTPUT-LIMIT`, so output over the limit fails the step in which it happened.
- **Cleanup.** When the child ends, the VM kills and reaps the program under test (`docs/vm/10-io-processes.md` §10.4). The runner closes each child with `Process.close` (or a read timeout closes it), which for a captured child sends `SIGTERM` first and `SIGKILL` after one second, so the child VM's own signal handling kills the program under test before it dies; the `agentica` CLI it started then takes its VM with it (`PR_SET_PDEATHSIG`, `vm/main.c`). If `agentica test` is interrupted, `SIGINT` reaches the whole foreground process group, and on a break the driver kills the runner VM with `SIGTERM`; each VM's signal handling then kills its own children.
- **Seeds.** With `--seed N`, every scenario child and every program under test gets `--seed N`, so handlers and programs repeat.
- **Driver.** `src/bdd-driver.rkt` parses the options (usage errors print a report with `RUNTIME-BDD-USAGE` and exit 2; two `--steps` is one), compiles the step program (a front-end or `LOWER-` diagnostic is a file error of the step program, exit 1; a file that cannot be read is `RUNTIME-BDD-INFRA`, exit 2) and the runner from its embedded root, and writes both `.agcb` files and the configuration into a private temporary directory. The configuration is `config.jsonl`: its first line is the settings as JSON, decoded with `JSON.decode` into a struct, then one line per discovered file or discovery error, so a long list never meets the argument limit or the 1 MiB line limit. The VM path is found as for a normal run (`AGENTICA_VM`, then next to the executable or the checkout). The driver removes `AGENTICA_VM_METRICS` and `AGENTICA_VM_METRICS_FILE` from the runner VM's environment, so every child inherits the cleaned environment. If the runner exits 0, 1 or 2 with an empty stderr, the driver prints its stdout and exits with its code; otherwise (a bug in the runner, a missing VM) it prints a report with one `RUNTIME-BDD-INFRA` file error that names the runner's diagnostic, and exits 2. The report is built by `std/test/report`; the plain and `--ai` texts print `PASS` or `FAIL`, the feature and the scenario, the diagnostic on the next line (plain) or after ` | ` (`--ai`), with `; expected ...; actual ...` in the inspect form, and the last line `N passed, N failed, N not executed, N file errors`.

## Unit test files (`Test.run`)

A unit test file is a `*_test.agc` program whose `main` calls `Test.run` with a list of `Test.test(name) do ... end` blocks; the language rules are in [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md) ("Unit tests (`Test`)"). Each test file is compiled on its own (a front-end error is a file error of that file) and runs in its own child VM, one task per test, with 30 seconds per test (RUNTIME-TEST-TIMEOUT, and the rest of the file is not executed).

### Runner protocol

The test runner (`agentica test`, roadmap 25b) starts the file with the program arguments `--agentica-test list` or `--agentica-test run`, and `Test.run` answers with records on stdout, each one line made of U+001E, `agentica-bdd ` and a JSON object with sorted keys. In both modes the first line on stdin is a token chosen by the runner (empty when stdin is missing or closed). The VM guarantees two things: every record carries the token as `token`, and every record starts a line (a newline is written first when the program's output through `puts`, `print` or `IO.inspect` stopped mid-line; bytes written to `/dev/stdout` with `File` functions are not tracked). The runner checks both, and takes a line as a record only when it starts with the marker and carries the token, so a line the program prints cannot pass for a record. Stdin belongs to the runner in both modes: for the program, from the start of `main`, it is empty (`IO.gets` gives the end-of-input error, `IO.read` gives `""`, `IO.eof?` is true), and file descriptor 0 is `/dev/null`, so `/dev/stdin` reads nothing too.

- `list` writes `{"column":C,"event":"test","line":L,"name":N,"token":T}` for each test in order, at the `Test.test` call, then `{"event":"ready"}`, and ends the run. No test runs.
- `run` reads one test index (from 0) per line on stdin, after the token. For each, it runs the test in a new task, a child of the task that called `Test.run`, waits for it, and writes `{"event":"pass"}` or a `fail` record: the diagnostic as `--json` writes it (`code`, `file`, `message`, `range`) plus `"event":"fail"` and, for an assertion, `expected` and `actual` as the raw texts. At the end of stdin it ends the run. A line that is not a test index in plain digits (no sign, no leading zero) is a `fail` record with RUNTIME-BDD-INFRA, and exit 1.

In both modes, the run ends as a return from `main` does: exit 0, or exit 1 with the summary line on stderr when a task crash was never observed, such as a crash outside every test.

### Failure order

The order in which a failed test reports its failure is part of the `Test` builtin: see [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md#unit-tests-test).

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

## Decided against

- **Port BDD to C.** It would be the biggest C module after HTTP, all of it pure computation over strings (std-first says no), and handlers would still need a way to fail one scenario without ending the run.
- **One process for the whole suite.** A crash, a `System.exit` or a step limit in a handler would end every scenario. Agentica has no exceptions, and adding them for BDD is not worth a second error model.
- **One process per step.** State and the program under test would have to cross processes, and there would be many more processes.
- **The user's step program as the runner.** Its `main` would run with `--allow-run` and no limit in the process that writes the report; a `puts` in `main` would break the JSON report.
- **The runner starts the programs under test and proxies their streams**, so handlers would not need `--allow-run`. Without channels a child cannot match replies to its tasks, so a receive task next to a send would break. And a limit list such as `--allow-run-only PATH` is no boundary: a handler could start `agentica --allow-run` with any program. The owner decided on 2026-10-12 that handlers may always spawn.
- **An implicit context with module state.** Agentica has no mutable globals, by design.
- **A result file instead of records on stdout.** It needs a temporary directory per scenario and gives no progress while the child runs; the marker on stdout costs nothing.
