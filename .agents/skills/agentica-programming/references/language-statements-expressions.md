# Statements and expressions

The exact rule behind a checker error or a core question about statements,
expressions and operators. Builtin methods and `to_s`: `builtins.md`.

## Statements

- The first assignment creates a name in the current block; later ones change
  its value, never its type. An annotation is allowed only on creation
  (`total: Float = 0.5`; else `CHECK-ANNOTATION-ON-EXISTING`).
- `_` binds nothing: `_ = f()` drops a result; it can be a `for` variable, a
  parameter or a pattern slot, repeated freely. Reading `_` is
  `CHECK-UNKNOWN-NAME`; `_: Int = x` is `PARSE-UNEXPECTED-TOKEN`.
- A name that is never read is `CHECK-UNUSED-VARIABLE`: a variable, a `for`
  variable, a block parameter or a pattern name; not a function parameter. Start
  the name with `_` (`_count`) to keep it, or write `_` for a `for` variable
  (`for _ in 0...n`), a block parameter (`|_, i|`) or a pattern slot
  (`error(_)`). Updating is no read: `count += 1`, `x = x + 1` and
  `xs = xs.push(v)` leave the name unused unless something else reads it.
- `x += e` (also `-=`, `*=`, `/=`, `%=`) is `x = x op e`; `x` must exist.
- A name created in a block is not visible after its `end`. A new variable
  cannot reuse a visible name (no shadowing: `CHECK-SHADOWED-NAME`).
- `for item in items` binds a read-only variable (`CHECK-IMMUTABLE-ASSIGNMENT`
  on assignment) over a `List[T]`, a `Set[T]` or a `Range`; anything else is
  `CHECK-NOT-A-LIST`. A range runs zero times when empty or reversed and is
  never built as a list. Write `0...n`, `n.times`, `a.upto(b)` or `a.downto(b)`;
  a `for` over a range never counts down.
- `case value` ... `end` is a statement. Arms are `pattern -> block`; a short
  arm may hold one simple statement on the arrow line (`1 -> puts("one")`). A
  `do` after the value is optional. Arm bindings are local to their arm.
