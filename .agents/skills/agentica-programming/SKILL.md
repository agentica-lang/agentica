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

1. Save `program.agc` with exactly one `def main() -> Void`.
2. `agentica check F` checks only. `agentica F ARGS` runs (`System.args()`
   returns ARGS). `agentica compile F -o F.agcb`, then `agentica run [FLAGS]
   -- F.agcb ARGS`. Use the path the user gives if `agentica` is not on PATH.
3. Exit 0: success. Exit 1: first diagnostic on stderr (stable code `LEX-`,
   `PARSE-`, `CHECK-`, `RUNTIME-` or `PKG-`, a span or, for `agentica.toml` and
   `agentica.lock`, a key path, often a `help` line). Exit 2: bad
   usage or unreadable file. Fix the first error and rerun.
4. Done means exit 0 and the output matches the request. A check does not test
   runtime behavior.
5. `agentica help NAME` (`--json` too) prints a signature; `agentica help`
   lists namespaces; `agentica help --json` prints all builtins as an array;
   unknown names exit 2. Flags: `--allow-run` (for `Process.spawn`),
   `--seed N`, `--max-steps N`, `--json`.

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
  elsif price == 0
    return ok(0)
  else
    return ok(price)
  end
end

def main() -> Void
  items: List[Item] = [Item(name: "pen", price: 3), Item(name: "book", price: 12)]
  total = 0
  for item in items
    total += item.price
  end
  names = items.map do |item| item.name.upcase end
  puts("#{names.join(",")} cost #{total}, half is #{total.to_f * 0.5}")
  n = 0
  while n < 2
    n += 1
  end
  for i in 0...2
    puts("i = #{i}")
  end
  case n
    1 -> puts("one")
    _ -> puts("n is #{n}")
  end
  case parse_price("x7")
    ok(p) -> puts(describe(Status.Owed(p)))
    error(message) -> puts(message)
  end
  puts(describe(Status.Paid))
end
```

Working Ruby forms: `s.length`, `s.strip`, `s.split(" ")`, `s.upcase`,
`s.include?("x")`, `s.to_i` (a Result), `s.to_i!`, `n.to_s`, `n.to_f`,
`xs.size`, `xs.push(v)`, `xs.sort`, `xs.join(",")`, `m.keys`, `m.put(k, v)`,
`m.get(k)` (a Result), `(1..3).to_a`, `n.times do |i| ... end`. Full list:
`references/builtins.md`.

Types: `Int` (64-bit), `Float`, `Bool`, `String`, `Nil`, `Void`, `List[T]`,
`Map[K, V]` (K is `Int` or `String`), `Set[T]` (T is `Int` or `String`;
`Set.new([1, 2])`, `add`, `include?`), `Result[T]`, `Range`, `Json`,
`Fn[A, ..., R]`, `Task[R]`,
`Await[T]`, `Channel[T]`, `Lazy[T]`, `Process`, your `struct`/`enum`/alias
names.
`type Names = List[String]` names a long type; `type Matrix[T] = List[List[T]]`
takes parameters (`Matrix[Int]` is `List[List[Int]]`). Types start uppercase;
values, functions and fields start lowercase or `_`. `_` discards (`_ = f()`,
`for _ in`); reading it is an error. Details: `references/language.md`.

## Rules agents break

- Syntax: no `;`, braces, `let`, `when`, `elif`, `then`, `match`, `loop do`,
  `continue` (use `next`). Strings are double-quoted (`'x'` fails). Comments are
  `#` (`//` fails). `break` and `next` stand alone: `if x` then `break`, never
  `break if x`.
- A `##` block directly above a `def`, `struct`, `enum`, field or variant is its
  Markdown doc. The first `##` block of a file, followed by a blank line, is the
  module doc. Any other `##` block is `PARSE-DETACHED-DOC`.
- Constants: top-level `LIMIT = 100` (capitals; `export` shares it). Literals,
  collections and effect-free builtins only (`CHECK-CONSTANT-EXPRESSION`).
  Import with `import {LIMIT} from "x"`, never `Mod.LIMIT`.
- File order: module doc, `import`s, constants, `struct`/`enum`/aliases,
  `export def`, private `def` (else `CHECK-DECL-ORDER`). A function may call a
  later one.
- Imports: `import Models from "models"` then `Models.User`, or `import {User,
  greet as hello} from "models"`. Never both on one line. Renames keep case:
  types stay capitalized, functions lowercase. A package declared in
  `agentica.toml` is `import S from "pkg/name/mod"` (`references/modules.md`).
- Defaults: a literal, `true`, `false`, `nil`, `[]`, `{}` or a payload-free
  variant (else `CHECK-DEFAULT-VALUE`). Defaulted parameters go last
  (`CHECK-DEFAULT-ORDER`), except a last `Fn` that a block fills. A function
  value (`&join`) still takes every argument.
- Heredoc for two or more lines: `<<~NAME`, the lines, then `NAME` alone.
  Common indentation is removed; interpolation and escapes work as in strings.
  One line is a plain string (`LEX-HEREDOC-ONE-LINE`); indent with spaces
  (`LEX-HEREDOC-INDENT`).
- A method chain may span lines: a line that starts with `.name` continues
  the one above (comments allowed between, no blank line); `|>` needs
  parentheses.
