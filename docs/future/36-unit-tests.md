## 36. Unit tests (`std/test`)

**Status:** planned (roadmap [phase 25](../roadmap/25-unit-tests.md)). Decided by the owner on 2026-10-13: Agentica gets minimal unit tests in the style of ExUnit, run by `agentica test` next to the BDD features. The order, decided the same day: after task crash isolation (§37, phase 24) and before HTTP 20c, doc comments (phase 22) and digit separators (phase 23) (§36.9).

The idea in one paragraph: a test file is a program named `*_test.agc` whose `main` calls `Test.run` with a list of `Test.test(name) do ... end` blocks. Each block returns `Result[Void]`, and the assertions (`Test.eq`, `Test.ok?`, `Test.error?`, `Test.assert`) return `Result[Void]` too, so they chain with `try`: Agentica has no exceptions. `agentica test` finds test files and `.feature` files in the same pass and writes one report, with the same text, `--ai` and `--json` shapes and the same exit codes as BDD. Each test file runs in its own child VM through the BDD runner (§31.5), and each test runs as its own task, so with §37 a crash fails only that test.

**Why now.** Unit tests are needed above all for the planned self-hosted front end (§35) and for the `std/` modules (`std/http`, `std/bdd` and its internal modules, `std/queue`), which today are tested only through whole-output golden fixtures: one fixture per behavior, and a failure shows a diff of the whole output, not the check that failed.

### 36.1 Today

Checked at `099daa3`:

- `agentica test [PATH...] [--steps FILE]` runs `.feature` files only (`src/bdd-driver.rkt`, `stdlib/bdd/runner.agc`). The driver finds the files; the runner runs each scenario in its own child VM and builds the report with `std/bdd/report` (`stdlib/bdd/report.agc`: `FileResult`, `ScenarioResult`, `json`, `text`, `exit_code`).
- The record protocol (U+001E, `agentica-bdd `, then JSON on stdout), the step limit per child, the 30-second deadline and the 1 MiB output limits are those of §31.5.
- There is no assertion with expected and actual outside BDD. A program checks with `if` and `puts`, and a golden fixture compares the output.
- `try` already works in a block passed to a function whose parameter is `Fn[..., Result[T]]` (`docs/grammar.md`, "Blocks and closures"), so `Test.test(name) do ... end` with `try` inside needs no checker change.
- Agentica has no user generics (only enums), and a function cannot learn the span of its caller.

### 36.2 Shape

```agentica
import "ports" as Ports

def main() -> Void
  Test.run([
    Test.test("parses a port") do
      try Test.eq(Ports.parse("8080"), ok(8080))
      Test.eq(Ports.parse(" 80 "), ok(80))
    end,
    Test.test("rejects zero") do
      Test.error?(Ports.parse("0"))
    end,
    Test.test("default is below 1024") do
      Test.assert(Ports.default() < 1024, "default port must be privileged")
    end
  ])
end
```

```text
$ agentica test test/
PASS test/ports_test.agc / parses a port
FAIL test/ports_test.agc / rejects zero
test/ports_test.agc:10:7 [RUNTIME-TEST-ASSERTION] expected an error; actual "ok(0)"
PASS test/ports_test.agc / default is below 1024
2 passed, 1 failed, 0 not executed, 0 file errors
```

### 36.3 API

```text
Test.test(name: String, body: Fn[Result[Void]]) -> TestCase
Test.run(tests: List[TestCase]) -> Void
Test.eq(actual: T, expected: T) -> Result[Void]
Test.ok?(result: Result[T]) -> Result[Void]
Test.error?(result: Result[T]) -> Result[Void]
Test.assert(condition: Bool, message: String) -> Result[Void]
```

