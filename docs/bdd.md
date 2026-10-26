# Executable BDD specifications

`agentica test` runs `.feature` specifications and `*_test.agc` unit test files
in one report. Steps are predefined or written in Agentica. Matching is
deterministic: an unknown or ambiguous step fails. Programs under test run as
local processes. The step API is the standard module `std/bdd`, and the runner
is a fixed Agentica program embedded in `agentica`. The user guide is
[`library/testing/bdd.md`](../site/content/library/testing/bdd.md).

## Run

```sh
make
dist/agentica test tests/bdd/specs/ --steps tests/bdd/handlers.agc
dist/agentica --ai test tests/bdd/specs/json-lines.feature
make test-bdd
```

`make` builds the binary, which carries the driver and the runner.
`agentica test` builds and installs nothing.

```text
agentica [--ai|--json] [--seed N] test [PATH...] [--steps FILE] [--only TEXT] [--ai|--json]
```

- **Discovery.** With no paths, `specs/` and `test/` are searched; a missing
  default folder is skipped, and if neither exists the run fails with
  `CHECK-BDD-EMPTY`. Folders are searched recursively for `.feature` and
  `*_test.agc`, sorted and deduplicated. An unreadable folder, a broken
  `.feature` link or a non-UTF-8 name is a `RUNTIME-BDD-INFRA` file error, and
  the search goes on. A symbolic link to a folder is not followed: one named
  like a target (`x.feature`, `x_test.agc`) is a `RUNTIME-BDD-INFRA` file error,
  any other is skipped; a path named on the command line is used as given. A
  feature file over 1 MiB is `RUNTIME-BDD-IO`.
- **`--steps FILE`** names the one step program (two is `RUNTIME-BDD-USAGE`). It
  may come before or after `test`. Without it, only the predefined steps exist.
  A program that does not compile is a file error even when no feature needs it.
- **`--only TEXT`** (once, not empty; otherwise `RUNTIME-BDD-USAGE`) keeps the
  scenarios and tests whose name contains `TEXT`. If none matches, the run fails
  with `CHECK-BDD-EMPTY`.
- **Seed.** Every run has one: `--seed N`, or one the runner draws. It reaches
  every step program, test file and program under test. A failing run's text
  report shows it on the summary line, so `--seed N` replays the run. The JSON
  report always has it; a usage report has `null` when no `--seed` was given.
- **Permissions.** Step handlers and programs under test can start programs.
  `agentica test` takes the `--deny-*` flags and `--sandbox`, in front of
  `test` or after it. They reach every test file, step program and program
  under test, not the runner, which still reads the test folders and starts
  them. With `--deny-run` (or `--sandbox`) a step cannot start a program under
  test. Under `--deny-fs` a missing program under test shows as exit 2 from
  its `agentica` command.
- **Exit codes.** 0 when every scenario passes and there is at least one; 1 for
  verification failures or an empty suite; 2 for usage errors and any
  `RUNTIME-BDD-INFRA`. All three output formats give the same verdict.
