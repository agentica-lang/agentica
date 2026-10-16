## Phase 31: Test functions without `main`

Specified in [`docs/future/50-test-functions.md` section
50](../future/50-test-functions.md#50-test-functions). Phase 31 lets a
`*_test.agc` file have no `main`: its top-level `test_*` functions are its
tests, and the front end adds the `main` that runs them. It has one item, 31a,
which is part 50a of §50. Its place in the order is row 7.11 of the
[roadmap](README.md), in post-bootstrap step 6.

- [ ] **31a: test functions without `main` (§50, part 50a).**
  - **Front end:** the pass of §50.2 in `compiler/linker.agc`, and the
    `test_file` flag from `compile_test` through `Compile.file`,
    `Pipeline.compile` and `Pipeline.check_file`. The codes
    `CHECK-TEST-SIGNATURE`, `CHECK-TEST-MAIN` and (if needed) `CHECK-TEST-NAME`
    are proposals until this item lands.
  - **Tests:** spec tests for each code in `tests/test_spec_checker.py` (the
    code and the span); in `tests/test_unit_test.py`, a file with only
    `test_*` functions passes and fails as expected, its names appear in the
    report, and `--only` selects them; goldens of the report.
  - **Docs:** `docs/grammar/06c-tasks-and-tests.md` and
    `docs/grammar/07-diagnostics.md`, the site testing page, the programming
    skill (`references/testing.md` and `references/diagnostics.md`), and a
    `CHANGELOG.md` entry under `[Unreleased]`. The `main` and `Test.run` form
    stays documented as valid.
  - **Where:** `compiler/` only. No VM change, and no stage0 refresh, because
    `compiler/` does not use the new form.

The item is one PR, with its own tests and docs.

**Done when:** a test file with no `main` runs under `agentica test`, and the
report names each test from its function name; a file with both `main` and
`test_*` functions is `CHECK-TEST-MAIN`; and the `main` and `Test.run` form
still works and is documented.
