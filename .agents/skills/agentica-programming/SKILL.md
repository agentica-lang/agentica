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

1. Save `program.agc` with one `def main() -> Void` (`check` alone does not
   need it).
2. `agentica check F` only checks; `check --stdin F` checks standard input as
   F. `agentica F ARGS` runs (`System.args()` returns ARGS). `agentica compile
   F -o F.agcb`, then `agentica run [FLAGS] -- F.agcb ARGS`. Use the path the
   user gives if `agentica` is not on PATH.
3. Exit 0: success. Exit 1: the first diagnostic on stderr, with a stable code
   (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-` or `PKG-`), a span (a key path for
   `agentica.toml` and `agentica.lock`) and often a `help` line. Exit 2: bad
   usage or an unreadable file. Fix the first error and rerun. `--ai` prints it
   as compact text; `--json` as one object.
4. Exit 0 and the output the request asks for mean done. A check does not test
   runtime behavior.
5. `agentica help NAME` prints a signature (unknown name: exit 2); `agentica
   doc PATH` prints the exported API of a file or `std/` module. Questions about
   code, without reading it: `agentica outline`, `type-at`, `refs` and `symbol`
   (`references/queries.md`). Run flags: `--deny-run`, `--deny-net`,
   `--deny-fs`, `--deny-env` (`Process` starts, network, `File`/`Dir`/`Path`
   but `Path.join`, `System.env` return an error starting `denied: --deny-X`;
   each implies `--deny-native`), `--deny-native` (refuse `extern`),
   `--sandbox` (all of them, for untrusted code; a program that can start
   processes escapes a single flag, so use `--sandbox` or add `--deny-run`),
   `--seed N`, `--max-steps N`.

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

Types: `Int` (64-bit), `Float`, `Bool`, `String`, `Nil`, `Void`, `List[T]`,
`Map[K, V]` and `Set[T]` (K and T are `Int` or `String`), `Result[T]`, `Range`,
`Json`, `Fn[A, ..., R]`, `Task[R]`, `Await[T]`, `Channel[T]`, `Lazy[T]`,
`Process`, your own names. Types start uppercase; values, functions and fields
start lowercase or `_`. `_` discards (`_ = f()`, `for _ in`) and cannot be read.
Builtins: `references/builtins.md`.

## Rules agents break

- Syntax: no `;`, braces, `let`, `when`, `elif`, `then`, `match`, `loop do`
  or `continue` (use `next`). Strings are double-quoted. `break` and `next`
  stand alone: `if x` then `break`, never `break if x`.
- File order: module doc, `import`s, constants, `struct`/`enum`/aliases,
  `export def`, then private `def` (`CHECK-DECL-ORDER`). A `##` block sits
  directly above its declaration (`PARSE-DETACHED-DOC`). A default is a literal
  constant; parameters with a default come last (`CHECK-DEFAULT-ORDER`).
- Imports: `import Models from "models"` then `Models.User`, or `import {User,
  LIMIT, greet as hello} from "models"`; never both on one line, never
  `Mod.LIMIT` for a constant. Packages: `references/modules.md`.
- Calls take parentheses. Only builtin methods and zero-argument module
  functions drop them: `s.length`, `xs.size`, `IO.gets!`.
- Values are immutable: `xs = xs.push(4)`, `m = m.put("k", 1)`. A bare
  `xs.push(4)` is `CHECK-UNUSED-VALUE`. No field or index assignment:
  `user = user.with(age: 31)`.
- A block cannot assign an outer variable (`CHECK-CAPTURED-ASSIGNMENT`), but a
  `for x in xs ... end` loop can, so use it for running totals.
- No implicit Int/Float (`CHECK-TYPE-MISMATCH`): `2 * 1.5` fails; convert with
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
  terminal (`to_a`, `first(n)`, `each`, `reduce`), and each returns a `Result`.
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

- `references/language.md`: a checker error or a core rule not stated here.
- `references/builtins.md`: a builtin not in the cheat sheet, or an exact
  signature.
- `references/lazy.md`: `Lazy[T]`, endless sources, file lines or channels
  through steps, `try` in a step.
- `references/examples.md`: a complete program to start from.
- `references/performance.md`: slow programs, 100,000+ items,
  `AGENTICA_VM_TRACE=profile`, `Profile.measure`.
- `references/modules.md`: several files, `std/`, `pkg/` or packages.
- `references/json.md`: JSON. `references/toml.md`: TOML (`std/toml`).
- `references/files.md`: files, directories, paths, locks, removing trees.
- `references/processes.md`: starting programs (`Process`).
- `references/native.md`: calling C functions (`extern` blocks, `compute def`).
- `references/tasks.md`: concurrency, timed awaits, `Task.cancel`, `Channel`.
- `references/analysis.md`: compiler answers inside a program (`std/analysis`).
- `references/binary.md`: `std/binary`. `references/logger.md`: `std/logger`.
- `references/network.md`: TCP, TLS, HTTP client or server.
- `references/bdd.md`: `.feature` specs and steps (`agentica test`).
- `references/testing.md`: unit tests (`Test.test`, `Test.eq`, `Test.run`).
- `references/diagnostics.md`: a diagnostic code whose meaning or fix is
  unclear.
- `references/queries.md`: `outline`, `type-at`, `refs`, `symbol` (and
  `--partial` while the code does not check).

Style and idiom: `agentica-code-guidelines`. Online docs:
`https://sonic182.github.io/agentica/llms.txt` (index) and `llms-full.txt`
(all). `agentica help NAME` is the authority on signatures.