- **JSON report.** Keys: `ok`, `passed`, `failed`, `not_executed`,
  `file_errors`, `exit_code`, `seed`, `files`. Each file has `path`, `feature`,
  `kind` (`feature`, `tests`, `steps` for the step program, or `""`), `status`,
  `scenarios`, `error` and `output`. Each test is a scenario with `steps: []` at
  its `Test.test` call. A test is `passed`, `failed`, or `not_executed` (after a
  test that ended the file's child VM).
- **Text report.** `PASS`, `FAIL` or `NOT RUN`, then `file / name`. A failure
  that has a call stack (a runtime error in a test, or in a step handler) shows
  it under the diagnostic: the line `  stack, innermost first:`, then one line
  per frame (`name at file:line:column`). With `--ai` it is ` | stack ` and the
  frames joined by `; `. Only failed tests have `output`: their stdout, plus
  stderr if their child VM died during them, the last 64 Ki characters. Stdout
  printed by `main` before `Test.run` belongs to the first test.
- **Summary line.** The text report ends with
  `N passed, M failed, K not executed, F file errors`, and `, seed S` is added
  when the run fails.
- **Limits.** Unread stdout over 1 MiB fails the running test with
  `RUNTIME-BDD-OUTPUT-LIMIT`. Stderr is captured for the whole file, up to 1
  MiB; past that the file fails, and the test then running is `NOT RUN`, when
  the file exits within a 2-second grace after the cut. A file still running
  after the grace (it is stuck in the test that printed) is reported as that
  test failing with `RUNTIME-BDD-OUTPUT-LIMIT`. A file that prints more than 1
  MiB while it lists its tests is a file error with the same code. These limits
  count characters. Longer texts in reports are cut at 64 Ki characters, with
  `...`.
- **Expected and actual.** A failed `then_*` check compares with `Test.eq` and
  shows its values in inspect form (a JSON line as its canonical text). An
  undefined or ambiguous step's `actual` is the step text. Front-end type errors
  keep `expected` and `actual` as raw type names, such as `Int` and `String`.
  Reports show no other handler or program output.

## Feature files

### Gherkin rules

The parser supports English `Feature`, `Background`, `Scenario`, `Example`,
`Scenario Outline`, `Examples`, `Given`, `When`, `Then`, `And` and `But`. It
returns the first error (`std/bdd/gherkin`). A location's column is 1, except a
step's, which is its keyword's (after the indentation); a range runs to the end
of the line.

- **Lines and tags.** Blank lines and `#` comments are skipped; `# language: en`
  is accepted, and any other `# language:` is `PARSE-GHERKIN-UNSUPPORTED`. Tags
  start with `@` and each `@` needs a non-space character after it
  (`PARSE-GHERKIN-TAGS`). Tags before a step, or left at the end of the file,
  are `PARSE-GHERKIN-TAGS`. Tags are copied into the report and never skip
  anything.
- **Headings.** A name is required except for `Background` and `Examples`
  (`PARSE-GHERKIN-HEADER`). One `Feature` comes first (`PARSE-GHERKIN-HEADER`).
  Free text is a description only before the first step, with no tags waiting
  and not after `Examples`; otherwise `PARSE-GHERKIN-STEP`.
- **Background** comes at most once, before any scenario, without tags
  (`PARSE-GHERKIN-HEADER`). Its steps run before each scenario's steps. A
  Background, scenario or Feature without steps is `PARSE-GHERKIN-EMPTY`.
- **Outlines.** `Scenario Outline` needs an `Examples` block; `Examples` outside
  an outline is `PARSE-GHERKIN-EXAMPLES`, and so is a table with no header row,
  an empty or repeated header cell, or no rows. Each row is a scenario, with
  `<name>` replaced in the name, steps, Doc Strings and cells. The scenario's
  name ends with ` (a, b)`: the row's values in the columns that the outline's
  name does not show, so each row has its own name in the report and for
  `--only` (`Name (sqlite, 42)`; a name that shows every column gets nothing).
  A `<name>` that is not a column is `PARSE-GHERKIN-PARAMETER`. Several
  `Examples` blocks add their rows in order, and a row's tags are the Feature's,
  then the scenario's, then its `Examples` block's.
- **Steps.** A step outside a Background or scenario, or after `Examples`, is
  `PARSE-GHERKIN-STEP`. `And` and `But` take the kind of the step before them in
  the section, and need one. The keyword does not matter for matching; the kind
  matters for the `Then` rule.
- **Doc Strings.** The opening `"""` may be followed by a media type (ignored;
  only letters, digits, `_`, `.`, `/`, `+` and `-`); other text after it is
  `PARSE-GHERKIN-ARGUMENT`. The content ends at the next `"""` line (missing:
  `PARSE-GHERKIN-ARGUMENT` at the opening line). Each line loses up to the
  opening line's indentation, and lines are joined with LF.
- **Data tables.** Rows start with `|` and end at an unescaped `|`. Cells are
  trimmed. `\|`, `\\` and `\n` are decoded; any other escape, a lone final `\`,
  or uneven rows are `PARSE-GHERKIN-TABLE`.
- **One argument per step.** A Doc String or table must follow a step in a
  Background or scenario, with no tags waiting. A step takes at most one
  (`PARSE-GHERKIN-ARGUMENT`).
- **Not supported**, each `PARSE-GHERKIN-UNSUPPORTED`: `Rule:`,
  `Scenario Template:`, `Scenarios:`, `*` steps, backtick Doc Strings, a keyword
  followed by a colon, and localized keywords.

Program paths in a feature are relative to the feature's directory, and programs
run there. CLI paths and the step program are relative to the working directory.

### Matching

Every step of a scenario is matched against every definition, predefined steps
first, before the scenario starts. A pattern is literal text plus `{string}`
(single or double quotes; a backslash escapes the next character) and `{int}`
(an optional `-` and ASCII digits). Captures arrive as strings, in order; quoted
ones lose their delimiters and unescape. A match covers the whole text, with
backtracking, and `{int}` is tried from the longest digit run to the shortest.
Any other `{...}`, or a stray brace, is `RUNTIME-BDD-PATTERN`. A pattern used
twice, predefined ones included, is `RUNTIME-BDD-DUPLICATE`. Both are errors of
the step program at its first line.

No match is `CHECK-BDD-UNDEFINED`, and two or more is `CHECK-BDD-AMBIGUOUS`;
both carry the step text in quotes as `actual`. The first unresolved step fails,
the other steps of that scenario are `not_executed`, and no child starts.

## Predefined steps

The patterns are in
[`library/testing/bdd.md`](../site/content/library/testing/bdd.md) ("Built-in
steps"). Each is a handler in `std/bdd`:

- **Step:** `the Agentica program {string}`
  - **What it does and its errors:** `Process.spawn_captured` of `agentica
    [--seed N] PATH` in the feature's directory, 30 s to start. A missing
    `.agc` file is `RUNTIME-BDD-PROGRAM`; a missing `agentica` is
    `RUNTIME-BDD-INFRA`.

- **Step:** `I send ...`, `I close stdin`
  - **What it does and its errors:** `Process.send` or `Process.close_stdin`, 5
    s. Closed stdin is `RUNTIME-BDD-CONTEXT`; a timeout is
    `RUNTIME-BDD-TIMEOUT`; other errors are `RUNTIME-BDD-IO`.

- **Step:** `I receive ...` (three forms)
  - **What it does and its errors:** `Process.read_line` within the timeout. A
    different line, or an ended stdout, is `RUNTIME-BDD-ASSERTION`; a timeout is
    `RUNTIME-BDD-TIMEOUT`; the output limit is `RUNTIME-BDD-OUTPUT-LIMIT`. The
    JSON form parses both lines (`RUNTIME-BDD-JSON` if either is invalid) and
    compares canonical texts.

- **Step:** `stdin remains open`
  - **What it does and its errors:** A send of empty text succeeds, and
    `Process.wait` for 1 ms times out; otherwise `RUNTIME-BDD-ASSERTION`.

- **Step:** `the program exits with code {int} ...`
  - **What it does and its errors:** `Process.wait`; a timeout is
    `RUNTIME-BDD-TIMEOUT`; a truncated output is `RUNTIME-BDD-OUTPUT-LIMIT`;
    then the code is compared.

- **Step:** `stdout is:`, `stderr is:`
  - **What it does and its errors:** Need an exited program
    (`RUNTIME-BDD-CONTEXT`, "complete output requires program exit"). Stdout is
    what no line step has read yet; stderr is all of it.

JSON lines compare by their canonical text, `JSON.encode(JSON.parse(line))`: key
order and whitespace do not matter, arrays keep their order, and value kinds
stay distinct. Timeouts must be positive.

## Step programs

A step program is a normal program: its `main` builds the list of steps with
`BDD.step` and passes it to `BDD.run`. Signatures are in
[`library/testing/bdd.md`](../site/content/library/testing/bdd.md).

- A handler gets the scenario's context and returns the context it ends with;
  the next step gets that one. Most `BDD` calls take the context first and
  return it, and `BDD.doc_string`, `BDD.table` and `BDD.get` return their value
  instead. Only `BDD.set` and `BDD.given_program` change the context. Use the
  one each call returns: a handler that drops the context `BDD.given_program`
  returned loses the program under test.
- `BDD.doc_string` or `BDD.table` on a step without one is
  `RUNTIME-BDD-CONTEXT`. `BDD.get` of a missing name is
  `error("missing scenario state")`. A stream call before `BDD.given_program`,
  or a second program in a scenario, is `RUNTIME-BDD-CONTEXT`.
- Every `Then` step, including its `And` and `But`, must make at least one BDD
  assertion, and every scenario must make one. A BDD failure ends the step at
  once.
- `BDD.run` adds the predefined steps in front of the list and never returns. A
  step program that never calls it is `RUNTIME-BDD-CONTEXT`. Run directly, it
  prints `run this step program with agentica test --steps FILE` on stderr and
  exits 2.
- `main` runs once to list the steps and again in each scenario, so it should
  only build the list. Anything else it prints goes nowhere.
- Handlers may use tasks and pass `ctx` in a struct. Assertions made in tasks
  count. A context changed in a task is lost unless the handler takes it back
  from `Task.await`. Tasks must end before the handler returns
  (`RUNTIME-BDD-PENDING-TASKS`); the same holds for tasks that `main` leaves
  running before `BDD.run`.
- A handler's stdin is an empty pipe the runner closes at once: reading it gives
  the end of input. The protocol is on the child channel, not on stdin or
  stdout, so a handler may print anything.
- A step program that does not compile is one file error. A crash in a step
  keeps the VM's code and its span in the step program. BDD failures are located
  at the feature step.

## Isolation and process lifetime

`agentica test` compiles the step program and the runner to bytecode in a
private temporary directory, and runs the runner on the VM. The runner lists the
steps in one child VM, then runs **each scenario in its own child VM**, which
runs the step program in scenario mode. A step that crashes, calls `System.exit`
(even with 0), exceeds its step limit or loops forever fails only its scenario
(`RUNTIME-BDD-PREMATURE-EXIT` for an exit). Its remaining steps are
`not_executed`, and the next scenario runs. A step program that does not
compile, does not list its steps, or has a bad pattern is one file error, and
then no scenario runs.

- **Host access.** BDD gives no isolation from the host: programs run with the
  user's permissions and environment. Programs under test start with the same
  `agentica` command and no step limit, as `agentica FILE.agc` does.
- **Limits.** A scenario has a 30-second deadline from the start of its child;
  it is the only bound on the CPU and memory of a program under test.
  Program-driving calls without a timeout get 5 seconds, and starting a program
  gets 30. The scenario child has 1,000,000 steps per step plus 1,000,000, and
  that budget also pays for `std/bdd`'s own work; builtins cost steps per call,
  not per byte. Unread stdout and stderr are each kept up to 1 MiB, checked
  after every step. Handler output is limited to 1 MiB per step.
- **Cleanup.** When a scenario ends, its child is closed and stops the program
  under test; the runner closes each child with `Process.close`, which sends
  `SIGTERM`, then `SIGKILL` after one second. An interrupted run (Ctrl-C,
  `SIGTERM`) stops its children, but its temporary directory may stay until the
  next `agentica test` removes it, because the VM does not unwind (the Racket
  driver always removed it; `docs/future/18-front-end-language.md` §18.4, until
  signals, §46). On Linux the runner also ends, and stops its children, when
  the driver is killed with `SIGKILL` (see
  [`vm/10-io-processes.md`](vm/10-io-processes.md) §10.4).
- **Temporary directory.** Each run holds an exclusive lock on a `lock` file
  (`flock`; `LockFileEx` on Windows). A later `agentica test` removes a
  same-user directory whose lock it can take. A run killed while it makes its
  directory leaves `agentica-bdd-new-HEX`; the sweep removes it too, once it is
  an hour old and its lock is free. Without the lock, the run fails with
  `RUNTIME-BDD-INFRA` (exit 2), and so does a temporary directory that other
  users can write without the sticky bit; set `TMPDIR` to a private folder.
  On Windows the folder is the first of `TMPDIR`, `TMP` and `TEMP` that is a
  folder, the run directory has its final name from the start (there is no
  `-new-` name and no rename), and the sweep takes a directory only when it is
  a minute old. Windows has no sticky bit, so nothing checks the temporary
  folder: the run assumes a temporary folder that only the user can modify (the
  default per-user `%TEMP%`). A shared multi-user temporary folder is out of
  scope, because another user who can delete entries of that folder could swap
  the run directory before its `lock` pins it.
- **Shared resources.** Test files and scenarios run one at a time, each in its
  own child VM, next to other programs. A fixed temporary file name or port can
  collide with another run; use port 0 and a fresh temporary directory.

## How a run works

```text
agentica test [PATH...] [--steps FILE]
  (the driver, compiler/bdd/bdd_driver.agc, runs in the front end of the binary)
  compiles std/test/runner (embedded) and the step program to .agcb files
  in a private temporary directory, then runs the runner with
  `agentica run` of the same binary:
    1. list child:    steps.agcb --agentica-bdd list   -> the patterns, in order (channel)
    2. per .feature:  parse, expand, match
    3. per scenario:  steps.agcb --agentica-bdd scenario (own child VM)
                      <- one init line, then one line per step (channel)
                      -> assert, end, fail records (channel)
    4. the report: plain, --ai or --json on stdout; exit 0, 1 or 2
```

- **The runner is a fixed program.** User code never runs in the process that
  writes the report. A user's `main` runs only in children, always under a step
  limit, a deadline and captured output.
- **One step program, two modes.** The list child and the scenario child are the
  same `.agcb`, chosen by `System.args`, so step numbers match.
- **Scenario child.** Started with `--json` (so a crash leaves its diagnostic as
  the last stderr line) and `--max-steps` of 1,000,000 times the number of
  steps plus one. The list child is the same with `list` and a 30-second limit.
- **Protocol.** One JSON record per line, on the child channel: a bidirectional
  socket pair of its own, opened by `Process.spawn_channel` and found by the
  child on descriptor 3 (`docs/vm/10-io-processes.md` §10.4). A record is plain
  JSON with no marker and no token. The child's stdin is closed at once, and its
  stdout and stderr are the program's own, so nothing a handler prints can pass
  for a record. The child flushes its stdout before it sends a record. The
  runner sends a step only after the previous one ended.

- **Direction:** runner to child
  - **Record:** settings, once (`base`, `agentica`, `seeded`, `seed`)
  - **Meaning:** Where programs resolve and run, how to start `agentica`, and
    what to pass on

- **Direction:** runner to child
  - **Record:** `{"index":2,"definition":14,...}`
  - **Meaning:** Run step 2 with definition 14; a pattern mismatch is
    `RUNTIME-BDD-INFRA`

- **Direction:** runner to child
  - **Record:** end of the channel (`Process.channel_close`)
  - **Meaning:** `BDD.run` ends the child with `System.exit(0)`

- **Direction:** child to runner
  - **Record:** `assert`, `end` (with `index`), `fail` (with `code`, `message`,
    and `expected` and `actual` when known)
  - **Meaning:** A passing assertion; the handler returned with no task left
    running; a BDD failure (the child then exits 1)

- **Direction:** list child to runner
  - **Record:** `step` records, then `ready`
  - **Meaning:** The definitions in order

**Outcome of a step.** After sending step `i`, the runner reads the channel with
`Process.channel_read_line`, up to the scenario deadline. After an `end` or
`fail` record it reads what the handler printed with `Process.read_available`,
which the child flushed before the record:

- **What happens:** `end`, and step `i` is a `Then` (or its `And`/`But`) with no
  `assert` since it was sent
  - **Step `i`:** failed
  - **Scenario error:** `RUNTIME-BDD-NO-ASSERTION` (the child is closed)

- **What happens:** `end` otherwise
  - **Step `i`:** passed
  - **Scenario error:** none

- **What happens:** `fail` record
  - **Step `i`:** failed
  - **Scenario error:** that record's code, message, expected and actual, at the
    step

- **What happens:** the channel ends, and the last stderr line is a JSON
  diagnostic
  - **Step `i`:** failed
  - **Scenario error:** that diagnostic, with its span in the step program

- **What happens:** the channel ends otherwise (a `System.exit`, even 0, or no
  diagnostic)
  - **Step `i`:** failed
  - **Scenario error:** `RUNTIME-BDD-PREMATURE-EXIT`

- **What happens:** the deadline passes
  - **Step `i`:** failed
  - **Scenario error:** `RUNTIME-BDD-TIMEOUT` (the read closes the channel, and
    the runner then closes the child)

- **What happens:** handler output over 1 MiB unread (stdout, or stderr)
  - **Step `i`:** failed
  - **Scenario error:** `RUNTIME-BDD-OUTPUT-LIMIT`

Every step after a failed one is `not_executed`. After the last step passes, the
runner closes the channel, waits for its end and for exit 0, and fails the
scenario with `RUNTIME-BDD-NO-ASSERTION` when no step asserted. The runner
closes each child on every path.

- **Pending tasks.** `BDD.run` checks `Task.pending_count() == 0` on entry, and
  the child checks it after each handler. A count above zero is a `fail` record
  with `RUNTIME-BDD-PENDING-TASKS`. Without this check, a task left running
  would be cancelled silently, and its failed assertion would never be reported.
  Then, if a program under test is running, the child probes it with a zero-byte
  `Process.read_bytes`; a truncated stream is `RUNTIME-BDD-OUTPUT-LIMIT`.
- **Driver.** The driver (`compiler/bdd/bdd_driver.agc`, part of the front end
  of the binary, so it runs in the process that `agentica test` started) parses
  the options and writes the configuration to `config.jsonl`, one line per file,
  so long lists never meet an argument or line limit. The runner writes its
  report to a file of the run directory, which the driver prints, so a report is
  not limited to the 1 MiB that a captured stream keeps. If the runner fails
  with stderr output, the driver reports one `RUNTIME-BDD-INFRA` file error and
  exits 2.

## Unit test files (`Test.run`)

A unit test file is a `*_test.agc` program whose `main` calls `Test.run`; the
language rules are in
[`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md). Each file is
compiled on its own, and runs in its own child VM with one task per test. A test
over 30 seconds is `RUNTIME-TEST-TIMEOUT`, and the rest of the file does not
run.

