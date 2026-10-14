---
title: Test
weight: 1
description: Unit tests in the style of ExUnit, with assertions that return a Result.
---

`Test` is a builtin module for unit tests; it needs no import. A test file is a program whose `main` calls `Test.run` with a list of tests. Each test is a block that returns `Result[Void]`, and each assertion returns `Result[Void]` too, so `try` stops a test at its first failed assertion. Agentica has no exceptions.

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

`Test` and `TestCase` are reserved names.

## Test.test

```text
Test.test(name: String, body: Fn[Result[Void]]) -> TestCase
```

Builds a test from a name and a block. A `TestCase` has no fields; it keeps the name, the block and the place of the `Test.test` call, which is where the test is reported. Names must not be empty and must be different within a file, or `Test.run` fails with `RUNTIME-TEST-NAME` at that `Test.test` call.

## Test.run

```text
Test.run(tests: List[TestCase]) -> Void
```

Serves the test runner and never returns. Call it once: a second call, in a test or in a task you spawned, fails with `RUNTIME-TEST-RUN`. Under `agentica test` the runner talks to the file on a channel of its own (see [Process](/library/io-and-system/process/)), so the test's standard input and standard output are its own: `IO.gets` returns the end-of-input error, and anything a test prints, even a line that looks like a record, is only output, shown under a failed test. A file that calls `Test.run` with the `agentica test` arguments but without that channel fails with `RUNTIME-TEST-RUN`. Each test runs in its own task, so a test that crashes fails alone and the next test still runs. Running the file as a normal program prints `run this file with agentica test` on stderr and exits 2. Name the file `*_test.agc` and run it with `agentica test`

A test fails, in this order, with:

- the crash of its task (`RUNTIME-DIVISION-BY-ZERO`, `RUNTIME-UNWRAP-ERROR`, ...), at the place of the crash;
- its first failed assertion (`RUNTIME-TEST-ASSERTION`), at that assertion, with its expected and actual values;
- the `error(message)` its block returned (`RUNTIME-TEST-ERROR`), at the test;
- tasks it started and left running (`RUNTIME-TEST-PENDING-TASKS`); they are stopped before the next test;
- a task it started that crashed and was not awaited (`RUNTIME-TASK-CRASHED`, with the crash text).

A crash outside every test, such as one in a task that `main` started, that nothing awaited fails the whole file.

Each test gets its own random generator, seeded from the run's seed and the test's name, so a test sees the same `Random` values whether it runs alone or with the others.

## Test.eq

```text
Test.eq(actual: T, expected: T) -> Result[Void]
```

Compares two values of the same type. The type comes from the first argument, the actual value, so put it first: `Test.eq(r, error("x"))` works, while `Test.eq(error("x"), r)` is `CHECK-RESULT-TYPE`, since `error("x")` alone does not say what its `ok` type is. The type must have equality: numbers, `Bool`, `String`, `nil`, ranges, `Json`, and lists, maps, Results, structs and enums made of them. Functions, tasks, handles and two different types are `CHECK-TYPE-MISMATCH`. Maps are equal in any key order, and a `Json` compares as its JSON text with sorted keys. When the values differ, the test reports `values are not equal` and the error shows both in the `inspect` form, with any `Json` as its JSON text.

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

A failed assertion also counts against the test it runs in, even when its result is not used, so `Test.eq(a, b)` as a statement still fails the test. Outside a test, an assertion only returns its result.

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
