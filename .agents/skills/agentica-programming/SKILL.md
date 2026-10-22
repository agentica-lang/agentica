---
name: agentica-programming
description: >-
  Write, check, run and repair Agentica application code (`.agc` files): a
  Ruby-like language with static types and immutable values. Covers its
  builtins, JSON, files, processes, tasks, networking and BDD specs. Not for
  interpreter, VM or test-suite changes (use agentica-development).
---

# Agentica programming

Ruby-like syntax, static types, checked before it runs. Values never change in
place. If a form is in neither this file nor `references/`, it does not exist:
check a signature with `agentica help NAME`.

## Check and run

1. Save `program.agc` with one `def main() -> Void` (`check` alone does not need
   it). Use the path the user gives if `agentica` is not on PATH.
2. `agentica F ARGS` checks, then runs. `agentica check F` only checks; `check
   --stdin F` checks standard input as F. Run all cases in one command: `for f
   in cases/*.txt; do agentica program.agc < "$f" || break; done`.
3. Exit 0: success. Exit 1: the first diagnostic on stderr, with a stable code
   (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`, `PKG-`), a span and often a `help`
   line. Fix it and rerun. Exit 2: bad usage or an unreadable file.
4. Exit 0 and the requested output mean done. A check does not test runtime
   behavior.
5. `agentica help NAME` prints a signature; `agentica doc PATH` prints the
   exported API of a file or `std/` module. `--deny-run`, `--deny-net`,
   `--deny-fs`, `--deny-env` and `--deny-native` make the blocked calls fail
   with `denied: --deny-X`; `--sandbox` sets all of them, for untrusted code. A
   program can start a process past one flag, so use `--sandbox` or add
   `--deny-run`.

## Cheat sheet

```ruby
# Comments start with #. Blocks end with end.
struct Item
  name: String
  price: Int
end

enum Status
  Paid
  Owed(Int)
end

def describe(status: Status) -> String
  case status
    Status.Paid -> return "paid"
    Status.Owed(amount) -> return "owed #{amount}"
  end
end

def parse_price(text: String) -> Result[Int]
  price = try text.to_i
  if price < 0
    return error("negative: #{price}")
  end
  return ok(price)
end

def main() -> Void
  items: List[Item] = [Item(name: "pen", price: 3), Item(name: "book", price: 12)]
  total = 0
  for item in items
    total += item.price
  end
  names = items.map do |item| item.name.upcase end
  puts("#{names.join(",")} cost #{total}, half is #{total.to_f * 0.5}")
  case total
    15 -> puts("fifteen")
    _ -> puts("total is #{total}")
  end
  case parse_price("x7")
    ok(p) -> puts(describe(Status.Owed(p)))
    error(message) -> puts(message)
  end
end
```

Common calls (Ruby or Python names in brackets work in code too):

```text
IO.gets() -> Result[String]         next line; error at end (IO.gets!() halts)
IO.eof?() / IO.read()               end of stdin? / all of stdin
s.split(sep) / s.trim [strip]       split / trim
s.length [size] / xs.size [length]  length of text / of a list
s.to_int / s.to_int! [to_i]         Result[Int] / halts on bad text
m.get(k) / m.get(k, d) [dict.get]   Result[V] / V with a default
m.put(k, v) / xs.push(v)            new value: assign it
xs.sort_by do |x| key end           sort by key
xs.reduce(i) do |acc, x| ... end    fold left: f(acc, item)
r.ok? / r.unwrap! / r.unwrap_or(d)  Result checks; r.message is the error text
```

Types: `Int` (64-bit), `Float`, `Bool`, `String`, `Nil`, `Void`, `List[T]`,
`Map[K, V]` and `Set[T]` (K and T are `Int` or `String`), `Result[T]`, `Range`,
`Json`, `Fn[A, ..., R]`, `Task[R]`, `Await[T]`, `Channel[T]`, `Lazy[T]`,
`Process`, your own names. Types start uppercase; values, functions and fields
start lowercase or `_`. `_` discards (`_ = f()`, `for _ in`) and cannot be read.
Builtins: `references/builtins.md`.

## Rules agents break

- No `;`, braces, `let`, `when`, `elif`, `then`, `match`, `loop do` or
  `continue` (use `next`). Strings are double-quoted. `break` and `next` stand
  alone: `if x` then `break`, never `break if x`.
- File order: module doc, `import`s, constants, types, `export def`, then
  private `def` (`CHECK-DECL-ORDER`). A `##` block sits directly above its
  declaration (`PARSE-DETACHED-DOC`). Defaults are literal constants and come
  last (`CHECK-DEFAULT-ORDER`).
- Imports: `import Models from "models"` then `Models.User`, or `import {User,
  LIMIT, greet as hello} from "models"`. Never both on one line; never
  `Mod.LIMIT`. Packages: `references/modules.md`.
- Calls take parentheses. Only builtin methods and zero-argument module
  functions drop them: `s.length`, `xs.size`, `IO.gets!`.
- Values are immutable: `xs = xs.push(4)`, `m = m.put("k", 1)`, `user =
  user.with(age: 31)`. A bare `xs.push(4)` is `CHECK-UNUSED-VALUE`.
- A block cannot assign an outer variable (`CHECK-CAPTURED-ASSIGNMENT`); a `for
  x in xs ... end` loop can, so use it for running totals.
- No implicit Int/Float (`CHECK-TYPE-MISMATCH`): `2 * 1.5` fails; use `n.to_f`
  or `x.to_i!`. `7 / 2` is `3`.
- `==` works only on Int, Float, Bool, String, Nil (same type) and ranges.
  Compare enums and structs with `case` or a field. No chained comparisons.
- Empty `[]`, `{}`, `Set.new([])` need a type from an annotation, parameter,
  field or return type: `m: Map[String, Int] = {}`.
- `case` on Int, Float, String, Bool or Nil needs a final `_`. On an enum, list
  every variant or add `_`. Guarded, literal and nested arms never cover a
  variant: end with `ok(_)`, `Shape.Pair(_, _)` or `_`.
- `for` takes a List, Set or Range: `0...n` excludes n, `1..n` includes it. No
  `range(n)`.
- Result: `ok(v)` and `error(msg)` need an expected Result type (`r: Result[Int]
  = error("bad")`, else `CHECK-RESULT-TYPE`). `try` needs a Result operand (`try
  text.to_i`, not `try text.to_i!`) in a Result-returning function. `"x".to_i`
  is a Result, not `0`.
- `Task.await(task, timeout_ms)` returns `Await[R]` (`Await.Done(v)` or
  `Await.TimedOut`), not `R`; a timeout does not cancel the task.
- A `Lazy` (`xs.lazy`, `File.foreach`, `ch.lazy(ms)`) runs only in a terminal
  (`to_a`, `first(n)`, `each`, `reduce`), and each terminal returns a `Result`.
- `Void` has no value (`v = puts("x")` is `CHECK-VOID-VALUE`). Functions, tasks
  and handles cannot be printed or interpolated. Write `(-5).to_s`, since
  `-5.to_s` fails.
- Call `IO.flush()` after each stdio protocol message; logs go to `IO.warn()`.
  Use structs for fixed JSON records; `Json` is for dynamic data.

Not in Agentica, and what to write: `Map.new` (`{}` with a type), `IO.read_all`
(`IO.read()`), `s.chars` (`s.split("")`), `s.ord` (`String.code(s)`), `s.bytes`
(`s.to_bytes`), `s.len` (`s.length`), `s.empty?` (`s.length == 0`), `r.is_err?`
or `r.error?` (`!r.ok?`), `=~` and `matches?` (no regex builtin).

## When to read a reference

Read only what the task needs:

- `references/language.md`: a checker error or core rule not stated here;
  compile, `--ai`, `--json`
- `references/builtins.md`: other builtins, exact signatures
- `references/lazy.md`: `Lazy[T]`, endless sources, lines or channels in steps
- `references/examples.md`: a complete program to start from
- `references/performance.md`: slow code, `Profile`, `AGENTICA_VM_TRACE`
- `references/modules.md`: several files, `std/`, `pkg/`, packages
- `references/json.md`: JSON. `references/toml.md`: `std/toml`
- `references/files.md`: files, directories, paths, locks
- `references/processes.md`: `Process`, stdio, `System.env`
- `references/native.md`: C functions (`extern`, `compute def`, `Native.wait_*`)
- `references/tasks.md`: concurrency, timed awaits, `Task.cancel`, `Channel`
- `references/analysis.md`: compiler answers in a program (`std/analysis`)
- `references/binary.md`: `std/binary`, bit operations, `Crypto`.
  `references/logger.md`: `std/logger`
- `references/network.md`: TCP, TLS, HTTP client or server
- `references/bdd.md`: `.feature` specs and steps (`agentica test`)
- `references/testing.md`: unit tests (`Test.test`, `Test.eq`, `Test.run`)
- `references/diagnostics.md`: a diagnostic code with an unclear meaning or fix
- `references/queries.md`: `outline`, `type-at`, `refs`, `symbol`

Style: `agentica-code-guidelines`. Docs:
`https://sonic182.github.io/agentica/llms.txt` (index) and `llms-full.txt`
(all). `agentica help NAME` is the authority on signatures.
