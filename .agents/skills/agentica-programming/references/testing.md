# Unit tests (`Test`)

`Test` is a builtin module (no import). `Test` and `TestCase` are reserved.

```text
Test.test(name: String, body: Fn[Result[Void]]) -> TestCase
Test.run(tests: List[TestCase]) -> Void
Test.eq(actual: T, expected: T) -> Result[Void]
Test.ok?(result: Result[T]) -> Result[Void]
Test.error?(result: Result[T]) -> Result[Void]
Test.assert(condition: Bool, message: String) -> Result[Void]
```

A test file is a program whose `main` calls `Test.run` with a list of
`Test.test(name) do ... end` blocks, each returning `Result[Void]`. Assertions
return `Result[Void]` too: chain them with `try` and let the last one be the
block's result (there are no exceptions, so `try` is the only way to stop a test
early).

```ruby
def parse_port(text: String) -> Result[Int]
  n = try text.strip.to_i
  return error("port out of range: #{n}") if n < 1 or n > 65535

  ok(n)
end

def main() -> Void
  Test.run([
    Test.test("parses a port") do
      try Test.eq(parse_port("8080"), ok(8080))
      Test.eq(parse_port(" 80 "), ok(80))
    end,
    Test.test("rejects zero") do
      Test.error?(parse_port("0"))
    end,
    Test.test("default is privileged") do
      Test.assert(parse_port("80").unwrap! < 1024, "default port must be privileged")
    end
  ])
end
```

A `*_test.agc` file may instead have no `main`: its top-level `test_*`
functions are its tests, in source order, each named after the function
without `test_`, `_` as spaces (`test_parses_port` is `parses port`). Each
takes no parameters and returns `Result[Void]`, written so (not a type alias);
a function body needs its `return`.

```ruby
def test_parses_port() -> Result[Void]
  try Test.eq(parse_port("8080"), ok(8080))
  Test.eq(parse_port(" 80 "), ok(80))
end
```

`CHECK-TEST-MAIN`: a test file with both `main` and `test_*` functions (a
helper named `test_*` too: rename it). Without `main`: `CHECK-TEST-SIGNATURE`
for a test function with parameters, type parameters or another result;
`CHECK-TEST-NAME` for one named just `test_`. `agentica check` checks these for
`*_test.agc` files; running a test file with no `main` is `CHECK-MAIN`.

- `Test.eq(actual, expected)`: actual first (the expected type comes from the
  left argument, so `Test.eq(error("x"), r)` is `CHECK-RESULT-TYPE`; write
  `Test.eq(r, error("x"))`). Both have one data type: numbers, `Bool`, `String`,
  `nil`, ranges, `Json`, and lists, maps, sets, Results, structs and enums of
  those; `Fn`, `Task`, handles, `TestCase` and two different types are
  `CHECK-TYPE-MISMATCH`. Maps compare in any key order and sets in any element
  order; Floats by IEEE 754 (NaN is not equal to itself); a `Json` as its
  canonical text (sorted keys).
- `Test.ok?(r)` and `Test.error?(r)` check a Result's tag;
  `Test.assert(cond, message)` fails with `message`.
- A failed assertion counts against its test even when its Result is
  discarded (`_ = Test.eq(a, b)`), including one made in a task the test
  spawned. A bare assertion followed by another statement is
  `CHECK-UNUSED-RESULT`: `try` it, or leave it as the last statement of a test
  block. Outside a test an assertion only returns its Result.
- Names must be non-empty and different in a file (`RUNTIME-TEST-NAME` at the
  `Test.test` call). Call `Test.run` from `main` itself: in a test or a spawned
  task it is `RUNTIME-TEST-RUN`. `Test.run` never returns; run directly it
  prints `run this file with agentica test` and exits 2.
- Under `agentica test` the runner talks to the file on a channel of its own
  (descriptor 3), so the file's stdin and stdout are its own. The runner closes
  stdin at once (`IO.gets` is an end-of-input error). Print anything with
  `puts`/`print`/`IO.inspect`: it is shown only under a failed test.
- A task crash outside every test (say, in a task `main` started) that nothing
  awaited fails the whole file (exit 1 with the crash summary).
- Each test runs in its own task and fails with, in this order: a crash (its own
  code and span), its first failed assertion (`RUNTIME-TEST-ASSERTION` at the
  assertion), an `error(m)` returned by the block (`RUNTIME-TEST-ERROR`), tasks
  it left running (`RUNTIME-TEST-PENDING-TASKS`; they are stopped), or a task it
  spawned that crashed unawaited (`RUNTIME-TASK-CRASHED`). Await every task you
  spawn in a test. The next test still runs after a crash.
- Each test's `Random` generator is seeded from the run's seed and the test's
  name, so values do not depend on the other tests.

## Running tests

- Name the file `*_test.agc` and run `agentica test` (searches `test/` and
  `specs/`), `agentica test test/ports_test.agc`, or `agentica test --only TEXT`
  (tests and scenarios whose name contains `TEXT`). Test files and `.feature`
  files share one report and the BDD exit codes (0 all passed, 1 a failure or
  nothing found, 2 usage or infrastructure).
- Lines: `PASS file / name`, `FAIL file / name` then `file:line:col [CODE]
  message`, for a crash the call stack, and the test's own stdout indented by
  two spaces; `NOT RUN file / name` for a test not run. A file that fails
  before or after its tests (exit, crash in `main`, no `Test.run`:
  `RUNTIME-TEST-RUN`) is a file error with what it printed and its stderr.
- Each test file runs in its own child VM, each test in its own task, 30 seconds
  per test (`RUNTIME-TEST-TIMEOUT`). `System.exit`, a step limit or a timeout in
  a test ends the file's run: the rest is not executed. A front-end error in a
  test file is a file error; the other files still run.
- A passed test's output is dropped; a failed one shows the last 64 Ki
  characters. Stdout is limited to 1 MiB per test and stderr to 1 MiB for the
  whole file: past a limit the running test (or the file) fails with
  `RUNTIME-BDD-OUTPUT-LIMIT`. The run always has a seed; `--seed N` replays it
  (the report shows the seed when the run fails).
