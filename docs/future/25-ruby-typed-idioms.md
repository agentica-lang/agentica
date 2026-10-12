## 25. Ruby typed idioms

**Status:** Part A (25.1 to 25.11) is planned (roadmap phase 15, order step 7.4), after 7i deletes the evaluator (order 7.2). Part B (25.12) lists ideas to evaluate later. Part C (25.13) lists ideas that were decided against, so they are not proposed again. Decided by the user on 2026-10-12.

Agentica is "Ruby with types" for LLM agents. This section takes more Ruby forms that models already know, with the rule of [section 11](11-ruby-ergonomics.md#11-ruby-style-ergonomics): accept a form when it is real Ruby (or a typed version of it) or when it makes Agentica consistent with itself, and keep static checking and immutable values. Three limits do not move: no OOP (no classes, no inheritance, no user methods on user types), no user generics, and values stay immutable.

**How Part A lands.**

- Everything here comes after 7i deletes the evaluator (order 7.2). Each item changes the front end (`src/lexer.rkt`, `src/parser.rkt`, `src/modules.rkt`, `src/checker.rkt`) and `src/lower.rkt`, and runs on the C VM. No item touches `src/evaluator.rkt`.
- Most items are sugar that `lower.rkt` turns into code the VM already runs, so the bytecode format and the VM do not change. The exceptions are said in each item: 25.4 changes the VM's `EQ` and `NE` opcodes, 25.6 adds a prelude mark on functions and its error-span rule, and 25.11 adds one `Float` builtin.
- Library work follows the roadmap rule [New library features: `std/` first](../roadmap/README.md#new-library-features-std-first): pure computation is written in Agentica, and C is only for its exceptions. 25.6 and 25.11 need one small mechanism for this, the compiler prelude (25.6).
- Each item is its own PR, with the grammar (`docs/grammar.md`), the programming skill (`.agents/skills/agentica-programming/SKILL.md` and the matching `references/` file), the site page, the development skill's notes and tests. When an item lands, its text moves to `grammar.md` and is deleted here.
- **Tests** in each PR: parser, lexer and checker tests that assert the diagnostic code and span (`tests/parser-test.rkt`, `tests/lexer-test.rkt`, `tests/checker-test.rkt`, `tests/modules-test.rkt`); the golden fixtures (`tests/fixtures/vm/*.expected`: exit code, stdout, stderr and diagnostic code on the VM); and the runnable `agentica` blocks of the site page, which `tests/site-examples-test.rkt` checks.
- **Evaluation.** Section 11's rule holds: before the programming skill teaches a new form as the main style, an evaluation round with a second model checks that agents use it well (`tests/eval/run.py`). For 25.8 the round is a precondition: it does not ship without it.

| § | Item | Layers | New diagnostic codes |
|---|---|---|---|
| 25.1 | Default parameter values | parser, checker, lowering | `CHECK-DEFAULT-ORDER`, `CHECK-DEFAULT-VALUE` |
| 25.2 | Re-exports | parser, linker | none |
| 25.3 | `value.with(field: x)` | parser, checker, lowering | none |
| 25.4 | Value equality for data | checker, VM `EQ`/`NE` | none |
| 25.5 | Standalone lambdas | parser, checker, lowering | none |
| 25.6 | More Enumerable methods | catalog, prelude, checker, lowering, VM error spans | none |
| 25.7 | `unless` | lexer, parser | none |
| 25.8 | Statement modifiers | parser, checker | `CHECK-MODIFIER-BINDING` |
| 25.9 | `File.open` with a block | catalog, checker, lowering | none |
| 25.10 | Heredocs `<<~NAME` | lexer | `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT` |
| 25.11 | `format` | checker, prelude, lowering, one builtin | `CHECK-FORMAT-LITERAL`, `CHECK-FORMAT-SPEC` |

### 25.1 Default parameter values

```agentica
def join(xs: List[String], sep: String = ", ") -> String
  return xs.join(sep)
end

def main() -> Void
  puts(join(["a", "b"]))         # a, b
  puts(join(["a", "b"], "-"))    # a-b
end
```

**Syntax:**

```ebnf
parameter        = NAME, ":", type, [ "=", expression ] ;
```

The parser takes any expression after `=`, so the checker can give a clear diagnostic for one that is not allowed.

**Checker rules:**

- **Defaults only at the end.** After a parameter with a default, every parameter has a default, except a last parameter of type `Fn[...]`, which may stay without one so a block can still fill it: `def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) -> Void`. Anything else is `CHECK-DEFAULT-ORDER` at the parameter without a default.
- **A default is a constant:** an `Int`, `Float` or `String` literal (a minus sign allowed before a number; no `#{...}` in the string), `true`, `false`, `nil`, `[]`, `{}`, or a nullary enum variant (`Level.Info`, or `Log.Level.Info` through an import alias). Anything else (a call, a variable, `&name`, a struct, an interpolated string) is `CHECK-DEFAULT-VALUE` at the expression, with a help that says to make the parameter required.
- **Its type** is checked against the parameter type, like an initializer: `[]` and `{}` take the parameter type as their expected type, and a mismatch is `CHECK-TYPE-MISMATCH` at the default.
- **Fresh at each call.** The default is built at each call; no call shares a value with another. Since values are immutable, Python's shared mutable default cannot happen anyway.
- **Calls** to a function with `N` required parameters and `M` in all take `N` to `M` arguments; otherwise `CHECK-ARITY`, whose message says the range ("expects 1 to 2 arguments"). Arguments fill parameters from the left. When the last parameter is a `Fn` without a default, the block, or else the last argument, always goes to it, and the other arguments fill the parameters before it from the left: with `each_line` above, `each_line("a.txt") do |l| ... end` and `each_line("a.txt", 50, &show)` both work.
- Defaults apply to direct calls, through an import alias too (`Util.join(xs)`). A function value always takes every argument: `&join` has type `Fn[List[String], String, String]`, and `.call` needs both.
- Defaults are part of an exported signature. `main` still takes no parameters. Blocks and lambdas (25.5) take no defaults.
- This replaces overloading by arity, which user functions do not get (25.13). The builtin catalog keeps its few arity overloads (`Map.get`, `HTTP.client`).

**Lowering:** the checker records the full argument list on the call; `lower.rkt` emits the missing arguments as constants at the call site (a constant load, or an empty list or map). Every call in the bytecode passes all its arguments, so the bytecode and the VM do not change.

**`std/log`:** with defaults, `std/log` ([section 24](24-logging.md#242-stdlog)) could have `def info(message: String, fields: Map[String, String] = {}) -> Void` instead of the `_with` functions. That choice stays with the `std/log` PR (14c); section 24 is unchanged.

**Tests:** parsing and spans; each code; `CHECK-ARITY` with a range; `[]` and `{}` typed by the parameter; a block after defaulted parameters; a call through an import alias; a golden fixture with calls that leave out 0, 1 and 2 arguments. **Docs:** `grammar.md` (the `parameter` rule; "Functions and entry point" drops "no default values"), the programming skill (`SKILL.md`, functions), `site/content/tour/functions.md`.

### 25.2 Re-exports

Like Elixir's `defdelegate`, a module can pass on a name it imports, so a small facade module can collect the API of several files:

```agentica
# web.agc
import "url.agc" as Url
import "http_parts.agc" as Parts

export Url.parse
export Url.Address
export Parts.header_value
```

```agentica
import "web.agc" as Web

def main() -> Void
  case Web.parse("http://localhost:8080/a")
    ok(address) -> puts(address.host)
    error(message) -> puts(message)
  end
end
```

**Syntax:**

```ebnf
declaration      = (* ...today's forms, plus: *)
                 | reexport_decl ;
reexport_decl    = "export", TYPE_NAME, ".", ( NAME | TYPE_NAME ), NL ;
```

There is no clash with today's grammar: `export` is followed only by `def`, `struct` or `enum`, which are reserved words, so a `TYPE_NAME` after `export` is free. There is no renaming (`as`): one thing keeps one name, and a facade that wants another name writes a wrapper function. There are no wildcards (`export Url.*`), as for imports.

**Rules**, all in the linker (`src/modules.rkt`):

- The alias must be an import of this file: otherwise `CHECK-IMPORT-NAME` with the help "unknown module alias", decided in the linker. The name must be exported by that module (`CHECK-IMPORT-NAME`, with the "did you mean" help that 14c adds).
- The name joins this module's exports. The export entry keeps the original module's key (its canonical path) and name, not this file's, so the importer resolves to the original declaration. It must not collide with a declaration of this file or another re-export (`CHECK-REDEFINED-NAME`).
- Inside the file, the name is still `Url.parse`: a re-export adds no local name.
- It is the same declaration, not a copy. A program that imports both `web.agc` and `url.agc` sees `Web.Address` and `Url.Address` as one type. A chain (a re-export of a re-export) leads to the original declaration; a cycle cannot happen, since import cycles are already `CHECK-IMPORT-CYCLE`. A re-exported enum brings its variants (`Web.Option.Some(x)`).
- Re-exports, like imports, may follow each other and the imports without a blank line.
- An exported signature may still mention a private type that importers cannot name, as today.

**Lowering:** none. The linker resolves `Web.parse` to the original declaration before the checker runs, so the checker, `lower.rkt` and the VM see the original function. `&Web.parse` is a normal function value.

**Tests:** in `tests/modules-test.rkt`: a facade over two files; a chain of two re-exports; the same type through two aliases; an enum's variants; the three error codes; a golden fixture. **Docs:** `grammar.md` ("File modules and imports": "Imports cannot be re-exported" changes), the programming skill (`references/modules.md`), `site/content/tour/modules.md`.

### 25.3 Struct update with `with`

Like Ruby's `Data#with`: a copy of a struct with some fields changed. The original is unchanged.

```agentica
struct User
  name: String
  age: Int
end

def main() -> Void
  ana = User(name: "Ana", age: 30)
  older = ana.with(age: 31)
  puts(older)     # User(name: "Ana", age: 31)
  puts(ana.age)   # 30
end
```

**Syntax:** `postfix_expr` gets one more form, `".", "with", "(", named_arguments, ")"`. `with` is not a reserved word; it has this meaning only after a `.` and before `(`, and its arguments are always named.

**Checker rules:**

- The receiver must be a struct (`CHECK-UNKNOWN-METHOD` on any other type, with a help for structs). Each name must be a field of it (`CHECK-UNKNOWN-FIELD`), given at most once (`CHECK-DUPLICATE-FIELD`), with a value of the field's type (`CHECK-TYPE-MISMATCH`; `[]` and `{}` take the field type).
- At least one field: `ana.with()` is `CHECK-ARITY`. A positional argument (`ana.with(31)`) is `PARSE-UNEXPECTED-TOKEN`, with a help that shows `with(age: 31)`.
- `with` builds a new value of the struct's type, so it follows the rules of construction: for a type that another module keeps private, it gives the same diagnostic as constructing it. With generic structs (15.3) the type arguments stay, so a field's new value has the same type as before.
- A field named `with` whose type is `Fn[...]` is `CHECK-REDEFINED-NAME`; otherwise `user.with(...)` would clash with calling an `Fn` field without `.call` (15.1). A data field named `with` stays valid, so a JSON object with a `"with"` key still decodes into a struct; `value.with` without parentheses reads that field, and `value.with(...)` is always the update.
- **Named arguments appear only here and in struct construction** (`User(name: ..., age: ...)`). Calls to functions stay positional; keyword arguments are in Part B.

**Lowering:** the receiver is evaluated once, then the new values left to right; `lower.rkt` builds a new struct with today's construction instruction, reading the fields that do not change from the receiver. No VM change.

**Tests:** each code; a struct from an imported module; nested use (`a.with(address: a.address.with(city: "Lima"))`); evaluation order with calls that print; a golden fixture. **Docs:** `grammar.md` ("Structs and lists"), the programming skill (`SKILL.md`), `site/content/tour/structs.md`.

### 25.4 Value equality for data

Like Ruby's `Data`, two values of the same struct type are equal when their fields are equal. The compiler provides it; it is not user operator overloading.

```agentica
a = User(name: "Ana", age: 30)
b = User(name: "Ana", age: 30)
puts(a == b)                    # true
puts(a.with(age: 31) != b)      # true
```

**Which types have equality.** Today `==` and `!=` work on primitive values and ranges ("Operators" in `grammar.md`). With this item a type has equality when it is:

- `Int`, `Float`, `Bool`, `String`, `Nil` or `Range`, as today;
- a struct whose field types all have equality, or an enum whose payload types all have equality: same type, and the fields (or the variant and its payloads) equal one by one, in declared order;
- `List[T]`, `Map[K, V]` or `Result[T]` whose element types have equality: lists of the same length with equal elements in order; maps with the same keys and equal values, in any order (as Ruby's `Hash#==`); Results with the same tag and equal payloads (`error` compares the message).

A struct may hold itself through a list or an enum (`children: List[Node]`). The check assumes yes on a cycle: while it decides whether `Node` has equality, `Node` counts as having it, so the answer depends only on the other fields. A generic enum's equality depends on its type arguments: `Option[Int]` has it, `Option[Fn[Int, Int]]` does not; a user enum is checked per use, with its type arguments filled in.

Lists, maps and Results are in this item because a struct with a `tags: List[String]` field is common, and struct equality without them would rarely apply. `Json`, `Fn`, `Task` and handles (files, sockets, processes, HTTP values) have no equality.

**Checker rules:** both sides must have the same type, and that type must have equality; otherwise `CHECK-TYPE-MISMATCH`, as today for structs. When a struct has no equality because of one field, the message names the field and a secondary span marks its declaration: `User has no equality: field "on_save" is Fn[User, Void]`. No new code is needed; the rule is the one that exists, made wider. A `Float` field follows IEEE 754, so a value that holds a NaN is not equal to itself, like the NaN.

**VM:** the `EQ` and `NE` opcodes compare structs, enums, lists, maps and Results by value, with an explicit stack (no C recursion, so deep values cannot overflow the C stack), and charge a turn cost for their work as they already do for long strings (`docs/vm/10-io-scheduler.md` §10.2.1). The checker has already ruled out `Fn` and handles, so the VM never meets them there. The alternative, one equality function per type generated by `lower.rkt`, was not chosen: it needs a function per struct, list and map type used with `==`, while the VM already knows the shape of every value. `case` patterns are unchanged.

**Tests:** checker tests for each kind and for a struct with an `Fn` field (code and secondary span); golden fixtures for nested structs, lists of structs, maps in another order, enums, Results, a NaN field; a deep list (100,000 levels) for the explicit stack; a C test of the opcode. **Docs:** `grammar.md` ("Operators": "The core has no list or struct equality" changes), the programming skill, `site/content/tour/structs.md`, `docs/vm/` (the `EQ` opcode).

### 25.5 Standalone lambdas

Open in [section 11.4](11-ruby-ergonomics.md#114-blocks-and-closures); planned here.

```agentica
inc = lambda do |x: Int| x + 1 end
puts(inc.call(41))                      # 42

check: Fn[String, Result[Int]] = lambda do |s|
  n = try s.to_i
  ok(n * 2)
end
```

**Syntax:** a new primary expression, `"lambda", block`. `lambda` becomes a reserved word.

**Checker rules:**

- A lambda is a block without a call. Its value has type `Fn[A, ..., R]`, it captures by value, and the block rules hold (`CHECK-CAPTURED-ASSIGNMENT`, `CHECK-SHADOWED-NAME`, `return` leaves the lambda).
- Parameters must be annotated, unless there is an expected `Fn` type (an annotated variable, a parameter, a field, a return). With neither, `CHECK-BLOCK-TYPE`, as for a block.
- The result type comes from the expected `Fn` if there is one, or else from the body, as for `map`. As for `map`, `try` needs a known result type, so it works only with an expected `Fn` (the second example).
- A lambda cannot call itself (it has no name); recursion uses `def`.
- Not accepted, each with a help that shows `lambda do |x: Int| ... end`: `->(x) { ... }`, `lambda { |x| ... }`, `proc do ... end`, `Proc.new`. The hint row for `lambda do ... end` in `grammar.md` §7 goes away.

**Lowering:** the same closure as a block passed to a call; no VM change.

**Tests:** parser tests; annotated and expected-type forms; `CHECK-BLOCK-TYPE`; `try` with and without an expected type; a lambda stored in a struct's `Fn` field and in a `Map[String, Fn[...]]`; a golden fixture. **Docs:** `grammar.md` ("Blocks and closures", the reserved words, §7 hints), the programming skill (`SKILL.md`), `site/content/tour/blocks.md`; section 11.4 then lists only what is still open.

### 25.6 More Enumerable methods

**What exists today:** `List` has `size`, `append` (`push`), `set`, `repeat`, `reverse`, `map`, `filter`, `reduce`, `concat`, `take`, `drop`, `at`, `sort`, `sort_by`, `each`, `any?` and `all?`; `Range` has `size`, `to_a`, `include?`, `each`, `first` and `last`; `Map` has `has_key?`, `keys`, `values`, `size`, `put`, `get` and `delete` (`grammar.md`, `src/builtins.rkt`). `tally` and `zip` do not exist yet. This item adds the missing ones:

```text
List.select(list: List[A], f: Fn[A, Bool]) -> List[A]                 # alias of List.filter
List.reject(list: List[A], f: Fn[A, Bool]) -> List[A]
List.find(list: List[A], f: Fn[A, Bool]) -> Result[A]
List.each_with_index(list: List[A], f: Fn[A, Int, Void]) -> Void
List.flat_map(list: List[A], f: Fn[A, List[B]]) -> List[B]
List.partition(list: List[A], f: Fn[A, Bool]) -> List[List[A]]
List.take_while(list: List[A], f: Fn[A, Bool]) -> List[A]
List.drop_while(list: List[A], f: Fn[A, Bool]) -> List[A]
List.each_slice(list: List[A], size: Int) -> List[List[A]]
List.each_slice(list: List[A], size: Int, f: Fn[List[A], Void]) -> Void
List.group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]       # K is Int or String
List.tally(list: List[K]) -> Map[K, Int]                              # K is Int or String
List.uniq(list: List[K]) -> List[K]                                   # K is Int or String
List.sum(list: List[N]) -> N                                          # N is Int or Float
List.min_by(list: List[A], key: Fn[A, O]) -> Result[A]                # O is Int, Float or String
List.max_by(list: List[A], key: Fn[A, O]) -> Result[A]
Range.select(r: Range, f: Fn[Int, Bool]) -> List[Int]
Range.reject(r: Range, f: Fn[Int, Bool]) -> List[Int]
Range.map(r: Range, f: Fn[Int, B]) -> List[B]
Range.find(r: Range, f: Fn[Int, Bool]) -> Result[Int]
Range.sum(r: Range) -> Int
Map.each(map: Map[K, V], f: Fn[K, V, Void]) -> Void
Map.select(map: Map[K, V], f: Fn[K, V, Bool]) -> Map[K, V]
Map.reject(map: Map[K, V], f: Fn[K, V, Bool]) -> Map[K, V]
```

**Rules:**

- All are methods by the existing rule (`xs.find do |x| ... end`), keep their inputs, run callbacks once per element left to right (`find`, `take_while` and `drop_while` stop where the answer is known), and use the caller's step budget.
- `select` is an alias of `filter` in the alias table, like `push` for `append`; `filter` stays.
- Ruby returns `nil` from `find`, `min_by` and `max_by` when nothing matches; here they return `error("not found")` or `error("the list is empty")`, like `Range.first`. Ties in `min_by` and `max_by` go to the first element.
- `partition` returns two lists, `[yes, no]`, since there are no tuples (12.5); with destructuring (Part B) it would read like Ruby.
- `each_slice(n)` without a block returns the slices; with a block it calls it on each. `n < 1` is `RUNTIME-INVALID-COUNT`. The last slice may be shorter.
- `group_by` and `tally` keep the order in which keys first appear; `uniq` keeps the first copy of each value. The restrictions on `K`, `N` and `O` match the map key types and `List.sort_by`'s key types; another type is `CHECK-TYPE-MISMATCH`, as for `sort`.
- `sum` of an empty list is `0` or `0.0`; an `Int` sum that does not fit is `RUNTIME-INTEGER-OVERFLOW`. Section 5's planned `List.sum` is this one. `Range.sum` uses the same rule, without building a list.
- The `Range` functions that return a list have the 1048576-value limit of `Range.to_a`.
- `Map.each`, `select` and `reject` go in insertion order; their blocks take two parameters (`do |k, v|`).
- **Not here:** `zip` needs tuples to be typed (`List[(A, B)]`); it waits for them (12.5, and destructuring in Part B). `List.member?` is already planned in section 5. `count` stays out (section 5 keeps `size` as the only count).

**Where the code lives: the compiler prelude.** By the std-first rule these are Agentica code, not C. But a `std/` module cannot hold them today, for two reasons: a user function cannot be generic, and a user function cannot be called as a method. So this item adds one small mechanism, the **compiler prelude**:

1. Each function above has a normal entry in the builtin catalog (`src/builtins.rkt`): signature with the catalog's type variables, help text, and a mark that its body is a prelude function. The checker checks calls against the entry like any builtin (methods are resolved by receiver type in `resolve-method`, `src/checker.rkt`), so call sites, methods, aliases, blocks and `agentica help` work as for `List.map`. Nothing new for users.
2. The bodies live in `stdlib/prelude/list.agc` (and `range.agc`, `map.agc`), written in Agentica on the existing builtins. Only prelude files may use the catalog's type variables (`A`, `B`, `K`, ...); user code still cannot. The checker checks a prelude body with each type variable as an opaque type: a value of type `A` can be stored, put in a list, returned, and passed to an `Fn` that takes `A`, and nothing else. A variable restricted to a short list of types (`K` is `Int` or `String`) may have one body per allowed type, and the catalog entry names the body for each type: `List.sum` has `sum_int` and `sum_float`, since `0` and `0.0` and the two additions differ. A body that works for every allowed type (`uniq`, which only uses the value as a map key) may be one body, checked once per allowed type.
3. **Always linked, checked once.** The linker cannot know which prelude functions a program uses: methods and `format` are resolved by the checker, after linking. So the prelude modules are always linked into every program. They are checked once, when the compiler is built, and the result is cached with the embedded source (as `embed-source` embeds `std/` files in `src/stdlib.rkt`), so checking a user program does not pay for them. `lower.rkt` emits only the prelude functions reachable from the checked program (one copy per allowed type that is used, for restricted ones) and calls them like user functions. Prelude files are not importable through `std/`, and their names cannot clash with user names.

**Runtime errors inside prelude code** must look like errors of a builtin, never of a file the user did not write:

- A runtime diagnostic raised while a prelude function runs is reported at the user's call site, or at the argument the builtin rule names (as `List.take` reports `RUNTIME-INVALID-COUNT` at its count argument). For this, `lower.rkt` gives a call to a prelude function the call span and the argument spans, as `call-builtin` already has (`docs/vm/03-ir-and-bytecode.md`), and marks prelude functions in the bytecode. When the VM raises a diagnostic in a prelude frame, it takes the span from the innermost frame that is not a prelude frame.
- Prelude frames are skipped in stack traces (14b, [section 24.3](24-logging.md#243-stack-traces-on-runtime-errors)), like native frames. A user block called from a prelude function keeps its own frame, so an error in the block shows the block and then the user's call.
- A prelude-only intrinsic, `__fail_arg(code, index, message)`, raises the given `RUNTIME-` code at argument `index` of the current prelude call: `each_slice` uses it for `RUNTIME-INVALID-COUNT` when `n < 1`, and the `Range` functions for the 1048576-value limit. Only prelude files may use it, as with the type variables; in user code the name is `CHECK-UNKNOWN-NAME`.
- An overflow inside a prelude body (`sum`) is raised by the VM's own add instruction, so it is reported at the user's call by the first rule.

These are the only VM changes of this item: the prelude mark on functions and the span rule above, plus `__fail_arg`.

This is not user generics: only files that ship with the compiler use type variables, and only behind catalog signatures. A function moves to C later only when a measurement shows it is hot, as the std-first rule says; its catalog entry stays the same.

**Tests:** each function on lists of `Int`, `String` and structs, empty lists and the edge cases above, golden fixtures, the site examples, and checker tests for the restricted type variables and for a prelude body that misuses an opaque type. Runtime errors, with fixed expected stderr (span and stack): `each_slice(0)` (count error at the argument), an `Int` `sum` that overflows (at the call), a `Range` function over the 1048576-value limit (at the receiver), and an error inside the user's block reached through a prelude function (the block's frame, then the user's call; no prelude frame). A test that `__fail_arg` in user code is `CHECK-UNKNOWN-NAME`.

### 25.7 `unless`

```agentica
unless File.stat(path, 1000).ok?
  puts("missing: #{path}")
end
```

**Syntax:**

```ebnf
statement        = (* ...today's forms, plus: *)
                 | unless_statement ;
unless_statement = "unless", expression, NL, block,
                   [ "else", NL, block ], "end", NL ;
```

`unless` becomes a reserved word. The condition is `Bool` (`CHECK-TYPE-MISMATCH` otherwise), and the statement means `if !cond`. `else` is allowed, because Ruby allows it and the parser only swaps the two blocks; rejecting it would need its own diagnostic. `elsif` inside `unless` is `PARSE-UNEXPECTED-TOKEN`, as in Ruby, with a help that says to use `if`. `until` is not part of this item.

**Lowering:** none; the parser builds an `if` node with the condition negated and the spans of the source. No new codes.

**Tests:** parser tests (with and without `else`, `elsif` rejected, spans), a checker test for a non-`Bool` condition, a golden fixture. **Docs:** `grammar.md` (statements, reserved words), the programming skill, `site/content/tour/control-flow.md`.

### 25.8 Statement modifiers

```agentica
def first_even(xs: List[Int]) -> Result[Int]
  for x in xs
    next unless x % 2 == 0
    return ok(x)
  end
  return error("none")
end

def report(verbose: Bool, total: Int) -> Void
  puts("total: #{total}") if verbose
end
```

This reverses a decision of section 11, whose "Which forms to accept" paragraph lists statement modifiers among the Ruby forms that do not fit. Agents write them often (`break if x`, `return x if c`), and today they get a help. **Precondition:** by section 11's rule, an evaluation round with a second model must show that agents use them well before this item ships; if the round shows new mistakes (for example modifiers on assignments that introduce a variable), the item changes or stays out.

**Syntax:**

```ebnf
statement        = simple_statement, [ modifier ], NL
                 | (* ...the compound statements as today *) ;
modifier         = ( "if" | "unless" ), expression ;
```

The one-line case arm and the one-line block body take a modifier too (`1 -> puts("one") if verbose`). A modifier after a compound statement (`end if x`) and the loop modifiers (`x += 1 while c`, `until`) are `PARSE-UNEXPECTED-TOKEN`; the loop ones keep a help that shows a `while` loop. `return if c` is a `return` without a value: `if` and `unless` cannot start an expression, so the parser stops there.

**Checker rules:** `S if c` means `if c` / `S` / `end`, and `S unless c` means the same with `!c`. The condition is `Bool`. A modifier on an assignment may update a variable that is already visible (`x = 0 if reset`, `count += 1 if ok`), but may not introduce one: `CHECK-MODIFIER-BINDING` at the name, since the variable would exist only inside the hidden `if`. A non-`Void` block whose last statement has a modifier does not give a value on every path (`CHECK-MISSING-RETURN`, as today).

**Lowering:** none; the parser builds the `if` node. **Tests:** each statement kind with both modifiers, `CHECK-MODIFIER-BINDING`, the rejected forms, `return` without a value, a golden fixture. **Docs:** `grammar.md` (statements; the line "There are no statement modifiers" and the §7 hint rows for `break if x` and `puts(x) if ok` change), the programming skill, `site/content/tour/control-flow.md`, and section 11's paragraph.

### 25.9 `File.open` with a block

Ruby's `File.open(path) do |f| ... end` closes the file when the block ends. This is the real use of Ruby's `ensure`, and here it replaces it.

```agentica
def count_lines(path: String) -> Result[Int]
  return File.open(path, "read", 1000) do |f|
    count = 0
    while true
      case File.read_line(f, 1000)
        ok(_) -> count += 1
        error(message) ->
          if message == "filesystem: end of file"
            break
          end
          return error(message)
      end
    end
    ok(count)
  end
end
```

There is no `File.eof?` today, and `File.read_line` returns an error both at the end of the file and for invalid UTF-8, so the example tells them apart by the error text the VM gives at the end (`filesystem: end of file`) and returns any other error. A `File.eof?(handle, timeout_ms)` builtin, like `IO.eof?`, would make this cleaner; it is a separate small item.

**API:** one more arity of the existing builtin (the catalog already has arity overloads, `Map.get`):

```text
File.open(path: String, mode: String, timeout_ms: Int) -> Result[FileHandle]                    # today
File.open(path: String, mode: String, timeout_ms: Int, f: Fn[FileHandle, Result[T]]) -> Result[T]
```

**Rules:**

- If the open fails, the block does not run and the call returns that error.
- Otherwise the block runs with the handle, and then the handle is closed with `File.close(handle, timeout_ms)`, whether the block returned `ok` or `error` (an early `return error(...)` and a failed `try` included). If the block returned `ok(v)`, the call returns `ok(v)`, or the close error if the close fails (it flushes writes, so its error matters). If the block returned an error, the call returns that error, and a close error is dropped.
- A runtime diagnostic inside the block ends the whole run, and the run's end closes the handle as today. A handle that leaves the block (returned inside the Result or captured by a lambda) is closed; using it gives the error `Result` of a closed handle, as today.
- The block's result must be `Result[T]`. `T` comes from the expected type of the call if there is one, or else from the body. Unlike `map`, `try` works in this block even when `T` is inferred: the outer type is always `Result`, so the checker knows what `try` returns from it. This is a small checker rule for builtins whose block result is `Result[T]`.
- The same shape fits other handles that need a close: `TCP.connect`, `TLS.connect` and `Process.spawn` (where the close kills and reaps the process). Each is its own small item, added when a program needs it.

**Lowering:** `lower.rkt` expands the call into the existing `File.open`, a call to the block's closure, `File.close` and the branches above. There is no new builtin and no VM change; a `std/` function cannot do this, because it would have to be generic in `T`.

**Tests:** golden fixtures on temporary files: read and write with `ok`; an early `error`; a failed `try`; a failed open (block not run); the handle used after the block. A failing close is hard to cause from a test (it needs a full disk), so a test of the lowered code checks that each of the four outcomes (block `ok` or `error`, close `ok` or `error`) gives the result above. **Docs:** `grammar.md` ("Files and paths"), the programming skill (`references/files.md`), `site/content/library/files.md`.

### 25.10 Heredocs

Ruby's squiggly heredoc: a multi-line string whose common indentation is removed.

```agentica
def help_text(name: String) -> String
  text = <<~TEXT
    Usage: #{name} [options]

      --verbose   print more
    Exit code 0 on success.
  TEXT
  return text
end
```

The value is `"Usage: tool [options]\n\n  --verbose   print more\nExit code 0 on success.\n"` for `name = "tool"`.

**Lexer only.** The lexer turns a heredoc into the same string token (with interpolation parts) as a normal string literal, so the parser, checker, lowering and VM do not change.

- **Start:** `<<~` followed directly by an uppercase name (`[A-Z][A-Z0-9_]*`). The rest of the line is lexed as usual (`puts(<<~TEXT)` works); the body starts on the next line. Several heredocs on one line take their bodies one after the other, in order, as in Ruby.
- **End:** a line with only optional spaces and the same name. The body lines and the end line produce no `NL` tokens; the line that holds `<<~NAME` ends with its `NL` as usual.
- **Indentation:** the smallest number of leading spaces among the body lines that are not blank is removed from every line. A blank line (spaces only) becomes an empty line. A tab in a line's leading whitespace is `LEX-HEREDOC-INDENT`, with a help to use spaces, because tab widths make the result unclear. Each body line ends with `\n`, the last included.
- **Token order.** At the place of `<<~NAME`, the lexer emits the heredoc's tokens: one `string` token without interpolation, or `interp-start`, the tokens of each `#{...}` expression, `interp-middle` and `interp-end`, as for a normal string. Then come the tokens of the rest of the opener line, then its `NL` (when outside delimiters), then the tokens after the end line. So the parser sees one string primary where `<<~NAME` stands.
- **Spans.** The string piece tokens (`string`, `interp-start`, `interp-middle`, `interp-end`) all take the span of `<<~NAME`, so every node that `span-from` builds in `src/parser.rkt` (the start of its first token to the end of the last consumed token) stays on the opener line, with start before end. The tokens inside `#{...}` keep their real line and column in the body: the lexer finds the indentation with a first pass over the body lines, then lexes each line from its real position after the indentation, so the indentation is cut from the text, not from the source positions. These spans lie after their parent's span, so spans are not monotonic here: a child may lie outside its parent. The PR checks that no code assumes a child span lies inside its parent's (diagnostics print each span on its own line, which works).
- **Inside parentheses:** `foo(<<~A, x)` works, and so does `foo(<<~A,` with the next argument on the line after the end line: inside delimiters no `NL` is emitted, the body is read when the opener line ends, and the call goes on after the end line, as in Ruby.
- **Escapes and interpolation** are those of a normal string: `\n`, `\r`, `\t`, `\"`, `\\`, `\#`, and `#{...}`, which must end on its line; a bad escape is `LEX-INVALID-ESCAPE`. A `"` needs no escape. The indentation is removed from the source text before escapes and interpolation, so an interpolated value is never re-indented.
- **Errors:** end of file before the end line is `LEX-UNTERMINATED-HEREDOC` at `<<~NAME`. A name that is not uppercase (`<<~text`) is `LEX-UNEXPECTED-CHAR` at `<<~`, with a help that shows `<<~TEXT`. Only the squiggly form exists: `<<NAME`, `<<-NAME` and the quoted forms (`<<~'NAME'`) are `LEX-UNEXPECTED-CHAR` with a help that shows `<<~NAME` (and `\#` for text without interpolation).
- `case` patterns and `import` paths still take plain string literals only.

**Tests:** in `tests/lexer-test.rkt`: indentation, blank lines, interpolation and escapes, two heredocs on one line, a heredoc inside a call, the three codes with their spans; a golden fixture; a site example. **Docs:** `grammar.md` (Literals: "no multiline strings" changes), the programming skill (`SKILL.md`), `site/content/tour/strings.md`.

### 25.11 `format`

```agentica
puts(format("%-8s|%6.2f|%03d|%x", "apple", 2.5, 7, 255))   # apple   |  2.50|007|ff
```

**Spec.** `format(fmt, args...)` returns a `String`, like Ruby's `Kernel#format`. A conversion is `%[flags][width][.precision]type`:

| Type | Argument | Text |
|---|---|---|
| `d` | `Int` | decimal |
| `x` | `Int` | lowercase hex; a negative number is `-` and the hex of its magnitude (`-ff`, as in Python; Ruby writes `..f01`) |
| `f` | `Float` | fixed point, 6 digits after the point unless `.precision` says otherwise; `NaN`, `Inf` and `-Inf` as in Ruby |
| `s` | any value with `to_s` | its `to_s`, as `puts` writes it |
| `%%` | none | a `%` |

Flags: `0` pads numbers with zeros after the sign (`%05d` of `-42` is `-0042`); `-` pads on the right with spaces. With both (`%-05d`), `0` is ignored, as in C and Ruby. Other flags (`+`, space, `#`) are `CHECK-FORMAT-SPEC`. `width` is 1 to 1000 and counts characters as `String.length` does. `precision` is 0 to 50 and only for `f`. An `Int` for `%f` is not converted (`n.to_f`, as everywhere).

**The format string must be a literal, checked at compile time.** The checker cannot check a format string that is only known at run time, so the choice was a literal checked by the compiler or a format string at run time that returns a `Result[String]`. The literal is chosen: the checker then knows how many arguments there are and their types, so a mistake is a compile error with a span inside the string, the result is a plain `String`, and nearly all real format strings are literals. A program that needs a format chosen at run time picks between literals.

**Checker rules:**

- `format` is a top-level name like `puts`, handled by the checker: the number of arguments depends on the literal, so it has no single catalog signature. Only the function name is reserved: a user `def format` is `CHECK-REDEFINED-NAME`, a breaking change accepted before 1.0. Variables, parameters and fields named `format` stay valid, since `format(...)` is a call and a variable is not callable.
- The first argument must be a plain string literal, without `#{...}`: `CHECK-FORMAT-LITERAL` otherwise, with a help to use interpolation for text that is built at run time.
- A bad conversion (unknown type, an unknown flag, a `%` at the end, `precision` on `d`, `x` or `s`, `0` on `s`, a width or precision out of range) is `CHECK-FORMAT-SPEC`, with the span of the conversion inside the literal.
- A wrong number of arguments is `CHECK-ARITY`; an argument of the wrong type is `CHECK-TYPE-MISMATCH` at the argument, with a secondary span at its conversion.
- `sprintf(...)`, `"%d" % x` and `String.format(...)` get a help that shows `format(...)`.

**Where the code lives.** By the std-first rule, padding, decimal and hex text are Agentica code in a prelude file, `stdlib/prelude/format.agc` (25.6; these functions use no type variables). One part is a builtin under exception 5 of the rule: `Float.to_fixed(x: Float, digits: Int) -> String` (digits 0 to 50, otherwise `RUNTIME-INVALID-COUNT`; NaN and the infinities give Ruby's `NaN`, `Inf` and `-Inf`), because correct decimal rounding of a binary `Float` needs exact arithmetic that would be fragile in Agentica; the VM calls `snprintf` with `%.*f`, and it is a public builtin, also a method (`x.to_fixed(2)`). The `Int` bit builtins of phase 13 are not needed: hex is written with division and `%`, and the smallest `Int` is handled as a special case.

**Lowering:** `lower.rkt` turns each call into a concatenation of the literal parts and calls to the prelude functions, one per conversion, so no format string is parsed at run time. No VM change other than the new builtin.

**Tests:** checker tests for each code with spans inside the literal; golden fixtures for every type, flag, width and precision, negative numbers, the smallest `Int`, NaN and the infinities, `%%`; `Float.to_fixed` (NaN and the infinities included) against vectors from a checked-in Python script (standard library only), including halfway cases such as `0.125` and `2.675`. **Docs:** `grammar.md` (builtin functions, §7 hints), the programming skill (`references/builtins.md`), `site/content/library/string.md` and `numbers.md`.

### 25.12 To evaluate later (Part B)

These may help, but each needs more design, a real program that asks for it, or another feature first. None is planned; each needs its own spec before a phase takes it.

#### 25.12.1 `case/in` pattern matching

**What:** Ruby 3's `case value in pattern`: nested patterns (`Shape.Box(Point(x, 0), _)`), struct patterns by field (`User(name:, age:)`), list patterns (`[first, *rest]`), and guards (`in x if x > 0`). **Why:** the most valuable item of this part; it removes nested `case` statements and lets agents write the Ruby they know. Today patterns are one level deep with no guards. **Why not now:** high complexity: exhaustiveness and unreachable-arm checks for nested patterns, list patterns with a rest, bindings in guards, and the lowering to a decision tree. **Open questions:** keep `->` arms or take `in`; how list rests fit immutable lists; which patterns `Map` gets; whether `case ... in` becomes an expression.

#### 25.12.2 Keyword arguments

**What:** `def connect(host: String, port: Int = 80)` called as `connect("a", port: 8080)`. **Why:** clearer calls with several defaults. **Why not now:** it comes after defaults (25.1); it changes the call rules, function values (`Fn` types have no names) and blocks. **Open questions:** whether every parameter may be named or only those with defaults; how a named argument mixes with a block.

#### 25.12.3 `loop do ... end`

**What:** Ruby's endless loop. **Why:** agents write it (section 11 rejects it and gives a help). **Why not now:** it would be a statement, not a block, because `break` cannot leave a block; `while true` already does the job. **Open questions:** whether the evaluation logs show enough of it to justify a statement that looks like a block.

#### 25.12.4 `then` and `tap`

**What:** `x.then do |v| ... end` and `x.tap do |v| ... end`. **Why:** pipelines in Ruby style. **Why not now:** they are methods on every type with a generic result, which the method rule (methods come from the receiver type's module) does not have. **Open questions:** a builtin rule for "any type" methods, as `to_s` and `inspect` have.

#### 25.12.5 Safe navigation `&.`

**What:** `user&.address&.city`. **Why:** short code for optional values. **Why not now:** `nil` is not a value of every type, so there is nothing to navigate; it needs optional types (`T?`) first. **Open questions:** whether `T?` comes at all, and how it relates to user `Option[T]` and to `JsonField` (§17).

#### 25.12.6 Destructuring

**What:** `a, b = pair`, block parameters `|(k, v)|`, multiple return values. **Why:** `partition`, `zip` and `Map` iteration read better. **Why not now:** it needs tuples ([section 12.5](12-data-structures.md#125-later)). **Open questions:** tuple syntax and types, and whether lists can be destructured with a length check.

#### 25.12.7 Lazy enumerators and generators

**What:** `(1..).lazy.select { ... }.first(3)`, `Enumerator.new`. **Why:** streams of unknown length without building lists. **Why not now:** it needs a way to suspend a computation; it should come after tasks and the multicore decision, which may give channels (§8). **Open questions:** whether a channel or a task covers the real use cases.

#### 25.12.8 Declarative hygienic macros

**What:** pattern-based macros like Rust's `macro_rules!`. **Why:** only if real cases appear that blocks, functions and the items above do not cover. **Why not now:** no such case is known. **Rules if it ever comes:** expansion before the checker, hygienic names, spans at the call site so diagnostics point at user code, and never procedural macros (25.13).

### 25.13 Decided against (Part C)

Each of these is decided; it gets a `help` that names the Agentica form where one exists.

- **Runtime metaprogramming:** `define_method`, `class_eval`, `instance_eval`, `method_missing`, `send`/`public_send`: the checker must know every call; use a `Map[String, Fn[...]]` to dispatch by name.
- **`respond_to?`:** already not planned (15.5): the answer is known at compile time.
- **Reflection:** `instance_variable_get`/`set`, listing fields or methods: it breaks static checking and makes the VM keep names at run time; `JSON.from` shows a value's fields.
- **`eval` and `binding`:** no code from strings at run time; the checker would not see it.
- **Monkey patching and refinements:** builtin types and modules are fixed; write a function.
- **Hooks** (`included`, `inherited`, `method_added`): there are no classes or mixins to hook.
- **Mixins** (`include`, `extend`, `Comparable`) **and the metatables idea of [section 7](07-metatables.md):** user types have no methods; a struct of `Fn` fields and wrapper functions cover the same need (the pattern below).
- **Duck typing:** a struct of `Fn` fields is the interface, checked by name (15.1).
- **Symbols:** `String` keys and enums cover them.
- **`freeze` and `dup`:** every value is already immutable.
- **`yield`:** the block is a named `Fn` parameter, called with `.call`.
- **`*args` and `**opts` splats:** a `List` or a struct parameter, and defaults (25.1).
- **`%w[...]`:** a list literal.
- **`raise`/`rescue`/`ensure`:** errors are `Result` values with `try`; `File.open` with a block (25.9) covers `ensure`.
- **User operator overloading, and overloading by argument type or by arity:** it breaks the inference of blocks and of empty literals (`[]`, `{}`) from the expected parameter type, makes diagnostics worse (which overload did you mean), and needs name mangling in the VM and the linker; defaults (25.1) cover arity. Struct equality (25.4) is provided by the compiler, not by the user.
- **General and procedural macros:** agents write worse code in custom DSLs, diagnostics land in expanded code, and they need a new stage; blocks, the compiler's equality (25.4) and spans that the compiler passes to `assert` and `std/log` cover the use cases.

**Composition instead of inheritance.** To "inherit" behavior:

1. The interface is a struct of `Fn` fields ([section 15.1](15-adapters-and-json-inspection.md#151-calling-fn-fields-without-call)), for example `Storage` with `get` and `put`.
2. A wrapper (decorator) function takes a base value and returns a new one with some fields replaced, keeping the others: `def logged(base: Storage) -> Storage` returns `base.with(get: ...)` (25.3), where the new `get` logs and then calls `base.get`.
3. A facade module passes on names from other modules with re-exports (25.2), like Elixir's `defdelegate`.
