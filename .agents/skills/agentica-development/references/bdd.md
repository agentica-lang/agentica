# `agentica test`: BDD and unit test runner

How `agentica test` works: the driver (`compiler/bdd/bdd_driver.agc`, part of
the front end), `std/bdd`, the runner in `stdlib/test/`, step programs, unit
test files and the child channel records. Read before changing any of them.
User docs and the runner protocol are in `docs/bdd.md`.

## BDD (`agentica test`)

`agentica test` runs on the VM and is written in Agentica. `std/bdd` is the
public step API; `std/bdd/gherkin` and `std/bdd/match` (Gherkin parsing and
step matching) and `std/test/runner` and `std/test/report` (the runner and
report, shared by BDD and unit tests) are internal (importable through `std/`
like any registered module, but not in the programming skill or the site). All
are registered in `stdlib/MODULES`.

- `agentica test` is part of the front end of the binary (§18.3;
  `compiler/app/cli.agc` calls `Driver.run(options, settings)` in its own
  process, with the settings of the command line: the version, the provider of
  the `std/` sources and `self_path`, the path of the binary). The runner and
  each program under test are children of the same binary: `settings.self_path
  run [--seed N] --driver-pid PID --embedded runner -- config.jsonl` (the binary
  carries the compiled runner; see "Embedded programs" below), and `self_path
  ... FILE.agc` for a program under test (`std/bdd`). The user's `--deny-*`
  flags do not reach the front end, so it can start them; the user's program
  never runs in that runtime. `agentica test` takes every `--deny-*` flag and
  `--sandbox`, in front of `test` or after it, once each (`DENY` in
  `bdd_options.agc`). The driver adds them after the binary in the config's
  `agentica` words (no new config field, so the stage0 driver still works with
  this runner): `std/bdd` starts each program under test with them, and the
  runner gives them (`deny`, the words after the binary) to every child of the
  user's code. The runner runs without them. Under `--deny-fs`, `std/bdd`
  cannot stat a program under test, so its `agentica` command reports a missing
  file. A front end that stops on a
  runtime error (a bug in the driver) ends the process with status 2 and the
  error on stderr, never the 1 of a failed test run. Without `--self` (the front
  end started as an ordinary program) `test` says so and exits 2.
  - the tests that need a fake runner run the front end as an ordinary program
    (the `std/` sources from a folder, so the runner is compiled into the run
    dir) with `--self` naming a shell script that fakes the runner when it is
    asked for `runner.agcb` and runs the real binary otherwise (on Windows a
    copy of `node.exe` with a preloaded script, since the VM starts only `.exe`
    and `.com` files there) (`front_end_command` in `tests/agentica_test.py`,
    `fake_binary` in `tests/test_bdd.py`);
  - a missing binary is the driver's `cannot find agentica at PATH`
    infrastructure report in the chosen format.
