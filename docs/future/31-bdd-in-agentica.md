## 31. BDD in Agentica

**Status:** done (roadmap phase 21, 21a to 21f). Decided on 2026-10-12: BDD on the VM (a catch-up item of 7h; it removes the `BDD` fallback before 7i deletes the evaluator) is written **in Agentica**, as the `std/bdd` module and a small runner program, not ported to C. Order of the catch-up, decided by the user on 2026-10-13: TCP (done), then TLS (done), then HTTP 20a (done), then BDD in Agentica (this section, phase 21; it needs only 20a), then HTTP 20b to 20d, then 7i.

The idea in one paragraph: `agentica test` compiles two programs, a fixed runner (embedded, written in Agentica) and the user's step program (a normal program with `main` that imports `std/bdd`, builds its list of steps and calls `BDD.run`). The runner parses the `.feature` files, matches steps to patterns and writes the report. It runs **each scenario in its own child VM**: the step program, started again in a scenario mode. A crash, a `System.exit`, a step limit or a timeout of that child fails only that scenario, as today. Step handlers get an explicit context (`ctx`) instead of the implicit current scenario, because Agentica has no mutable globals. Three small builtins are added to C, each one something Agentica cannot do (31.9). Step handlers can always call `Process.spawn`, because each scenario child runs with `--allow-run`: the user decided this on 2026-10-12 (31.10; the rejected options are in 31.13).

Phase 21 has six PRs (roadmap [`21-bdd-in-agentica.md`](../roadmap/21-bdd-in-agentica.md)): the two process builtins, the task count, the Gherkin parser, the matcher with the canonical JSON rule, the report, and the switch.

### 31.1 Today

Checked at `0c2e3b0`:

- `agentica test [PATH...] [--steps FILE]` is handled in `src/main.rkt:166-198`; it calls `run-bdd` (`src/bdd-runner.rkt:168-216`), which runs everything inside the Racket process on the frozen evaluator.
- Gherkin is parsed by `src/gherkin.rkt:13-229` with Racket regular expressions; its tests are `tests/gherkin-test.rkt`.
- Step files are evaluated: `load-definitions` (`src/bdd-runner.rkt:74-109`) runs each `--steps` file's `main`, which may only call `BDD.step`; each handler later runs as its own evaluation with an entrypoint and its captures (`src/bdd-runner.rkt:99-103`), with one million steps, suppressed and bounded output (`quiet-output`, `src/bdd-runner.rkt:31-40`) and `#:require-complete-tasks? #t` (`src/bdd-runner.rkt:44-47`), which gives `RUNTIME-BDD-PENDING-TASKS` (`src/task.rkt:48`).
- The builtins (`src/builtins.rkt:91-107`) read an implicit current scenario: `BDD.doc_string`, `BDD.table`, `BDD.set`, `BDD.get`, `BDD.assert` and the program-driving calls are served by `bdd-call` (`src/bdd.rkt:114-219`) on a mutable `bdd-context` (`src/bdd.rkt:9-10`) with locks per stream.
- The predefined steps are `built-in-definitions` (`src/bdd-runner.rkt:49-72`). Patterns are compiled to regular expressions (`compile-step-pattern`, `src/bdd.rkt:221-236`; `match-step-pattern`, `src/bdd.rkt:238-244`); undefined and ambiguous steps are found before a scenario starts (`resolve`, `src/bdd-runner.rkt:111-120`).
- A program under test runs as `racket src/main.rkt --legacy-eval --max-steps 1000000 FILE` (or the packaged executable), in the feature's directory, with stdout and stderr drained by threads into 1 MiB buffers (`default-bdd-command`, `src/bdd.rkt:16-21`; `start-program!`, `src/bdd.rkt:69-112`). Each scenario has a 30-second deadline (`src/bdd.rkt:25`).
- `BDD.run(feature_path, step_files)` also runs a suite from a program, through the fallback (`make-bdd-service`, `src/bdd-runner.rkt:218-232`).
- Isolation today comes from the evaluator: a handler that divides by zero, calls `System.exit` or loops forever fails only its scenario (`tests/bdd/handlers.agc:30-41`, `tests/bdd-test.rkt:92-119`).
- What the VM has today and this plan uses: closures and blocks stored in structs and lists; `std/` modules embedded at build time (`src/stdlib.rkt:17-18`), whose relative imports stay inside `std/` (`src/modules.rkt:79-82`); `Map`, `JSON.*` (parse, encode, decode into structs, builders), `File.read_text`, `File.stat`, `Dir.list`, `Path.join` and `Path.resolve`, `System.args`, `System.exit`, `Time.monotonic_ms`, tasks, and every `Process` builtin behind `--allow-run` (`docs/vm/10-io-tls-processes-http.md` §10.4).
- What the VM lacks for BDD: a child's stderr is always forwarded to the VM's own stderr (`forward_err`, `vm/process.c:403-416`), so a program cannot read it; a child always runs in the VM's working directory (`uv_process_options_t` in `vm/process.c:532`, no `cwd`); a child's stdout is read only on request, so a child that writes a lot while nobody reads blocks; and a program cannot see whether tasks are still running (the VM knows: `pending_tasks`, `vm/task.c:129-132`). JSON values cannot list their keys (`JSON.kind` and friends are phase 10).
- The `BDD` alias is reserved today: `import "std/bdd" as BDD` gives `CHECK-REDEFINED-NAME` while the builtin module exists.

### 31.2 Shape

