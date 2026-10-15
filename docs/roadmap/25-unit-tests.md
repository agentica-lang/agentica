## Phase 25: Unit tests

Specified in [`docs/future/36-unit-tests.md` section
36](../future/36-unit-tests.md#36-unit-tests-test). Phase 25 adds the builtin
`Test` module and runs `*_test.agc` files with `agentica test`, next to the
features, through the BDD runner and report. It comes right after task crash
isolation (phase 24), so a crash fails one test; its place in the order is row
7.1 of the [roadmap](README.md). It has two PRs, each with its own tests and
docs.

- [x] **25a: the `Test` module (§36.3, §36.4).**
  - **VM:** `Test.test` (the `TestCase` value with its call span; as built, an
    opaque type, not a record), `Test.eq` (it pulls §25.4's type predicate and
    deep compare forward, with an explicit stack, for 15d to reuse; `Json` at
    any depth compares and prints as canonical text), `Test.ok?`, `Test.error?`,
    `Test.assert`, the assertion records on the nearest test task, and
    `Test.run` (list and run modes, one task per test, the pending-task and
    unobserved-crash checks, the records of §36.6 with raw texts, the per-test
    seed from the given seed and the test name).
  - **Front end:** the catalog entries; `Test.eq` needs a type with §25.4
    equality or `Json` (`CHECK-TYPE-MISMATCH`); `Test` and `TestCase` reserved.
  - **Tests:** the golden fixtures and checker tests of §36.12.
  - **Docs:** `docs/grammar.md` (the `Test` module, reserved names); the
    programming skill (`references/testing.md`, its row in "When to read a
    reference", `references/diagnostics.md`);
    `site/content/library/testing/test.md`; the development skill.
  - **Done.** As built:
    - `vm/testing.c` holds the `Test` builtins; `vm/equal.c` holds `agc_equal`,
      the deep compare (one explicit stack of value pairs, Floats by IEEE 754,
      maps by key in any order, a `Json` by its canonical `JSON.encode` text,
      `RUNTIME-INTERNAL` for a value with no equality); `agc_test_text` in
      `vm/text.c` is the inspect form with each `Json` as its canonical text.
      Both are in `vm/value.h` for `std/bdd` (25b) and `==` (15d) to reuse; BDD
      is not wired to them yet.
    - `TestCase` is an opaque builtin type, like `FileHandle` (a new value tag,
      `<TestCase>` in inspect), not a builtin record: it has no fields at all,
      so a record gave nothing.
    - Each task records the test it was spawned under (`test`, inherited at
      spawn; a test's task points to itself). An assertion records its first
      failure there (`note`), which is the nearest test task of §36.3 without
      walking parent links. When a test's task ends, the scheduler records
      whether it left running children (`left_children`): that is the pending
      check, made when the test returns, not when `Test.run` wakes later. Its
      leftover tasks, which moved to the caller of `Test.run`, are cancelled
      with `agc_task_cancel` whatever the outcome. The unobserved-crash check
      looks only at crashes of tasks spawned under that test, and after the
      record every crash of that test's tasks is observed, so a second crash or
      a leftover's crash never reaches the next test. At the end of stdin and
      after a list, `Test.run` ends the run as a return from `main` does
      (`agc_report_unobserved`): a crash outside every test that nothing
      observed prints the summary line and exits 1, which the 25b runner reports
      as a file error. `Test.run` inside a test, or in any task but `main`'s, is
      the new code `RUNTIME-TEST-RUN`.
    - The outcome order is §36.3's (crash, first assertion, the block's
      `error`), then pending tasks, then an unobserved crash. A crash keeps its
      code, message and span on the task (`crash_code`, `crash_message`,
      `crash_span`) for the record.
    - Records use the BDD marker (U+001E and `agentica-bdd `; superseded by 25c:
      the records are plain JSON lines on the child channel, with no marker) and
      sorted keys. A `fail` record is the `--json` diagnostic (`code`, `file`,
      `message`, `range`) plus `event`, `expected` and `actual`. An index line
      that is not plain digits (no sign, no leading zero) naming a test is a
      `RUNTIME-BDD-INFRA` fail record and exit 1. `Test.run` checks the names
      before it looks at the mode, so a bad name fails a direct run too.
    - The per-test seed is the run's seed (`--seed`, or the one drawn at start,
      now kept in the runtime) XOR the FNV-1a hash of the name, through the
      usual splitmix64 seeding.
    - The checker's predicate for `Test.eq` is `data-type?` (the old
      `printable-type?`, renamed): the §25.4 set plus `Json`. 15d needs it
      without `Json`. The §25.4 message that names the field without equality,
      with its secondary span, is left for 15d.
    - The assertions carry the effect `test` in the catalog, so an assertion
      used as a statement is not `CHECK-UNUSED-VALUE`.
    - Tests: the goldens `test-assertions` (run mode: every assertion passing
      and failing, a struct, a map in another key order, an enum, a Result,
      `Json` and a list of `Json`, an ignored failure, the block's error, a
      crash and the next test, pending tasks, an unobserved crash, an assertion
      in a spawned task at that task's span, `Test.run` inside a test, an
      assertion outside a test), `test-crash-observed` (two crashes in one test,
      a leftover that crashes after its test returned, and a crash outside the
      tests that only the end-of-run summary reports), `test-list` (list mode),
      `test-direct` (run directly: stderr, exit 2), `test-name-empty` and
      `test-name-duplicate`; a seed check in `tests/vm-diff-common.rkt` (a test
      gives the same values alone and after another test, and other values with
      another seed) and the span of `RUNTIME-TEST-NAME` at the second
      `Test.test` call; checker tests for two different types, an `Fn`, a struct
      with an `Fn` field, a block that does not return `Result[Void]`, `try` in
      a test block, and `Test` and `TestCase` as type names.
    - **Left for 25b:** the CLI tests of §36.12 and `RUNTIME-TEST-TIMEOUT` (the
      runner's deadline).
    - **Dropped by the owner's rule** (only what proves the change): a deep
      value for the explicit stack and a C test of `agc_equal` (15d adds them
      with `==`).
- [x] **25b: `agentica test` runs test files (§36.5 to §36.8).**
  - **Driver** (`src/bdd-driver.rkt`): find `*_test.agc` next to `.feature`
    files in one pass; the default paths `specs/` and `test/`; compile each test
    file; `--only TEXT`.
  - **Shared layer (first PR of 25b, done):** `std/bdd/runner` and
    `std/bdd/report` move to `std/test/runner` and `std/test/report`, shared by
    BDD and unit tests; `std/test/report` owns `Span` and `Example`, which
    `std/bdd/gherkin` and `std/bdd/match` import, and `error_at` replaces
    `from_diagnostic`; Gherkin parsing and step matching stay in `std/bdd`.
    BDD's `then_*` checks compare with `Test.eq` (`agc_equal`) and their records
    carry the inspect texts `Test.eq` shows (a `Json` line as its canonical
    text); the report prints `expected` and `actual` as they are instead of
    quoting them again. Goldens `test-report-run` and `test-report-exit`
    (renamed from `bdd-report-*`).
  - **Protocol (second PR of 25b, done; superseded by 25c, which removed the
    token, `mid_line`, the reserved stdin and `agc_protocol_line` and moved the
    protocol to the child channel):** the first stdin line in both modes is a
    token from the runner, and every record carries it (`token`), so a test's
    own output cannot forge a record; a record starts on a fresh line
    (`mid_line` of the output stream, kept per piece copied into its buffer and
    used by `agc_write_record`); with the arguments `--agentica-test list|run`
    the VM reserves stdin (`rt->in.reserved`): user code reads it as empty from
    the start of `main`, and only `Test.run` reads it (`agc_protocol_line`),
    from a private close-on-exec copy of fd 0; fd 0 itself becomes `/dev/null`,
    so `/dev/stdin` and `/proc/self/fd/0` read nothing. `Test.run` runs only in
    `main`'s task: any other task, not only a test, is `RUNTIME-TEST-RUN` (the
    docs said so; the code now agrees). Goldens `test-protocol` (stdin and
    `/dev/stdin` empty in `main` and in a test, a record after a partial line, a
    forged record) and `test-run-task` (`Test.run` in a task `main` spawned);
    the `test-*` goldens carry the token. `tests/test_vm_test_protocol.py`
    drives a test file over pipes with an independent Python peer
    (`tests/fixtures/test-protocol-peer.py`): the token, list records, one index
    at a time, a forged record and a `/dev/stdin` read. Docs: `docs/grammar.md`,
    the site `Test` page (also: `Test.eq` takes its type from the first
    argument, so `Test.eq(error("x"), r)` is `CHECK-RESULT-TYPE`),
    `references/testing.md`, the development skill.
  - **Runner and report** (`stdlib/test/runner.agc`, `stdlib/test/report.agc`):
    the list and run children for test files (with `--allow-run`), the seed
    drawn when none is given, the 30-second deadline per test from the moment
    its index is sent, the output limit and captured stdout per test, the list
    record's `line` and `column`, `kind`, `output`, `seed`, the `not_executed`
    status and count.
  - **First users:** unit tests for `std/queue` and `std/http`'s pure helpers in
    `tests/std/`, run by a rackunit test.
  - **Tests:** the CLI tests of §36.12.
  - **Docs:** `docs/grammar.md` and `docs/bdd.md` (`agentica test`), the
    programming skill (`references/testing.md`, `references/bdd.md`),
    `site/content/getting-started.md`, the development skill.
  - CHANGELOG: an entry under `[Unreleased]` for any user-visible change.

  - **Done** (third PR). As built: `std/test/units` runs a test file and
    `std/test/child` holds the helpers both runners share; `--only` and the
    defaults `specs/` and `test/` as specified; a broken step program no longer
    hides the test files; the seed drawn by the runner reaches every child, BDD
    scenarios included, and the text formats show it on the last line only when
    the run failed, so a passing run's text stays the same; a test that was not
    run is `NOT RUN file / name` in the text formats; the run token comes from
    the driver's OS randomness, not the seed, and reaches the runner on its
    stdin, not in the config file; stderr shown with a failure keeps only the
    non-VM lines and its last 64 Ki characters; the 1 MiB stderr cap is per
    file, and hitting it fails the file, not the running test (an unread-stdout
    overflow still fails the test); a list child that exits, crashes or never
    calls `Test.run` is a file error with its output (a file entry's `output`);
    `--only` must be given once and not empty, and a `--only` that matches
    nothing is `CHECK-BDD-EMPTY`; a `--steps` program that does not compile is a
    file error even with no feature; a usage report carries `--seed`;
    `RUNTIME-TEST-RUN` also names a test file whose `main` never calls
    `Test.run`; a scenario has `output` too (always `""` for BDD), and a file's
    `kind` is `feature`, `tests`, `steps` (the step program) or `""`. Not done:
    `--jobs N` (§36.6, later).

**Done when:** `agentica test test/` runs a `*_test.agc` file and a `.feature`
file in one report with the BDD formats and exit codes, a failed `Test.eq` shows
expected, actual and its span, a crashing test fails alone, and the `std/` unit
tests run in `make test`.

- [x] **25c: the child protocol on its own descriptor
  ([§14](../vm/14-core-invariants.md#14-vm-core-invariants)).** A simplification
  of 25b's protocol, so a test's stdin and stdout are the test's own and the VM
  core loses the special cases 25b added (#155, #158). Decided by the owner on
  2026-10-13: it also moves the BDD scenario children's protocol to the same
  descriptor, so there is one child-protocol channel. Its place in the order is
  row 7.2.1a of the [roadmap](README.md), after the VM layers (row 7.2.1b,
  [§15](../vm/15-layers.md#15-vm-layers)) and rows 7.2.1d to 7.2.1f, so its new
  `Process` builtins are written on the port. One PR.
  - **Spec first, generic feature:** a parent channel for any child process,
    specified in the processes spec (§10.4 of
    [`docs/vm/10-io-processes.md`](../vm/10-io-processes.md)) and
    `docs/grammar.md` inside this PR, before the code. Parent side:
    `Process.spawn_captured` gains an optional extra pipe (its form, a new
    argument or a sibling builtin, is fixed in the spec, since default parameter
    values, 15a, come later); the child gets it as fd 3 and the environment
    marker `AGENTICA_CHANNEL=3`, and the parent writes and reads it with
    `Process` builtins. Child side: one minimal builtin pair, named in the spec
    (for example a read of one line and a write on the parent channel), each
    returning a `Result` with an error when the program has no channel.
    `Test.run` (C) uses the same channel internally. On the VM the channel is a
    pipe on the loop, never a pool job (§14.1).
  - **How the child knows:** the child VM takes fd 3 as its parent channel only
    when `AGENTICA_CHANNEL=3` is set and `fstat` shows a socket or a FIFO opened
    for reading and writing, whatever its arguments are. It then moves the
    descriptor to a private close-on-exec descriptor above 2 and removes the
    marker from its environment, so its own children inherit neither. An
    inherited fd 3 without the marker (make's jobserver, say) is never taken for
    it, and neither is a regular file or a character device with the marker
    (left untouched); with no channel, `Test.run` is `RUNTIME-TEST-RUN`. A
    hostile test can still find the private descriptor through `/proc/self/fd`,
    as §36.7 accepts for a hostile test.
  - **Runners:** `std/test/runner`, `std/test/units` (which calls
    `spawn_captured`) and `std/test/child` pass the protocol on the channel: the
    index lines go in and the records come out there. `stdlib/bdd.agc` moves
    both its scenario children (the step and record lines it reads with
    `IO.gets` and writes with `IO.print` today) and its list mode (which prints
    its records on stdout today) to the child-side builtins; its mode is still
    chosen from `System.args`. A child's stdout is only the program's output, so
    no record can be forged by printing. A test child's stdin is an empty pipe
    the runner closes at once, so a test that reads stdin sees its end, not the
    runner's lines.
  - **Removed, every place the token lives:** `src/bdd-driver.rkt` (it draws the
    token and writes it on the runner VM's stdin), `stdlib/test/runner.agc` (it
    reads the token and passes it on), `stdlib/test/units.agc` (it writes the
    token to each child and checks records with it), `stdlib/test/child.agc`
    (`record_for`'s token check), the `token` field of every record, and the
    Racket tests that drive them. In the VM: the reserved stdin
    (`rt->in.reserved`, `reserve_stdin` in `vm/main.c`, the private
    close-on-exec copy of fd 0 and `/dev/null` on fd 0), `agc_protocol_line`'s
    stdin source, and `mid_line` of the output stream and `agc_write_record`
    (used by `vm/testing.c`). `Test.run` reads and writes fd 3.
  - **Docs:** §10.4 and `docs/grammar.md` (`Process.spawn_captured`'s extra
    pipe, the child-side builtin pair, `Test.run`), [§36.6 and
    §36.7](../future/36-unit-tests.md#366-isolation-a-child-vm-per-file-a-task-per-test)
    (the protocol, stdin and output of a test), `docs/bdd.md` (the scenario
    child's protocol), the programming skill (`references/testing.md`,
    `references/processes.md`, `references/bdd.md`), the site pages of `Process`
    and `Test`, the development skill.
  - **Tests:** the goldens `test-protocol*` and `test-run-task` (a test reads
    its real stdin and prints a partial line; a record-shaped line on stdout is
    output, not a record), the `test-*` goldens lose the token;
    `tests/test_vm_test_protocol.py` and its Python peer
    (`tests/fixtures/test-protocol-peer.py`) drive fd 3; a BDD scenario that
    prints a record-shaped line; a golden or peer test for the parent channel on
    its own (both sides, and the no-channel error), one where an inherited fd 3
    without the marker is ignored, and one where a grandchild does not inherit
    the channel.

  - **Done** (one PR). As built, see [§10.4](../vm/10-io-processes.md) (the
    spec) and the choices below. **Form:** a sibling builtin,
    `Process.spawn_channel(command, args, dir, timeout_ms)`, since default
    parameters (15a) come later; the channel is one `socketpair` per child, the
    child end is fd 3 and `AGENTICA_CHANNEL=3` is in its environment; the parent
    has `channel_read_line`, `channel_send` and `channel_close` (a half close),
    and `read_available` (the stdout captured so far, consumed, never waiting;
    the runner reads it after each record, and the child flushes stdout before a
    record, so the output of a test is exactly what came before its record); the
    child has `Process.parent_read_line(timeout_ms)` and
    `Process.parent_send(text, timeout_ms)`, both with a positive timeout run as
    a job timer (§14.2), `process: no parent channel` when there is none. A
    timed-out channel call closes the channel and only the channel, so the
    runner can still read the output of the process and close it. Every spawn
    rebuilds the child's environment and removes `AGENTICA_CHANNEL`, so a parent
    without a channel strips an inherited marker, as for `UV_USE_IO_URING`. The
    channel is Linux-only, in a new service, `vm/duplex.c` (one stream with a
    line buffer, two lock records and one job kind), and the VM takes fd 3 at
    startup in `vm/main.c` only with the marker and a socket or a FIFO opened
    for reading and writing (a one-way FIFO would fail the read start and park
    `Test.run` for ever). **Records** are plain JSON lines with no marker and no
    token; `Test.run` and BDD flush stdout, then send. **`Test.run` rule (owner
    decision, option B):** the "main only" check of 25b stays: `Test.run` must
    be called from `main`'s own task, and a call from a test or any other task
    is `RUNTIME-TEST-RUN`, "call Test.run from main, outside every test"; a call
    with no channel under `--agentica-test list|run` is `RUNTIME-TEST-RUN` too.
    There is no "serves once" rule and no "channel in use" answer for the test's
    own code: `Process.parent_read_line` and `Process.parent_send` are for
    runner code, and a test that calls them can break the protocol (accepted,
    §36.7). **Removed from the VM:** `rt->in.reserved`, `reserve_stdin`, the
    private copy of fd 0 and `/dev/null` on fd 0, `agc_protocol_line`,
    `mid_line` of the output stream and `agc_write_record` (and their C tests).
    **Removed elsewhere:** the token in the driver, the runner, `units` and
    `child` (`record_for`, `marker`), the leak test of the token and the
    forged-record case of the stdout test. **Goldens:** the `test-*` fixtures
    drive a channel (`.channel` sidecar: the lines to send, one after each
    record, run by `tests/fixtures/channel-run.py`, which merges the channel
    records into stdout as `channel> ...` lines, in the order the child produced
    them); new `test-no-channel`; `test-protocol` and `test-run-task` were
    rewritten. **Tests:** `tests/test_vm_child_channel.py` (a Python peer on
    both sides: lines in pieces, a 300 KB line, EOF, timeouts,
    `no parent channel`, a marker without a descriptor, a descriptor without the
    marker, a grandchild that gets neither, a channel line over 1 MiB, a stalled
    send, a UTF-8 character split between two `read_available` calls,
    `channel_close` after the peer exited, and fd 3 as a regular file, a
    character device or a write-only FIFO (refused, untouched) or as a
    read-write FIFO (taken)), `tests/test_vm_test_protocol.py` (the Python peer
    is the runner), a test that reads stdin and prints record-shaped lines in
    `tests/unit-test-test.rkt`, a BDD step that prints a record-shaped line.
    **Review round:** a cut of stdout or stderr wakes a pending
    `channel_read_line` with `process: output exceeds 1048576 bytes` (sticky,
    lines first), so a test or a handler that prints for ever fails at 1 MiB
    with `RUNTIME-BDD-OUTPUT-LIMIT` (`endless_test.agc` and a BDD step, each
    asserted to end long before the deadline); an index line that is not valid
    UTF-8 is the `RUNTIME-BDD-INFRA` fail record too; goldens `test-bad-index`,
    `test-bad-index-bytes` (the exit after a fail record) and
    `process-channel-close` (`Process.close` and a task cancel with a channel
    read and a send pending); a 1 MB test name makes `Test.run` list send a
    record bigger than the socket buffer (the queued write path, in the protocol
    peer).
