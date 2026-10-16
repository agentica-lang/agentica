## 50. Test functions

**Status:** planned (2026-10-16), one part (50a). Roadmap phase 31
([`docs/roadmap/31-test-functions.md`](../roadmap/31-test-functions.md)) is row
7.11 of the [roadmap](../roadmap/README.md) order, in post-bootstrap step 6.
Nothing is implemented. The `main` and `Test.run` form of
[§36](36-unit-tests.md) stays valid.

### 50.1 Today

- A test file is a `*_test.agc` program whose `main` calls `Test.run` with a
  list of `Test.test(name) do ... end` blocks (§36.2).
- Every program needs `main() -> Void`: `check_main` in
  `compiler/check_register.agc` reports CHECK-MAIN otherwise. So a test file
  with no `main` is CHECK-MAIN today.
- `agentica test` decides that a file is a test file by its name:
  `kind_of` in `compiler/bdd_discover.agc` returns "tests" for `_test.agc`.
  Only the driver reads the name; the compiler never does.
- The driver compiles a test file with `Compile.file`, which reaches
  `Linker.link_file` through `Pipeline.compile` and `Pipeline.check_file`.
  Nothing tells the front end that the file is a test.

### 50.2 Shape

- **What**: a `*_test.agc` file may have no `main`. Then its top-level
  functions whose names start with `test_` are its tests, in source order.
  Each takes no parameters and returns `Result[Void]`. Its body is what a
  `Test.test` block holds today: assertions chained with `try`, the last one
  its result. The file may also hold helper functions, structs, enums and
  constants, and import modules of the real code:

```agentica
def test_parses_port() -> Result[Void]
  try Test.eq(parse_port("8080"), ok(8080))
  Test.eq(parse_port(" 80 "), ok(80))
end
```

  `parse_port` is a helper of the same file.

- **How (no text scanning)**: the front end parses the file as always. A
  small pass after parsing looks at the top-level function declarations of the
  root file. When the file is a test file and has no `main`, the pass adds a
  `main` declaration equivalent to `def main() -> Void` with
  `Test.run([Test.test("parses port", &test_parses_port), ...])`. The test
  name is the function name without `test_`, with `_` turned into spaces.
  - The pass belongs in the linker stage: it runs in `compiler/linker.agc`
    after `Modules.load` and before `rewrite_all`. The linker owns the
    declarations of the root file, and `check_main` already reads them from
    `linked.modules`, so the generated code goes through the same rewrite and
    the same checker as any code. A pass after the linker would also have to
    change `Linked`.
  - Only functions declared in that file count, not imported ones. A `test_`
    in a comment or a string never counts, because the pass reads
    declarations, not text.
  - The generated nodes take their spans from the test function they stand
    for, so a diagnostic about them is reported at that function. Their node
    ids come from the numbering that `Linked.ids` counts (`parser_ids` and
    `id_count` in `compiler/linker.agc`). The checker sizes its type table
    from `Linked.ids` (`ids_of` in `compiler/checker.agc`), so the generated
    ids must fall inside it.
  - The checker then checks the generated code like any code, so a wrong
    signature gets a normal diagnostic at the test function. Proposed codes:
    - `CHECK-TEST-SIGNATURE`: a `test_*` function with parameters, or a
      return type other than `Result[Void]`. At the function.
    - `CHECK-TEST-MAIN`: a file with both a `main` and `test_*` functions.
      This is an error, not a rule where `main` wins, so a forgotten `main`
      never hides tests. At `main`.
    - A function named just `test_` has an empty test name. The PR gives it
      an error too (proposed `CHECK-TEST-NAME`).
  - The PR decides which stage emits each code. This design fixes the codes
    and their spans.
  - The runner, the protocol, tasks per test, timeouts, `--only`, seeds and
    the report do not change. The lowering, the bytecode and the VM do not
    change.

- **How the driver knows it is a test file**: `agentica test` decides by
  name, in the driver only (§50.1). The front end gets that fact as a flag of
  the compile call, not from the file name inside `compiler/`. The change:
  `compile_test` in `compiler/bdd_driver.agc` passes `test_file: true` down
  through `Compile.file` (`compiler/bdd_compile.agc`), `Pipeline.compile` and
  `Pipeline.check_file` (`compiler/pipeline.agc`) to `Linker.link_file`
  (`compiler/linker.agc`). Every other caller passes `false`: `agentica check`
  and `agentica FILE.agc` (`compiler/cli.agc`), the runner and the step
  program (`compiler/bdd_driver.agc`), `compiler/bytecode.agc`, and the text
  forms in `check_text.agc`, `lower_text.agc` and `link_text.agc`. So
  `agentica check` and `agentica FILE.agc` still report CHECK-MAIN for a test
  file with no `main`. Whether they should set the flag too is for the PR to
  decide.

- **Not in 50a**: a `test` keyword form (`test name() ... end`). It is
  rejected for now by the one-way rule, since `def test_...` needs no new
  syntax. Parametrized tests (arguments with a table of values) are also left
  out: a loop inside a test covers them today. Either can come later, if the
  need shows.

- **Tests plan**: spec tests through the CLI, as `--json check FILE` with the
  code and the span, in `tests/test_spec_checker.py`, for each new code.
  `agentica test` integration in `tests/test_unit_test.py`: a file with only
  `test_*` functions passes and fails as expected, its names appear in the
  report, and `--only` selects them. Goldens of the report.

- **Docs plan**: the programming skill's testing reference
  (`.agents/skills/agentica-programming/references/testing.md`), its
  diagnostics table (`references/diagnostics.md`), the site testing page
  (`site/content/library/testing/test.md`), the test-file description in
  `docs/grammar/06c-tasks-and-tests.md` and the codes in
  `docs/grammar/07-diagnostics.md` if it lists them, and `CHANGELOG.md` under
  `[Unreleased]`. `SKILL.md` changes only if it shows the test-file form; it
  names only the API today. The `main` and `Test.run` form stays documented as
  valid.

- **stage0**: no refresh needed. `compiler/` does not use the new form.