```text
agentica test [PATH...] [--steps FILE]          (Racket driver, src/bdd-driver.rkt)
  compiles std/bdd/runner (embedded root) and the step program to two .agcb
  in a private temporary directory, then runs:
  agentica-vm --allow-run [--seed N] -- runner.agcb CONFIG-JSON
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
- **The step program is both the list child and the scenario child.** One `.agcb`, two modes chosen by `System.args`. Patterns, predefined steps and user steps come from the same `BDD.run(steps)` call in both modes, so the step numbers the runner sends match the ones the child runs.
- Scenarios run one at a time, as today. Running them in parallel is a later option (a `--jobs N` flag), not part of this phase.
- **Cost.** One runner VM and one list child per run, and one child VM per scenario. A VM starts in about a millisecond and loads the step program's bytecode, so a child per scenario is cheap next to what most scenarios already pay: each `the Agentica program "..."` step starts the `agentica` CLI (Racket start-up, then compile, then the VM), as today. The driver compiles the runner (about 1,500 lines of Agentica) on every `agentica test`; 21f measures it, and caching the compiled runner is a later option if it shows.

### 31.3 Gherkin: the subset, unchanged

`std/bdd/gherkin.agc` (21c) is internal, like `std/bdd/match.agc` (21d), `std/bdd/report.agc` (21e) and `std/bdd/runner.agc` (21f): they are registered in `src/stdlib.rkt` so that `std/bdd.agc` and the golden fixtures can import them, which also makes them importable by any program, but they are unsupported (not in the programming skill or the site, and their API may change in any PR). No import guard is added for them. It parses exactly what `src/gherkin.rkt` parses today, with the same diagnostic codes, the same first error and the same locations. It works on `String` and lines: `String.split(text, "\n")`, a trailing CR removed from each line, `String.trim` for the trimmed text, and `String.split(line, "")` once per line when it must look at characters (a list of one-character strings, indexed in O(1)). It returns a `Feature` value or one diagnostic, never halts. The subset, as written in `src/gherkin.rkt`:

- **Lines.** Empty lines and lines that start with `#` are skipped. `# language: en` is accepted; any other `# language:` line is `PARSE-GHERKIN-UNSUPPORTED` ("only English Gherkin is supported").
- **Tags.** A line that starts with `@` must be tags separated by spaces or tabs, each `@` followed by at least one non-space character (`PARSE-GHERKIN-TAGS` "invalid tags"). Tags wait for the next `Feature`, `Scenario`, `Example`, `Scenario Outline` or `Examples`. Tags before a step are `PARSE-GHERKIN-TAGS` ("tags must precede a section"); tags left at the end of the file too ("tags without a section", at line 1). Tags never skip anything; they are copied into the report.
- **Headings.** `Feature:`, `Background:`, `Scenario Outline:`, `Scenario:`, `Example:` and `Examples:` at the start of the trimmed line, then spaces or tabs, then the name. A name is required except for `Background` and `Examples` (`PARSE-GHERKIN-HEADER` "a section needs a name"). One `Feature` per file, first (`PARSE-GHERKIN-HEADER`); a missing one is "missing Feature" at line 1.
- **Background.** At most once, before any scenario, without tags (`PARSE-GHERKIN-HEADER`). Its steps run before each scenario's own steps. A Background without steps is `PARSE-GHERKIN-EMPTY`.
- **Scenarios.** `Scenario` and `Example` are the same. A scenario without steps is `PARSE-GHERKIN-EMPTY`; a Feature without scenarios too.
- **Outlines.** `Scenario Outline` needs at least one `Examples` (`PARSE-GHERKIN-EXAMPLES`); `Examples` outside an outline is `PARSE-GHERKIN-EXAMPLES`. After `Examples:`, blank and comment lines are skipped and a table follows, with a header row and at least one row; header cells are not empty and are unique (`PARSE-GHERKIN-EXAMPLES`). Several `Examples` blocks add rows; tags before an `Examples` apply to its rows. Each row becomes a scenario: `<name>` is replaced in the scenario name, the step text, the Doc String and the table cells; a name that is not a column is `PARSE-GHERKIN-PARAMETER` at the row. A scenario's tags are the Feature's, then the scenario's, then the Examples block's.
- **Steps.** `Given`, `When`, `Then`, `And`, `But`, then spaces or tabs, then the text. A step outside a Background or scenario, or after `Examples`, is `PARSE-GHERKIN-STEP`. `And` and `But` take the kind of the step before them in the same section; with none before, `PARSE-GHERKIN-STEP`. The keyword does not matter for matching; the kind matters only for the `Then` assertion rule (31.5).
- **Doc Strings.** A line that is `"""`, optionally followed by a media type of letters, digits and `_ . / + -` (ignored); anything else after the quotes is `PARSE-GHERKIN-ARGUMENT`. Content lines run to the next line whose trimmed text is `"""`; without one, `PARSE-GHERKIN-ARGUMENT` at the opening line. Each content line loses as many leading spaces or tabs as the opening line's indentation, at most; lines are joined with LF, so a final empty line keeps a final newline.
- **Data Tables.** Rows are lines that start with `|`, read while they do. A row ends with an unescaped `|`; cells are trimmed; `\|`, `\\` and `\n` are decoded, any other escape or a final lone `\` is an error; every row has the same width; a row has at least one cell. All of these are `PARSE-GHERKIN-TABLE`.
- **One argument per step.** A Doc String or table must follow a step in a Background or scenario, with no tags waiting, and a step takes at most one (`PARSE-GHERKIN-ARGUMENT`).
- **Not supported**, each `PARSE-GHERKIN-UNSUPPORTED`: `Rule:`, `Scenario Template:`, `Scenarios:`, `* ` steps, backtick Doc Strings, and a step keyword followed by a colon (`Then: ...`). Other keyword aliases and other languages are not recognised.
- **Descriptions.** Free text is allowed after a heading as long as the section has no steps yet, no tags are waiting, and it is not after `Examples`; otherwise `PARSE-GHERKIN-STEP` ("unexpected text after steps").
- **Locations.** Every scenario, step and Examples row keeps its line; a location's column is 1, and a diagnostic's range runs from column 1 to the end of the raw line, as today. File names in locations are the feature file's absolute path.
- **Limits.** A feature file is read with `File.read_text`, so it is at most 1 MiB (today it has no limit); a bigger file is `RUNTIME-BDD-INFRA` for that file.

### 31.4 Step patterns and matching

`std/bdd/match.agc` (21d) compiles and matches patterns by hand, with no regular expressions, and gives the same answers as `compile-step-pattern` and `match-step-pattern` (`src/bdd.rkt:221-244`):

- **Compiling.** A pattern is literal text and placeholders. `{string}` and `{int}` are the only placeholders; any other `{...}` is `RUNTIME-BDD-PATTERN` ("only {string} and {int} are supported"), and a `{` or `}` left over is `RUNTIME-BDD-PATTERN` ("unmatched pattern braces"). The result is the literal before the first placeholder, then one slot per placeholder: its capture, `IntCapture` or `StringCapture` (a private enum), and the literal after it.
- **Matching** is a whole-text match, tried piece by piece with backtracking (recursion depth is the number of pieces):
  - a literal must appear exactly at the current position;
  - `{int}` is an optional `-` and one or more ASCII digits; the candidates are tried from the longest to the shortest, the order of the greedy regular expression today;
  - `{string}` is a double-quoted or single-quoted string in which a backslash escapes the next character; it ends at the first unescaped closing quote, so it has only one candidate;
  - the match succeeds only at the end of the text.
- **Captures** come in order, as strings. A quoted capture loses its quotes, and each `\X` becomes `X`. An int capture is the digits as written (`"-3"`).
- **Resolving.** Every step of a scenario is matched against every definition, predefined steps first, before the scenario starts. No match is `CHECK-BDD-UNDEFINED` and two or more is `CHECK-BDD-AMBIGUOUS`, both with the step text as `actual`. The first unresolved step is reported as failed and every other step of that scenario as `not_executed`, and no child starts (as `run-scenario` does today, `src/bdd-runner.rkt:126-160`).
- **Duplicates.** Two definitions with the same pattern text (predefined steps included) are `RUNTIME-BDD-DUPLICATE`.

`RUNTIME-BDD-PATTERN` and `RUNTIME-BDD-DUPLICATE` are found by the runner, which compiles the list it gets from the list child, so they are file errors of the step program located at its first line, with the pattern in the message; today they point at the `BDD.step` call (31.10).

### 31.5 Isolation: one child VM per scenario

Agentica has no exceptions: a handler that divides by zero halts the program. So the runner gives each scenario its own process, and reads how it ended.

**Starting a child.** The runner starts the step program with `Process.spawn_captured` (31.9):

```text
VM --allow-run --json --max-steps M [--seed N] -- STEPS.agcb --agentica-bdd scenario
```

- `M` is 1,000,000 × (the number of steps + 1): today each handler call and the registration get one million steps each, so this keeps the same total. Within it, one step may now use more than one million (31.10).
- `--json` makes the child's last stderr line its diagnostic.
- `--allow-run` is always given, because the child starts the program under test (31.10).
- The child's working directory is the runner's (that of `agentica test`), as for handlers today.
- The list child is the same command with `list`, `--max-steps 1000000`, and a 30-second limit. How it ends is read as for a step (the table below); any failure is a file error of the step program, and then no scenario runs.

**Protocol.** Lines of JSON, one record per line. A record that the child writes starts with the marker U+001E followed by `agentica-bdd ` and the JSON; the runner looks for the marker anywhere in a line, and treats everything else on the child's stdout as handler output.

| Direction | Line | Meaning |
|---|---|---|
| runner → child, first | `{"base":"/abs/dir/of/feature","agentica":["/usr/bin/racket","/abs/src/main.rkt"],"allow_run":false,"seeded":true,"seed":9}` | Scenario settings: where program paths resolve and programs run, how to start `agentica`, and what to pass to programs under test |
| runner → child | `{"index":2,"definition":14,"pattern":"I remember {int}","captures":["7"],"has_doc":true,"doc":"{\"value\":7}","has_table":false,"table":[]}` | Run step 2 with definition 14 (in `BDD.run`'s order, predefined steps first). The child checks that `pattern` is the pattern of its definition 14; a mismatch (a step program that builds its list differently from run to run) is a `fail` record with `RUNTIME-BDD-INFRA`. `has_*` stand in for optional fields, which come with 10e |
| runner → child | end of stdin | No more steps: `BDD.run` ends the child with `System.exit(0)` (it never returns) |
| child → runner | `{"event":"assert"}` | One passing assertion, from any task |
| child → runner | `{"event":"end","index":2}` | The handler returned, with no task left running |
| child → runner | `{"event":"fail","code":"RUNTIME-BDD-ASSERTION","message":"...","expected":"...","actual":"..."}` | A BDD failure (`expected` and `actual` only when known); the child then exits 1 |
| list child → runner | `{"event":"step","pattern":"..."}`, then `{"event":"ready"}` | The definitions in order, then done |

The child reads its stdin with `IO.gets` and writes records with `IO.print` and `IO.flush`. Stdin is the protocol pipe, so a handler that reads stdin takes the next step's line or waits until the deadline; today stdin is empty for handlers (31.10). The runner sends a step only after the previous one ended, so the child never runs a step that should not run.

**How the runner reads a step's outcome.** After sending step `i` it reads the child's stdout with `Process.read_line`, up to the scenario deadline:

| What happens | Step `i` | Scenario error |
|---|---|---|
| `end` and step `i` is a `Then` (or its `And`/`But`) with no `assert` since it was sent | failed | `RUNTIME-BDD-NO-ASSERTION` ("Then must perform a BDD assertion"); the runner closes the child |
| `end` otherwise | passed | none; the next step is sent |
| `fail` record | failed | that record's code, message, expected and actual, located at the step |
| end of stdout, and the last stderr line is a JSON diagnostic | failed | that diagnostic as it is (`RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-STEP-LIMIT`, `RUNTIME-UNWRAP-ERROR`, ...), with its own span in the step program |
| end of stdout otherwise (a `System.exit`, even 0, or an exit without a diagnostic) | failed | `RUNTIME-BDD-PREMATURE-EXIT` ("step exited prematurely", with the exit code in the message) |
| the deadline passes | failed | `RUNTIME-BDD-TIMEOUT`; the read times out, which closes the child |
| handler output over 1 MiB (non-record stdout, or stderr) | failed | `RUNTIME-BDD-OUTPUT-LIMIT`. Stdout is counted by the runner as it reads. Stderr needs no wait: once either captured stream is truncated, every stdout read of that child fails with the truncation error, a read already waiting wakes with it, and a zero-byte `Process.read_bytes` returns it at once (31.9). So a child that floods stderr fails the step it is in, and the runner also probes after every `end` |

Every step after a failed one is `not_executed`. After the last step passes, the runner closes the child's stdin, waits for exit 0, and fails the scenario with `RUNTIME-BDD-NO-ASSERTION` ("scenario performed no BDD assertions") when no step asserted, as today. The runner then closes the child (`Process.close`) on every path.

**Deadlines.** The scenario has 30 seconds from the start of its child, as today; the runner's reads use what is left. Inside the child, the program-driving calls keep their own timeouts (5 seconds by default, the `within N milliseconds` ones, 30 seconds to start a program).

**Pending tasks.** On entry, `BDD.run` checks `Task.pending_count() == 0`: a `main` that leaves tasks running before calling it gets a `fail` record with `RUNTIME-BDD-PENDING-TASKS`, which the runner reports as a file error of the step program (as `#:require-complete-tasks?` does for registration today). After a handler returns, the child calls `Task.pending_count()` (31.9). Above zero is a `fail` record with `RUNTIME-BDD-PENDING-TASKS`, as today. Without this check, a task left running would be cancelled silently when the child exits, and an assertion it would have failed would never be reported. Assertions made by tasks that ended before the handler returned count for that step, as today. Then, if a program under test is running, the child probes it with a zero-byte `Process.read_bytes`; a truncated stream is a `fail` record with `RUNTIME-BDD-OUTPUT-LIMIT`, so output over the limit fails the step in which it happened, as `bdd-output-problem` does after every step today (`src/bdd-runner.rkt:149`).

