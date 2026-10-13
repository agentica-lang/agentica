## Phase 25: Unit tests

Specified in [`docs/future/36-unit-tests.md` section 36](../future/36-unit-tests.md#36-unit-tests-stdtest). Phase 25 adds the builtin `Test` module and runs `*_test.agc` files with `agentica test`, next to the features, through the BDD runner and report. It comes after task crash isolation (phase 24), so a crash fails one test, and before HTTP 20c (order step 7.1, decided by the owner on 2026-10-13). It comes after 7i, so it is VM-only, like every new feature. It has two PRs, each with its own tests and docs.

- [ ] **25a: the `Test` module (§36.3, §36.4).**
  - **VM:** `Test.test` (the `TestCase` record with its call span), `Test.eq` (equality of §25.4 plus `Json` by canonical text, with an explicit stack), `Test.ok?`, `Test.error?`, `Test.assert`, the assertion records on the nearest test task, and `Test.run` (list and run modes, one task per test, the pending-task and unobserved-crash checks, the records of §36.6, the per-test seed).
  - **Front end:** the catalog entries; `Test.eq` needs a type with equality (`CHECK-TYPE-MISMATCH`); `Test` and `TestCase` reserved.
  - **Tests:** the golden fixtures and checker tests of §36.12.
  - **Docs:** `docs/grammar.md` (the `Test` module, reserved names); the programming skill (`references/testing.md`, its row in "When to read a reference", `references/diagnostics.md`); `site/content/library/test.md`; the development skill.
- [ ] **25b: `agentica test` runs test files (§36.5 to §36.8).**
  - **Driver** (`src/bdd-driver.rkt`): find `*_test.agc` next to `.feature` files in one pass; the default paths `specs/` and `test/`; compile each test file; `--only TEXT`; draw a seed when none is given.
  - **Runner and report** (`stdlib/bdd/runner.agc`, `stdlib/bdd/report.agc`): the list and run children for test files, the 30-second test deadline, captured stdout per test, `kind`, `output`, `seed`, the `not_executed` status and count.
  - **First users:** unit tests for `std/queue` and `std/http`'s pure helpers in `tests/std/`, run by a rackunit test.
  - **Tests:** the CLI tests of §36.12.
  - **Docs:** `docs/grammar.md` and `docs/bdd.md` (`agentica test`), the programming skill (`references/testing.md`, `references/bdd.md`), `site/content/getting-started.md`, the development skill.
  - No CHANGELOG: the project adds none in the private alpha.

**Done when:** `agentica test test/` runs a `*_test.agc` file and a `.feature` file in one report with the BDD formats and exit codes, a failed `Test.eq` shows expected, actual and its span, a crashing test fails alone, and the `std/` unit tests run in `make test`.
