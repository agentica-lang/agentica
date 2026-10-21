---
name: agentica-programming
description: >-
  Write, check, run, and repair Agentica programs (`.agc` files), a Ruby-like
  language with static types and immutable values, including its builtins, JSON,
  files, processes, tasks, networking, and BDD specs. Use for Agentica
  application code. Do not use for interpreter, VM, or test-suite changes; use
  agentica-development for those.
---

# Agentica programming

Ruby-like syntax, static types, checked before it runs. Values never change in
place. If a form is in neither this file nor `references/`, it does not exist:
check a signature with `agentica help NAME`.

## Check and run

1. Save `program.agc` with exactly one `def main() -> Void` (`check` alone
   does not need it).
2. `agentica check F` checks only (`check --stdin F` checks the text on standard
   input as if F held it). `agentica F ARGS` runs (`System.args()`
   returns ARGS). `agentica compile F -o F.agcb`, then `agentica run [FLAGS]
   -- F.agcb ARGS`. Use the path the user gives if `agentica` is not on PATH.
3. Exit 0: success. Exit 1: first diagnostic on stderr (stable code `LEX-`,
   `PARSE-`, `CHECK-`, `RUNTIME-` or `PKG-`, a span or, for `agentica.toml` and
   `agentica.lock`, a key path, often a `help` line). Exit 2: bad
   usage or unreadable file. Fix the first error and rerun.
4. Done means exit 0 and the output matches the request. A check does not test
   runtime behavior.
5. `agentica help NAME` (`--json` too) prints a signature; `agentica help` lists
   namespaces; unknown names exit 2. `agentica doc PATH` prints the exported API
   of a file or a `std/` module. `agentica outline FILE`, `agentica type-at
   FILE:LINE:COL`, `agentica refs NAME|FILE:LINE:COL [PATH...]` and `agentica
   symbol NAME [PATH...]` query code without reading it
   (`references/queries.md`).
   Flags: `--allow-run` (for `Process.spawn`), `--seed N`, `--max-steps N`,
   `--json`.

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

Ruby forms that work: `s.length`, `s.strip`, `s.split(" ")`, `s.upcase`,
`s.include?("x")`, `s.to_i` (a Result), `n.to_s`, `n.to_f`, `xs.size`,
`xs.push(v)`, `xs.sort`, `xs.join(",")`, `m.keys`, `m.put(k, v)`, `m.get(k)`
(a Result), `(1..3).to_a`, `n.times do |i| ... end`. Full list:
`references/builtins.md`.

Types: `Int` (64-bit), `Float`, `Bool`, `String`, `Nil`, `Void`, `List[T]`,
`Map[K, V]` and `Set[T]` (K and T are `Int` or `String`), `Result[T]`, `Range`,
`Json`, `Fn[A, ..., R]`, `Task[R]`, `Await[T]`, `Channel[T]`, `Lazy[T]`,
`Process`, your `struct`/`enum`/alias names. Types start uppercase; values,
functions and fields start lowercase or `_`. `_` discards (`_ = f()`,
`for _ in`); reading it is an error. Details: `references/language.md`.

## Rules agents break

- Syntax: no `;`, braces, `let`, `when`, `elif`, `then`, `match`, `loop do`,
  `continue` (use `next`). Strings are double-quoted. Comments are `#`. `break`
  and `next` stand alone: `if x` then `break`, never `break if x`.
- File order: module doc, `import`s, constants (`LIMIT = 100`), `struct`/`enum`/
  aliases, `export def`, private `def` (`CHECK-DECL-ORDER`). A `##` block goes
  directly above a declaration (`PARSE-DETACHED-DOC`). Defaulted parameters are
  constants and go last.
- Imports: `import Models from "models"` then `Models.User`, or `import {User,
  LIMIT, greet as hello} from "models"`; never both on one line, never
  `Mod.LIMIT` for a constant. Packages: `references/modules.md`.
- Calls take parentheses. Only builtin methods and zero-argument module
  functions drop them: `s.length`, `xs.size`, `IO.gets!`.
- Values are immutable: `xs = xs.push(4)`, `m = m.put("k", 1)`. A bare
  `xs.push(4)` is `CHECK-UNUSED-VALUE`. No field or index assignment:
  `user = user.with(age: 31)`.
- A block cannot assign an outer variable (`CHECK-CAPTURED-ASSIGNMENT`). A
  `for x in xs ... end` loop can, so use it for running totals.
- No implicit Int/Float (`CHECK-TYPE-MISMATCH`): `2 * 1.5` fails. Convert with
  `n.to_f` or `x.to_i!`. `7 / 2` is `3`.
