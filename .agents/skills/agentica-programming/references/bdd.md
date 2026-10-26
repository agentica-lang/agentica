# BDD feature specifications

`agentica test [PATH...] [--steps FILE] [--only TEXT] [--ai|--json]` runs
`.feature` files and `*_test.agc` unit test files. It searches directories in
sorted order (folder links are not followed; a feature file is at most 1 MiB);
the default paths are `specs/` and `test/`. `--steps FILE` names the one step
program (repeating it is `RUNTIME-BDD-USAGE`); without it, a run with features
uses the nearest `steps.agc` in the folder of each path (the path if a folder)
or above it, up to the working directory (two different ones are
`RUNTIME-BDD-USAGE`). Empty discovery fails. Exit codes: 0 all pass, 1
verification fails, 2 infrastructure or usage fails. Programs under test run as
local processes on the VM. File and output rules shared with unit tests:
`testing.md`.

English syntax: `Feature`, one optional `Background` before scenarios,
`Scenario`/`Example`, `Scenario Outline` plus `Examples`, and
`Given`/`When`/`Then`/`And`/`But`. Each Examples row becomes a scenario,
substituting `<column>` in names, steps, Doc Strings and tables. Comments, tags
and descriptions before steps are accepted; tags never skip tests. `Rule`, `*`,
other keyword aliases and localized syntax fail explicitly. `And`/`But` inherit
the previous kind. Triple-quote Doc Strings are dedented; include a final empty
line to keep a trailing newline. Data Tables decode `\|`, `\\`, `\n`. One
argument per step.

Predefined step patterns (the keyword is irrelevant for matching):

```text
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

- The context rule: most BDD calls take the scenario's `ctx` first and return
  it; use the one they return. `BDD.doc_string`, `BDD.table` and `BDD.get` take
  it and return their value (`started = BDD.given_program(ctx, "../app.agc")`,
  then `BDD.when_line(started, "hi")`). A handler returns the context it ends
  with; the next step gets it. Only `set` and `given_program` change it, but any
  BDD call can end a handler or block. `BDD.Context` can be named, not built.
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
  `actual` in the inspect form (`"text"` quoted, `3`, a JSON line as canonical
  text), each cut at 64 Ki characters.
- Missing Doc Strings/tables fail (`RUNTIME-BDD-CONTEXT`); absent state returns
  an error Result. Every `Then` (And/But included) and every scenario must
  perform a BDD assertion. A BDD failure ends the step at once.
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
  million (library work included); output is limited to 1 MiB of unread stdout,
  1 MiB of stderr and 1 MiB of handler output per step.
- `--only TEXT` (once, not empty) keeps scenarios and tests whose name contains
  `TEXT`; no match is `CHECK-BDD-EMPTY`. Without `--seed N` every child shares
  the seed the runner drew (`testing.md`). A `*_test.agc` file in `specs/` is a
  test file: a helper with that name fails with `RUNTIME-TEST-RUN`. Use port 0
  and fresh temporary directories, not fixed names.
- To run a suite from a program, start `agentica test --json` with
  `Process.spawn` and parse its report: `ok`, `passed`, `failed`,
  `not_executed`, `file_errors`, `exit_code`, `seed`, `files`.

## Diagnostics

`agentica test` reports the first problem of each kind with a stable code:

- `PARSE-GHERKIN-HEADER`, `PARSE-GHERKIN-STEP`, `PARSE-GHERKIN-ARGUMENT`,
  `PARSE-GHERKIN-TABLE`, `PARSE-GHERKIN-EXAMPLES`, `PARSE-GHERKIN-TAGS`,
  `PARSE-GHERKIN-EMPTY`, `PARSE-GHERKIN-PARAMETER`, `PARSE-GHERKIN-UNSUPPORTED`:
  the `.feature` file breaks the supported Gherkin subset (section order, a step
  outside a scenario, a Doc String or table in the wrong place, bad Examples,
  misplaced tags, a Feature without scenarios or a Background without steps, an
  Examples column missing for a `<parameter>`, a non-English keyword).
- `CHECK-BDD-UNDEFINED`, `CHECK-BDD-AMBIGUOUS`, `CHECK-BDD-EMPTY`: no step
  pattern matches; more than one matches; no `.feature` or `*_test.agc` files
  found (or no name matches `--only`).
- `RUNTIME-BDD-ASSERTION`, `RUNTIME-BDD-NO-ASSERTION`: an expectation failed; a
  `Then` step or a whole scenario made no BDD assertion.
- `RUNTIME-BDD-TIMEOUT`, `RUNTIME-BDD-PREMATURE-EXIT`: an operation or the
  scenario passed its deadline, or got a bad timeout; a step called
  `System.exit` or its child ended without a diagnostic.
- `RUNTIME-BDD-CONTEXT`, `RUNTIME-BDD-PROGRAM`, `RUNTIME-BDD-JSON`: a missing
  Doc String or table, a stream call before a program started, a second program,
  a step program that never calls `BDD.run`; a missing `.agc` program; a JSON
  expectation that is not valid JSON.
- `RUNTIME-BDD-DUPLICATE`, `RUNTIME-BDD-PATTERN`, `RUNTIME-BDD-PENDING-TASKS`: a
  pattern used twice, an invalid pattern (both at the step program's first
  line); tasks left running by a handler or by `main` before `BDD.run`.
- `RUNTIME-BDD-OUTPUT-LIMIT`, `RUNTIME-BDD-IO`, `RUNTIME-BDD-INFRA`,
  `RUNTIME-BDD-USAGE`: program or handler output over 1 MiB; a stream I/O
  failure, a feature file or step line over 1 MiB; a missing executable, VM or
  feature path, an unreadable folder or broken `.feature` link, a step program
  that cannot be read; bad command-line usage, such as two `--steps`.

A step program that does not compile is a file error with its own diagnostic
(for example `CHECK-TYPE-MISMATCH` for a handler of the wrong type). A crash in
a step keeps the VM's code (`RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-STEP-LIMIT`,
...) and its span in the step program; BDD failures are located at the feature
step.