- A `case` gives a value in three places: the right side of an assignment
  (`text = case r ... end`, `x: T = case ...`, `x += case ...`), after `return`,
  and the last line of a block (`xs.map do |x| case x ... end end`). Each arm
  ends with an expression, its value, after any other lines; all arms have one
  type (`CHECK-TYPE-MISMATCH` at the arm's last expression): the annotation, else
  the first arm's, so write `x: Result[Int] = case ...` when the first arm is
  `error(...)`, `[]` or `none`. The case is exhaustive. An arm that ends with
  another statement (`return`, `next`, `break`, a nested `case`) is
  `CHECK-CASE-ARM-VALUE`. In a block whose result is not known (`Task.spawn`)
  a last-line case whose arms are `Void` or of one other type, with at least
  one `Void`, is a statement and the block gives no value; arms of two
  different non-`Void` types are `CHECK-TYPE-MISMATCH`, even beside a `Void`
  arm.
  Elsewhere (`puts(case ...)`, `1 + case ...`) it is `PARSE-UNEXPECTED-TOKEN`.
- Patterns are primitive literals, `_`, `ok(...)`, `error(...)`, or qualified
  enum variants with one slot per payload. A slot is a name, `_`, a literal
  (`-1` too) or a variant pattern, to any depth. A name appears once per arm
  (`CHECK-SHADOWED-NAME`). A bare name is not a top-level pattern. There are no
  struct or list patterns (`CHECK-PATTERN-TYPE` for a pattern that does not fit
  the value).
- Several patterns on one arm's line: `"ex", "px" -> ttl(v)` runs when one
  matches. Such an arm binds no names (`CHECK-CASE-ARM-BINDING`: use `_`), and
  each pattern counts on its own for cover and `CHECK-UNREACHABLE-CASE-ARM`.
- A guard, `pattern if condition -> ...`, must be Bool (`CHECK-TYPE-MISMATCH`),
  sees its arm's names, stays on the pattern's line, and when false `case` tries
  the next arm. A later arm may repeat a guarded arm's pattern. `_ if c ->` is
  not a catch-all.
- Cover: an enum `case` lists every variant or ends with `_`; any other `case`
  (Int, Float, String, `Bool`, `Nil`) ends with a top-level `_`. An arm covers
  its variant only when unguarded with names or `_` in every slot, so guarded,
  literal and nested-variant arms need a closing `ok(_)`, `Shape.Pair(_, _)` or
  `_`. Missing cover is `CHECK-NON-EXHAUSTIVE-CASE`; an arm after a covering arm
  or an unguarded `_` is `CHECK-UNREACHABLE-CASE-ARM`.
- `if` and `while` conditions must be `Bool`; there is no truthiness.
- `break` leaves the innermost `while` or `for`; `next` skips to its next
  iteration. Neither crosses a block or function (`CHECK-LOOP-CONTROL`). In a
  block, `return` leaves the block.
- A guard: `return x if c`, `return if c`, `break if c`, `next if c` is the
  `if c` with that statement and `end` written out. The `if` is on the line of
  the statement (no multi-line `case` value or block before it), and no
  `elsif`, `else` or second `if` follows. A guard fits a one-line case arm
  (`1 -> return x if c`) or `do` block. No other statement takes a modifier,
  and there is no `unless`.
- A statement after `return`, `break`, `next`, or an `if` (with `else`) or
  `case` whose every branch ends in one is `CHECK-UNREACHABLE-CODE`.
  `System.exit`, `!` functions, `while true` and `try` do not count as ending.
- Assignment is a statement. There is no `x[i] = v`, `x.f = v` or `continue`.

## Expressions

- Literals: `42`, `3.14`, `1.5e-3`, `1e5` (a Float), `1_000` (a `_` between
  digits is only visual), `0xFF`, `0b1010`, `0o755` (`0755` is decimal; a bad
  digit is `LEX-INVALID-NUMBER`), `"text"` (escapes `\" \\ \# \n \r \t`),
  `true`, `false`, `nil`. A minus sign is an operator, not part of the literal;
  an integer that does not fit is `CHECK-INT-RANGE`.
- Interpolation: `"total: #{n + 1}"`. Strings go in as is, `Json` as its JSON
  text, other data in their `IO.inspect` form. Keep the expression on one line;
  `\#{` is literal text. `case` patterns and `import` paths take plain strings
  only.
- Heredocs: `<<~NAME`, the text lines, then a line with only `NAME` (capitals,
  digits, `_`; other opener forms are `LEX-UNEXPECTED-CHAR`). The smallest
  indentation among the text lines is removed, and every line, the last too,
  ends with `\n`: `<<~T`, `  a`, `    b`, `T` is `"a\n  b\n"`. Escapes and
  `#{...}` work as in a string. The rest of the opener line is code
  (`puts(<<~T)`, `f(<<~A, <<~B)`); inside `(...)` the call goes on after the end
  line. It needs two text lines or more (`LEX-HEREDOC-ONE-LINE`; write
  `"text\n"`); a tab in the indentation is `LEX-HEREDOC-INDENT`; no end line is
  `LEX-UNTERMINATED-HEREDOC`.
- Regex literals: `/\d+-\d+/i`, a `Regex.Regex` of `std/regex`, which the file
  must import (`CHECK-REGEX-IMPORT`). After a value `/` is division, so a call
  takes it in parentheses: `puts(/x/)`. Details: `regex.md`.
- Lists `[1, 2, 3]`; maps `{"a": 1, "b": 2}`. A repeated key keeps the last
  value at its first position.
- `[]`, `{}` and `Set.new([])` need a type from an annotation, parameter, field
  or function result (`CHECK-EMPTY-LIST-TYPE`, `CHECK-EMPTY-MAP-TYPE`,
  `CHECK-EMPTY-SET-TYPE`): `m: Map[String, Int] = {}`. A non-empty list needs
  one element type.
- Struct construction names each field once, in any order: `User(name: "Ana",
  age: 25)` (`CHECK-MISSING-FIELD` for a field with no default left out,
  `CHECK-DUPLICATE-FIELD`).
- Update: `user.with(age: 31)` copies the struct with named fields changed. It
  takes at least one field, each named once, only by name (`user.with()` and
  `user.with(31)` are `PARSE-UNEXPECTED-TOKEN`), each with a value of the
  field's type (`[]` and `{}` take it; `CHECK-UNKNOWN-FIELD`,
  `CHECK-DUPLICATE-FIELD`, `CHECK-TYPE-MISMATCH`). The receiver runs first, then
  the values left to right, all seeing the old struct (`p.with(a: p.b, b: p.a)`
  swaps). It nests: `a.with(address: a.address.with(city: "Lima"))`. A bare
  `user.with(...)` is `CHECK-UNUSED-VALUE`; on a non-struct,
  `CHECK-UNKNOWN-METHOD`. A struct from another module updates only when that
  module exports it and you import it (`CHECK-IMPORT-NAME`).
- Enum variants are qualified by their type. Payload variants take positional
  arguments (`Change.Added("hi")`; `CHECK-ENUM-POSITIONAL-ARGS`); nullary ones
  take `Level.Info` or `Level.Info()`. Generic arguments come from payloads
  and expected types, so a nullary generic variant needs an expected type
  (`CHECK-ENUM-TYPE-INFERENCE`). An unknown variant is `CHECK-UNKNOWN-VARIANT`.