The runner starts the file with `--agentica-test list` or `--agentica-test run`
and a child channel (`Process.spawn_channel`, descriptor 3,
`docs/vm/10-io-processes.md` §10.4). The records and the test indexes travel on
the channel, as plain JSON lines with no marker and no token. The test's own
stdin and stdout are free: the runner closes the child's stdin at once, so
`IO.gets` gives the end-of-input error, and whatever the test prints, even a
line shaped like a record, is only output. `Test.run` flushes stdout before it
sends each record, and the runner reads the output of a test with
`Process.read_available` once the record has arrived. A failed test shows the
last 64 Ki characters of that output; a passing test shows none. A test that
prints more than 1 MiB is `RUNTIME-BDD-OUTPUT-LIMIT`, also when it never ends:
the runner learns of the cut from its pending read, closes the channel, gives
the child a short grace and then fails the test (with no output when the child
was still running). `Test.run` without a channel, under these arguments, is
`RUNTIME-TEST-RUN`, and so is a call from any task but `main`'s own.
`Process.parent_read_line` and `Process.parent_send` are for runner code: a test
that calls them can break the protocol, and nothing stops it.

- `list` sends `{"column":C,"event":"test","line":L,"name":N}` for each test,
  then `{"event":"ready"}`. No test runs.
- `run` reads one test index per line from the channel, from 0, and ends at the
  end of the channel. It runs each test in a new task, a child of the task that
  called `Test.run`, and sends `{"event":"pass"}` or a `fail` record: the
  `--json` diagnostic (`code`, `file`, `message`, `range`) with
  `"event":"fail"`, plus `expected` and `actual` for an assertion, and `stack`,
  `stack_omitted` and `spawned_at` (as `--json` writes them) when the test's
  task crashed with a runtime error. A line that
  is not a plain index, or not valid UTF-8, is a `fail` record with
  `RUNTIME-BDD-INFRA`, and exit 1.