- `compiler/bdd/bdd_driver.agc` (the driver; `bdd_options.agc` reads the
  arguments, usage errors included)
  - `bdd_rundir.agc` makes the run dir (the rules: `docs/bdd.md`, "Isolation
    and process lifetime"): a private 0700 `agentica-bdd-new-<hex>` (16 bytes
    of `/dev/urandom`, 16 tries; on Windows 8 bytes of `Random.int`, 4 of the
    clock and the pid), refuses a group-writable `TMPDIR` unless it has the
    user's uid and gid and no setgid bit (the user-private-group case), locks
    `lock` for the whole run, then renames the dir with `Path.rename` (never
    replaces), so the sweep never sees an unlocked new dir. Links and dirs
    without `lock` are left alone. On Windows the sweep closes the lock before
    removing the dir (a folder with an open file cannot be removed)
  - it writes the `std/` sources into `std/` of the run dir, compiles the
    step program and discovers the feature files (`bdd_discover.agc`;
    `bdd_compile.agc` is the Agentica pipeline from a file to the bytes, or the
    first `Problem`) into 0600 `.agcb` files, writes `config.jsonl`, and runs
    the runner with `run [--seed N] --driver-pid PID --embedded
    runner -- config.jsonl` of the binary, as a captured child
    (`bdd_runner.agc`; the child environment has no metrics variables, a rule
    of every `Process.spawn*`)
  - Embedded programs: the runner (`compiler/embedded/runner.agc`: a root that
    calls `Runner.main()`) and the default step program (`steps.agc`:
    `BDD.run([])`) are compiled at build time and carried by the binary
    (`vm/embedded.h`, `make` rule on `EMBEDDED_PROGRAMS`), so `agentica test`
    does not compile them on every run. The driver uses them when the provider
    of `std/` is `Embedded` (`Program.Embedded("runner")` in `bdd_runner.agc`;
    an empty `steps_bytecode` in the runner config means the default steps,
    started with `--embedded steps`; no field was added to the config, so a
    driver that does not know the embedded programs still works with this
    runner). The runner decodes the config with `JSON.decode`, which has no
    optional fields: a field that the driver does not write fails the decode
    (`expected required field`). Signal a new case with a value of a field the
    driver already writes, as the empty `steps_bytecode` does. With a folder
    provider (the tests with a fake runner) it compiles both into the run dir.
    The first binary of the bootstrap carries none and has the driver of
    stage0: its `agentica test` compiles them and its `run --embedded` exits 2;
    `tests/test_bdd.py` runs both. The texts of the two roots are constants in
    `bdd_driver.agc`; `tests/test_bdd.py` checks that the files equal them, and
    that a run with the embedded programs reports the same as one with the
    compiled ones
  - `Process.spawn_captured` keeps 1 MiB of each stream, and the report of a big
    run is larger, so the runner writes the report to `report.txt` of the run
    dir (`report_path` in the config) and the driver prints that file; stderr
    stays captured
  - the run dir is removed with `Path.remove` and the lock closed at the end of
    every run that ends normally; a stop signal does not unwind the VM, so the
    dir stays until a later run sweeps it (§18.4)
  - Discovery lives here, not in the runner, because `File.stat` follows links:
    `File.lstat` sees links, folder links are skipped, and an unreadable folder,
    an unreadable entry, a broken `.feature` link or a name with U+FFFD (the
    mark `Dir.list` leaves for bytes that are not UTF-8) on a folder or a
    `.feature` file is a `RUNTIME-BDD-INFRA` entry for that path.
  - `config.jsonl` is the config on its first line (fields: `bdd_driver.agc`;
    `steps_error` is the step program's front-end diagnostic as `--json` writes
    it (`diagnostic_json.agc`), so the report stays in Agentica), then `count`
    lines of `{path, problem, kind, bytecode, source_root, front_end}`, which
    the runner reads with `File.read_line` in a `map` over `0...count`.
  - A runner exit of 0, 1 or 2 with an empty stderr and a report file is the
    answer
  - anything else, or more than one `--steps`, is a one-file
    `RUNTIME-BDD-INFRA` or `USAGE` report built by `bdd_report.agc`.
