# Unit tests (`Test`)

`Test` is a builtin module; it needs no import. `Test` and `TestCase` are reserved names.

```text
Test.test(name: String, body: Fn[Result[Void]]) -> TestCase
Test.run(tests: List[TestCase]) -> Void
Test.eq(actual: T, expected: T) -> Result[Void]
Test.ok?(result: Result[T]) -> Result[Void]
Test.error?(result: Result[T]) -> Result[Void]
Test.assert(condition: Bool, message: String) -> Result[Void]
```

A test file is a program whose `main` calls `Test.run` with a list of `Test.test(name) do ... end` blocks. Each block returns `Result[Void]`. Assertions return `Result[Void]` too: chain them with `try`, and let the last one be the block's result. Agentica has no exceptions, so `try` is the only way to stop a test early.

```agentica
def parse_port(text: String) -> Result[Int]
  n = try text.strip.to_i
  if n < 1 or n > 65535
    return error("port out of range: #{n}")
  end
  return ok(n)
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

- `Test.eq(actual, expected)`: actual first, as ExUnit's `assert actual == expected`. Both have one type, and it must be data: numbers, `Bool`, `String`, `nil`, ranges, `Json`, and lists, maps, Results, structs and enums of those. `Fn`, `Task`, handles, `TestCase` and two different types are `CHECK-TYPE-MISMATCH`. Maps compare in any key order; Floats by IEEE 754 (NaN is not equal to itself); a `Json` compares as its canonical text (sorted keys). The error is `expected E; actual A` in the `inspect` form, with `Json` as its JSON text.
- Put the actual value first: the expected type comes from the left argument, so `Test.eq(error("x"), r)` is `CHECK-RESULT-TYPE`; write `Test.eq(r, error("x"))`.
- A failed `Test.eq` reports the message `values are not equal` with `expected` and `actual`.
- `Test.ok?(r)` and `Test.error?(r)` check a Result's tag: `expected ok; actual error("...")`, `expected an error; actual ok(0)`.
- `Test.assert(cond, message)` fails with `message`.
- A failed assertion also counts against its test even when its Result is dropped (`Test.eq(a, b)` as a statement), including one made in a task the test spawned. Outside a test, an assertion only returns its Result.
- Names must be non-empty and different in a file (`RUNTIME-TEST-NAME` at the `Test.test` call). Call `Test.run` from `main` itself: a call in a test, or in a task you spawned, is `RUNTIME-TEST-RUN`.
- Under `agentica test`, the runner talks to the test file on a channel of its own (descriptor 3, `Process.parent_read_line` and `Process.parent_send` in `references/processes.md`), so the file's stdin and stdout are its own. The runner closes stdin at once (`IO.gets` is an end-of-input error). Print anything you like with `puts`/`print`/`IO.inspect`, even a line that looks like a record: it is output, shown only under a failed test. `Test.run` without that channel, under the arguments `agentica test` passes, is `RUNTIME-TEST-RUN`. The two `Process.parent_*` calls are for runner code: a test that calls them can break the protocol, and nothing stops it.
- A task crash outside every test (say, in a task `main` started) that nothing awaited fails the whole file (exit 1 with the crash summary).
- Each test runs in its own task. A test fails with, in this order: a crash (its own code and span), its first failed assertion (`RUNTIME-TEST-ASSERTION` at the assertion), an `error(m)` returned by the block (`RUNTIME-TEST-ERROR`), tasks it left running (`RUNTIME-TEST-PENDING-TASKS`; they are stopped), or a task it spawned that crashed unawaited (`RUNTIME-TASK-CRASHED`). Await every task you spawn in a test. The next test still runs after a crash.
- Each test's `Random` generator is seeded from the run's seed and the test's name, so values do not depend on the other tests.
- `Test.run` never returns. Run directly, it prints `run this file with agentica test` and exits 2.

## Running tests

- Name the file `*_test.agc` and run `agentica test` (searches `test/` and `specs/`), `agentica test test/ports_test.agc`, or `agentica test --only TEXT` (tests and scenarios whose name contains `TEXT`). Test files and `.feature` files share one report and the BDD exit codes (0 all passed, 1 a failure or nothing found, 2 usage or infrastructure).
- Lines: `PASS file / name`, `FAIL file / name` then `file:line:col [CODE] message; expected E; actual A`, for a crash the call stack (`  stack, innermost first:` and one `name at file:line:col` line each; `stack` in `--json`), and the test's own stdout indented by two spaces, `NOT RUN file / name` for a test not run. `--json` adds `kind: "tests"`, `output` and `status: "not_executed"`; `--ai` puts the output after ` | output`. A file that fails before or after its tests (exit, crash in `main`, no `Test.run`: `RUNTIME-TEST-RUN`) is a file error with what it printed and its stderr.
- Each test file runs in its own child VM, each test in its own task, 30 seconds per test (`RUNTIME-TEST-TIMEOUT`). `System.exit`, a step limit or a timeout in a test ends the file's run: the rest is not executed. A front-end error in a test file is a file error; the other files still run.
- A passed test's output is dropped. Output is the last 64 Ki characters; stdout is limited to 1 MiB per test (unread stdout too), stderr to 1 MiB for the whole file (past it the file fails, not the test, when the file exits within 2 seconds of the cut; a file still running then is reported as the running test failing with `RUNTIME-BDD-OUTPUT-LIMIT`). A file that prints more than 1 MiB before `Test.run` has listed its tests is a file error with that code. A test that times out keeps what it printed (at most the 1 MiB limit). A test that prints more than 1 MiB without ending fails at once with `RUNTIME-BDD-OUTPUT-LIMIT`, and shows no output if it was still running. The run always has a seed; `--seed N` replays it (the report shows the seed when the run fails).