The order in which a failed test reports its failure is part of the `Test`
builtin: see
[`grammar/06c-tasks-and-tests.md`][agentica-link-1].

## Decided against

- Porting BDD to C: the handlers still need a way to fail one scenario without
  ending the run.
- One process for the suite, or one per step: a crash would end every scenario,
  or state would cross processes.
- The user's step program as the runner: its `main` would run without a limit in
  the process that writes the report.
- Proxying the programs' streams from the runner: without channels, a receive
  task next to a send would break.
- An implicit context with module state: Agentica has no mutable globals.
- A result file instead of stdout records: it needs a temporary directory per
  scenario.

## Diagnostics

`agentica test` reports the first problem of each kind with a stable code:

- **Code:** `PARSE-GHERKIN-*` (`HEADER`, `STEP`, `ARGUMENT`, `TABLE`,
  `EXAMPLES`, `TAGS`, `EMPTY`, `PARAMETER`, `UNSUPPORTED`)
  - **Meaning:** The `.feature` file breaks the supported subset; the rule is in
    the Gherkin list above

- **Code:** `CHECK-BDD-UNDEFINED`, `CHECK-BDD-AMBIGUOUS`, `CHECK-BDD-EMPTY`
  - **Meaning:** No step matches, more than one matches, or no feature or test
    file was found (or `--only` matches nothing)