- Calls take parentheses. Only builtin methods and zero-argument module
  functions drop them: `s.length`, `xs.size`, `IO.gets!`.
- Values are immutable: `xs = xs.push(4)`, `m = m.put("k", 1)`. A bare
  `xs.push(4)` is `CHECK-UNUSED-VALUE`. No field or index assignment:
  `user = user.with(age: 31)`; named fields see the old struct.
- Several steps on one value: a pipe chain, `x |> f(a)` is `f(x, a)`; the right
  side is your function or `Alias.f(...)`.
- A block cannot assign an outer variable (`CHECK-CAPTURED-ASSIGNMENT`). A
  `for x in xs ... end` loop can, so use it for running totals.
- No implicit Int/Float (`CHECK-TYPE-MISMATCH`): `2 * 1.5` fails. Convert with
  `n.to_f`, `Float.from_int(n)`, `x.to_i!` or `Float.to_int!(x)`. `7 / 2` is
  `3`.
- `==` works only on Int, Float, Bool, String, Nil (same type) and ranges.
  Compare enums and structs with `case` or a field. No chained comparisons:
  `a < b and b < c`.
- `if` and `while` need a Bool. `!` binds tightly: `!(a >= b)`.
- Empty `[]`, `{}`, `Set.new([])` need a type from an annotation, parameter,
  field or return type: `m: Map[String, Int] = {}`.
- A non-Void function returns on every path. A loop does not count: put a
  `return` after `while true`.
- `case` on Int, Float, String, Bool or Nil needs a final `_`. On an enum, list
  every variant or add `_`. Guards see arm names; patterns work in payloads
  (`ok(Option.Some(0))`). A guarded or literal/nested arm never covers a
  variant: end with `ok(_)`, `Shape.Pair(_, _)` or `_`.
- `for` takes a List, Set or Range. `0...n` excludes n; `1..n` includes it. No
  `range(n)`.
- Result: `ok(v)` and `error(msg)` need an expected Result type (`r: Result[Int]
  = error("bad")`, else `CHECK-RESULT-TYPE`). `try` needs a Result operand
  (`try text.to_i`, not `try text.to_i!`) in a Result-returning function.
  `"x".to_i` is a Result, not `0`. In a `Lazy` block `try` always works: a
  failure ends the pipeline and the terminal returns it.
- `Task.await(task, timeout_ms)` returns `Await[R]` (`Await.Done(v)` or
  `Await.TimedOut`), not `R`; `timeout_ms` is above 0; a timeout does not cancel
  the task.
- `xs.lazy`, `(1..n).lazy`, `Lazy.produce(seed) do |x| ... end`,
  `File.foreach(path, n, ms)` and `ch.lazy(ms)` build a `Lazy` recipe; its
  steps (`map`, `filter`, `take` ...) run only in a
  terminal (`to_a`, `first(n)`, `each`, `reduce`, `find`,
  `write_lines(path, ms)`), which always gives a `Result`. No `next`, `yield`
  or `Enumerator`.
- `Void` has no value; it is only a function result or completion.
  `v = puts("x")` is `CHECK-VOID-VALUE`.
- Functions, tasks and handles have no `to_s` and cannot be printed or
  interpolated. `nil.to_s` is `"nil"`; write `(-5).to_s`, since `-5.to_s` fails.
- Call `IO.flush()` after each stdio protocol message. Send logs to stderr with
  `IO.warn()`.
- Fixed JSON records use structs with typed fields. `Json` and `JSON.object` are
  for dynamic data. Maps and lists hold one type.

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
- `references/lazy.md`: `Lazy[T]`, an endless source, the lines of a file or
  the values of a channel through steps, writing lines to a file, `try` in a
  step, or the first few results of a long chain of steps.
- `references/examples.md`: a complete program to start from.
- `references/performance.md`: slow programs, 100,000+ items or about 1 MB,
  hot paths, `AGENTICA_VM_TRACE=profile`, `Profile.measure` sections,
  `Profile.steps` budgets, flame graphs.
- `references/modules.md`: several files, shared constants, `std/`, `pkg/` or
  packages (`agentica.toml`, `agentica.lock`).
- `references/json.md`: JSON. `references/toml.md`: TOML (`std/toml`).
- `references/files.md`: files, directories, paths, locks, private files,
  removing or renaming paths or trees.
- `references/processes.md`: starting programs (`Process`).
- `references/tasks.md`: concurrency, `Task.map`, timed awaits, `Task.cancel`,
  `Channel`.
- `references/binary.md`: packing or unpacking bytes (`std/binary`).
- `references/logger.md`: levels, fields, handlers (`std/logger`).
- `references/network.md`: TCP, TLS, HTTP client or server.
- `references/bdd.md`: `.feature` specs and BDD steps (`agentica test`).
- `references/testing.md`: unit tests (`Test.test`, `Test.eq`, `Test.run`).
- `references/diagnostics.md`: a diagnostic code whose meaning or fix is
  unclear.

For style and idiom, use `agentica-code-guidelines`. Online docs:
`https://sonic182.github.io/agentica/llms.txt` indexes them;
`https://sonic182.github.io/agentica/llms-full.txt` has them all.
`agentica help NAME` is the authority on signatures for the installed binary.
