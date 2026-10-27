## 25. Ruby typed idioms

**Status:** the built parts are 25.1 (default parameter values), 25.2
(re-exports), 25.3 (struct update `with`), 25.6 (the compiler prelude and the
Enumerable methods), 25.10 (heredocs), 25.12.1 (`case` guards and nested
patterns) and 25.14 (the pipe operator `|>`); their rules live in
[`docs/grammar/`](../grammar.md) and the programming skill, which are the
contract. What remains here, one PR per item (row 7.6 of the [roadmap
order](../roadmap/README.md)): 25.4 (value equality, 15d), 25.5 (standalone
lambdas, 15e) and 25.9 (`File.open` with a block, 15i), after phase 16 (section
26), and 25.11 (`format`, 15k). Part B (25.12) lists ideas to evaluate later,
and Part C (25.13) lists what was decided against, so it is not proposed again.
Decided by the user on 2026-10-12.
Done when: site examples run on the VM and evaluation confirms agents use
the forms with the same diagnostic quality as the forms they replace.

Agentica is "Ruby with types" for LLM agents. This section takes more Ruby forms
that models already know, with this rule: accept a form when it is real Ruby (or
a typed version of it) or when it makes Agentica consistent with itself, and
keep static checking and immutable values. A form from another language is not
accepted: its hint names the Agentica form, and a newly accepted form is checked
with a second model in an evaluation round. Three limits do not move: no OOP (no
classes, no inheritance, no user methods on user types), no user generics, and
values stay immutable.

