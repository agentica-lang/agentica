## Phase 25: Unit tests

Specified in [`docs/future/36-unit-tests.md` section 36](../future/36-unit-tests.md#36-unit-tests-test). Phase 25 adds the builtin `Test` module and runs `*_test.agc` files with `agentica test`, next to the features, through the BDD runner and report. It comes right after task crash isolation (phase 24), so a crash fails one test; its place in the order is row 7.1 of the [roadmap](README.md). It has two PRs, each with its own tests and docs.

- [ ] **25a: the `Test` module (§36.3, §36.4).**
  - **VM:** `Test.test` (the `TestCase` record with its call span), `Test.eq` (it pulls §25.4's type predicate and deep compare forward, with an explicit stack, for 15d to reuse; `Json` at any depth compares and prints as canonical text), `Test.ok?`, `Test.error?`, `Test.assert`, the assertion records on the nearest test task, and `Test.run` (list and run modes, one task per test, the pending-task and unobserved-crash checks, the records of §36.6 with raw texts, the per-test seed from the given seed and the test name).
  - **Front end:** the catalog entries; `Test.eq` needs a type with §25.4 equality or `Json` (`CHECK-TYPE-MISMATCH`); `Test` and `TestCase` reserved.
  - **Tests:** the golden fixtures and checker tests of §36.12.
  - **Docs:** `docs/grammar.md` (the `Test` module, reserved names); the programming skill (`references/testing.md`, its row in "When to read a reference", `references/diagnostics.md`); `site/content/library/test.md`; the development skill.
- [ ] **25b: `agentica test` runs test files (§36.5 to §36.8).**
  - **Driver** (`src/bdd-driver.rkt`): find `*_test.agc` next to `.feature` files in one pass; the default paths `specs/` and `test/`; compile each test file; `--only TEXT`.
  - **Runner and report** (`stdlib/bdd/runner.agc`, `stdlib/bdd/report.agc`): the list and run children for test files (with `--allow-run`), the seed drawn when none is given, the 30-second deadline per test from the moment its index is sent, the output limit and captured stdout per test, the list record's `line` and `column`, `kind`, `output`, `seed`, the `not_executed` status and count.
  - **First users:** unit tests for `std/queue` and `std/http`'s pure helpers in `tests/std/`, run by a rackunit test.
  - **Tests:** the CLI tests of §36.12.
  - **Docs:** `docs/grammar.md` and `docs/bdd.md` (`agentica test`), the programming skill (`references/testing.md`, `references/bdd.md`), `site/content/getting-started.md`, the development skill.
  - No CHANGELOG: the project adds none in the private alpha.

**Done when:** `agentica test test/` runs a `*_test.agc` file and a `.feature` file in one report with the BDD formats and exit codes, a failed `Test.eq` shows expected, actual and its span, a crashing test fails alone, and the `std/` unit tests run in `make test`.