- Unit tests (the protocol is in `docs/bdd.md`, "Unit test files")
  - the driver (`--only` is a word after `test`; the driver option
    `--test-timeout-ms N`, default 30000; tests pass a short deadline there)
    discovers `*_test.agc` next to `.feature` files in the same walk (an entry's
    `kind` is `tests`, `feature` or `""`), uses `specs/` and `test/` when no
    path is given (a missing default folder is skipped; nothing found is
    `CHECK-BDD-EMPTY`), and compiles each test file into `test-<n>.agcb` (a
    front-end diagnostic goes to the entry's `front_end` as `--json` writes it)
  - `bdd_compile.agc` `file` takes the program from the bytecode cache
    (`io/bytecode_cache.agc`) for a test file and a `--steps` file, not for
    the driver's own runner and steps; `--no-cache` (in front of `test` or
    after it, `Opts.Options.no_cache`) turns it off. The programs under test
    that `std/bdd` starts as `agentica FILE.agc` use the cache like any run
  - the config gains `only`, `test_timeout_ms`, `steps_given` and
    `empty_message`
  - the runner VM's stdin is closed at once, since nothing is read from it
  - a usage or infrastructure report from the driver carries `--seed` when
    given.
  - In the runner, the seed is `--seed` or one drawn with `Random.int` and
    passed to every child (`--seed` always) and to the report.
  - Without `--steps`, `default_steps` (`bdd_driver.agc`) takes the nearest
    `steps.agc` from each path up to the working directory, only when the run
    has a feature file (two different files are a usage report), so the config
    is the same as for `--steps`
  - The steps are listed only when there is a feature (a `--steps` program that
    does not compile is still a file error without one)
  - a broken step program is one `steps` file error, and the test files still
    run.
  - A `--only` that matches no name adds a `CHECK-BDD-EMPTY` file error
    (`matched`).
  - `stdlib/test/units.agc` (`std/test/units`) runs a test file: a list child
    (`--agentica-test list`, started with `Process.spawn_channel` and its stdin
    closed at once; `Child.read_records` reads the channel until it ends, then
    `Process.output`; a read that ends with `process: output exceeds` (the file
    prints for ever while listing, `listing_flood_test.agc`) closes the child at
    once and is a file error with `RUNTIME-BDD-OUTPUT-LIMIT`; a `fail` record, a
    crash diagnostic or a non-zero exit is a file error, a file that exits 0
    without `ready` is `RUNTIME-TEST-RUN`; the file error keeps the printed
    lines and stderr in the file's `output`), the `--only` filter, then one run
    child (`--max-steps` 1,000,000 × (tests + 1)) that gets one index per test
    with `Process.channel_send`.
  - `await_test` reads the test's record with `Process.channel_read_line`, then
    the stdout the test printed with `Process.read_available` (the child flushes
    stdout before it sends the record, so the order is fixed)
  - the last 64 Ki characters of it (minus one trailing newline,
    `Child.printed`) go to `output` for a failed test, and a timed-out test
    keeps what was read.
  - `process: output exceeds` comes from either cap (stdout over 1 MiB unread
    since the last record, or stderr over 1 MiB for the child), so `overflow`
    closes the channel, waits for `Process.output` for `Child.brief` (at most 2
    s; a child still stuck in the running test then fails it with
    `RUNTIME-BDD-OUTPUT-LIMIT` and no output, which is how a test that prints
    for ever ends at 1 MiB: the cut wakes the pending
    `Process.channel_read_line` with the same error, `endless_test.agc`) and
    checks the stderr: under 262,144 characters it is the running test's unread
    stdout (the test fails with the tail of `stdout`, `chatty_test.agc`)
  - else it is the per-child stderr cap and the file's error (`Failure.blame`
    false, the stderr tail as the file's `output`), and the running test is
    `NotExecuted`.
  - The tests are walked through a `Map[Int, UnitTest]`, not by list index.
  - The deadline is `test_timeout_ms` from the index (`RUNTIME-TEST-TIMEOUT`)
  - a timeout, an end of stdout (the child's last stderr diagnostic, else
    `RUNTIME-BDD-PREMATURE-EXIT`, plus the stderr lines the program wrote itself
    in `output`) or the output limit stops the child, and the remaining tests
    are `Verdict.NotExecuted`.
  - After the last test it closes stdin and waits: exit 1 with the unobserved
    summary is a `RUNTIME-TASK-CRASHED` file error.
  - `stdlib/test/child.agc` (`std/test/child`) holds what both runners share:
    `Records` and `read_records` (the records on a child's channel, read until
    it ends), `record_of` (a whole line as JSON, or null), `event_of`, the
    record fields, `left`, `brief`, `gone?`, `located`, `printed` (one trailing
    newline off), `tail`, `stderr_diagnostic` (which also reads the unobserved
    summary) and `stderr_text` (drops only lines of the VM's exact shapes,
    re-encoded and compared, and keeps the last 64 Ki characters).
  - Tests: `tests/test_unit_test.py` with `tests/fixtures/unit/` (the timeout
    case is slow: the 30 s deadline has no flag), the golden `test-child` and
    the `std/` unit tests in `tests/std/`.
- `stdlib/test/runner.agc` (`std/test/runner`; it imports `std/bdd/gherkin` and
  `std/bdd/match`)
  - reads the config, lists the steps with one child that has a channel
    (`--agentica-bdd list`, the channel read to its end with
    `Child.read_records`; the same output error while listing closes the child
    and is a `RUNTIME-BDD-OUTPUT-LIMIT` steps error), compiles the patterns,
    reads each listed `.feature` file (over 1 MiB is a `RUNTIME-BDD-IO` file
    error), parses and resolves each scenario, and runs every scenario that
    resolves in its own child VM (`--agentica-bdd scenario`, `--max-steps`
    1,000,000 per step plus one, a 30 s scenario deadline), then prints
    `Report.json` or `Report.text` and exits with `Report.exit_code`.
  - It talks to the child over a channel (`Process.spawn_channel`; the child's
    stdin is closed at once): an init line, then one step line per step with
    `Process.channel_send`; the child answers with records, plain JSON lines
    (`assert`, `step`, `fail`, `end`, `ready`) read with
    `Process.channel_read_line`.
  - After an `end` or `fail` record the runner reads what the handler printed
    with `Process.read_available` and fails the step with
    `RUNTIME-BDD-OUTPUT-LIMIT` when the stdout or stderr cap was hit.
  - An `end` whose `index` is not the current step is a `RUNTIME-BDD-INFRA`
    protocol error
  - a failed `Process.channel_send` of a line fails the step at once (`send
    exceeds` is `RUNTIME-BDD-IO`, anything else goes through `read_failure`)
  - `read_failure`, and `failure` in `units`, treat the messages `Child.gone?`
    names (end of input, a closed channel or stdin, and `error writing to stream
    port`, which a write to a dead child gives) as a dead child, so its fail
    record or stderr diagnostic is shown
  - a `fail` record after the last step is the scenario's error (`await_exit`
    reads the channel to its end after `Process.channel_close`).
  - A child that dies prints its diagnostic on stderr with `--json`; the runner
    reads the last line with `Report.from_json`, else `PREMATURE-EXIT`.
