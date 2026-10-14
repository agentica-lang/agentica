# Executable BDD specifications

`agentica test` runs `.feature` specifications and `*_test.agc` unit test files in one report. Steps are predefined or written in Agentica. Matching is deterministic: an unknown or ambiguous step fails. Programs under test run as local processes. The step API is the standard module `std/bdd`, and the runner is a fixed Agentica program embedded in `agentica`. The user guide is [`library/testing/bdd.md`](../site/content/library/testing/bdd.md).

## Run

```sh
make exe
dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc
dist/agentica --ai test tests/bdd/specs/json-lines.feature
make test-bdd
```

`make exe` builds the CLI. `racket src/main.rkt test ...` runs from source after `make vm`. `agentica test` builds and installs nothing.

```text
agentica [--ai|--json] [--allow-run] [--seed N] test [PATH...] [--steps FILE] [--only TEXT] [--ai|--json] [--allow-run]
```

- **Discovery.** With no paths, `specs/` and `test/` are searched; a missing default folder is skipped, and if neither exists the run fails with `CHECK-BDD-EMPTY`. Folders are searched recursively for `.feature` and `*_test.agc`, sorted and deduplicated. An unreadable folder, a broken `.feature` link or a non-UTF-8 name is a `RUNTIME-BDD-INFRA` file error, and the search goes on. A symbolic link to a folder is not followed: one named like a target (`x.feature`, `x_test.agc`) is a `RUNTIME-BDD-INFRA` file error, any other is skipped; a path named on the command line is used as given. A feature file over 1 MiB is `RUNTIME-BDD-IO`.
- **`--steps FILE`** names the one step program (two is `RUNTIME-BDD-USAGE`). It may come before or after `test`. Without it, only the predefined steps exist. A program that does not compile is a file error even when no feature needs it.
- **`--only TEXT`** (once, not empty; otherwise `RUNTIME-BDD-USAGE`) keeps the scenarios and tests whose name contains `TEXT`. If none matches, the run fails with `CHECK-BDD-EMPTY`.
- **Seed.** Every run has one: `--seed N`, or one the runner draws. It reaches every step program, test file and program under test. A failing run's text report shows it on the summary line, so `--seed N` replays the run. The JSON report always has it; a usage report has `null` when no `--seed` was given.
- **`--allow-run`** lets programs under test start programs. Step handlers always can.
- **Exit codes.** 0 when every scenario passes and there is at least one; 1 for verification failures or an empty suite; 2 for usage errors and any `RUNTIME-BDD-INFRA`. All three output formats give the same verdict.
- **JSON report.** Keys: `ok`, `passed`, `failed`, `not_executed`, `file_errors`, `exit_code`, `seed`, `files`. Each file has `path`, `feature`, `kind` (`feature`, `tests`, `steps` for the step program, or `""`), `status`, `scenarios`, `error` and `output`. Each test is a scenario with `steps: []` at its `Test.test` call. A test is `passed`, `failed`, or `not_executed` (after a test that ended the file's child VM).
- **Text report.** `PASS`, `FAIL` or `NOT RUN`, then `file / name`. Only failed tests have `output`: their stdout, plus stderr if their child VM died during them, the last 64 Ki characters. Stdout printed by `main` before `Test.run` belongs to the first test.
- **Summary line.** The text report ends with `N passed, M failed, K not executed, F file errors`, and `, seed S` is added when the run fails.
- **Limits.** Unread stdout over 1 MiB fails the running test with `RUNTIME-BDD-OUTPUT-LIMIT`. Stderr is captured for the whole file, up to 1 MiB; past that the file fails, and the test then running is `NOT RUN`. These limits count characters. Longer texts in reports are cut at 64 Ki characters, with `...`.
- **Expected and actual.** A failed `then_*` check compares with `Test.eq` and shows its values in inspect form (a JSON line as its canonical text). An undefined or ambiguous step's `actual` is the step text. Front-end type errors keep `expected` and `actual` as raw type names, such as `Int` and `String`. Reports show no other handler or program output.

## Feature files

### Gherkin rules

The parser supports English `Feature`, `Background`, `Scenario`, `Example`, `Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And` and `But`. It returns the first error (`std/bdd/gherkin`). A location's column is 1, and its range runs to the end of the line.

- **Lines and tags.** Blank lines and `#` comments are skipped; `# language: en` is accepted, and any other `# language:` is `PARSE-GHERKIN-UNSUPPORTED`. Tags start with `@` and each `@` needs a non-space character after it (`PARSE-GHERKIN-TAGS`). Tags before a step, or left at the end of the file, are `PARSE-GHERKIN-TAGS`. Tags are copied into the report and never skip anything.
- **Headings.** A name is required except for `Background` and `Examples` (`PARSE-GHERKIN-HEADER`). One `Feature` comes first (`PARSE-GHERKIN-HEADER`). Free text is a description only before the first step, with no tags waiting and not after `Examples`; otherwise `PARSE-GHERKIN-STEP`.
- **Background** comes at most once, before any scenario, without tags (`PARSE-GHERKIN-HEADER`). Its steps run before each scenario's steps. A Background, scenario or Feature without steps is `PARSE-GHERKIN-EMPTY`.
- **Outlines.** `Scenario Outline` needs an `Examples` block; `Examples` outside an outline is `PARSE-GHERKIN-EXAMPLES`, and so is a table with no header row, an empty or repeated header cell, or no rows. Each row is a scenario, with `<name>` replaced in the name, steps, Doc Strings and cells. A `<name>` that is not a column is `PARSE-GHERKIN-PARAMETER`. Several `Examples` blocks add their rows in order, and a row's tags are the Feature's, then the scenario's, then its `Examples` block's.
- **Steps.** A step outside a Background or scenario, or after `Examples`, is `PARSE-GHERKIN-STEP`. `And` and `But` take the kind of the step before them in the section, and need one. The keyword does not matter for matching; the kind matters for the `Then` rule.
- **Doc Strings.** The opening `"""` may be followed by a media type (ignored; only letters, digits, `_`, `.`, `/`, `+` and `-`); other text after it is `PARSE-GHERKIN-ARGUMENT`. The content ends at the next `"""` line (missing: `PARSE-GHERKIN-ARGUMENT` at the opening line). Each line loses up to the opening line's indentation, and lines are joined with LF.
- **Data tables.** Rows start with `|` and end at an unescaped `|`. Cells are trimmed. `\|`, `\\` and `\n` are decoded; any other escape, a lone final `\`, or uneven rows are `PARSE-GHERKIN-TABLE`.
- **One argument per step.** A Doc String or table must follow a step in a Background or scenario, with no tags waiting. A step takes at most one (`PARSE-GHERKIN-ARGUMENT`).
- **Not supported**, each `PARSE-GHERKIN-UNSUPPORTED`: `Rule:`, `Scenario Template:`, `Scenarios:`, `*` steps, backtick Doc Strings, a keyword followed by a colon, and localized keywords.

Program paths in a feature are relative to the feature's directory, and programs run there. CLI paths and the step program are relative to the working directory.

### Matching

Every step of a scenario is matched against every definition, predefined steps first, before the scenario starts. A pattern is literal text plus `{string}` (single or double quotes; a backslash escapes the next character) and `{int}` (an optional `-` and ASCII digits). Captures arrive as strings, in order; quoted ones lose their delimiters and unescape. A match covers the whole text, with backtracking, and `{int}` is tried from the longest digit run to the shortest. Any other `{...}`, or a stray brace, is `RUNTIME-BDD-PATTERN`. A pattern used twice, predefined ones included, is `RUNTIME-BDD-DUPLICATE`. Both are errors of the step program at its first line.

No match is `CHECK-BDD-UNDEFINED`, and two or more is `CHECK-BDD-AMBIGUOUS`; both carry the step text in quotes as `actual`. The first unresolved step fails, the other steps of that scenario are `not_executed`, and no child starts.

## Predefined steps

The patterns are in [`library/testing/bdd.md`](../site/content/library/testing/bdd.md) ("Built-in steps"). Each is a handler in `std/bdd`:

| Step | What it does and its errors |
| --- | --- |
| `the Agentica program {string}` | `Process.spawn_captured` of `agentica [--allow-run] [--seed N] --max-steps 1000000 PATH` in the feature's directory, 30 s to start. A missing `.agc` file is `RUNTIME-BDD-PROGRAM`; a missing `agentica` is `RUNTIME-BDD-INFRA`. |
| `I send ...`, `I close stdin` | `Process.send` or `Process.close_stdin`, 5 s. Closed stdin is `RUNTIME-BDD-CONTEXT`; a timeout is `RUNTIME-BDD-TIMEOUT`; other errors are `RUNTIME-BDD-IO`. |
| `I receive ...` (three forms) | `Process.read_line` within the timeout. A different line, or an ended stdout, is `RUNTIME-BDD-ASSERTION`; a timeout is `RUNTIME-BDD-TIMEOUT`; the output limit is `RUNTIME-BDD-OUTPUT-LIMIT`. The JSON form parses both lines (`RUNTIME-BDD-JSON` if either is invalid) and compares canonical texts. |
| `stdin remains open` | A send of empty text succeeds, and `Process.wait` for 1 ms times out; otherwise `RUNTIME-BDD-ASSERTION`. |
| `the program exits with code {int} ...` | `Process.wait`; a timeout is `RUNTIME-BDD-TIMEOUT`; a truncated output is `RUNTIME-BDD-OUTPUT-LIMIT`; then the code is compared. |
| `stdout is:`, `stderr is:` | Need an exited program (`RUNTIME-BDD-CONTEXT`, "complete output requires program exit"). Stdout is what no line step has read yet; stderr is all of it. |

JSON lines compare by their canonical text, `JSON.encode(JSON.parse(line))`: key order and whitespace do not matter, arrays keep their order, and value kinds stay distinct. Timeouts must be positive.

## Step programs

A step program is a normal program: its `main` builds the list of steps with `BDD.step` and passes it to `BDD.run`. Signatures are in [`library/testing/bdd.md`](../site/content/library/testing/bdd.md).

- A handler gets the scenario's context and returns the context it ends with; the next step gets that one. Most `BDD` calls take the context first and return it, and `BDD.doc_string`, `BDD.table` and `BDD.get` return their value instead. Only `BDD.set` and `BDD.given_program` change the context. Use the one each call returns: a handler that drops the context `BDD.given_program` returned loses the program under test.
- `BDD.doc_string` or `BDD.table` on a step without one is `RUNTIME-BDD-CONTEXT`. `BDD.get` of a missing name is `error("missing scenario state")`. A stream call before `BDD.given_program`, or a second program in a scenario, is `RUNTIME-BDD-CONTEXT`.
- Every `Then` step, including its `And` and `But`, must make at least one BDD assertion, and every scenario must make one. A BDD failure ends the step at once.
- `BDD.run` adds the predefined steps in front of the list and never returns. A step program that never calls it is `RUNTIME-BDD-CONTEXT`. Run directly, it prints `run this step program with agentica test --steps FILE` on stderr and exits 2.
- `main` runs once to list the steps and again in each scenario, so it should only build the list. Anything else it prints goes nowhere.
- Handlers may use tasks and pass `ctx` in a struct. Assertions made in tasks count. A context changed in a task is lost unless the handler takes it back from `Task.await`. Tasks must end before the handler returns (`RUNTIME-BDD-PENDING-TASKS`); the same holds for tasks that `main` leaves running before `BDD.run`.
- A handler's stdin is the runner's protocol pipe, so handlers must not read it.
- A step program that does not compile is one file error. A crash in a step keeps the VM's code and its span in the step program. BDD failures are located at the feature step.

## Isolation and process lifetime

`agentica test` compiles the step program and the runner to bytecode in a private temporary directory, and runs the runner on the VM. The runner lists the steps in one child VM, then runs **each scenario in its own child VM**, which runs the step program in scenario mode. A step that crashes, calls `System.exit` (even with 0), exceeds its step limit or loops forever fails only its scenario (`RUNTIME-BDD-PREMATURE-EXIT` for an exit). Its remaining steps are `not_executed`, and the next scenario runs. A step program that does not compile, does not list its steps, or has a bad pattern is one file error, and then no scenario runs.

- **Host access.** BDD gives no isolation from the host: programs run with the user's permissions and environment. Each scenario child runs with `--allow-run`. Programs under test start with the same `agentica` command, `--max-steps 1000000`, and `--allow-run` only when `agentica test` has it.
- **Limits.** A scenario has a 30-second deadline from the start of its child. Program-driving calls without a timeout get 5 seconds, and starting a program gets 30. The scenario child has 1,000,000 steps per step plus 1,000,000, and that budget also pays for `std/bdd`'s own work; builtins cost steps per call, not per byte. Unread stdout and stderr are each kept up to 1 MiB, checked after every step. Handler output is limited to 1 MiB per step.
- **Cleanup.** When a scenario ends, its child is closed and stops the program under test; the runner closes each child with `Process.close`, which sends `SIGTERM`, then `SIGKILL` after one second. An interrupted run stops its children and removes its temporary directory. On Linux the runner also ends, and stops its children, when the driver is killed with `SIGKILL` (see [`vm/10-io-processes.md`](vm/10-io-processes.md) §10.4).
- **Temporary directory.** Each run holds an exclusive lock on a `lock` file. A later `agentica test` removes a same-user directory whose lock it can take. Without `flock`, the run fails with `RUNTIME-BDD-INFRA` (exit 2), and so does a temporary directory that other users can write without the sticky bit; set `TMPDIR` to a private folder.
- **Shared resources.** Test files and scenarios run one at a time, each in its own child VM, next to other programs. A fixed temporary file name or port can collide with another run; use port 0 and a fresh temporary directory.

## How a run works

```text
agentica test [PATH...] [--steps FILE]        (Racket driver, src/bdd-driver.rkt)
  compiles std/test/runner (embedded) and the step program to .agcb files
  in a private temporary directory, then runs the runner on the VM:
    1. list child:    steps.agcb --agentica-bdd list   -> the patterns, in order
    2. per .feature:  parse, expand, match
    3. per scenario:  steps.agcb --agentica-bdd scenario (own child VM)
                      <- one init line, then one line per step (stdin)
                      -> assert, end, fail records (stdout)
    4. the report: plain, --ai or --json on stdout; exit 0, 1 or 2
```

- **The runner is a fixed program.** User code never runs in the process that writes the report. A user's `main` runs only in children, always under a step limit, a deadline and captured output.
- **One step program, two modes.** The list child and the scenario child are the same `.agcb`, chosen by `System.args`, so step numbers match.
- **Scenario child.** Started with `--json` (so a crash leaves its diagnostic as the last stderr line), `--allow-run`, and `--max-steps` of 1,000,000 times the number of steps plus one. The list child is the same with `list` and a 30-second limit.
- **Protocol.** One JSON record per line. A child's record starts with U+001E, then `agentica-bdd `, then the JSON; the runner finds the marker anywhere in a line, and everything else on stdout is handler output. The runner sends a step only after the previous one ended.

| Direction | Record | Meaning |
|---|---|---|
| runner to child | settings, once (`base`, `agentica`, `allow_run`, `seeded`, `seed`) | Where programs resolve and run, how to start `agentica`, and what to pass on |
| runner to child | `{"index":2,"definition":14,...}` | Run step 2 with definition 14; a pattern mismatch is `RUNTIME-BDD-INFRA` |
| runner to child | end of stdin | `BDD.run` ends the child with `System.exit(0)` |
| child to runner | `assert`, `end` (with `index`), `fail` (with `code`, `message`, and `expected` and `actual` when known) | A passing assertion; the handler returned with no task left running; a BDD failure (the child then exits 1) |
| list child to runner | `step` records, then `ready` | The definitions in order |

**Outcome of a step.** After sending step `i`, the runner reads the child's stdout with `Process.read_line`, up to the scenario deadline:

| What happens | Step `i` | Scenario error |
|---|---|---|
| `end`, and step `i` is a `Then` (or its `And`/`But`) with no `assert` since it was sent | failed | `RUNTIME-BDD-NO-ASSERTION` (the child is closed) |
| `end` otherwise | passed | none |
| `fail` record | failed | that record's code, message, expected and actual, at the step |
| stdout ends, and the last stderr line is a JSON diagnostic | failed | that diagnostic, with its span in the step program |
| stdout ends otherwise (a `System.exit`, even 0, or no diagnostic) | failed | `RUNTIME-BDD-PREMATURE-EXIT` |
| the deadline passes | failed | `RUNTIME-BDD-TIMEOUT` (the read closes the child) |
| handler output over 1 MiB (non-record stdout, or stderr) | failed | `RUNTIME-BDD-OUTPUT-LIMIT` |

Every step after a failed one is `not_executed`. After the last step passes, the runner closes stdin, waits for exit 0, and fails the scenario with `RUNTIME-BDD-NO-ASSERTION` when no step asserted. The runner closes each child on every path.

- **Pending tasks.** `BDD.run` checks `Task.pending_count() == 0` on entry, and the child checks it after each handler. A count above zero is a `fail` record with `RUNTIME-BDD-PENDING-TASKS`. Without this check, a task left running would be cancelled silently, and its failed assertion would never be reported. Then, if a program under test is running, the child probes it with a zero-byte `Process.read_bytes`; a truncated stream is `RUNTIME-BDD-OUTPUT-LIMIT`.
- **Driver.** `src/bdd-driver.rkt` parses the options and writes the configuration to `config.jsonl`, one line per file, so long lists never meet an argument or line limit. If the runner fails with stderr output, the driver reports one `RUNTIME-BDD-INFRA` file error and exits 2.

## Unit test files (`Test.run`)

A unit test file is a `*_test.agc` program whose `main` calls `Test.run`; the language rules are in [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md). Each file is compiled on its own, and runs in its own child VM with one task per test. A test over 30 seconds is `RUNTIME-TEST-TIMEOUT`, and the rest of the file does not run.

The runner starts the file with `--agentica-test list` or `--agentica-test run` and sends a token as the first stdin line. Every record carries the token and starts a line, so program output cannot pass for one. For the program, stdin is empty: `IO.gets` gives the end-of-input error, and file descriptor 0 is `/dev/null`.

- `list` writes `{"column":C,"event":"test","line":L,"name":N,"token":T}` for each test, then `{"event":"ready"}`. No test runs.
- `run` reads one test index per line, from 0. It runs each test in a new task, a child of `main`'s task, and writes `{"event":"pass"}` or a `fail` record: the `--json` diagnostic (`code`, `file`, `message`, `range`) with `"event":"fail"`, plus `expected` and `actual` for an assertion. A line that is not a plain index is a `fail` record with `RUNTIME-BDD-INFRA`, and exit 1.

The order in which a failed test reports its failure is part of the `Test` builtin: see [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md#unit-tests-test).

## Decided against

- Porting BDD to C: the handlers still need a way to fail one scenario without ending the run.
- One process for the suite, or one per step: a crash would end every scenario, or state would cross processes.
- The user's step program as the runner: its `main` would run without a limit in the process that writes the report.
- Proxying the programs' streams from the runner: without channels, a receive task next to a send would break.
- An implicit context with module state: Agentica has no mutable globals.
- A result file instead of stdout records: it needs a temporary directory per scenario.

## Diagnostics

`agentica test` reports the first problem of each kind with a stable code:

| Code | Meaning |
|---|---|
| `PARSE-GHERKIN-*` (`HEADER`, `STEP`, `ARGUMENT`, `TABLE`, `EXAMPLES`, `TAGS`, `EMPTY`, `PARAMETER`, `UNSUPPORTED`) | The `.feature` file breaks the supported subset; the rule is in the Gherkin list above |
| `CHECK-BDD-UNDEFINED`, `CHECK-BDD-AMBIGUOUS`, `CHECK-BDD-EMPTY` | No step matches, more than one matches, or no feature or test file was found (or `--only` matches nothing) |
| `RUNTIME-BDD-ASSERTION`, `RUNTIME-BDD-NO-ASSERTION` | An expectation failed, or a `Then` step or a whole scenario made no BDD assertion |
| `RUNTIME-BDD-TIMEOUT`, `RUNTIME-BDD-PREMATURE-EXIT` | A deadline or timeout passed; a step called `System.exit`, or its child ended without a diagnostic |
| `RUNTIME-BDD-CONTEXT`, `RUNTIME-BDD-PROGRAM`, `RUNTIME-BDD-JSON` | A missing Doc String or table, a stream call before a program started, a second program, a step program that never calls `BDD.run`, a missing `.agc` program, or a JSON expectation that is not valid JSON |
| `RUNTIME-BDD-DUPLICATE`, `RUNTIME-BDD-PATTERN`, `RUNTIME-BDD-PENDING-TASKS` | A pattern used twice, an invalid pattern (both at the step program's first line), or tasks left running before a step ends or before `BDD.run` |
| `RUNTIME-BDD-OUTPUT-LIMIT`, `RUNTIME-BDD-IO`, `RUNTIME-BDD-INFRA`, `RUNTIME-BDD-USAGE` | Output over 1 MiB; a stream I/O failure, or a line over 1 MiB; a missing executable, VM or path, an unreadable folder, a broken link, a step program that cannot be read, or a runner failure; bad command-line usage |
| `RUNTIME-TEST-*` | The unit test codes, reported per test: see [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md) |
