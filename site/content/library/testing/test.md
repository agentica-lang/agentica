---
title: Test
weight: 1
description: Unit tests in the style of ExUnit, with assertions that return a Result.
---

`Test` is a builtin module for unit tests; it needs no import. A test file is a program whose `main` calls `Test.run` with a list of tests. Each test returns `Result[Void]`, and so does each assertion, so `try` stops a test at its first failed assertion. Agentica has no exceptions.

```agentica {mode="check"}
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
    Test.test("ports are below 65536") do
      Test.assert(parse_port("65536").ok? == false, "65536 must be rejected")
    end
  ])
end
```

`Test` and `TestCase` are reserved names. `IO.inspect` of a `TestCase` shows `<TestCase>`.

## Test.test

```text
Test.test(name: String, body: Fn[Result[Void]]) -> TestCase
```

Builds a test from a name and a block. A `TestCase` keeps the name, the block and the place of the call, which is where the test is reported. Names must not be empty and must be unique within a file; otherwise `Test.run` fails with `RUNTIME-TEST-NAME` at that call.

## Test.run

```text
Test.run(tests: List[TestCase]) -> Void
```

Serves the test runner and never returns. Call it from `main` itself: in any other task it fails with `RUNTIME-TEST-RUN`.

Under `agentica test`, the runner talks to the file on a channel of its own (see [Process](/library/io-and-system/process/)). A test's standard input and output are its own: `IO.gets` returns the end-of-input error, and anything the test prints, even a line that looks like a record, is only output, shown under a failed test. A test must not call `Process.parent_read_line` or `Process.parent_send`; they belong to the runner, and nothing stops a test from breaking the protocol. A file that calls `Test.run` with the `agentica test` arguments but without that channel fails with `RUNTIME-TEST-RUN`.

- Name the file `*_test.agc`. `agentica test` finds such files in `test/` by default and prints one line per test: `PASS file / name`, or `FAIL file / name` with the diagnostic and the output of the test below it.
- Each test runs in its own task, so a crash fails only that test. Each test has 30 seconds (`RUNTIME-TEST-TIMEOUT`). A test that exits, hits its step limit or times out ends the file's run, and the tests after it are `NOT RUN`.
- A file that exits, crashes or never calls `Test.run` is a file error that shows what it printed.
- A test that times out keeps the output it printed, up to 1 MiB. A test that prints more than 1 MiB fails at once with `RUNTIME-BDD-OUTPUT-LIMIT`, even if it never ends, and shows no output.
- Run as a normal program, the file prints `run this file with agentica test` on stderr and exits 2.

A test fails with the first of these that applies:

- the crash of its task (`RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-UNWRAP-ERROR`, ...), at the crash; the report shows the call stack, as a normal halt does;
- its first failed assertion (`RUNTIME-TEST-ASSERTION`), with the expected and actual values;
- the `error(message)` its block returned (`RUNTIME-TEST-ERROR`), at the test;
- tasks it started and left running (`RUNTIME-TEST-PENDING-TASKS`), which are stopped before the next test;
- a crash of a task it started that no await observed (`RUNTIME-TASK-CRASHED`).

A crash outside every test, such as one in a task that `main` started and nothing awaited, fails the whole file. After the record, every crash of the test's tasks counts as observed, and its running tasks are cancelled before the next test. The run-ending errors (a runtime error in `main`, `RUNTIME-STEP-LIMIT`, an internal VM error, `System.exit`) still end the whole run, from a test too.

Each test gets its own random generator, seeded from the run's seed and the test's name, so a test sees the same `Random` values alone or with the others.

## Test.eq

```text
Test.eq(actual: T, expected: T) -> Result[Void]
```

Compares two values of the same type. The type comes from the first argument, so put the actual value first: `Test.eq(r, error("x"))` works, but `Test.eq(error("x"), r)` is `CHECK-RESULT-TYPE`, since `error("x")` does not say what its `ok` type is. The type must have equality: `Int`, `Float`, `Bool`, `String`, `Nil`, `Range`, `Json`, and lists, maps, sets, Results (`Result[Void]` too), structs and enums made of them. Functions, tasks, handles and two different types are `CHECK-TYPE-MISMATCH`. Lists compare in order; maps by key and sets by element, in any order; structs and enums by type, variant and fields, and Floats by IEEE 754. A `Json` compares by its canonical text at any depth.

When the values differ, the test reports `values are not equal`, and the error text is `expected E; actual A`, with both values in the `inspect` form (a `Json` as its JSON text). `Test.ok?` gives `expected ok; actual A`, `Test.error?` gives `expected an error; actual A`, and `Test.assert` gives its message. The first recorded failure of a test is the one reported, and `RUNTIME-TEST-ASSERTION` carries `expected` and `actual` for `Test.eq`, only `actual` for `Test.ok?` and `Test.error?`, and neither for `Test.assert`.

```agentica
struct Point
  x: Int
  y: Int
end

def main() -> Void
  puts(Test.eq(Point(x: 1, y: 2), Point(x: 1, y: 2)))
  puts(Test.eq({"a": 1, "b": 2}, {"b": 2, "a": 1}))
  puts(Test.eq([1, 2], [1, 3]))
end
```

```output
ok()
ok()
error("expected [1, 3]; actual [1, 2]")
```

A failed assertion counts against the test it runs in (its own task, or a task spawned inside it), even when its result is not used, so `Test.eq(a, b)` as a statement still fails the test. Outside a test, an assertion only returns its result.

## Test.ok?

```text
Test.ok?(result: Result[T]) -> Result[Void]
```

Checks that a `Result` is `ok`.

```agentica
def main() -> Void
  puts(Test.ok?("12".to_i))
  puts(Test.ok?("x".to_i).message)
end
```

```output
ok()
expected ok; actual error("cannot convert \"x\" to Int")
```

## Test.error?

```text
Test.error?(result: Result[T]) -> Result[Void]
```

Checks that a `Result` is an error.

```agentica
def main() -> Void
  puts(Test.error?("x".to_i))
  puts(Test.error?("0".to_i).message)
end
```

```output
ok()
expected an error; actual ok(0)
```

## Test.assert

```text
Test.assert(condition: Bool, message: String) -> Result[Void]
```

Checks a condition; a failure carries the message.

```agentica
def main() -> Void
  puts(Test.assert(1 < 2, "one is below two"))
  puts(Test.assert(2 < 1, "two is below one").message)
end
```

```output
ok()
two is below one
```