- Field access `user.name`; index `items[0]`, `stock["apple"]` (a missing key is
  `RUNTIME-KEY-NOT-FOUND`, a bad list index `RUNTIME-INDEX-OUT-OF-RANGE`).
  Strings cannot be indexed (`CHECK-NOT-INDEXABLE`: use `s.at(i)`).
- `&name` references a top-level function without capturing locals: `f: Fn[Int,
  Int] = &double`, then `f.call(21)`. A builtin with one form and no rule of its
  own is a value too: `&Time.now_ms` (`Fn[Int]`), `&Int.to_s` (receiver first,
  `Fn[Int, String]`); others (`&List.map`, `&puts`, `&OpenSSL.Digest.sha256`)
  need a block. An `Fn` field of a struct is called by its name: `store.put(a,
  b)` is `store.put.call(a, b)`. A block is also a function value and captures
  locals. Function values go in containers, fields, parameters and returns;
  signatures must match exactly. Bare function names are not values; a lambda
  `->(x: Int) { x + 1 }` is (`language-blocks-results.md`). There is no
  equality or JSON encoding; inspect prints `<Fn>`.

Operators, from highest to lowest precedence:

| Level | Operators |
|---|---|
| 1 | call, `.field`, `[index]`, `( )` |
| 2 | unary `-`, `not` / `!`, `try` |
| 3 | `*` `/` `%` |
| 4 | `+` `-` |
| 5 | `\|>` (pipe) |
| 6 | `<` `<=` `>` `>=` |
| 7 | `==` `!=` |
| 8 | `and` / `&&` |
| 9 | `or` / `\|\|` |
| 10 | `..` `...` (ranges, no chaining) |

- `+ - * /` take two numbers of one type; no implicit conversion (`2 * 1.5` is
  `CHECK-TYPE-MISMATCH`: use `n.to_f` or `x.to_i!`). `+` also joins two Strings
  or two lists of one type (`[1] + [2]`, a new list), and `s * n` repeats a
  String (`"ab" * 3` is `"ababab"`; the Int comes second;
  a negative `n` or a result over 256 MiB is `RUNTIME-INVALID-COUNT`).
- `/` on Int truncates toward zero (`7 / 2` is `3`); `%` takes two Ints. A zero
  divisor is a runtime error, Float too (`RUNTIME-DIVISION-BY-ZERO`).
- `< <= > >=` take two numbers of one type (Strings: `a.compare(b) < 0`).
  Comparisons do not chain: `a < b and b < c` (`PARSE-CHAINED-COMPARISON`).
- `==` and `!=` take two values of one type: primitives, ranges, Bytes, and
  lists, maps, sets, Optionals, Results, structs and enums made of those. They
  compare in depth: lists in order, maps and sets in any order, structs field
  by field, enums by variant and payload (`a == b`, `xs == []`, `r == ok(1)`).
  Fn, Task, Channel, handles, Json and anything that holds one cannot be
  compared (`CHECK-TYPE-MISMATCH`), nor a generic `T`. A NaN anywhere makes a
  value unequal, even to itself.
- `&&`, `||`, `!` take Bool and short-circuit; `and`, `or`, `not` are the same.
  `!` binds tightly: `!(a >= b)`. A `!` right after a name is part of it
  (`read!`). Operands run left to right.
- `x |> f(a)` means `f(x, a)`. The right side is a call with parentheses
  (`f(a)`, `Alias.f(a)`), optionally after `try`, else `PARSE-PIPE-TARGET`;
  pipes group left. A bare name that no function of the program has is a
  method of the left value: `xs |> map(->(x) { x * 2 }) |> sum()` is
  `xs.map(->(x) { x * 2 }).sum`; a program function of that name wins. A
  builtin is never piped with its type (`CHECK-PIPE-METHOD`: `x.upcase` or
  `x |> upcase()`, not `x |> String.upcase()`). A multi-line
  chain goes in parentheses, one step per line; a leading `|>` does not continue
  a line, unlike a leading `.name`.

  ```ruby
  out = (
    header(v)
    |> add(a)
    |> add_all(b)
  )
  ```

## Forms from other languages

Rejected with a `help` line that names the Agentica form: `let`, `match`,
`when`, `elif`, `fn(x: Int)`, `lambda do`, `len(x)`, `Hash.new`, `range(n)`,
`return x unless c` (use `if not c`), `loop do`, `puts(x) if ok`, `continue`
(use `next`), `;`, braces, single-quoted strings. `xs << x` is
`xs = xs.push(x)`.
