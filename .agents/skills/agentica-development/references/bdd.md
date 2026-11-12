# `agentica test`: BDD and unit test runner

How `agentica test` works: the driver (`compiler/bdd/bdd_driver.agc`, part of
the front end), `std/bdd`, the runner in `stdlib/test/`, step programs, unit
test files and the child channel records. Read before changing any of them.
User docs and the runner protocol are in `docs/bdd.md`. `std/bdd` is the public
step API; the modules under `std/bdd/` and `std/test/` are internal (not in
the programming skill or the site).

## Driver (`compiler/bdd/`)

- `agentica test` runs in the front end (`compiler/app/cli.agc` calls
  `Driver.run(options, settings)`). The runner and each program under test are
  children of the same binary: `settings.self_path run [--seed N] --driver-pid
  PID --embedded runner -- config.jsonl`, and `self_path ... FILE.agc` for a
  program under test. The user's `--deny-*` flags do not reach the front end,
  so it can start them; the user's program never runs in that runtime. `test`
  takes every `--deny-*` flag and `--sandbox` (`DENY` in `bdd_options.agc`);
  the driver adds them after the binary in the config's `agentica` words, so
  `std/bdd` starts each program under test with them and the runner gives them
  (`deny`) to every child of the user's code. The runner runs without them.
  Under `--deny-fs`, `std/bdd` cannot stat a program under test. A front end
  that stops on a runtime error (a driver bug) exits 2 with the error on
  stderr, never the 1 of a failed run.
- Tests that need a fake runner run the front end as an ordinary program with
  `--self` naming a script that fakes the runner when asked for `runner.agcb`
  and runs the real binary otherwise (`front_end_command` in
  `tests/agentica_test.py`, `fake_binary` in `tests/test_bdd.py`; on Windows a
  copy of `node.exe`, since the VM starts only `.exe` and `.com` files there).