- `stdlib/bdd.agc` (`std/bdd`): `step`, `run`, the `Context` value passed
  through each handler (scenario state, the step's doc string or table, the
  program under test), `assert`, `set`/`get` and the program steps. The `then_*`
  checks compare with `Test.eq` (`agc_equal`; a `Json` line by its canonical
  text) and put the inspect texts of expected and actual in the `fail` record
  (`Json` as `JSON.encode`, the same text `agc_test_text` gives), so BDD and
  unit tests show values the same way. `run` puts the predefined steps first;
  in the child it checks the step index and pattern, calls the handler, then
  fails on pending tasks (`Task.pending_count`) and on an unobserved task crash
  (`Task.unobserved_crash`), probes the program's output limit and sends `end`.
  Every record is one JSON line sent with `Process.parent_send` after
  `IO.flush()` (list mode sends one `step` record per step, then `ready`; the
  scenario mode reads the settings line and the step lines with
  `Process.parent_read_line`, 24 h timeout, `idle_ms()`, since the runner holds
  the deadline; the send timeout is `send_ms()`). Every failure sends one `fail`
  record and exits 1. When `deliver` cannot send, it warns on stderr with the
  reason and exits 1; a record over 1 MiB (`process: send exceeds`) is replaced
  by a small `RUNTIME-BDD-OUTPUT-LIMIT` fail record.
- Codes: `RUNTIME-BDD-*`, `CHECK-BDD-*` and `PARSE-GHERKIN-*` (the list:
  `docs/bdd.md`, "Diagnostics"). Tests: `tests/test_bdd.py` (the step
  program, isolation, registration, usage), `tests/test_bdd_integration.py`
  (programs under test, limits, seed, cleanup), both running the CLI as a child
  process, the `bdd-*` goldens for `std/bdd/gherkin` and `std/bdd/match`, and
  the `test-report-*` goldens for `std/test/report`.
- `stdlib/bdd/gherkin.agc` (`std/bdd/gherkin`) parses the English Gherkin
  subset with stable codes, the first error and spans. `parse(file, text)`
  returns `Outcome.Done(Feature)` or `Outcome.Failed(Diagnostic)` (the
  `std/test/report` types); a `Span` is file, line, column 1 and the end column
  of the raw line, with no offset. Table rows and `<name>` substitution split
  the text and join it once, with no `+=` or `push` per character or cell, so
  they cost linear time in the line. Building the step, row, Examples, draft and
  scenario lists with `push` per line is still quadratic in the line count.
  Goldens: `bdd-gherkin-outline`, `-sections` and `-arguments`.