- **Code:** `RUNTIME-BDD-ASSERTION`, `RUNTIME-BDD-NO-ASSERTION`
  - **Meaning:** An expectation failed, or a `Then` step or a whole scenario
    made no BDD assertion

- **Code:** `RUNTIME-BDD-TIMEOUT`, `RUNTIME-BDD-PREMATURE-EXIT`
  - **Meaning:** A deadline or timeout passed; a step called `System.exit`, or
    its child ended without a diagnostic

- **Code:** `RUNTIME-BDD-CONTEXT`, `RUNTIME-BDD-PROGRAM`, `RUNTIME-BDD-JSON`
  - **Meaning:** A missing Doc String or table, a stream call before a program
    started, a second program, a step program that never calls `BDD.run`, a
    missing `.agc` program, or a JSON expectation that is not valid JSON

- **Code:** `RUNTIME-BDD-DUPLICATE`, `RUNTIME-BDD-PATTERN`,
  `RUNTIME-BDD-PENDING-TASKS`
  - **Meaning:** A pattern used twice, an invalid pattern (both at the step
    program's first line), or tasks left running before a step ends or before
    `BDD.run`

- **Code:** `RUNTIME-BDD-OUTPUT-LIMIT`, `RUNTIME-BDD-IO`, `RUNTIME-BDD-INFRA`,
  `RUNTIME-BDD-USAGE`
  - **Meaning:** Output over 1 MiB; a stream I/O failure, or a line over 1 MiB;
    a missing executable, VM or path, an unreadable folder, a broken link, a
    step program that cannot be read, or a runner failure; bad command-line
    usage

- **Code:** `RUNTIME-TEST-*`
  - **Meaning:** The unit test codes, reported per test: see
    [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md)

[agentica-link-1]: grammar/06c-tasks-and-tests.md#unit-tests-test