- `==` works only on Int, Float, Bool, String, Nil (same type) and ranges.
  Compare enums and structs with `case` or a field. No chained comparisons.
- Empty `[]`, `{}`, `Set.new([])` need a type from an annotation, parameter,
  field or return type: `m: Map[String, Int] = {}`.
- `case` on Int, Float, String, Bool or Nil needs a final `_`. On an enum, list
  every variant or add `_`. A guarded, literal or nested arm never covers a
  variant: end with `ok(_)`, `Shape.Pair(_, _)` or `_`.
- `for` takes a List, Set or Range. `0...n` excludes n; `1..n` includes it. No
  `range(n)`.
- Result: `ok(v)` and `error(msg)` need an expected Result type (`r: Result[Int]
  = error("bad")`, else `CHECK-RESULT-TYPE`). `try` needs a Result operand
  (`try text.to_i`, not `try text.to_i!`) in a Result-returning function.
  `"x".to_i` is a Result, not `0`.
- `Task.await(task, timeout_ms)` returns `Await[R]` (`Await.Done(v)` or
  `Await.TimedOut`), not `R`; a timeout does not cancel the task.
- A `Lazy` recipe (`xs.lazy`, `File.foreach`, `ch.lazy(ms)`) runs only in a
  terminal (`to_a`, `first(n)`, `each`, `reduce`), which gives a `Result`
  (`references/lazy.md`).
- `Void` has no value (`v = puts("x")` is `CHECK-VOID-VALUE`). Functions, tasks
  and handles cannot be printed or interpolated. Write `(-5).to_s`, since
  `-5.to_s` fails.
- Call `IO.flush()` after each stdio protocol message; logs go to `IO.warn()`.
  Fixed JSON records use structs; `Json` is for dynamic data.

Not in Agentica, and what to write instead: `Map.new` (`{}` with a type),
`IO.read_all` (`IO.read()`), `s.chars` (`s.split("")`), `s.ord`
(`String.code(s)`), `s.bytes` (`s.to_bytes`), `s.len` (`s.length`), `s.empty?`
(`s.length == 0`), `r.is_err?` or `r.error?` (`!r.ok?`), `=~` and `matches?`
(no regex builtin).

## When to read a reference

Read only what the task needs:

- `references/language.md`: a checker error about an operator, type, Void,
  pattern, block, method or Result, or a core rule not stated here.
- `references/builtins.md`: a builtin not in the cheat sheet, or an exact
  signature (String, List, Map, Set, Range, Int, Float, IO, System, Time,
  Random, `Crypto.sha256`).
- `references/lazy.md`: `Lazy[T]`, an endless source, file lines or channel
  values through steps, `write_lines`, `try` in a step, the first results of a
  long chain.
- `references/examples.md`: a complete program to start from.
- `references/performance.md`: slow programs, 100,000+ items or about 1 MB, hot
  paths, `AGENTICA_VM_TRACE=profile`, `Profile.measure`, `Profile.steps`, flame
  graphs.
- `references/modules.md`: several files, shared constants, `std/`, `pkg/` or
  packages (`agentica.toml`, `agentica.lock`).
- `references/json.md`: JSON. `references/toml.md`: TOML (`std/toml`).
- `references/files.md`: files, directories, paths, locks, private files,
  removing or renaming paths or trees.
- `references/processes.md`: starting programs (`Process`).
- `references/tasks.md`: concurrency, `Task.map`, timed awaits, `Task.cancel`,
  `Channel`.
- `references/analysis.md`: asking the compiler for diagnostics, an outline, a
  type, a symbol or references from a program, with unsaved buffers
  (`std/analysis`).
- `references/binary.md`: packing or unpacking bytes (`std/binary`).
- `references/logger.md`: levels, fields, handlers (`std/logger`).
- `references/network.md`: TCP, TLS, HTTP client or server.
- `references/bdd.md`: `.feature` specs and BDD steps (`agentica test`).
- `references/testing.md`: unit tests (`Test.test`, `Test.eq`, `Test.run`).
- `references/diagnostics.md`: a diagnostic code whose meaning or fix is
  unclear.
- `references/queries.md`: `agentica outline`, `type-at`, `refs` and `symbol`:
  a file's declarations, the type and definition at a position, every
  reference to a name, or where a name is defined, without reading the files.

For style and idiom, use `agentica-code-guidelines`. Online docs:
`https://sonic182.github.io/agentica/llms.txt` indexes them;
`https://sonic182.github.io/agentica/llms-full.txt` has them all.
`agentica help NAME` is the authority on signatures for the installed binary.