- `stdlib/bdd/match.agc` (`std/bdd/match`) compiles and matches step patterns
  and runs the duplicate and resolve checks, by hand with no regular
  expressions; it imports `gherkin` for `Diagnostic`, `Outcome` and `Step`, and
  `std/test/report` for `Span`. `compile(texts, where)` returns
  `Outcome.Done(List[Pattern])` or the first problem in order: a text seen
  before is `RUNTIME-BDD-DUPLICATE`, a bad one `RUNTIME-BDD-PATTERN` (the
  reason, then `: ` and the pattern), both at `where`, the span the caller gives
  (the step program's first line). A `Pattern` is its `text`, the `head` literal
  and one `Slot` (an `{int}` or `{string}` capture, then a literal) per
  placeholder, split on `{` with `List.map`. `captures(pattern, text)` is
  `ok(List[String])` or `error("no match")`: a whole-text match that backtracks
  (`{int}` from the longest digit run down, `{string}` up to the first
  unescaped closing quote, each `\X` decoded to `X`). `resolve(patterns, step)`
  matches every pattern and returns `Resolved(index, captures)`, or
  `CHECK-BDD-UNDEFINED` or `CHECK-BDD-AMBIGUOUS` at the step's span (the
  report's `actual` is the step text, added by the caller). Goldens:
  `bdd-match-captures`, `-resolve` and `-errors`; `json-canonical` pins the
  JSON rule that `Test.eq` on `Json`, and so `then_json_line`, relies on
  (`JSON.encode(JSON.parse(x))` sorts keys and keeps the last duplicate,
  `sort_members` in `vm/json.c`).
- A crash record carries the stack: `Test.test` bodies that crash send `stack`,
  `stack_omitted` and `spawned_at` in the `fail` record; `record_error` in
  `stdlib/test/units.agc` keeps them as the error's `original`
  (`Child.diagnostic_of`), so `--json` writes them and `Report.text` prints them
  under the diagnostic (`stack_text` in `stdlib/test/report.agc`; an `original`
  from `from_json` with a stack, such as a crashed step handler, prints too).
  The records of an assertion, a returned error and the pending-task and
  unobserved-crash failures have no stack.
- `stdlib/test/report.agc` (`std/test/report`) builds the report and imports
  nothing; it owns `Span` and `Example`, which `std/bdd/gherkin` and
  `std/bdd/match` import from it. Its input is the run as data, which the
  runner fills (`FileResult`, `ScenarioResult`, `StepResult`; the types are in
  the module).
  - A `Verdict` is `Pass` or `Fail(Error)`: a file's own error (parse error,
    step program), or a scenario's first failure; it can also be
    `NotExecuted`, a test that never ran.
  - An `Error` is the diagnostic as the VM's `--json` writes it, with
    `expected` and `actual` as `Detail` (`Unknown` or `Known(String)`), and
    `original`, `JSON.null()` or the whole object `from_json` parsed.
    `from_json(text)` reads a diagnostic as `--json` writes it (a front-end
    error of the step program) and keeps that object, so the report writes every
    key unchanged (`help`, `function`, `callee`, `labels`); `error_at(code,
    message, span)` builds one from fields (the runner turns a
    `Gherkin.Diagnostic` into one with it); `with_actual` adds the text it is
    given as `actual` (the runner passes the step text's inspect form,
    `step.text.inspect`) to an undefined or ambiguous step (an error built from
    fields; it returns an error with a non-null `original` unchanged);
    `file_error(path, kind, error)` builds a file entry.
  - `json(files, seed)` builds the report with `JSON.object` (keys come out
    sorted, the canonical form; the statuses, totals, `ok` and `not_executed`
    are derived, not passed in; a file has `kind`, a scenario `output`);
    `text(files, ai, seed)` is the plain or `--ai` text (a test file's lines
    name its path where a feature name goes, `SKIP` for a test not run, a failed
    test's output indented below it or after ` | output`, and `, seed N` on the
    last line when the exit code is not 0) without the final newline
    (`expected` and `actual` as they are: a BDD or `Test` assertion already
    wrote them in the inspect form, once, so the report does not quote them
    again); `exit_code(files)` is 0 when at least one scenario ran and nothing
    failed, 2 when a file or scenario error is `RUNTIME-BDD-INFRA` or
    `RUNTIME-BDD-USAGE`, else 1.
  - Every list is built with `List.map` and joined once, so a report costs
    linear time.
  - Goldens: `test-report-run` and `test-report-exit`.
  - `original` must only come from `from_json`: any other error keeps
    `JSON.null()` there, or `json` would write the stale object instead of its
    fields.

## Step handlers and programs under test

The rules (Gherkin subset, handler type, assertions, isolation, programs under
test) are in `docs/bdd.md`. `make test-bdd` builds the CLI and runs
`tests/bdd/specs` with `tests/bdd/handlers.agc`; CI runs it too.