**Cleanup.** When the child ends, the VM kills and reaps the program under test (§10.4). The runner closes each child with `Process.close` (or a read timeout closes it), which for a captured child sends `SIGTERM` first (31.9), so the child VM's own signal handling kills the program under test before it dies; the `agentica` CLI it started then takes its VM with it (`PR_SET_PDEATHSIG`, `vm/main.c:139-143`). If `agentica test` is interrupted, `SIGINT` reaches the whole foreground process group, and on a break the driver kills the runner VM with `SIGTERM`; each VM's signal handling then kills its own children (§10.4).

**Seeds.** With `--seed N`, every scenario child and every program under test gets `--seed N`, so handlers and programs repeat, as today.

### 31.6 `agentica test`

**CLI**, as today except `--steps`:

```text
agentica [--ai|--json] [--allow-run] [--seed N] test [PATH...] [--steps FILE] [--ai|--json] [--allow-run]
```

- `PATH` is a `.feature` file or a directory searched recursively for `.feature` files; the default is `specs/`. Paths are made absolute and lexical (`Path.resolve`), duplicates removed, and the files sorted by path, as today.
- `--steps FILE` names **one** step program (a program with `main` that calls `BDD.run`, 31.7); it may appear before or after `test`. Given twice, it is `RUNTIME-BDD-USAGE` ("one --steps program; import the other files from it"). Without it, the driver uses an embedded step program with only the predefined steps (`BDD.run([])`), so a suite of predefined steps still needs no file.
- `--allow-run` now decides only whether programs under test get `--allow-run` (31.10).
- `--max-steps` is not used by `test`, as today.

