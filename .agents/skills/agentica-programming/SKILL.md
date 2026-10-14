---
name: agentica-programming
description: Write, check, run, and repair Agentica programs (`.agc` files), a Ruby-like language with static types and immutable values, including its builtins, JSON, files, processes, tasks, networking, and BDD specs. Use for Agentica application code. Do not use for interpreter, VM, or test-suite changes; use agentica-development for those.
---

# Agentica programming

Agentica is Ruby-like syntax with static types, checked before it runs. Values never change in place. This file has the cheat sheet and the rules agents break; `references/` has the rest. If a form is in neither, it does not exist: check a signature with `agentica help NAME` instead of guessing.

## Check and run

1. Save the program as `program.agc`, with exactly one `def main() -> Void`.
2. `agentica check program.agc` checks without running. `agentica program.agc ARGS` runs it on the VM; `System.args()` returns ARGS. If `agentica` is not on `PATH`, use the path the user gives.
3. Exit 0 is success. Exit 1 is a program diagnostic on stderr: the first error, a stable code (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`), a span, often a `help` line that names the Agentica form. Exit 2 is bad usage or an unreadable file. Fix the first error and run again.
4. Finish only when the run exits 0 and the output matches the request. A check does not test runtime behavior.
5. `agentica help NAME` prints one builtin's signature (`agentica help Map.get`; add `--json` for a machine form); `agentica help` lists the namespaces; unknown names exit 2. Useful flags: `--allow-run` (needed by `Process.spawn`), `--seed N` (makes `Random` repeatable), `--max-steps N`, `--json` (diagnostics as one JSON object). `agentica --help` lists the other commands. Tests and BDD: `references/testing.md`, `references/bdd.md`.

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

Common Ruby forms that work: `s.length`, `s.strip`, `s.split(" ")`, `s.upcase`, `s.include?("x")`, `s.to_i` (a Result), `s.to_i!`, `n.to_s`, `n.to_f`, `xs.size`, `xs.push(v)`, `xs.sort`, `xs.join(",")` (a `List[String]`), `m.keys`, `m.put(k, v)`, `m.get(k)` (a Result), `(1..3).to_a`, `n.times do |i| ... end`. The full list is in `references/builtins.md`.

Types: `Int` (signed 64-bit), `Float`, `Bool`, `String`, `Nil`, `Void`, `List[T]`, `Map[K, V]` (K is `Int` or `String`), `Result[T]`, `Range`, `Json`, `Fn[A, ..., R]`, `Task[R]`, `Channel[T]`, `Process`, and your own `struct` and `enum` names. Type names start with an uppercase letter; variables, functions, and fields start with a lowercase letter or `_`. Details: `references/language.md`.

## Rules agents break

- Syntax: no semicolons, braces, `let`, `when`, `elif`, `then`, `match`, or `loop do`. Strings are double-quoted (`'x'` is an error). Comments are `#` only (`//` is an error). `break` and `next` stand alone on a line; write `if x ... break ... end`, not `break if x`.
- A `##` block directly above a `def`, `struct`, `enum`, field or variant is its Markdown doc (`## Adds two numbers.` above `def add(a: Int, b: Int) -> Int`). The first `##` block of a file, followed by a blank line, documents the module. Any other `##` block is `PARSE-DETACHED-DOC`.
- Calls take parentheses: `puts("hi")`, `main()`, `run(5) do |x| ... end`. Only a builtin method or a zero-argument module function may drop them: `s.length`, `xs.size`, `IO.gets!`.
- Values are immutable: `xs = xs.push(4)`, `m = m.put("k", 1)`. A bare `xs.push(4)` is `CHECK-UNUSED-VALUE`. Fields and indexes cannot be assigned.
- A block cannot assign an outer variable (`CHECK-CAPTURED-ASSIGNMENT`). A `for x in xs ... end` loop can, so use it for running totals.
- No implicit Int/Float: `2 * 1.5` is `CHECK-TYPE-MISMATCH`. Convert with `n.to_f`, `Float.from_int(n)`, `x.to_i!`, or `Float.to_int!(x)`. `7 / 2` is `3`.
- `==` works only on Int, Float, Bool, String, Nil (same type on both sides) and ranges. Compare enums and structs with `case` or a field. Comparisons do not chain: write `a < b and b < c`.
- `if` and `while` need a Bool: `if 1` is an error. `!` binds tightly: `!(a >= b)`.
- Empty `[]` and `{}` need a type from an annotation, a parameter, a field, or the return type: `m: Map[String, Int] = {}`.
- A non-Void function must `return` on every path. A loop does not count, so put a `return` after `while true`.
- `case` on Int, Float, String, Bool, or Nil needs a final `_` arm. On an enum, list every variant or add `_`.
- `for` takes a List or a Range. `0...n` excludes n; `1..n` includes it. There is no `range(n)`.
- Result: `ok(v)` and `error(msg)` need an expected Result type: `r: Result[Int] = error("bad")` (a bare `r = error("bad")` is `CHECK-RESULT-TYPE`). `try` needs a Result operand (`try text.to_i`, not `try text.to_i!`) and a Result-returning function. `"x".to_i` is a Result, not `0`.
- `Void` is only a function result or a completion. `v = puts("x")` is `CHECK-VOID-VALUE`.
- Functions, tasks, and handles have no `to_s`, so they cannot be printed or interpolated. `nil.to_s` is `"nil"`. Write `(-5).to_s`, since `-5.to_s` is an error.
- Use `IO.flush()` after each stdio protocol message, and send logs with `IO.warn()` (stderr).
- For fixed JSON records, use structs with typed fields. `Json` and `JSON.object` are for dynamic data; maps and lists hold one type.

Not in Agentica, and what to write instead: `continue` (use `next`), `Map.new` (`{}` with a type), `IO.read_all` (`IO.read()`), `s.chars` (`s.split("")`), `s.ord` (`String.code(s)`), `s.len` (`s.length`), `s.empty?` (`s.length == 0`), `r.is_err?` or `r.error?` (`!r.ok?`), `=~` and `matches?` (no regex builtin).

## When to read a reference

Read only the files the task needs:

| Read | When the program |
|---|---|
| [references/language.md](references/language.md) | hits a checker error about an operator, type, Void, pattern, block, method, or Result, or needs a core rule this file does not state |
| [references/builtins.md](references/builtins.md) | calls a builtin not in the cheat sheet, or needs an exact signature for `String`, `List`, `Map`, `Range`, `Int`, `Float`, `IO`, `System`, `Time`, or `Random` |
| [references/examples.md](references/examples.md) | needs a complete program to start from |
| [references/modules.md](references/modules.md) | spans several files, or imports `std/` or `pkg/` modules |
| [references/json.md](references/json.md) | reads or writes JSON |
| [references/files.md](references/files.md) | reads or writes files, directories, or paths |
| [references/processes.md](references/processes.md) | starts other programs and talks to them (`Process`) |
| [references/tasks.md](references/tasks.md) | runs work concurrently, passes values between tasks, or uses `Channel` |
| [references/network.md](references/network.md) | uses TCP, TLS, or the HTTP client or server |
| [references/bdd.md](references/bdd.md) | writes `.feature` specifications or a BDD step program (`agentica test`) |
| [references/testing.md](references/testing.md) | writes unit tests (`Test.test`, `Test.eq`, `Test.run`) |
| [references/diagnostics.md](references/diagnostics.md) | hits a diagnostic code whose meaning or fix is unclear |

The Agentica site has the full documentation as Markdown: `https://sonic182.github.io/agentica/llms.txt` indexes the pages, and `https://sonic182.github.io/agentica/llms-full.txt` has them all. For the installed binary, `agentica help NAME` is the authority on signatures.
