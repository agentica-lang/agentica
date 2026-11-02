## 50. Test functions

**Status:** planned (2026-10-16), one part (50a, one PR). Row 7.11 of the
[roadmap](../roadmap/README.md) order, item 14 of the list after 0.8.0.
Nothing is implemented. The `main` and `Test.run` form of the grammar's
`Unit tests (Test)` and `agentica test` sections stays valid.

### 50.1 Today

- A test file is a `*_test.agc` program whose `main` calls `Test.run` with a
  list of `Test.test(name) do ... end` blocks (the grammar's `Test` rules).
- A run and `compile` need `main() -> Void`: `check_main` in
  `compiler/check/check_register.agc` reports CHECK-MAIN otherwise, so a test
  file with no `main` is CHECK-MAIN there today. `agentica check` does not need
  a `main`.
- `agentica test` decides that a file is a test file by its name: `kind_of` in
  `compiler/bdd/bdd_discover.agc` returns "tests" for `_test.agc`. Only the
  driver reads the name; the compiler never does, and nothing tells the front
  end that the file is a test.

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

- **How (no text scanning)**: a small pass after parsing looks at the top-level
  function declarations of the root file. When the file is a test file and has no
  `main`, it adds a `main` equivalent to `def main() -> Void` with
  `Test.run([Test.test("parses port", &test_parses_port), ...])`; the name is the
  function name without `test_`, with `_` turned into spaces.
  - The pass belongs in the linker stage (`compiler/modules/linker.agc`, after
    `Modules.load` and before `rewrite_all`), so the generated code goes through
    the same rewrite and checker as any code; a later pass would also have to
    change `Linked`. Only functions declared in that file count (a `test_` in a
    comment or string never does). The generated nodes take the spans of the test
    function they stand for, and their ids must fall inside the numbering that
    `Linked.ids` counts (the checker sizes its type table from it).
  - Proposed codes (the PR decides which stage emits each; this design fixes the
    codes and spans): `CHECK-TEST-SIGNATURE` for a `test_*` function with
    parameters or a result other than `Result[Void]`, at the function;
    `CHECK-TEST-MAIN` for a file with both a `main` and `test_*` functions, at
    `main` (an error, not "main wins", so a forgotten `main` never hides tests);
    `CHECK-TEST-NAME` for a function named just `test_`.
  - The runner, protocol, tasks per test, timeouts, `--only`, seeds and report do
    not change, and neither do the lowering, the bytecode or the VM.

- **How the driver knows it is a test file**: `agentica test` decides by name,
  in the driver only (§50.1). The front end gets that fact as a flag of the
  compile call (`test_file: true`, passed from `compile_test` in
  `compiler/bdd/bdd_driver.agc` down to `Linker.link_file`), not from the file
  name inside `compiler/`. Every other caller passes `false`, so `agentica
  FILE.agc` still reports CHECK-MAIN for a test file with no `main`. Whether
  they should set the flag too is for the PR to decide.

- **Not in 50a**: a `test` keyword form (`test name() ... end`). It is
  rejected for now by the one-way rule, since `def test_...` needs no new
  syntax. Parametrized tests (arguments with a table of values) are also left
  out: a loop inside a test covers them today. Either can come later, if the
  need shows.

- **Tests and docs**: a spec test through the CLI for each new code, and an
  `agentica test` integration test (only `test_*` functions; names in the
  report; `--only` selects them). The `main` and `Test.run` form stays
  documented as valid.

### 50.3 Done when

- A test file with no `main` runs under `agentica test`, and the report
  names each test from its function name; a file with both `main` and
  `test_*` functions is `CHECK-TEST-MAIN`; and the `main` and `Test.run`
  form still works and is documented.