**Principle: one way to do each thing.** Strictness wins, so agents are precise.
A Ruby form is worth adding only when it does not create a second way to write
something the language already has. Where it would, it is not accepted: the
parser or the checker gives a diagnostic whose help shows the canonical form.
The same principle is why Agentica has no warnings: a diagnostic is an error
or it does not exist
([section 26](26-strict-diagnostics.md#26-strict-diagnostics)).

The test: a form fails when it only renames or negates an existing call, its
callback, or a statement (an alias, `reject` for `filter` with `!`, `unless` for
`if !`), or re-spells one call or statement. A method passes when the
composition it replaces needs a loop, several calls, or a seed value or typed
accumulator that the caller would otherwise have to choose. So `sum` (a `reduce`
whose seed, `0` or `0.0`, the caller picks), `find`, `each_with_index`,
`flat_map` and `Map.each` pass. `reject` fails, and so do the `Range` Enumerable
methods (each is `to_a` and then one `List` call). By the same test `unless` and
statement modifiers (re-spellings of `if`), `loop do` (`while true`), keyword
arguments (a second way to pass the same argument) and new method aliases are in
Part C.

**How an item lands.** Each remaining item changes the front end (`compiler/`)
and runs on the VM; most are sugar that lowering turns into code the VM already
runs, so the bytecode format does not change. A real program or an evaluation
round must ask for it first.

### 25.4 Value equality for data

Like Ruby's `Data`, two values of the same struct type are equal when their
fields are equal. The compiler provides it; it is not user operator overloading.

```agentica
a = User(name: "Ana", age: 30)
b = User(name: "Ana", age: 30)
puts(a == b)                    # true
puts(a.with(age: 31) != b)      # true
```

**Which types have equality.** Today `==` and `!=` work on primitive values and
ranges ("Operators" in `grammar.md`). With this item a type has equality when it
is:

- `Int`, `Float`, `Bool`, `String`, `Nil` or `Range`, as today;
- `Void` as a payload: a `Result[Void]` success has no value to compare, so
  `ok() == ok()` is true;
- a struct whose field types all have equality, or an enum whose payload types
  all have equality: same type, and the fields (or the variant and its payloads)
  equal one by one, in declared order;
- `List[T]`, `Map[K, V]` or `Result[T]` whose element types have equality: lists
  of the same length with equal elements in order; maps with the same keys and
  equal values, in any order (as Ruby's `Hash#==`); Results with the same tag
  and equal payloads (`error` compares the message).

A struct may hold itself through a list or an enum (`children: List[Node]`), and
types may refer to each other. The checker decides equality for each group of
mutually recursive types together (a strongly connected component of the type
graph): every type in the group has equality only if no type in the group has a
field without equality, so a cycle does not make the answer depend on the order
of the check. A result computed while an assumption about the group was still
open is never cached. A generic enum's equality depends on its type arguments:
`Option[Int]` has it, `Option[Fn[Int, Int]]` does not; a user enum is checked
per use, with its type arguments filled in.

`List.member?` (a prelude method, in the builtin catalog) uses this wider
equality: it takes any element type
that has equality.

Lists, maps and Results are in this item because a struct with a
`tags: List[String]` field is common, and struct equality without them would
rarely apply. `Json`, `Fn`, `Task` and handles (files, sockets, processes, HTTP
values) have no equality.

**Checker rules:** both sides must have the same type, and that type must have
equality; otherwise `CHECK-TYPE-MISMATCH`, as today for structs. When a struct
has no equality because of one field, the message names the field and a
secondary span marks its declaration:
`User has no equality: field "on_save" is Fn[User, Void]`. No new code is
needed; the rule is the one that exists, made wider. A `Float` field follows
IEEE 754, so a value that holds a NaN is not equal to itself, like the NaN.

**An operand that needs an expected type.** When one side is a form whose type
comes from context (`[]`, `{}`, `error(...)`, a nullary variant of a generic
enum such as `Option.None`), the other side's type is its expected type:
`r == error("not found")` checks `error(...)` as `r`'s `Result[T]`, and
`opt == Option.None` as `opt`'s `Option[T]`. When neither side gives a type
(`error("a") == error("b")`, `[] == []`), the existing diagnostics apply
(`CHECK-RESULT-TYPE`, `CHECK-EMPTY-LIST-TYPE`, `CHECK-ENUM-TYPE-INFERENCE`).

**One way to test for empty.** There is no `empty?`, so the canonical test is
`xs.size == 0` (and `m.size == 0`). `xs == []`, `m == {}`, `[] == xs`, `{} == m`
and their `!=` forms (the literal on either side) are `CHECK-TYPE-MISMATCH` with
a help that shows `xs.size == 0` (or `xs.size != 0`). `s == ""` stays valid,
since `String` equality already exists.

**Reuse.** The checker's type predicate for the set above plus `Json`
(`data-type?`) and the deep compare `agc_equal` in `vm/equal.c` were built for
`Test.eq` (phase 25a,
[`docs/roadmap/25-unit-tests.md`](../roadmap/25-unit-tests.md)); this item
reuses them for `==` and `!=`.

**VM:** the `EQ` and `NE` opcodes compare structs, enums, lists, maps and
Results by value, with an explicit stack (no C recursion, so deep values cannot
overflow the C stack), and charge a turn cost for their work as they already do
for long strings (`docs/vm/10-io-scheduler.md` §10.2.1). The checker rules out
`Fn` and handles; as a backstop, `EQ` raises `RUNTIME-INTERNAL` if it meets one
(a crafted `.agcb`). One equality function per type generated by lowering was
not chosen: it needs a function per struct, list and map type used with `==`,
while the VM already knows the shape of every value. `case` patterns are
unchanged.

**Format version:** the wider `EQ` and `NE` change what an opcode means, so this
PR bumps the bytecode format version (`docs/vm/03-ir-and-bytecode.md` §4: any
change to an opcode's meaning bumps it). A new opcode (`EQ_DEEP`) was not
chosen: the front end and the VM ship together, and one opcode is simpler than
two.

**Docs that change with it:** `docs/vm/03-ir-and-bytecode.md` §4.2 (the pairs
`EQ` and `NE` accept, and the `RUNTIME-INTERNAL` rule for other pairs) and
`docs/vm/10-io-scheduler.md` §10.2.1 (the scalar-only `==` text, and the turn
cost of the wider `EQ`).

### 25.5 Standalone lambdas

```agentica
inc = lambda do |x: Int| x + 1 end
puts(inc.call(41))                      # 42

check: Fn[String, Result[Int]] = lambda do |s|
  n = try s.to_i
  ok(n * 2)
end
```

**Syntax:** a new primary expression, `"lambda", block`. `lambda` becomes a
reserved word.

**Checker rules:**

- A lambda is a block without a call. Its value has type `Fn[A, ..., R]`, it
  captures by value, and the block rules hold (`CHECK-CAPTURED-ASSIGNMENT`,
  `CHECK-SHADOWED-NAME`, `return` leaves the lambda).
- Parameters must be annotated, unless there is an expected `Fn` type (an
  annotated variable, a parameter, a field, a return). With neither,
  `CHECK-BLOCK-TYPE`, as for a block.
- The result type comes from the expected `Fn` if there is one, or else from the
  body, as for `map`. As for `map`, `try` needs a known result type, so it works
  only with an expected `Fn` (the second example).
- A lambda cannot call itself (it has no name); recursion uses `def`.
- The strict rules of [section
  26](26-strict-diagnostics.md#26-strict-diagnostics) hold inside a lambda as in
  a block: an unused parameter or local is `CHECK-UNUSED-VARIABLE` (a `_` name
  opts out), a statement after `return` is `CHECK-UNREACHABLE-CODE`, and a
  dropped `Result` is `CHECK-UNUSED-RESULT`.
- **One way:** a `lambda` literal written directly as the last argument of a
  call that accepts a trailing block (a named call, a builtin or method call, or
  a call through an import alias) whose last parameter is an `Fn` is a second
  way to write a trailing block. It does not apply to `.call(...)`, which cannot
  take a block, so `g.call(1, lambda do |x: Int| x end)` is valid. Example:
  `xs.map(lambda do |x: Int| x * 2 end)` is `CHECK-BLOCK-TARGET` (the code about
  where a block goes; no new code) with a help that shows
  `xs.map do |x| x * 2 end`. Lambdas stay valid wherever a trailing block cannot
  go: assigned to a variable, a struct field, a list or map element, a non-last
  argument, or a return value.
- Not accepted, each with a help that shows `lambda do |x: Int| ... end`:
  `->(x) { ... }`, `lambda { |x| ... }`, `proc do ... end`, `Proc.new`. The
  `grammar.md` §7 hint row for `fn(x: Int) ...`, `lambda do ... end` and a `do`
  block with no call stays, minus `lambda do`; `fn(x: Int)` and a `do` block
  with no call get a help that shows `lambda do |x: Int| ... end`.

**Lowering:** the same closure as a block passed to a call; no VM change.

Once lambdas land, the `getter`/`putter` helpers of [section
15.1](15-adapters-and-json-inspection.md#151-calling-fn-fields-without-call)
are replaced by `lambda`.

### 25.9 `File.open` with a block

Ruby's `File.open(path) do |f| ... end` closes the file when the block ends.
This is the real use of Ruby's `ensure`, and here it replaces it.

**One way:** the block form is the canonical way to read or write a file through
a handle, and the programming skill and the site teach it. Manual `File.open`
and `File.close` stay only for a handle that lives beyond one block, such as one
shared with tasks. The whole-file helpers (`File.read_text`, `File.write_text`)
stay for reading or writing a whole file at once.

```agentica
def read_lines(path: String) -> Result[List[String]]
  return File.open(path, "read", 1000) do |f|
    lines: List[String] = []
    while !(try File.eof?(f, 1000))
      lines = lines.push(try File.read_line(f, 1000))
    end
    ok(lines)
  end
end
```

**`File.eof?`** comes with this item:
`File.eof?(handle: FileHandle, timeout_ms: Int) -> Result[Bool]` (unlike
`IO.eof?`, which returns `Bool`, so the loop needs `try`) for a file handle. It
peeks at the next byte without using it, with the timeout
and handle-lock rules of the other `File` stream functions, and returns an error
for a handle that is closed or not open for reading. It is a builtin under
exception 1 of the std-first rule (it touches the OS). Without it, a loop has to
tell the end of the file apart from invalid UTF-8 by the error text of
`File.read_line`.

**API:** one more arity of the existing builtin (the catalog already has arity
overloads, `Map.get`):

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]                    # today
File.open(path: String, mode: String, timeout_ms: Int, f: Fn[FileHandle, Result[T]]) -> Result[T]
```

**Rules:**

- If the open fails, the block does not run and the call returns that error.
- Otherwise the block runs with the handle, and then the handle is closed with
  `File.close(handle, timeout_ms)`, whether the block returned `ok` or `error`
  (an early `return error(...)` and a failed `try` included). If the block
  returned `ok(v)`, the call returns `ok(v)`, or the close error if the close
  fails (it flushes writes, so its error matters). If the block returned an
  error, the call returns that error, and a close error is dropped.
- A runtime diagnostic inside the block ends the task (the whole run only in
  `main`); the handle, owned by the task, is closed by the crash, or by the
  run's end in `main`, as today. A handle that leaves the block (returned inside
  the Result or captured by a lambda) is closed; using it gives the error
  `Result` of a closed handle, as today.
- The block's result must be `Result[T]`. `T` comes from the expected type of
  the call if there is one, or else from the body. Unlike `map`, `try` works in
  this block even when `T` is inferred: the outer type is always `Result`, so
  the checker knows what `try` returns from it. This is the small checker rule
  that `Task.map` ([section 27.1](27-iteration-and-concurrency.md#271-taskmap))
  already added for builtins whose block result is `Result[T]` with `T`
  inferred; this item reuses it. `try` in a block with a fixed `Result` type
  already works (`Test.test`, `File.each_line`).
- The strict rules of [section
  26](26-strict-diagnostics.md#26-strict-diagnostics) hold in the block: an
  unused handle parameter is `CHECK-UNUSED-VARIABLE` (`do |_|`), a statement
  after `return` is `CHECK-UNREACHABLE-CODE`, and a dropped `Result` inside it
  (`File.write_text(...)` without `try`) is `CHECK-UNUSED-RESULT`. The lowered
  `File.close` is not user code, so it is never reported.
- The same shape fits other handles that need a close: `TCP.connect`,
  `TLS.connect` and `Process.spawn` (where the close kills and reaps the
  process). Each is its own small item, added when a program needs it.

**Lowering:** lowering expands the call into the existing `File.open`, a call
to the block's closure, `File.close` and the branches above. The block form
needs no new builtin and no VM change; the only VM change of this item is the
appended `File.eof?` builtin. It is a lowering, not a `std/` function, since
that would have to be generic in `T`. A failing close is hard to cause in a test
(it needs a full disk), so a test of the lowered code checks the four outcomes
(block `ok` or `error`, close `ok` or `error`).

### 25.11 `format`

```agentica
puts(format("%-8s|%6.2f|%03d|%x", "apple", 2.5, 7, 255))   # apple   |  2.50|007|ff
```

**Spec.** `format(fmt, args...)` returns a `String`, like Ruby's
`Kernel#format`. A conversion is `%[flags][width][.precision]type`:

- **Type:** `d`
  - **Argument:** `Int`
  - **Text:** decimal

- **Type:** `x`
  - **Argument:** `Int`
  - **Text:** lowercase hex; a negative number is `-` and the hex of its
    magnitude (`-ff`, as in Python; Ruby writes `..f01`)

- **Type:** `f`
  - **Argument:** `Float`
  - **Text:** fixed point, 6 digits after the point unless `.precision` says
    otherwise; `NaN`, `Inf` and `-Inf` as in Ruby

- **Type:** `s`
  - **Argument:** any value with `to_s`
  - **Text:** its `to_s`, as `puts` writes it

- **Type:** `%%`
  - **Argument:** none
  - **Text:** a `%`

Flags: `0` pads numbers with zeros after the sign (`%05d` of `-42` is `-0042`);
`-` pads on the right with spaces. With both (`%-05d`), `0` is ignored, as in C
and Ruby. Other flags (`+`, space, `#`) are `CHECK-FORMAT-SPEC`. `width` is 1 to
1000 and counts characters as `String.length` does. `precision` is 0 to 50 and
only for `f`. An `Int` for `%f` is not converted (`n.to_f`, as everywhere).

**One way:** `format` is only for width, precision, flags or hex, and `"#{x}"`
interpolation stays the way to put values in text. A format string whose
conversions are all bare `%s` or `%d` (no flags, width or precision), or that
has no conversion at all (`%%` alone counts as none: `format("%%")` gets a help
that shows the string literal `"%"`), is `CHECK-FORMAT-SPEC` with a help that
shows the interpolated string (`format("%s is %d", name, age)` gives
`"#{name} is #{age}"`). `format("%.2f", x)` is the one public way to write a
fixed number of digits.

**The format string must be a literal, checked at compile time.** The checker
cannot check a format string that is only known at run time, so the choice was a
literal checked by the compiler or a format string at run time that returns a
`Result[String]`. The literal is chosen: the checker then knows how many
arguments there are and their types, so a mistake is a compile error with a span
inside the string, the result is a plain `String`, and nearly all real format
strings are literals. A program that needs a format chosen at run time picks
between literals.

**Checker rules:**

- `format` has a catalog entry in `compiler/catalog/builtins_data.agc` with a
  "checker-handled, variadic" marker: the number of arguments depends on the
  literal, so the checker checks the call itself, not against a fixed
  signature. The entry is needed because the linker keeps a call name unchanged
  only when `builtin-ref` finds it, and otherwise adds the module prefix
  (`@N::`), so `format` in an imported module would be renamed. The one entry
  covers linking, the name reservation (the linker's duplicate check uses
  `builtin-ref`) and `agentica help format`. Only the function name is
  reserved: a user `def format` is `CHECK-REDEFINED-NAME`, a breaking change
  accepted before 1.0. Variables, parameters and fields named `format` stay
  valid, since `format(...)` is a call and a variable is not callable.

- The first argument must be a plain one-line string literal, without `#{...}`
  and not a heredoc: `CHECK-FORMAT-LITERAL` otherwise, with a help to use
  interpolation for text that is built at run time.

- A bad conversion (unknown type, an unknown flag, a `%` at the end, `precision`
  on `d`, `x` or `s`, `0` on `s`, a width or precision out of range) is
  `CHECK-FORMAT-SPEC`, with the span of the conversion inside the literal.

- A wrong number of arguments is `CHECK-ARITY`; an argument of the wrong type is
  `CHECK-TYPE-MISMATCH` at the argument, with a secondary span at its
  conversion.

- `sprintf(...)`, `"%d" % x` and `String.format(...)` get a help that shows
  `format(...)`.

- `agentica help format` shows a help entry like a builtin's: the form
  `format(fmt: String literal, args...) -> String`, the conversions and flags,
  and an example. `agentica help format --json` has the same fields as a builtin
  (name, signature, effects: none, description), with the arity given as "2 or
  more" (a format with no conversion is rejected).

**Where the code lives.** By the std-first rule, padding, decimal and hex text
are Agentica code in the compiler prelude, `stdlib/prelude/format.agc` (the
design is in the development skill's `references/stages.md`).
One part is a builtin under exception 5 of the rule:
`__float_fixed(x: Float, digits: Int) -> String` (digits 0 to 50, otherwise
`RUNTIME-INVALID-COUNT`; NaN and the infinities give Ruby's `NaN`, `Inf` and
`-Inf`), because correct decimal rounding of a binary `Float` needs exact
arithmetic that would be fragile in Agentica; the VM calls `snprintf` with
`%.*f`. It is prelude-only, guarded like `__fail_arg` (a catalog entry with the
prelude-only flag; the checker gives `CHECK-UNKNOWN-NAME` outside prelude
modules, and the loader rejects a call to it from a function without the prelude
flag), so `format("%.2f", x)` stays the one public way. `x.to_fixed(2)`,
`x.round(2).to_s` and similar get `CHECK-UNKNOWN-METHOD` with a help that shows
`format("%.2f", x)`. The `Int` bit builtins of phase 13 are not needed: hex is
written with division and `%`, and the smallest `Int` (`-9223372036854775808`,
whose magnitude does not fit in `Int`) is a special case for `%d` with zero
padding (`%021d`) as well as for `%x`. Its tests check `__float_fixed` against
vectors from a checked-in Python script (standard library only), halfway cases
such as `0.125` and `2.675` included. `docs/vm/03-ir-and-bytecode.md` §4.5
("There are no internal helper builtins") gains `__float_fixed`.

**Lowering:** lowering turns each call into a concatenation of the literal
parts and calls to the prelude functions, one per conversion, so no format
string is parsed at run time. For each `%s` argument, lowering emits the
`to_s` call at the call site, as interpolation does, and passes the resulting
`String` to the prelude padding function. A `%s` argument without `to_s` (an
`Fn`, a task, a handle) is `CHECK-TYPE-MISMATCH` at the argument, with a
secondary span on its conversion. No VM change other than the new builtin.

### 25.12 To evaluate later (Part B)

These may help, but each needs more design, a real program that asks for it, or
another feature first. None is planned; each needs its own spec before a phase
takes it, and each must also pass the one-way principle (top of this section)
before it is planned.

#### 25.12.4 `then` and `tap`

**What:** `x.then do |v| ... end` and `x.tap do |v| ... end`. **Why:** pipelines
in Ruby style. **Why not now:** they are methods on every type with a generic
result, which the method rule (methods come from the receiver type's module)
does not have. **Open questions:** a builtin rule for "any type" methods, as
`to_s` and `inspect` have.

#### 25.12.5 Safe navigation `&.`

**What:** `user&.address&.city`. **Why:** short code for optional values. **Why
not now:** `nil` is not a value of every type, so there is nothing to navigate;
it needs optional types (`T?`) first. **Open questions:** whether `T?` comes at
all, and how it relates to user `Option[T]` and to `JsonField` (grammar, JSON).

#### 25.12.6 Destructuring

**What:** `a, b = pair`, block parameters `|(k, v)|`, multiple return values.
**Why:** `partition`, `zip` and `Map` iteration read better. **Decided:** there
are no tuples in the language (owner, 2026-10-20): Ruby has none either and uses
arrays. A struct carries grouped values of different types (a builtin struct
where a builtin needs one, such as a future `Lazy.Step`, §27.4), and a list
carries values of one type. **Open question:** whether lists can be
destructured with a length check.

#### 25.12.7 Lazy enumerators and generators

**What:** `(1..).lazy.select { ... }.first(3)`, `Enumerator.new`. **Why:**
streams of unknown length without building lists. **Now in [section
27](27-iteration-and-concurrency.md#27-iteration-and-concurrent-collections):**
`File.each_line` reads a big file line by line in bounded memory (§27.4, step
1), and `Lazy[T]` is built over lists, ranges, `Lazy.produce`, `File.foreach`
and `ch.lazy` (§27.4, step 2: `xs.lazy.filter do ... end.first(3)`); generators
with `yield` (`Enumerator.new`, fibers, an external `next`) are decided against
(§27.5), since a task that sends into a channel (§27.2) is the producer.

#### 25.12.8 Declarative hygienic macros

**What:** pattern-based macros like Rust's `macro_rules!`. **Why:** only if real
cases appear that blocks, functions and the items above do not cover. **Why not
now:** no such case is known. **Rules if it ever comes:** expansion before the
checker, hygienic names, spans at the call site so diagnostics point at user
code, and never procedural macros (25.13).

### 25.13 Decided against (Part C)

Each of these is decided; it gets a `help` that names the Agentica form where
one exists.

- **Runtime metaprogramming:** `define_method`, `class_eval`, `instance_eval`,
  `method_missing`, `send`/`public_send`: the checker must know every call; use
  a `Map[String, Fn[...]]` to dispatch by name.
- **`respond_to?`:** already not planned (15.5): the answer is known at compile
  time.
- **Reflection:** `instance_variable_get`/`set`, listing methods: it breaks
  static checking and makes the VM keep names at run time; `JSON.from` shows a
  value's fields. Listing the fields of a struct type is `Type.members`
  (`docs/grammar/06-semantics.md`, "Structs and lists").
- **`eval` and `binding`:** no code from strings at run time; the checker would
  not see it.
- **Monkey patching and refinements:** builtin types and modules are fixed;
  write a function.
- **Hooks** (`included`, `inherited`, `method_added`): there are no classes or
  mixins to hook.
- **Mixins** (`include`, `extend`, `Comparable`) and metatable-style methods
  (the former §7) are not planned: user types have no methods; a struct of `Fn`
  fields and wrapper functions compose behavior while retaining static checking.
  The §7 proposal's method-attachment syntax adds no need beyond that
  pattern. For chaining user functions, use `|>` (in the grammar).
- **Duck typing:** a struct of `Fn` fields is the interface, checked by name
  (15.1).
- **Symbols:** `String` keys and enums cover them.
- **`freeze` and `dup`:** every value is already immutable.
- **`yield`:** the block is a named `Fn` parameter, called with `.call`.
- **Generators and fibers** (`Enumerator.new`, `Fiber`): decided against in
  [section 27.5](27-iteration-and-concurrency.md#275-decided-against); a
  producer task that sends into a `Channel` is the generator.
- **`{ |x| ... }` brace blocks:** they re-spell `do |x| ... end`, and `{` is
  already the map literal.
- **Keyword arguments** (was 25.12.2): `connect("a", port: 8080)` would be a
  second way to pass an argument that can already be passed by position. Calls
  stay positional; `with` and struct construction stay the only places
  with named arguments.
- **`loop do ... end`** (was 25.12.3): `while true ... end` already does it, and
  `break` cannot leave a block, so it would be a statement that looks like a
  block. Section 11's help stays.
- **`unless`** (was 25.7): a second way to write `if !c`. `unless` is not a
  reserved word, so `unless c` is a name followed by more tokens. The parser
  picks the help when a statement starts with the name `unless` and more of the
  expression follows on that line: `PARSE-UNEXPECTED-TOKEN` with a help that
  shows `if !c ... end`. A variable named `unless` on its own still works, and
  `unless.foo` keeps today's diagnostic for that name.
- **Statement modifiers** (was 25.8): `return x if c`, `break if c`,
  `puts(x) if v` are a second way to write `if`. Section 11's rejection stays as
  it is, with its existing help (`if x`, then the statement on its own line,
  then `end`).
- **New method aliases** (`select`, `collect`, `detect`, `inject`) and **second
  ways** (`reject`, the `Range` Enumerable methods, the block form of
  `each_slice`): see the compiler prelude; each gets `CHECK-UNKNOWN-METHOD` (or
  `CHECK-BLOCK-TARGET`) with the canonical form.
- **`*args` and `**opts` splats:** a `List` or a struct parameter, and
  defaults.
- **`%w[...]`:** a list literal.
- **`raise`/`rescue`/`ensure`:** errors are `Result` values with `try`;
  `File.open` with a block (25.9) covers `ensure`.
- **User operator overloading, and overloading by argument type or by arity:**
  it breaks the inference of blocks and of empty literals (`[]`, `{}`) from the
  expected parameter type, makes diagnostics worse (which overload did you
  mean), and needs name mangling in the VM and the linker; defaults cover
  arity. Struct equality (25.4) is provided by the compiler, not by the user.
- **General and procedural macros:** agents write worse code in custom DSLs,
  diagnostics land in expanded code, and they need a new stage; blocks,
  functions and the compiler's equality (25.4) cover the use cases, and where a
  builtin needs to know where it was called, the compiler can pass it its call
  span.

**Composition instead of inheritance.** To "inherit" behavior:

1. The interface is a struct of `Fn` fields ([section
15.1](15-adapters-and-json-inspection.md#151-calling-fn-fields-without-call)),
   for example `Storage` with `get` and `put`.
2. A wrapper (decorator) function takes a base value and returns a new one with
   some fields replaced, keeping the others:
   `def logged(base: Storage) -> Storage` returns `base.with(get: ...)`,
   where the new `get` logs and then calls `base.get`.
3. A facade module passes on names from other modules with re-exports
   (`docs/grammar/05b-modules.md`), like Elixir's `defdelegate`.