- **`Test.test`** builds a `TestCase`, a builtin record with no public fields, like `FileInfo`. It keeps the name, the block and its own call span (the test's location in the report). The name must not be empty, and names are unique in a file; otherwise `Test.run` fails the file with `RUNTIME-TEST-NAME`.
- **`Test.run`** serves the runner (§36.6) and never returns: it ends with `System.exit`. Run directly (`agentica ports_test.agc`), it prints "run this file with agentica test" on stderr and exits 2, as `BDD.run` does.
- **Assertions** return `ok()` when they hold, and `error(text)` when they do not. The text is short and readable: `expected ok(80); actual error("not a number")`. Each also knows its own call span.
  - `Test.eq` compares by value. `T` must have equality in the sense of §25.4 (scalars, strings, ranges, and lists, maps, Results, structs and enums made of them), or be `Json`, compared by canonical text (§31.8). `Fn`, `Task` and handles are `CHECK-TYPE-MISMATCH`. Expected and actual are shown with `inspect` (a `Json` as its JSON text). The order is `actual, expected`, as ExUnit's `assert actual == expected` reads.
  - `Test.ok?` and `Test.error?` check the tag of a `Result`; the failure shows the value with `inspect`.
  - `Test.assert` fails with `message`.
- **Chaining.** `try Test.eq(...)` stops the test at the first failed assertion; the last assertion can be the block's result. A test that returns `ok()` passes.
- **An ignored failure still fails the test.** `Test.eq(a, b)` as a statement drops its `Result`, and `CHECK-UNUSED-RESULT` (phase 16) comes later. So each failed assertion is also recorded on the test it runs in (the nearest test task among the task and its ancestors, with 20b's parent links), and a test that returns `ok()` with a recorded failure fails with the first one. An assertion outside any test only returns its `Result`.
- **Outcome of a test**, in this order: a crash (§37) gives that diagnostic; else the first recorded failure gives `RUNTIME-TEST-ASSERTION` with the assertion's span, `expected` and `actual` (`Test.assert`: the message, no expected or actual); else an `error(m)` the block returned itself gives `RUNTIME-TEST-ERROR` with `m` at the test's span; else the test passes.
- **Tasks in a test.** A test may spawn tasks. When it returns, `Test.run` checks that its descendants have ended (`RUNTIME-TEST-PENDING-TASKS`, then they are cancelled with 20b's core, so the next test starts clean) and that none of them crashed unobserved (`RUNTIME-TASK-CRASHED`, §37.4).

### 36.4 Why a builtin module, not a `std/` module

The request names the feature `std/test`. The functions cannot be written in Agentica today, so `Test` is a builtin module, in C, like `Task`, and needs no import:

- `Test.eq`, `Test.ok?` and `Test.error?` are generic over any type. `std/` modules have no generics, and the compiler prelude, which may be generic (§25.6), starts only at order step 8.2.
- Every assertion needs the span of its own call. Builtins get it from `CALL_BUILTIN`; Agentica code cannot (stack traces are phase 14b, later).
- `Test.run` works on runtime state no Agentica code can see: the assertion records of §36.3, the crash of a test task, its descendants.
- A builtin module cannot share its name with an import alias (§30.7), so splitting the six functions between a builtin and an `std/test` module would give two names for one API.

Everything else stays in Agentica, as the std-first rule asks: the runner and the report are `std/bdd/runner` and `std/bdd/report`, extended (§36.6). `Test` and `TestCase` become reserved names (`CHECK-REDEFINED-NAME` for a user type or alias); no `.agc` file in the repo uses either. If the prelude later makes `Test.test` and `Test.run` possible in Agentica, they may move there with no API change.

### 36.5 Discovery, names and filtering

- `agentica test [PATH...]`: `PATH` is a `.feature` file, a `*_test.agc` file, or a directory searched recursively for both, in the same pass and with the same rules (§31.6: sorted, links to folders not followed, the same file errors). The default paths become `specs/` and `test/`; a default folder that does not exist is skipped, and finding nothing is exit 1, as today.
- Every test file is its own program: the driver compiles each one, like the step program. A front-end diagnostic is a file error of that file (exit 1); other files still run. `--steps` is only for features.
- A test is named by its file and its name: `test/ports_test.agc / parses a port`, as a scenario is by its feature and its name.
- **Filtering**, kept minimal: `--only TEXT` keeps the tests and scenarios whose name contains `TEXT`; the others are left out of the report, not counted as not executed. There are no tags for tests.

### 36.6 Isolation: a child VM per file, a task per test

The runner (`std/bdd/runner`, extended) handles a test file as it handles a scenario, with the same child start, record marker, deadlines and output limits (§31.5):

1. **List child:** `VM --json --max-steps 1000000 [--seed N] -- FILE.agcb --agentica-test list`. `Test.run` writes one `{"event":"test","name":...,"line":...}` record per test, in order, then `ready`. A crash or exit here is a file error.
2. **Run child**, one per file: `VM --json --max-steps M [--seed N] -- FILE.agcb --agentica-test run`, with `M` = 1,000,000 × (the number of tests + 1). The runner sends the index of each test to run, one per line, and the child answers `{"event":"pass"}` or `{"event":"fail", ...}` with the diagnostic object of the report. The runner sends the next index only after the answer.
3. **Inside the child,** `Test.run` runs each test as its own task, a child of the task that called `Test.run`, awaits it, and writes the record. Tests run one at a time, in file order; running them in parallel is a later option (`--jobs N`), as for scenarios.

**With §37** (the planned order): a crash in a test ends only its task. `Test.run` reports it as that test's failure, with the crash's code and span, and goes on with the next test. A crash outside the tests (in `main` before `Test.run`), a step limit, a `System.exit` or the deadline ends the child: the current test fails with that diagnostic (`RUNTIME-BDD-PREMATURE-EXIT`, `RUNTIME-STEP-LIMIT`, `RUNTIME-TEST-TIMEOUT`), and the rest of the file is `not_executed`.

**Without §37**, a crash in a test ends the whole child, so the crash fails that test and the rest of the file is `not_executed`. §36 can ship before §37 with this weaker isolation; then the crash rules of §36.3 (a crash as a test's failure, the unobserved-crash check) wait for §37. The decided order puts §37 first, and that is the recommendation: a file with one bug would otherwise hide the results of every test after it, which is exactly when a developer needs them.

**Timeouts.** Each test has 30 seconds from the moment its index is sent, as a scenario has (§31.5). Past it, the runner closes the child: the test fails with `RUNTIME-TEST-TIMEOUT` and the rest of the file is `not_executed`. There is no per-test setting; a test that needs a shorter bound uses the timeouts of the calls it makes.

**Seeds.** `--seed N` reaches every child, as for BDD. Inside the child, each test's task gets a generator seeded from `N` and the test's name, not from the spawn order, so a test sees the same values whether it runs alone (`--only`) or with the others. Without `--seed`, the runner draws a seed, passes it to every child and prints it in the report, so a failure can be replayed with `--seed`.

### 36.7 Output of a test

- A test's stdout is captured: the runner keeps the non-record lines that arrive while the test runs, up to 64 KiB per test, and shows them under a failed test (`output` in `--json`). A passed test's output is dropped, as ExUnit's `capture_io` does. The child's 1 MiB limit applies as for scenarios (`RUNTIME-BDD-OUTPUT-LIMIT`).
- Stderr is captured for the whole child and read when it exits. It is shown only with a file error, or with the test that was running when the child died. The §37 crash lines (`"task": true`) are not shown again, since the crash is already the test's error.
- Stdin is the protocol pipe, as for step handlers: tests must not read it.

### 36.8 Report and exit codes

- `std/bdd/report` writes both kinds of file in one report, with the same three formats. A test file is a file entry with `feature: ""` and `kind: "tests"` (a feature file gets `kind: "feature"`); each test is a scenario entry with its name, status, `location` (the `Test.test` call), `duration_ms`, `steps: []`, `error` and `output`.
- The scenario status gains `not_executed`, and the top-level `not_executed` count (always 0 today) counts the tests not run. The top level gains `seed`.
- The plain and `--ai` lines are those of BDD, with the file path where a feature name goes: `PASS file / name` or `FAIL file / name`, and the summary (`file:line:column [CODE] message; expected ...; actual ...`) on the next line or after ` | `. The last line counts the tests not executed.
- Exit codes are unchanged: 0 when everything passes and something ran, 1 when a test, scenario or file fails or nothing was found, 2 for usage errors and `RUNTIME-BDD-INFRA`.
- New codes: `RUNTIME-TEST-ASSERTION`, `RUNTIME-TEST-ERROR`, `RUNTIME-TEST-TIMEOUT`, `RUNTIME-TEST-NAME`, `RUNTIME-TEST-PENDING-TASKS`.

### 36.9 Order and the evaluator

- Decided by the owner on 2026-10-13: 7i (first item, done) → 20b → §37 (phase 24) → §36 (phase 25) → 20c → 22 → 23. It is after §37 so that a crash fails one test, not the rest of the file.
- `Test` is VM-only and lands before the evaluator is deleted, like HTTP 20a to 20d: the driver refuses it on an evaluator path with `LOWER-UNSUPPORTED` (`vm-only-builtins`, §31.9). `agentica test` already runs only on the VM (21f), so nothing else changes.
- **First users,** in the same phase: unit tests for `std/queue` and `std/http`'s pure helpers in `tests/std/`, run by a rackunit test through `agentica test --json`. The internal `std/bdd/*` modules and the self-hosted front end (§35) follow in their own PRs.

### 36.10 Later: doctests

§32.8 keeps doctests "to evaluate later": run the fenced `agentica` examples of `std/` docs. Once doc comments (phase 22) land, `agentica test` is the place to run them: each example with an `output` block becomes a test named `doc: MODULE.NAME #n`, in the same report, compiled and run in its own child VM and passed when its stdout equals the block. It needs only the discovery pass and the report of this section, not `Test` itself. It stays to evaluate, with §32.8.

### 36.11 Decided against

- **Exceptions or `assert` that stops the test by itself.** Agentica has no exceptions; Results and `try` are the one way to stop early (§36.3 still catches an ignored failure).
- **A runner per test file in Racket, or tests in-process in the runner VM.** The child VM per file reuses everything of §31 and keeps user code out of the process that writes the report.
- **A child VM per test.** Full isolation without §37, but one VM start per test; with §37 a task per test is enough.
- **`describe` blocks, `setup` callbacks and tags.** Not needed for the first users; a helper function does what `setup` does. Each can come later with its own spec.

### 36.12 Tests

- Golden fixtures (`tests/fixtures/vm/`): each assertion passing and failing, with its error text; `Test.eq` on a list, a map in another key order, a struct, a `Json`; the assertion records (an ignored failure fails the test); `Test.run` run directly (stderr text, exit 2).
- Checker tests: `Test.eq` on two different types and on an `Fn` (`CHECK-TYPE-MISMATCH`); a block that does not return `Result[Void]`; `try` in a test block; `Test` as a user type name (`CHECK-REDEFINED-NAME`).
- Racket tests over the CLI (`tests/bdd-test.rkt` or a new `tests/unit-test-test.rkt`), with fixtures in `tests/fixtures/`: a file that passes; a failed `Test.eq` (code, span, expected, actual in the three formats); a block's own `error`; a crash in a test (with §37 the next test still runs; the stderr line is not shown twice); a crash in `main` and a `System.exit` (the rest `not_executed`); a test that never ends (`RUNTIME-TEST-TIMEOUT`, with a short deadline set through the runner's config in the test); pending tasks; duplicate and empty names; `--only`; the seed (the same values alone and with others; the drawn seed in the report); captured stdout shown only for a failed test; a test file with a compile error next to a passing feature (one report, exit 1); a directory with both kinds.
- The `--max-steps` sweep does not apply to the CLI tests; the golden fixtures keep it.

**Docs** (in phase 25): `docs/grammar.md` (the `Test` module, reserved names, `agentica test`), `docs/bdd.md` (test files in the same run), the programming skill (a new `references/testing.md` and its row in "When to read a reference", `references/diagnostics.md`), `site/content/library/test.md` and `site/content/getting-started.md`, the development skill.