- `bdd_rundir.agc` makes the run dir (rules: `docs/bdd.md`, "Isolation and
  process lifetime"): private 0700, locked with `lock` for the whole run, then
  renamed with `Path.rename` (never replaces), so the sweep never sees an
  unlocked new dir; links and dirs without `lock` are left alone. Windows: the
  sweep closes the lock before removing the dir. It is removed at the end of
  every run that ends normally; a stop signal does not unwind the VM, so a
  later run sweeps it.
- The driver writes the `std/` sources into the run dir, discovers features
  (`bdd_discover.agc`), compiles the step program and tests (`bdd_compile.agc`,
  0600 `.agcb` files), writes `config.jsonl` and runs the runner as a captured
  child (`bdd_runner.agc`). Compiled tests and `--steps` files use the bytecode
  cache (`io/bytecode_cache.agc`; `--no-cache` turns it off), not the driver's
  own runner and steps.
- Discovery is in the driver because `File.stat` follows links: `File.lstat`
  sees links, folder links are skipped, and an unreadable folder or entry, a
  broken `.feature` link or a name with U+FFFD (what `Dir.list` leaves for
  non-UTF-8 bytes) is a `RUNTIME-BDD-INFRA` entry for that path. `*_test.agc`
  files are found in the same walk (entry `kind`: `tests`, `feature`, `""`);
  default paths `specs/` and `test/` (a missing default is skipped; nothing
  found, or a `--only` that matches no name, is `CHECK-BDD-EMPTY`).
- Test functions: `compile_test` compiles with `Settings.test_file`
  true (`check` sets it for a `*_test.agc` name; nothing else does), and
  `modules/test_main.agc` adds the `main` of a root file with `test_*`
  functions and none (fresh trees only, ids from the Program's on) before the
  linker registers its names. The bytecode cache keys such a compile apart
  (`test PATH`). The runner and protocol do not change.
- Without `--steps`, `default_steps` takes the nearest `steps.agc` from each
  path that holds a feature up to the working directory (two different files
  are a usage report). A broken step program is one `steps` file error and the
  test files still run.
- Embedded programs: the runner (`compiler/embedded/runner.agc`) and the
  default steps (`steps.agc`) are compiled at build time and carried by the
  binary (`EMBEDDED_PROGRAMS` in `mk/bootstrap.mk`). The driver uses them when
  the provider of `std/` is `Embedded`; an empty `steps_bytecode` in the config
  means the default steps (`--embedded steps`). With a folder provider
  (fake-runner tests) it compiles both into the run dir. The first bootstrap
  binary carries none and has the stage0 driver (its `run --embedded` exits 2);
  `tests/test_bdd.py` checks that the root texts (constants in `bdd_driver.agc`)
  equal the files.
- **Config compatibility:** the runner decodes the config with `JSON.decode`,
  which has no optional fields, so a field the driver does not write fails
  (`expected required field`) and the stage0 driver must still work. Never add
  a field to signal a new case: use a value of a field already written (the
  empty `steps_bytecode`). `config.jsonl` is the config line (fields:
  `bdd_driver.agc`; `steps_error` is the step program's diagnostic as `--json`
  writes it), then `count` lines of `{path, problem, kind, bytecode,
  source_root, front_end}`. For unit tests the config gains `only`,
  `test_timeout_ms` (`--test-timeout-ms N`, default 30000), `steps_given` and
  `empty_message`. `--tags EXPR` is an extra line with the expression as a
  JSON string (a missing line is no filter); the runner compiles it with
  `Tags.compile` (the driver checked it in `Opts.parse`), keeps the scenarios
  `Tags.selects?` and leaves unit test files out; a bad expression is
  `RUNTIME-BDD-USAGE`. `--jobs N` (more than 1) is one more line after it, a
  JSON integer (a missing line is 1; with no `--tags` the tags line is an empty
  string).
- The seed is `--seed` or one drawn with `Random.int`, passed to every child and
  to the report.
- `Process.spawn_captured` keeps 1 MiB per stream and a big report is larger,
  so the runner writes it to `report.txt` of the run dir (`report_path` in the
  config) and the driver prints that file. A runner exit of 0, 1 or 2 with an
  empty stderr and a report file is the answer; anything else is a one-file
  `RUNTIME-BDD-INFRA` or `USAGE` report (`bdd_report.agc`).

## Runner (`stdlib/test/runner.agc`)

- Reads the config, lists the steps with one child that has a channel
  (`--agentica-bdd list`; output over the cap while listing closes the child:
  `RUNTIME-BDD-OUTPUT-LIMIT`), compiles the patterns, reads each `.feature`,
  and runs every resolved scenario in its own child VM (`--agentica-bdd
  scenario`, `--max-steps` 1,000,000 per step plus one, 30 s deadline), then
  prints `Report.json` or `Report.text` and exits with `Report.exit_code`.
  The files run in order, or `--jobs N` at a time with `Task.map` in
  `run_entries`; the results are in file order.
- The child talks over a channel (`Process.spawn_channel`, stdin closed at
  once): an init line, then one step line per step (`Process.channel_send`);
  the child answers with JSON line records (`assert`, `step`, `fail`, `end`,
  `ready`, `skip`, `after`) read with `Process.channel_read_line`. After `end`
  or `fail` the runner reads the handler's output with `Process.read_available`
  and fails the step with `RUNTIME-BDD-OUTPUT-LIMIT` when a cap was hit. An
  `end` whose `index` is not the current step is a `RUNTIME-BDD-INFRA` protocol
  error. `skip` (`BDD.skip`: the child sends it and exits 0) ends the scenario
  as `Verdict.Skipped(reason)`: that step `Skipped`, later ones `NotExecuted`.
  A failed `channel_send` fails the step at once (`send exceeds` is
  `RUNTIME-BDD-IO`, else `read_failure`, which treats the messages `Child.gone?`
  names as a dead child so its fail record or stderr diagnostic is shown). A
  `fail` after the last step is the scenario's error. A child that dies prints
  its diagnostic on stderr with `--json`; the runner reads the last line with
  `Report.from_json`, else `PREMATURE-EXIT`.

## Unit tests (`stdlib/test/units.agc`; protocol: `docs/bdd.md`)

- `std/test/units` runs a test file: a list child (`--agentica-test list`,
  `Process.spawn_channel`, stdin closed at once; a read ending with `process:
  output exceeds` closes the child: a file error `RUNTIME-BDD-OUTPUT-LIMIT`; a
  `fail` record, a crash diagnostic or a non-zero exit is a file error; exit 0
  without `ready` is `RUNTIME-TEST-RUN`; the printed lines and stderr go in the
  file's `output`), the `--only` filter, then one run child (`--max-steps`
  1,000,000 x (tests + 1)) that gets one index per test with
  `Process.channel_send`. `await_ready` waits up to 30 s for the child's
  `ready` before the first index, so a test's time leaves out the child's
  start. Otherwise a file error with what the child printed: another record is
  `RUNTIME-BDD-INFRA`, no `ready` in 30 s `RUNTIME-TEST-TIMEOUT`, an early end
  the child's crash diagnostic. Tests are walked through a `Map[Int, UnitTest]`.
- `await_test` reads the record, then the printed stdout with
  `Process.read_available` (the child flushes before it sends the record, so the
  order is fixed); the last 64 Ki characters go to `output` for a failed test.
  The deadline is `test_timeout_ms` (`RUNTIME-TEST-TIMEOUT`).
- `process: output exceeds` comes from either cap (stdout over 1 MiB unread
  since the last record, or stderr over 1 MiB), so `overflow` closes the
  channel and waits for `Process.output` for `Child.brief` (at most 2 s). If
  the child is still stuck in the running test, the test fails with
  `RUNTIME-BDD-OUTPUT-LIMIT` and no output (a test that prints for ever; the
  cut wakes the pending `channel_read_line`). Otherwise it checks stderr: under
  262,144 characters it is the running test's unread stdout (the test fails
  with the stdout tail); else it is the per-child stderr cap and the file's
  error (`Failure.blame` false, stderr tail as `output`), and the running test
  is `NotExecuted`.
- A timeout, an end of stdout (the child's last stderr diagnostic, else
  `RUNTIME-BDD-PREMATURE-EXIT`) or the output limit stops the child; the rest
  are `NotExecuted`. After the last test it closes stdin and waits: exit 1 with
  the unobserved summary is a `RUNTIME-TASK-CRASHED` file error.
- `std/test/child` holds what both runners share.
- `std/test/coverage` merges the LCOV part of each child of `agentica test
  --coverage` (in the run folder, `N.info` or `N-K.info`) into
  `coverage/lcov.info`; the parts folder is the last line of the runner
  configuration.
- A crash record carries the stack (`stack`, `stack_omitted`, `spawned_at` in
  the `fail` record); `record_error` in `units.agc` keeps them as the error's
  `original`, so `--json` writes them and `Report.text` prints them. Assertion,
  returned-error, pending-task and unobserved-crash failures have no stack.

## `std/bdd` and its helpers

- `stdlib/bdd.agc`: `step`, `run`, `Context`, `assert`, `set`/`get`,
  `keep`/`call` (closures `Fn[Json, Result[Json]]` that capture a scenario's
  non-JSON values: `Context` cannot hold the step program's own type, since
  functions and structs are not generic), `read_line` and the program steps.
  The `then_*` checks compare with `Test.eq` (a `Json` line by canonical text)
  and put the inspect texts in the `fail` record, so BDD and unit tests show
  values the same way. In the child, `run` checks the step index and pattern,
  calls the handler, fails on pending tasks and an unobserved task crash,
  probes the output limit and sends `end`. Each record is one JSON line sent
  with `Process.parent_send` after `IO.flush()`; scenario mode reads step lines
  with `Process.parent_read_line` and a 24 h timeout (the runner holds the
  deadline). Every failure sends one `fail` record and exits 1. A record over
  1 MiB (`process: send exceeds`) becomes a small `RUNTIME-BDD-OUTPUT-LIMIT`
  fail record.
- Program launch and hooks: `given_env` and `given_argument` keep a `Map` and a
  list in `Scenario` until `start`, which passes them to
  `Process.spawn_captured` (`env`) and after the file. `after` keeps
  `Fn[Context, Result[Void]]` hooks; `finish` sends the fail record first and
  then `run_after` (each hook in its own task). `run_after` closes the
  scenario's `closing` channel, which every context shares, so a failed check
  crashes the hook's task even on a context captured earlier, and sends `after`
  when there are hooks. The runner reads on after a `fail`
  (`with_hook_problems`) to add the hooks' message, and uses the hook wording
  for a late timeout only after an `after` record. Every failing `bdd.agc`
  helper takes `ctx` so it can run the hooks; `abort` is for the failures
  before a context exists.
- `start` runs `agentica run -- BYTECODE` with the `--source-root` the front
  end would give: `compiled` builds it once per run in the run folder
  (`programs` in the settings line), named by the SHA-256 of the real path and
  the root file's text, with `agentica compile` (bytecode cache) to a name of
  its own and a rename. A compile that fails leaves `NAME.failed`; that, an
  empty `programs` or any I/O error (`--deny-fs`) starts through
  `agentica FILE.agc` as before, so the front end prints the diagnostic.
- `std/bdd/gherkin`: the English Gherkin subset with stable codes and the first
  error; a `Span` is file, line and columns, no offset. Table rows and `<name>`
  substitution split and join once; a `push` per line is quadratic in the line
  count.
- `std/bdd/match` compiles and matches step patterns by hand (no regex).
  `compile` returns the first problem (`RUNTIME-BDD-DUPLICATE`,
  `RUNTIME-BDD-PATTERN`, at the `where` span the caller gives). `captures` is a
  whole-text match that backtracks (`{int}` from the longest digit run down,
  `{string}` up to the first unescaped closing quote). `resolve` gives
  `Resolved`, `CHECK-BDD-UNDEFINED` or `CHECK-BDD-AMBIGUOUS` at the step's
  span. The `json-canonical` golden pins the rule `then_json_line` relies on
  (`JSON.encode(JSON.parse(x))` sorts keys and keeps the last duplicate,
  `sort_members` in `vm/json.c`).
- `std/test/report` builds the report and imports nothing; it owns `Span` and
  `Example`, which `gherkin` and `match` import. A `Verdict` is `Pass`,
  `Fail(Failure)`, `Skipped(reason)` (not a failure, exit code stays 0) or
  `NotExecuted`. A `Failure` is the diagnostic as `--json` writes it;
  `original` must only come from `from_json` (it keeps the whole parsed
  object); any other error keeps `JSON.null()` there, or `json` would write the
  stale object instead of its fields. `json` sorts keys and derives statuses
  and totals. `text` writes `expected` and `actual` as they are (already in
  inspect form). `exit_code` is 0 when a scenario ran and nothing failed, 2 for
  `RUNTIME-BDD-INFRA` or `RUNTIME-BDD-USAGE`, else 1. Lists are built with
  `List.map` and joined once.
- Codes: `docs/bdd.md`, "Diagnostics".
- Tests: `tests/test_bdd.py`, `tests/test_bdd_integration.py` (both through the
  CLI), `tests/test_unit_test.py` with `tests/fixtures/unit/` (the timeout case
  is slow: the 30 s deadline has no flag), the `bdd-*`, `test-report-*` and
  `test-child` goldens, `tests/std/`. `tests/bdd/specs` with
  `tests/bdd/handlers.agc` runs in `test_bdd.py` and `test_bdd_integration.py`.