**What the driver does** (`src/bdd-driver.rkt`, new; `src/main.rkt` only parses and calls it):

1. Parse the options (the code of `src/main.rkt:166-196`). Usage errors print a report with `RUNTIME-BDD-USAGE` and exit 2.
2. Compile the step program (front end, lowering, bytecode). A front-end or `LOWER-` diagnostic is a file error of the step program in the report, exit 1; a file that cannot be read is `RUNTIME-BDD-INFRA`, exit 2. Compile the runner from its embedded root (`import "std/bdd/runner" as Runner`, then `Runner.main()`).
3. Write both `.agcb` files into a private temporary directory (mode 0700), and delete it on every path, interrupts included. The VM loads them by path; they are not the one-shot private input of the normal run (`docs/vm/08-loader-and-cli.md` §9).
4. Run the runner VM with `--allow-run` (and `--seed N`), with one argument: the configuration as JSON (`vm`, `steps_bytecode`, `steps_source`, `agentica` as a command list, `paths`, `style`, `allow_run`, `seeded`, `seed`), decoded with `JSON.decode` into a struct. The VM path is found as for a normal run (`AGENTICA_VM`, then next to the executable or the checkout). The `agentica` command is the one `default-bdd-command` finds today (`racket` and `src/main.rkt`, or the packaged executable), without `--legacy-eval`. The driver removes `AGENTICA_VM_METRICS` and `AGENTICA_VM_METRICS_FILE` (§28, phase 18) from the runner VM's environment, so every child, scenario VMs and programs under test included, inherits the cleaned environment; the runner and the children need no code for it.
5. Capture the runner's stdout and stderr. If the runner exits 0, 1 or 2 with an empty stderr, print its stdout and exit with its code. Otherwise (a bug in the runner, a missing VM) print a report with one `RUNTIME-BDD-INFRA` file error that names the runner's diagnostic, and exit 2.

**Exit codes**, unchanged: 0 when every scenario passes and there is at least one; 1 when a scenario or a file fails, or no `.feature` file was found; 2 for usage errors and when any error is `RUNTIME-BDD-INFRA`.

**The report**, unchanged in shape, built by `std/bdd/report.agc` (21e) with `JSON.object`, `JSON.array` and `JSON.from`:

- top level: `ok`, `passed`, `failed`, `not_executed` (always 0, as today), `file_errors`, `exit_code`, `files`;
- each file: `path`, `feature`, `status`, `scenarios`, `error`; the step program's own errors are a file entry with its path and `feature: ""`;
- each scenario: `name`, `status`, `tags`, `location` (`file`, `line`, `column`), `example` (the Examples row's location or `null`), `duration_ms`, `steps`, `error`;
- each step: `text`, `status` (`passed`, `failed`, `not_executed`), `location`, `error`;
- each error: the diagnostic object as the VM's `--json` writes it (`code`, `message`, `file`, `range`, and `expected` and `actual` when known).

The plain and `--ai` formats are those of `format-bdd-report` (`src/bdd-runner.rkt:234-259`): `PASS` or `FAIL`, the feature and the scenario, the diagnostic on the next line (plain) or after ` | ` (`--ai`), with `; expected ...; actual ...` written in the String inspect form, and the last line `N passed, N failed, N not executed, N file errors`. Key order in the JSON may change; nothing reads it.

### 31.7 The `std/bdd` API

```ruby
import "std/bdd" as BDD
```

`BDD` stops being a builtin module in 21f, in the same PR that adds `std/bdd.agc`, so the alias is free (31.1). The module needs no generics: handlers are `Fn` values of one fixed type, state values are `Json`.

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

**Rules.**

- **Names stay.** Every function of today keeps its name; each takes the context first.
- **One rule for the context: every BDD call returns the context; use the one it returns.** Only `set` and `given_program` change it, but the rule has no exceptions, so a handler can end with any BDD call and a block's last expression is its result. A handler returns the context it ends with; the child's `BDD.run` loop passes it to the next step, with the next step's Doc String and table. The runner never sees a context.
- `BDD.Context` is an exported struct whose only field has a private type, so user code can name it in signatures but cannot build one: a context exists only inside a step. Calling `BDD.assert` from `main`, which today is `RUNTIME-BDD-CONTEXT`, is now impossible to write. Its contents (private): scenario state (`Map[String, Json]`), the current step's Doc String and table, the program under test (a private enum, none or one `Process`), and the scenario settings of the init line.
- `BDD.step` returns a value; nothing is registered globally. `BDD.run(steps)` takes the whole list, adds the predefined steps in front, and serves the mode in `System.args` (31.5). It never returns: it ends with `System.exit`. Run directly (`agentica steps.agc`), it prints "run this step program with agentica test --steps FILE" on stderr and exits 2.
- The step program's `main` runs once in the list child and once in each scenario child. It should only build the list and call `BDD.run`; whatever else it does is repeated, and its output goes nowhere.
- **Failing.** A BDD failure (an assertion, a missing Doc String, a timeout, a bad JSON line, ...) writes a `fail` record and calls `System.exit(1)`; the function's result after that is never used. `BDD.assert` with a false condition is `RUNTIME-BDD-ASSERTION` with the message, as today.
- `BDD.doc_string` and `BDD.table` with no argument on the step are `RUNTIME-BDD-CONTEXT`, as today. `BDD.get` of a missing name is `error("missing scenario state")`, as today.
- **Tasks.** A handler may pass `ctx` to tasks inside a struct, as with any value. Assertions in tasks count (they are records on stdout). A context changed in a task is lost unless the handler takes it back from `Task.await`. Tasks must end before the handler returns (31.5).
- The program-driving calls without a started program are `RUNTIME-BDD-CONTEXT` ("start a program before using its streams"), and a second `given_program` too ("only one program may start per scenario"). These hold only along the context chain: the program lives in the context, so a handler that drops the context `given_program` returned, or a task that starts a program in its own copy, is not caught. Today the scenario holds the program, so both rules hold for every call.

Example, `tests/bdd/handlers.agc` after 21f (shortened):

```ruby
import "std/bdd" as BDD

def save_number(ctx: BDD.Context, args: List[String]) -> BDD.Context
  return BDD.set(ctx, "number", Result.unwrap!(JSON.parse(args[0])))
end

def expect_number(ctx: BDD.Context, args: List[String]) -> BDD.Context
  actual = Result.unwrap!(JSON.int(Result.unwrap!(BDD.get(ctx, "number"))))
  return BDD.assert(ctx, actual == String.to_int!(args[0]), "wrong scenario value")
end

def main() -> Void
  limit = 5
  BDD.run([
    BDD.step("I remember {int}", &save_number),
    BDD.step("the remembered number is {int}", &expect_number),
    BDD.step("{int} is small") do |ctx, args|
      BDD.assert(ctx, args[0].to_i! < limit, "too big")
    end
  ])
end
```

Today's checker accepts this shape (a multi-line list of `BDD.step` calls with blocks, an exported struct holding an `Fn` field, an enum holding a `Process`), checked with a stand-in module under another alias.

### 31.8 Predefined steps

Same patterns, same order, same arguments as `built-in-definitions` (`src/bdd-runner.rkt:49-72`), now written in `std/bdd.agc` as handlers over the context API. How each program-driving call works in Agentica:

| Call | How |
|---|---|
| `given_program(path)` | The path resolves against the feature's directory (`Path.join`, `Path.resolve`); it must exist (`File.stat`) and end in `.agc`, else `RUNTIME-BDD-PROGRAM`. Starts `agentica [--allow-run] [--seed N] --max-steps 1000000 PATH` with `Process.spawn_captured` in the feature's directory, 30-second start timeout; a missing `agentica` is `RUNTIME-BDD-INFRA`. |
| `when_line(text)`, `when_input(text)` | `Process.send` with or without LF, 5 seconds. `process: stdin is closed` is `RUNTIME-BDD-CONTEXT` ("stdin is already closed"); a timeout is `RUNTIME-BDD-TIMEOUT`; other errors `RUNTIME-BDD-IO`. |
| `when_eof()` | `Process.close_stdin`, 5 seconds. It is idempotent now (31.10). |
| `then_line(expected, ms)` | `ms` must be positive (`RUNTIME-BDD-TIMEOUT`). `Process.read_line(p, ms)`; equal is an `assert` record, different is `RUNTIME-BDD-ASSERTION` with expected and actual; `network: operation timed out` is `RUNTIME-BDD-TIMEOUT`; `process: end of input` is `RUNTIME-BDD-ASSERTION` ("stdout ended before the expected line"); the output limit is `RUNTIME-BDD-OUTPUT-LIMIT`. The texts are the VM's own (`vm/stream.c:16`, `vm/process.c:277`), pinned by goldens. |
| `then_json_line(expected, ms)` | As `then_line`, then both lines through `JSON.parse` (either invalid: `RUNTIME-BDD-JSON`) and compared by their canonical texts (below). |
| `then_stdin_open()` | `Process.send(p, "", 5000)` succeeds (stdin open) and `Process.wait(p, 1)` times out (still running); otherwise `RUNTIME-BDD-ASSERTION`. |
| `then_exit(code, ms)` | `Process.wait(p, ms)`; a timeout is `RUNTIME-BDD-TIMEOUT`; then `Process.output` must not be truncated (`RUNTIME-BDD-OUTPUT-LIMIT`); then the code is compared. |
| `then_stdout(expected)`, `then_stderr(expected)` | The program must have exited (`Process.wait(p, 1)`), else `RUNTIME-BDD-CONTEXT` ("complete output requires program exit"). `Process.output(p, 5000)`: stdout is what no line step has read yet; stderr is all of it (31.10). |

**JSON equality.** `then_json_line` ignores object key order, keeps array order and keeps number kinds apart, as today. The VM already stores a parsed object's members sorted by key bytes, with a duplicate key keeping its last value (`sort_members`, `vm/json.c:112-153`), and encodes them in that order. 21d pins this in `grammar.md` (JSON): a parsed object encodes with its keys sorted and de-duplicated. Then `JSON.encode(JSON.parse(x))` is canonical, and two lines are equal when their canonical texts are equal: one line in `std/bdd.agc`, no JSON parser or sort in Agentica. A golden fixture holds the rule (key order, nested objects, duplicate keys, arrays, `1` against `1.0`).

**Cost.** The Gherkin and pattern scanners run in the runner, which has no step limit. What runs in the scenario child (the predefined steps, the JSON comparison) spends the child's step budget (31.10); builtins such as `JSON.parse` and `JSON.encode` cost steps by call, not by size, so a long JSON line stays cheap.

### 31.9 What stays in C

The std-first rule (roadmap README, "New library features: `std/` first") holds: the parser, the matcher, the JSON comparison, the runner, the protocol, the context and the report are Agentica. Three builtins are added, because Agentica cannot do these things at all:

```text
Process.spawn_captured(command: String, args: List[String], dir: String, timeout_ms: Int) -> Result[Process]
Process.output(p: Process, timeout_ms: Int) -> Result[ProcessOutput]
Task.pending_count() -> Int
```

- **`Process.spawn_captured`** (21a): like `Process.spawn` (same lookup, `--allow-run`, environment rules, cleanup), with three differences. The child starts in `dir` (`uv_process_options_t.cwd`; `"."` keeps the VM's directory). The VM reads the child's stdout and stderr all the time, so the child never blocks on a full pipe: stdout goes into a buffer that `Process.read_line` and `Process.read_bytes` read from, stderr into its own buffer, never forwarded. Past 1 MiB of unread stdout, or 1 MiB of stderr, the stream is marked truncated and further bytes are dropped; a read on a truncated stdout returns `error("process: output exceeds 1048576 bytes")`. A truncated stream also makes every stdout read fail with that error, wakes a read already waiting, and a zero-byte `Process.read_bytes` returns it at once, so a program can check for a stderr flood without waiting (31.5). **Every close of a captured child sends `SIGTERM`, then `SIGKILL` after one second:** `Process.close`, the close after a stream-I/O timeout or an oversized line (`shut` and its callers, `vm/process.c:188-197`, `278`, `302-309`, which send `SIGKILL` at once today), and the end-of-run cleanup. This applies to every captured child, not only to VMs, so a child that is a VM, or any program that handles `SIGTERM`, can stop its own children first. The grace period never blocks the VM: the handle is closed for the program at once (later calls fail with `process: process is closed`), and a libuv timer sends the `SIGKILL` and reaps the child later, never `nanosleep`. Only the end-of-run cleanup may wait, bounded, as it does today. `Process.spawn` keeps its immediate `SIGKILL`. **The command resolves as for `Process.spawn`:** a relative command or a relative `PATH` entry resolves against the VM's own working directory, not `dir`, because the VM resolves the executable before it starts the child (`docs/vm/10-io-tls-processes-http.md` §10.4); only the child runs in `dir`. A golden pins it (`Process.spawn_captured("./sh", ...)` with `dir` `/bin` is "executable is unavailable"). Exception 1 of the std-first rule: it touches the OS (processes, pipes, signals, the working directory).
- **`Process.output`** (21a): waits until the child's stdout and stderr both end (the child exited and nothing else holds the pipes), then returns `ProcessOutput(stdout: String, stderr: String, truncated: Bool)`, a builtin record like `FileInfo`: the stdout not read yet, all of stderr, and whether either was truncated. It does not consume anything, so it can be called again. A timeout is `error("network: operation timed out")` and keeps the child; a process from `Process.spawn` is an error ("process: output is not captured"). Exception 1.
- **`Task.pending_count`** (21b): the number of tasks of this run that have not ended, not counting `main`; it is `pending_tasks` (`vm/task.c:129-132`) made public. It reads the scheduler's own state, which no Agentica code can see; it is a primitive in the sense of the std-first exceptions (runtime state, like exception 4), not a library function that could move to `std/` later. The prelude helper tasks of 17c (§27.3) are not counted, which is how 17c's "helpers do not count as pending for `RUNTIME-BDD-PENDING-TASKS`" holds after this phase.

All three are public, documented builtins with golden fixtures; none is an internal helper. They are VM-only: until the evaluator is gone, the places that hand a checked program to the evaluator (the fallback and the `--legacy-eval` branch in `src/main.rkt`, and `read-program` in `src/bdd-runner.rkt:20-23`) refuse a program that calls one, with `LOWER-UNSUPPORTED` at the call ("needs the VM"), through the `vm-only-builtins` set and `check-vm-only` that HTTP's 20a adds first ([section 30.8](30-hybrid-http.md#308-migration-what-is-removed-and-what-it-breaks)); 21a and 21b add their names to the set; the frozen evaluator itself does not change. The second goes with its file in 21f, the first with the fallback in 7i.

Nothing else goes in C: `vm/` gets no BDD code, and `agentica-vm` gets no BDD flag.

### 31.10 Breaking changes and migration

| Today | After 21f |
|---|---|
| `BDD` is a builtin module, reserved | `import "std/bdd" as BDD`; `BDD` is free as a name and an alias |
| `BDD.run(feature_path, step_files) -> Result[Json]` | Removed. Run suites with `agentica test`; from a program, `Process.spawn` of `agentica test --json` (needs `--allow-run`) |
| `BDD.step(pattern, Fn[List[String], Void]) -> Void`, registered in `main` | `BDD.step(pattern, Fn[BDD.Context, List[String], BDD.Context]) -> BDD.Step`, collected in a list passed to `BDD.run(steps)` at the end of `main` |
| `BDD.doc_string()`, `BDD.table()`, `BDD.get(name)` | the same with `ctx` first |
| `BDD.assert`, `BDD.set` and the program-driving calls return `Void` | `ctx` first; each returns the context |
| `--steps FILE` repeatable; each file's `main` only registers | One `--steps` program with `main`; other files are imported; `main` runs again in each child |
| Handlers run without `Process.spawn` unless `--allow-run` | Handlers can always call `Process.spawn` (the child has `--allow-run` to start programs under test); `--allow-run` on `test` now only reaches programs under test. The user decided this on 2026-10-12. The flag was never a sandbox; BDD gives no isolation from the host (31.13 keeps the rejected alternatives) |
| One million steps per handler call, spent only by the handler's own code | One million per step plus one million, for the whole scenario child, and the budget now also pays for library code: `std/bdd`'s own work (decoding step lines, the predefined steps, the JSON comparison) runs in the child and spends its steps. Builtins cost steps per call, not per byte, so a JSON line of a few hundred KB still fits (31.11) |
| Handlers read an empty stdin | Stdin is the protocol pipe: a handler that reads it takes the next step's line or waits until the scenario deadline. Handlers must not read stdin |
| `stdout is:` compares all of stdout | It compares the stdout that no line step has read yet; all of it when no line step ran first |
| Program stdout and stderr: 1 MiB each in total, checked after every step | 1 MiB of unread stdout, 1 MiB of stderr, still checked after every step without waiting (31.5); a program that writes more stdout while the test reads lines passes |
| Handler output over 1 MiB: `RUNTIME-BDD-IO` | `RUNTIME-BDD-OUTPUT-LIMIT` |
| `I close stdin` twice: `RUNTIME-BDD-CONTEXT` | Allowed (`Process.close_stdin` is idempotent) |
| BDD failures in a handler are located at the `BDD.*` call | Located at the feature step; crashes keep their own span in the step program |
| `RUNTIME-BDD-PATTERN`, `RUNTIME-BDD-DUPLICATE` at the `BDD.step` call | At the step program's first line, with the pattern in the message |
| A bad step file leaves the other step files' steps usable | One step program: a bad one is a file error and no scenario runs |
| "handler main may only register BDD.step definitions", BDD calls outside a scenario: `RUNTIME-BDD-CONTEXT` | Gone: there is no global registration, and a context exists only inside a step; a step program that never calls `BDD.run` is `RUNTIME-BDD-CONTEXT` ("the step program did not call BDD.run") |
| Feature files of any size | At most 1 MiB (`File.read_text`) |

Feature files do not change: the Gherkin subset, the predefined steps and the report stay.

**Migration in 21f**, in the same PR:

- `tests/bdd/handlers.agc` to the new API (31.7); `tests/bdd/specs/*.feature` unchanged; `make test-bdd` unchanged.
- The step programs inside the Racket tests (`tests/bdd-test.rkt`, `tests/bdd-integration.rkt`, `tests/modules-test.rkt:304-313`, `tests/process-test.rkt:122-144`).
- `docs/grammar.md`: "Function values and BDD" (drop `BDD` from the reserved names and the builtin list in its table, point to `std/bdd`), the tasks paragraph on BDD, the `--allow-run` paragraph of Processes, the notes on the fallback and `--seed`; the new builtins in Processes and Lightweight tasks. `docs/bdd.md` rewritten for the new API, CLI and isolation.
- The programming skill: `references/bdd.md` (API, step program, diagnostics table with the changed meanings), `references/tasks.md` and `references/processes.md` (the new builtins, the BDD notes), the "When to read a reference" row, and `SKILL.md` where it lists `BDD` as a builtin module.
- The site: `site/content/library/bdd.md` (step programs are `{mode="check"}` blocks, since run directly they exit 2), `process.md`, `task.md`, `getting-started.md` (no evaluator notice for `test`).
- The development skill (`stages.md`, `runtime-notes.md`: where BDD lives now), `AGENTS.md` (the fallback list, Layout), `README.md`, and `CHANGELOG.md` under **Changed** (breaking: the list above) and **Removed** (`BDD.run`, the `BDD` builtins).
- The checker gives a help on `BDD.` without the import: "import \"std/bdd\" as BDD".

### 31.11 Tests

Per AGENTS.md: `rackunit`; golden fixtures in `tests/fixtures/vm/` for what is deterministic; process tests hermetic (local processes only, temporary directories, cleanup). Golden fixtures record their step count and run the `--max-steps` sweep (`docs/vm/12-testing-and-pr-plan.md` §12.1), so nothing that depends on time or on the order of processes goes there.

- **Golden fixtures** (pure code, feature text inside the program as strings; they import the internal modules directly): `bdd-gherkin-*` with every case of `tests/gherkin-test.rkt` (the expanded outline with tags, Doc Strings, tables, locations, and each error code with its line); `bdd-match-*` (each placeholder, greedy `{int}` with backtracking, escapes in both quote styles, the two pattern errors, undefined, ambiguous, duplicate); `json-canonical` (21d: `JSON.encode(JSON.parse(x))` sorts and de-duplicates keys, nested objects, arrays keep order, `1` against `1.0`); `bdd-report-*` (a synthetic run printed in the three formats, exit codes). The new builtins: `process-captured-*` (the working directory with `/bin/pwd`, a relative command resolved against the VM's directory and not `dir`, stderr kept, stdout read in part and the rest from `Process.output`, truncation with a child that writes 2 MiB and the read error it causes, a zero-byte read that reports a stderr flood at once, the not-captured error) and `task-pending-count` (0, then 1 after a spawn, then 0 after the await).
- **Racket tests over the CLI**, porting today's coverage to `agentica test` runs (no more in-process `run-bdd`):
  - the custom feature with `tests/bdd/handlers.agc` (4 passed, scenario-local state, the outline names);
  - the JSON-lines feature, live replies before stdin closes and recovery after a bad record;
  - isolation: assertion failure, no assertion, crash (`RUNTIME-DIVISION-BY-ZERO`), `System.exit(0)` (`RUNTIME-BDD-PREMATURE-EXIT`), infinite loop (`RUNTIME-STEP-LIMIT`), undefined step; later scenarios and files still run, statuses `not_executed`, exit 1;
  - tasks: concurrent assertions in tasks count, `RUNTIME-BDD-PENDING-TASKS`, a task that crashes, a receive task next to a send (`tests/bdd-integration.rkt:9-36`);
  - registration: blocks with captures, duplicate, bad pattern, a handler of the wrong type (`CHECK-TYPE-MISMATCH` as a file error), ambiguous, a step program that never calls `BDD.run`, a `main` that prints or loops (a clean report);
  - programs under test: no flush gives `RUNTIME-BDD-TIMEOUT`, wrong stdout, stderr and exit code, the output limit, literal input and EOF (`tests/bdd-integration.rkt:65-94`), the working directory is the feature's, a scenario killed at its deadline leaves no process behind (the program under test's pid, written by the program, is gone after the run);
  - a JSON line of a few hundred KB compared by `I receive a JSON line` passes within the step budget;
  - a step program whose `main` leaves a task running before `BDD.run` is a `RUNTIME-BDD-PENDING-TASKS` file error; a program that floods stderr fails the step in which it does;
  - the seed reaches handlers and programs (`tests/bdd-integration.rkt:38-58`);
  - `--allow-run`: programs under test need it, handlers do not (`tests/process-test.rkt:122-144`, changed);
  - the CLI: the three formats agree, usage errors exit 2, an empty directory exits 1, a missing VM is `RUNTIME-BDD-INFRA` with exit 2, two `--steps` is `RUNTIME-BDD-USAGE`, no handler output leaks to stderr.
- Tests that need the evaluator's BDD go: `tests/gherkin-test.rkt` (its cases are goldens), the `BDD.run` checks of `tests/bdd-test.rkt`, the BDD case of `tests/checker-test.rkt:147-159` (moved to a CLI case), and the BDD lines of `tests/evaluator-test.rkt`. `tests/task-test.rkt:65` tests the evaluator's task policy and goes with 7i.
- Timeouts in these tests stay generous (5 seconds per response), as `tests/bdd/specs/json-lines.feature` learned under CI load.

### 31.12 The fallback, and what is left for 7i

21f deletes `src/bdd.rkt`, `src/bdd-runner.rkt`, `src/gherkin.rkt`, the `BDD.*` entries of `src/builtins.rkt`, the BDD dispatch of the evaluator (`src/evaluator.rkt:491-503`) and `make-bdd-service`, so no program can reach the evaluator through BDD, and `agentica test` never starts it. The driver stops passing `--legacy-eval` (there is no BDD driver left to pass it). After 21f only a builtin `HTTP` call still triggers the fallback, until HTTP 20d removes it (the order above); then nothing does, but its code stays one more step: 7i deletes `src/evaluator.rkt` and its runtime modules (`task.rkt` with `RUNTIME-BDD-PENDING-TASKS` and `#:require-complete-tasks?`, `process.rkt`, `filesystem.rkt`, the network and HTTP modules), the fallback branch of `src/main.rkt`, `--legacy-eval`, `--vm`, and the evaluator's tests, as its item says. After 21f, 7i has no BDD work left.

### 31.13 Decided against

- **Port BDD to C.** It would be the biggest C module after HTTP, all of it pure computation over strings (std-first says no), and the handlers would still need a way to fail one scenario without ending the run.
- **One process for the whole suite** (handlers run in the same VM as the runner). A crash, a `System.exit` or a step limit in a handler would end every scenario. Agentica has no exceptions, and adding them for BDD is not worth a second error model.
- **One process per step.** State and the program under test would have to cross processes, and there would be many more processes.
- **The user's step program as the runner.** Its `main` would run with `--allow-run` and no limit in the process that writes the report; a `puts` in `main` would break the JSON report.
- **The runner starts the programs under test and proxies their streams**, so handlers would not need `--allow-run`. Without channels (phase 17, after 7i) a child cannot match replies to its tasks, so a receive task next to a send, which works today, would break. And a limit list such as `--allow-run-only PATH` is no boundary: a handler could start `agentica --allow-run` with any program.
- **Keep the implicit context with module state.** Agentica has no mutable globals, by design.
- **A result file instead of records on stdout.** It needs a temporary directory per scenario and gives no progress while the child runs; the marker on stdout costs nothing.
- **`std/bdd` before 21f under another alias.** Two BDD APIs at once; the documented alias is `BDD` from the first PR that exposes the module (the internal modules of 21c to 21e are not the API).
- **Handlers without `Process.spawn`.** The options above (the runner as a proxy, an allow list) were weighed and rejected; the user decided on 2026-10-12 that handlers may always spawn (31.10).
