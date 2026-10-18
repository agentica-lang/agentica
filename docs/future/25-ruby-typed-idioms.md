## 25. Ruby typed idioms

**Status:** Part A is planned (roadmap phase 15), after 7i deletes the evaluator
(order 7.2): 25.1 (defaults, front end only) as order row 7.5a, built after the
bootstrap; 25.2, 25.4, 25.5, 25.9 and 25.10 at order step 7.6, after the strict
diagnostics of [section 26](26-strict-diagnostics.md#26-strict-diagnostics); and
the prelude part, 25.6 and 25.11, at order step 8.2, after faster lists (8d).
25.7 and 25.8 were moved to Part C. Part B (25.12) lists ideas to evaluate
later. Part C (25.13) lists ideas that were decided against, so they are not
proposed again. Decided by the user on 2026-10-12. 25.1 (default parameter
values) is implemented (roadmap item 15a, order row 7.5a, in `compiler/`). 25.3
(struct update `with`) is implemented (roadmap item 15c, moved before the
bootstrap on 2026-10-15). 25.14 (the pipe operator) is implemented (roadmap item
15l, order row 7.2.1g). 25.10 (heredocs) is implemented (roadmap item 15j,
post-bootstrap step 5, in `compiler/`; see "As built" at the end of 25.10).
25.6 (the compiler prelude and the Enumerable methods) is implemented (roadmap
item 15f; see "As built" at the end of 25.6); 25.11 (`format`) is still planned.

Agentica is "Ruby with types" for LLM agents. This section takes more Ruby forms
that models already know, with this rule: accept a form when it is real Ruby (or
a typed version of it) or when it makes Agentica consistent with itself, and
keep static checking and immutable values. A form from another language is not
accepted: its hint names the Agentica form, and a newly accepted form is checked
with a second model in an evaluation round. Three limits do not move:
no OOP (no classes, no inheritance, no user methods on user types), no user
generics, and values stay immutable.

**Principle: one way to do each thing.** Strictness wins, so agents are precise.
A Ruby form is worth adding only when it does not create a second way to write
something the language already has. Where it would, it is not accepted: the
parser or the checker gives a diagnostic whose help shows the canonical form.
This sharpens that rule. The same principle is
why Agentica has no warnings: a diagnostic is an error or it does not exist
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
Part C, and each Part A item that overlaps an existing form names the canonical
one.

**How Part A lands.**

- Everything here comes after 7i deletes the evaluator (order 7.2); the prelude
  part (25.6, 25.11) also waits for faster lists (8d, order step 8), because its
  cost contract needs them. Each item changes the front end (`src/lexer.rkt`,
  `src/parser.rkt`, `src/modules.rkt`, `src/checker.rkt`) and `src/lower.rkt`,
  and runs on the C VM. No item touches `src/evaluator.rkt`.
- Most items are sugar that `lower.rkt` turns into code the VM already runs, so
  the bytecode format and the VM do not change. Five items change the VM, and
  three of them bump the bytecode format version, since any change to the layout
  or to an opcode's meaning does (`docs/vm/03-ir-and-bytecode.md` §4): 25.3 adds
  the `STRUCT_WITH` opcode and the Updates section (format version 4, built);
  25.4 widens the `EQ` and `NE` opcodes (format version bump); 25.6 adds a
  prelude flag on functions, argument spans on prelude calls, a name-only source
  entry per prelude file, the error-span rule, the prelude-only builtin
  `__fail_arg` and the public builtin `String.compare` (format version bump);
  25.9 appends the builtin `File.eof?` (no bump); and 25.11 appends the
  prelude-only builtin `__float_fixed` (no bump).
- Library work follows the roadmap rule [New library features: `std/`
  first](../roadmap/README.md#new-library-features-std-first): pure computation
  is written in Agentica, and C is only for its exceptions. 25.6 and 25.11 need
  one small mechanism for this, the compiler prelude (25.6).
- **The skill's budget.** `SKILL.md` stays near 5,000 tokens, so it gets only
  the core-language items, each in a few lines: defaults, `with`, equality,
  lambdas and heredocs. Library detail (the Enumerable methods, `format`,
  `File.open` with a block, re-exports) goes to the matching `references/` file
  (`builtins.md`, `files.md`, `modules.md`).
- Each item is its own PR, with the grammar (`docs/grammar.md`), the programming
  skill (`.agents/skills/agentica-programming/SKILL.md` and the matching
  `references/` file), the site page, the development skill's notes and tests.
  When an item lands, its text moves to `grammar.md` and is deleted here.
- **Tests** in each PR: parser, lexer and checker tests that assert the
  diagnostic code and span (`tests/parser-test.rkt`, `tests/lexer-test.rkt`,
  `tests/checker-test.rkt`, `tests/modules-test.rkt`); the golden fixtures
  (`tests/fixtures/vm/*.expected`: exit code, stdout, stderr and diagnostic code
  on the VM); and the runnable `agentica` blocks of the site page, which
  `tests/site-examples-test.rkt` checks.
- **Evaluation.** Section 11's rule holds: before the programming skill teaches
  a new form as the main style, an evaluation round with a second model checks
  that agents use it well (`tests/eval/run.py`).

- **§:** 25.1
  - **Item:** Default parameter values
  - **Layers:** parser, linker, checker, lowering
  - **New diagnostic codes:** `CHECK-DEFAULT-ORDER`, `CHECK-DEFAULT-VALUE`

- **§:** 25.2
  - **Item:** Re-exports
  - **Layers:** parser, linker
  - **New diagnostic codes:** none

- **§:** 25.3
  - **Item:** `value.with(field: x)`
  - **Layers:** parser, linker, checker, lowering, VM `STRUCT_WITH`
  - **New diagnostic codes:** none

- **§:** 25.4
  - **Item:** Value equality for data
  - **Layers:** checker, VM `EQ`/`NE`
  - **New diagnostic codes:** none

- **§:** 25.5
  - **Item:** Standalone lambdas
  - **Layers:** lexer (`lambda` reserved), parser, linker, checker, lowering
  - **New diagnostic codes:** none

- **§:** 25.6
  - **Item:** More Enumerable methods (after 8d)
  - **Layers:** catalog, prelude, checker, lowering, VM error spans
  - **New diagnostic codes:** none

- **§:** 25.7
  - **Item:** `unless`: moved to Part C

- **§:** 25.8
  - **Item:** Statement modifiers: moved to Part C

- **§:** 25.9
  - **Item:** `File.open` with a block
  - **Layers:** catalog, checker, lowering, VM builtin (`File.eof?`)
  - **New diagnostic codes:** none

- **§:** 25.10
  - **Item:** Heredocs `<<~NAME`
  - **Layers:** lexer, parser (heredoc flag on the AST string node)
  - **New diagnostic codes:** `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT`,
    `LEX-HEREDOC-ONE-LINE`

- **§:** 25.11
  - **Item:** `format` (after 8d)
  - **Layers:** catalog (linker name), checker, prelude, lowering, one
    prelude-only builtin
  - **New diagnostic codes:** `CHECK-FORMAT-LITERAL`, `CHECK-FORMAT-SPEC`

- **§:** 25.14
  - **Item:** Pipe operator `\|>`
  - **Layers:** lexer, parser, checker
  - **New diagnostic codes:** `PARSE-PIPE-TARGET`, `CHECK-PIPE-METHOD`

### 25.1 Default parameter values

Implemented in 15a: the rules are in `grammar` ("Default parameter values" in
`docs/grammar/06-semantics.md`). This section keeps the design notes. It was
built in `compiler/` (the Racket front end named below is gone): the parser
reads `= expression` after the type (`Ast.Param.default`), the linker resolves
the default in the declaring module (`rewrite.agc`), `check_defaults.agc` has
the order and value checks and the type check, `defaults.agc` has the argument
rules that the checker and the lowering share, and `lowering` emits the missing
arguments at the call site (`lower_expr.agc`). The simplest choices where the
design left room: the order and value checks run when the function is
registered, the type check with the function; a default may not read a module
constant; the arity message gives the range only for a function with defaults.

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

The parser takes any expression after `=`, so the checker can give a clear
diagnostic for one that is not allowed.

**Checker rules:**

- **Defaults only at the end.** After a parameter with a default, every
  parameter has a default, except a last parameter of type `Fn[...]`, which
  stays without one so a block can still fill it (an `Fn` parameter has no
  default):
  `def each_line(path: String, timeout_ms: Int = 1000, f: Fn[String, Void]) ->
Void`.
  Anything else is `CHECK-DEFAULT-ORDER` at the parameter without a default.
- **A default is a constant:** an `Int`, `Float` or `String` literal (a minus
  sign allowed before a number; no `#{...}` in the string), `true`, `false`,
  `nil`, `[]`, `{}`, or a nullary enum variant (`Level.Info`, `LogLevel.Info`
  for a builtin enum, or `Models.Level.Info` through an import alias). Anything
  else (a call, a variable, `&name`, a struct, an interpolated string) is
  `CHECK-DEFAULT-VALUE` at the expression, with a help that says to make the
  parameter required.
- **Its type** is checked against the parameter type, like an initializer: `[]`
  and `{}` take the parameter type as their expected type, and a mismatch is
  `CHECK-TYPE-MISMATCH` at the default.
- **Fresh at each call.** The default is built at each call; no call shares a
  value with another. Since values are immutable, Python's shared mutable
  default cannot happen anyway.
- **Calls** to a function with `N` required parameters and `M` in all take `N`
  to `M` arguments; otherwise `CHECK-ARITY`, whose message says the range
  ("expects 1 to 2 arguments"). Arguments fill parameters from the left. When
  the last parameter is a `Fn` without a default, the block, or else the last
  argument, always goes to it, and the other arguments fill the parameters
  before it from the left: with `each_line` above,
  `each_line("a.txt") do |l| ... end` and `each_line("a.txt", 50, &show)` both
  work.
- Defaults apply to direct calls, through an import alias too (`Util.join(xs)`).
  An import-alias call that drops its parentheses (`grammar.md`, "Expressions
  and precedence") may fill all its defaults: `x = Util.connect` is valid when
  every parameter of `connect` has a default. A function value always takes
  every argument: `&join` has type `Fn[List[String], String, String]`, and
  `.call` needs both.
- Defaults are part of an exported signature. `main` still takes no parameters.
  Blocks and lambdas (25.5) take no defaults.
- This replaces overloading by arity, which user functions do not get (25.13).
  The builtin catalog keeps its few arity overloads (`Map.get`, `HTTP.client`,
  `ok`/`ok()`, and the 4-argument `File.open` of 25.9).

**Linker:** a default such as `Level.Info` (or `Models.Level.Info` through an
alias) is resolved in the module that declares the function, by the linker like
any other name there, before `lower.rkt` copies it to a call site in another
module; so the copy never depends on the caller's aliases.

**Lowering:** the checker records the full argument list on the call;
`lower.rkt` emits the missing arguments as constants at the call site (a
constant load, an empty list or map, or an `enum` instruction for a nullary enum
variant). Every call in the bytecode passes all its arguments, so the bytecode
and the VM do not change.

**`std/logger`:** this item did not block it. The logger had two functions per
level (`info` and `info_meta`, [section 24.2](24-logging.md#242-stdlogger)).
When this item landed, `std/logger` dropped its `_meta` functions, and each
level function takes an optional `fields` parameter with the default `{}`. That
was a breaking change, which the owner accepted, since the language has no
outside users.

**Tests:** parsing and spans; each code; `each_line("a.txt", 50)` with no block,
which passes `50` to `f` and gives `CHECK-TYPE-MISMATCH`, not `CHECK-ARITY`;
`CHECK-ARITY` with a range; `[]` and `{}` typed by the parameter; a block after
defaulted parameters; a call through an import alias, and `x = Util.connect`
without parentheses when every parameter has a default; an exported function
with an enum default (`level: Level = Level.Info`) called from another module
that does not import the enum's file; a golden fixture with calls that leave out
0, 1 and 2 arguments. **Docs:** `grammar.md` (the `parameter` rule; "Functions
and entry point" drops "no default values"), the programming skill (`SKILL.md`,
functions, and `references/diagnostics.md` for the new codes),
`site/content/tour/functions.md`.

### 25.2 Re-exports

Like Elixir's `defdelegate`, a module can pass on a name it imports, so a small
facade module can collect the API of several files:

```agentica
# web.agc
import Url from "url"
import Parts from "http_parts"

export Url.parse
export Url.Address
export Parts.header_value
```

```agentica
import Web from "web"

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

There is no clash with today's grammar: `export` is followed only by `def`,
`struct` or `enum`, which are reserved words, so a `TYPE_NAME` after `export` is
free. There is no renaming (`as`): one thing keeps one name, and a facade that
wants another name writes a wrapper function. There are no wildcards
(`export Url.*`), as for imports.

**One way:** a re-export passes the one-way test. It replaces a one-line
forwarding wrapper (`def parse(s: String) -> Result[Url.Address]` calling
`Url.parse(s)`), not an existing form: it keeps one declaration and one identity
(`&Web.parse` and `&Url.parse` are the same function), and the facade cannot
drift from the original. The skill teaches the re-export as the canonical form;
the checker cannot reject a hand-written wrapper, as with `with`.

**Rules**, all in the linker (`src/modules.rkt`):

- The alias must be an import of this file: otherwise `CHECK-IMPORT-NAME` with
  the help "unknown module alias", decided in the linker. The name must be
  exported by that module (`CHECK-IMPORT-NAME`, with the "did you mean" help
  that §24.2 (D9) added).
- Re-exports are resolved after the file's imports are visited. Today the
  linker's `visit` fills a module's exports before it visits its imports, so
  this changes the order: the plain exports are filled first, the imports are
  visited, then the re-exports are added from the imported modules' finished
  exports.
- The name joins this module's exports. The export entry keeps the original
  module's key (its canonical path) and name, not this file's, so the importer
  resolves to the original declaration. It must not collide with a declaration
  of this file, another re-export or one of the file's import aliases
  (`CHECK-REDEFINED-NAME`).
- Inside the file, the name is still `Url.parse`: a re-export adds no local
  name.
- It is the same declaration, not a copy. A program that imports both `web.agc`
  and `url.agc` sees `Web.Address` and `Url.Address` as one type. A chain (a
  re-export of a re-export) leads to the original declaration; a cycle cannot
  happen, since import cycles are already `CHECK-IMPORT-CYCLE`. A re-exported
  enum brings its variants (`Web.Option.Some(x)`).
- Re-exports follow the blank-line rule of imports (`grammar.md`, "File and
  declarations"): they may follow each other and the imports directly, and one
  after a declaration needs the blank line (`PARSE-MISSING-BLANK-LINE`).
- An exported signature may still mention a private type that importers cannot
  name, as today.
- A re-export counts as a use of its alias for `CHECK-UNUSED-IMPORT` ([section
  26.1](26-strict-diagnostics.md#261-unused-imports)), so a facade that only
  re-exports is valid.

**Lowering:** none. The linker resolves `Web.parse` to the original declaration
before the checker runs, so the checker, `lower.rkt` and the VM see the original
function. `&Web.parse` is a normal function value.

**Tests:** in `tests/modules-test.rkt`: a facade over two files; a facade that
only re-exports (no `CHECK-UNUSED-IMPORT`); a chain of two re-exports; the same
type through two aliases; an enum's variants; the error cases (unknown alias,
unknown name, a name that collides with a declaration, a re-export or an import
alias); a golden fixture. **Docs:** `grammar.md` ("File modules and imports":
"Imports cannot be re-exported" changes), the programming skill
(`references/modules.md`), `site/content/tour/modules.md`.

### 25.3 Struct update with `with`

Implemented in 15c: the rules are in `grammar.md` ("Structs and lists"). This
section keeps the design notes. The owner moved it before the bootstrap
(2026-10-15), because `compiler/` uses immutable struct updates. It relaxes the
freeze of row 7.2.7 (it adds syntax to both parsers and rules to the checker),
and the checker port carries it.

Like Ruby's `Data#with`: a copy of a struct with some fields changed. The
original is unchanged.

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

**Syntax:** `postfix_expr` gets one more form,
`".", "with", "(", named_arguments, ")"`. `with` is not a reserved word; it has
this meaning only after a `.` and before `(` in the postfix loop, and its
arguments are always named. `Alias.with(...)` (a `TYPE_NAME` before the dot)
stays a module call, since a module call is parsed as a primary, not in the
postfix loop.

**One way:** `with` is the canonical way to change some fields of an existing
value; a constructor with every field is the way to build a new one. The checker
does not reject a constructor that copies fields by hand, since it cannot tell
intent, but the skill teaches `with`.

**Checker rules:**

- The receiver must be a struct (`CHECK-UNKNOWN-METHOD` on any other type, with
  a help for structs). Each name must be a field of it (`CHECK-UNKNOWN-FIELD`),
  given at most once (`CHECK-DUPLICATE-FIELD`), with a value of the field's type
  (`CHECK-TYPE-MISMATCH`; `[]` and `{}` take the field type).
- A bare `ana.with(...)` whose result is dropped is `CHECK-UNUSED-VALUE`, like a
  bare `xs.push(4)`: values are immutable, so the call would change nothing.
- At least one field: `ana.with()` is `PARSE-UNEXPECTED-TOKEN`, since
  `named_arguments` needs at least one argument. A positional argument
  (`ana.with(31)`) is `PARSE-UNEXPECTED-TOKEN`, with a help that shows
  `with(age: 31)`.
- `with` builds a new value of the struct's type, so it follows the rules of
  construction: for a type that another module keeps private, it gives the same
  diagnostic as constructing it (`CHECK-IMPORT-NAME`; the linker gives the node
  a `visible` predicate: the structs of the file, and the exported structs of
  the modules it imports directly; a closure in the node today, so the
  self-hosted linker turns it into data, §18.3 step 3). With generic structs
  (15.3) the type arguments stay, so a field's new value has the same type as
  before: `.with(` always parses as the update, and each field is checked after
  the struct's type arguments are substituted.
- A field named `with` whose type is `Fn[...]` is `CHECK-REDEFINED-NAME`. (A
  field named `with` whose type is a type parameter is banned where generic
  structs land, [section
  15.3](15-adapters-and-json-inspection.md#153-generic-structs), roadmap 10c.)
  The rule is added here, in advance, so that calling `Fn` fields without
  `.call` (10a, §15.1) stays a non-breaking change; otherwise `user.with(...)`
  would clash with calling an `Fn` field without `.call` (15.1). A data field
  named `with` stays valid, so a JSON object with a `"with"` key still decodes
  into a struct; `value.with` without parentheses reads that field, and
  `value.with(...)` is always the update.
- **Named arguments appear only here and in struct construction**
  (`User(name: ..., age: ...)`). Calls to functions stay positional; keyword
  arguments are decided against (25.13).

**Lowering:** the receiver is evaluated once, then the new values left to right;
every value sees the old struct. The first plan was today's construction
instruction, reading the fields that do not change from the receiver, with no VM
change. It was measured against one new instruction, `STRUCT_WITH`, which copies
the struct and writes the given fields (the field indexes are resolved at lower
time and kept in the Updates section of the bytecode, format version 4). The
instruction is about 8 percent slower for a 2-field struct and 15 to 34 percent
faster for a struct of 4 to 16 fields (the lexer-state case), so the instruction
stayed (numbers in the PR of 15c, and in `docs/vm-benchmarks.md`).

**Tests:** each code; a struct from an imported module; nested use
(`a.with(address: a.address.with(city: "Lima"))`); evaluation order with calls
that print; a golden fixture, with an independent Python peer; the loader rules
of the Updates section and a hostile receiver in `loader_test.c`. **Docs:**
`grammar.md` ("Structs and lists"), the programming skill (`SKILL.md`),
`site/content/tour/structs.md`.

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

`List.member?` (§25.6) uses this wider equality: it takes any element type
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

**Already built for `Test.eq`** (phase 25a,
[`docs/roadmap/25-unit-tests.md`](../roadmap/25-unit-tests.md)): the checker's
type predicate for the set above plus `Json` (`data-type?`) and the deep compare
`agc_equal` in `vm/equal.c` (one explicit stack of value pairs, Floats by IEEE
754, maps by key in any order). This item reuses them for `==` and `!=`.

**VM:** the `EQ` and `NE` opcodes compare structs, enums, lists, maps and
Results by value, with an explicit stack (no C recursion, so deep values cannot
overflow the C stack), and charge a turn cost for their work as they already do
for long strings (`docs/vm/10-io-scheduler.md` §10.2.1). The checker rules out
`Fn` and handles; as a backstop, `EQ` raises `RUNTIME-INTERNAL` if it meets one
(a crafted `.agcb`). One equality function per type generated by `lower.rkt` was
not chosen: it needs a function per struct, list and map type used with `==`,
while the VM already knows the shape of every value. `case` patterns are
unchanged.

**Format version:** the wider `EQ` and `NE` change what an opcode means, so this
PR bumps the bytecode format version (`docs/vm/03-ir-and-bytecode.md` §4: any
change to an opcode's meaning bumps it). A new opcode (`EQ_DEEP`) was not
chosen: the front end and the VM ship together, and one opcode is simpler than
two.

**Tests:** checker tests for each kind and for a struct with an `Fn` field (code
and secondary span); `r == error("not found")`, `opt == Option.None`, `xs == []`
and `[] == xs` (the `.size == 0` help, with the literal on either side), two
mutually recursive structs `A` and `B` where only `B` has an `Fn` field (both
`a1 == a2` and `b1 == b2` are rejected), and `error("a") == error("b")` (neither
side gives a type); golden fixtures for nested structs, lists of structs, maps
in another order, enums, Results, `ok() == ok()`, a NaN field; a deep recursive
value for the explicit stack (a `struct Node` with `children: List[Node]`,
100,000 levels deep, built with a loop); a C test of the opcode, including the
`RUNTIME-INTERNAL` backstop on an `Fn`. **Docs:** `grammar.md` ("Operators":
"The core has no list or struct equality" changes; "Maps": "There is no map
equality" changes; "Result and propagation": "Results have no equality"
changes), the programming skill, `site/content/tour/structs.md`, `lists.md`,
`maps.md`, `results-and-try.md` and `enums-and-case.md`,
`site/content/library/errors/result.md`, `docs/vm/03-ir-and-bytecode.md` §4.2
(`EQ` and `NE` on these pairs are no longer `RUNTIME-INTERNAL`), and
`docs/vm/10-io-scheduler.md` §10.2.1 (its "`==` only on scalars, strings and
ranges" text, and the turn cost of the wider `EQ`).

### 25.5 Standalone lambdas

Planned here.

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
  block with no call changes, and is not removed: `lambda do` leaves it, and
  `fn(x: Int)` and a `do` block with no call now get a help that shows
  `lambda do |x: Int| ... end`.

**Lowering:** the same closure as a block passed to a call; no VM change.

**Tests:** parser tests; annotated and expected-type forms; a `lambda` literal
as the last argument where the last parameter is an `Fn` (`CHECK-BLOCK-TARGET`
with the trailing-block help), `g.call(1, lambda do |x: Int| x end)` (valid),
and the valid places (a variable, a field, a list element, a non-last argument,
a return); `CHECK-BLOCK-TYPE`; `try` with and without an expected type; a lambda
stored in a struct's `Fn` field and in a `Map[String, Fn[...]]`; a lambda with
an unused parameter, a statement after `return`, and a dropped `Result` (the
three section 26 codes); a golden fixture. **Docs:** `grammar.md` ("Blocks and
closures", the reserved words, the §7 hint row), the programming skill
(`SKILL.md` and its adapter examples), `site/content/tour/blocks.md` and the
site's adapter examples, and [section
15.1](15-adapters-and-json-inspection.md#151-calling-fn-fields-without-call),
whose `getter`/`putter` helpers are replaced by `lambda` once lambdas land.

### 25.6 More Enumerable methods

**What exists today:** the `List`, `Range` and `Map` functions and methods are
in [`docs/grammar/06b-builtins.md`](../grammar/06b-builtins.md) and
[`06-semantics.md`](../grammar/06-semantics.md) ("Ranges"), and in
`src/builtins.rkt`. `tally` and `zip` do not exist yet. This item adds the
missing ones:

```text
List.find(list: List[A], f: Fn[A, Bool]) -> Result[A]
List.each_with_index(list: List[A], f: Fn[A, Int, Void]) -> Void
List.flat_map(list: List[A], f: Fn[A, List[B]]) -> List[B]
List.partition(list: List[A], f: Fn[A, Bool]) -> List[List[A]]
List.take_while(list: List[A], f: Fn[A, Bool]) -> List[A]
List.drop_while(list: List[A], f: Fn[A, Bool]) -> List[A]
List.each_slice(list: List[A], size: Int) -> List[List[A]]
List.group_by(list: List[A], key: Fn[A, K]) -> Map[K, List[A]]       # K is Int or String
List.tally(list: List[K]) -> Map[K, Int]                              # K is Int or String
List.uniq(list: List[K]) -> List[K]                                   # K is Int or String
List.sum(list: List[N]) -> N                                          # N is Int or Float
List.min_by(list: List[A], key: Fn[A, O]) -> Result[A]                # O is Int, Float or String
List.max_by(list: List[A], key: Fn[A, O]) -> Result[A]
Map.each(map: Map[K, V], f: Fn[K, V, Void]) -> Void
Map.filter(map: Map[K, V], f: Fn[K, V, Bool]) -> Map[K, V]
```

**Rules:**

- All are methods by the existing rule (`xs.find do |x| ... end`), keep their
  inputs, run callbacks once per element left to right (`find`, `take_while` and
  `drop_while` stop where the answer is known), and use the caller's step
  budget.
- **No new aliases.** Each method has one name. Where Ruby has two names, the
  one Agentica already has wins: `filter` (not `select`), `map` (not `collect`),
  `find` (not `detect`), `reduce` (not `inject`). The other name is
  `CHECK-UNKNOWN-METHOD` with a help that names the canonical method, in the
  foreign-habit hint table of `grammar.md` §7. The already shipped aliases
  (`length`, `push`, `strip`, `to_i`, ...) stay as they are; no
  new ones are added.
- **No second ways.** `reject` is not added: it is `filter` with `!` (help:
  `xs.filter do |x| !cond end`). The `Range` methods that Ruby's `Enumerable`
  gives (`select`, `map`, `find`, `sum`) are not added: they are `r.to_a` and
  then the `List` method (help: `(1..5).to_a.map do ... end`). `each_slice` has
  no block form: it returns the slices, and a block after it is
  `CHECK-BLOCK-TARGET` with a help that shows
  `xs.each_slice(2).each do |pair| ... end`.
- Ruby returns `nil` from `find`, `min_by` and `max_by` when nothing matches;
  here they return `error("not found")` or `error("the list is empty")`, like
  `Range.first`. Ties in `min_by` and `max_by` go to the first element, as
  `sort_by` keeps equal keys in order. A NaN key never wins `min_by` or `max_by`
  unless every key is NaN (then the first element wins), which matches `sort_by`
  putting NaN last. String keys compare by code point with the new builtin
  `String.compare(a: String, b: String) -> Int` (-1, 0 or 1, the order `sort`
  uses), since `<` takes only numbers; it is public and also a method
  (`a.compare(b)`), under exception 5 of the std-first rule (a basic operation
  on a core type).
- `partition` returns two lists, `[yes, no]`, since there are no tuples (12.5);
  with destructuring (Part B) it would read like Ruby.
- `each_slice(n)` returns the slices. `n < 1` is `RUNTIME-INVALID-COUNT`. The
  last slice may be shorter.
- `group_by` and `tally` keep the order in which keys first appear; `uniq` keeps
  the first copy of each value. The restrictions are written per catalog entry
  (the comments above): `group_by`, `tally` and `uniq` take the map key types,
  `sum` takes `Int` or `Float`, and `min_by` and `max_by` take `List.sort_by`'s
  key types; another type is `CHECK-TYPE-MISMATCH`, as for `sort`.
- `sum` of an empty list is `0` or `0.0`; an `Int` sum that does not fit is
  `RUNTIME-INTEGER-OVERFLOW`.
- `Map.each` and `Map.filter` go in insertion order; their blocks take two
  parameters (`do |k, v|`).
- **Not here:** `zip` needs tuples to be typed (`List[(A, B)]`); it waits for
  them (roadmap 8's "Later" list, and destructuring in Part B). `List.member?`
  is this item's. `count` stays out (`size` is the only count).

**Where the code lives: the compiler prelude.** By the std-first rule these are
Agentica code, not C. But a `std/` module cannot hold them today, for two
reasons: a user function cannot be generic, and a user function cannot be called
as a method. So this item adds one small mechanism, the **compiler prelude**:

1. Each function above has a normal entry in the builtin catalog
   (`src/builtins.rkt`): signature with the catalog's type variables, help text,
   and a mark that its body is a prelude function. The checker checks calls
   against the entry like any builtin (methods are resolved by receiver type in
   `resolve-method`, `src/checker.rkt`), so call sites, methods, aliases, blocks
   and `agentica help` work as for `List.map`. Nothing new for users.
2. The bodies live in `stdlib/prelude/list.agc` (and `map.agc`), written in
   Agentica on the existing builtins. Only prelude files may use the catalog's
   type variables (`A`, `B`, `K`, ...); user code still cannot. The checker
   checks a prelude body with each type variable as an opaque type: a value of
   type `A` can be stored, put in a list, a map value or a Result, used as a map
   key when the variable is limited to the map key types, returned, and passed
   to an `Fn` that takes `A`, and nothing else. In the prelude, `Map`'s key
   variable is always limited to the map key types, so `Map.filter` and
   `Map.each` are checked once per allowed key type, like `uniq`. Type-variable
   restrictions belong to each catalog entry, not to a letter (the same letter
   can mean different things in two entries): an entry may restrict a variable
   to a short list of types (`group_by`'s key to `Int` or `String`), and such an
   entry may have one body per allowed type, and the catalog entry names the
   body for each type: `List.sum` has `sum_int` and `sum_float`, since `0` and
   `0.0` and the two additions differ. A body that works for every allowed type
   (`uniq`, which only uses the value as a map key) may be one body, checked
   once per allowed type.
3. **Always linked, checked once.** The linker cannot know which prelude
   functions a program uses: methods and `format` are resolved by the checker,
   after linking. So the prelude modules are always linked into every program.
   They are checked once, when the compiler is built, and the result is cached
   with the embedded source (as `embed-source` embeds `std/` files in
   `src/stdlib.rkt`), so checking a user program does not pay for them.
   `lower.rkt` emits only the prelude functions reachable from the checked
   program (one copy per allowed type that is used, for restricted ones) and
   calls them like user functions. Prelude files are not importable through
   `std/`, and their names cannot clash with user names.

**Runtime errors inside prelude code** must look like errors of a builtin, never
of a file the user did not write. Two definitions first: blocks written in
prelude files are lowered with the prelude flag, like the prelude functions; and
a native frame (a `List.map`, `List.reduce`, `Int.times` or `Range.each` running
a block, `docs/vm/03-ir-and-bytecode.md` §4.3) whose caller is a prelude frame
belongs to the run of prelude frames: it is transparent to the rule, and its
call span is replaced the same way a prelude instruction's span is.

- A runtime diagnostic raised while a prelude function runs is reported at the
  user's call site, or at the argument the builtin rule names (as `List.take`
  reports `RUNTIME-INVALID-COUNT` at its count argument). For this, `lower.rkt`
  gives a call to a prelude function the call span and the argument spans, as
  `call-builtin` already has (`docs/vm/03-ir-and-bytecode.md`), and marks
  prelude functions in the bytecode. When the VM raises a diagnostic in a
  prelude frame, it uses the call site of the outermost frame of the innermost
  run of prelude frames: the call the user wrote. Example: user code calls
  `each_with_index` (prelude), which calls the user's block, which calls
  `xs.each_slice(0)` (prelude). The innermost run of prelude frames is
  `each_slice` alone, so the error points at the `each_slice` call inside the
  block, not at `each_with_index`.
- Prelude frames are skipped in stack traces (14b, [section
  24.3](24-logging.md#243-stack-traces-on-runtime-errors)), like native frames.
  A user block called from a prelude function keeps its own frame, so an error
  in the block shows the block and then the user's call.
- A prelude-only intrinsic, `__fail_arg(code, index, message)`, raises the given
  `RUNTIME-` code at argument `index` of the current prelude call. The current
  prelude call is the outermost frame of the innermost run of prelude frames, as
  in the span rule: the call the user wrote, even when one prelude function
  calls another. `each_slice` uses it for `RUNTIME-INVALID-COUNT` when `n < 1`
  (argument 1). It is a catalog entry in `src/builtins.rkt` with a prelude-only
  flag, so the linker keeps its name; the checker rejects it outside prelude
  modules (`CHECK-UNKNOWN-NAME`), and the loader check below stays. Prelude-only
  entries (`__fail_arg` and `__float_fixed`) are left out of `agentica help`,
  `agentica help --json` and every "did you mean" candidate list; a test checks
  all three.
- An overflow inside a prelude body (`sum`) is raised by the VM's own add
  instruction, so it is reported at the user's call by the first rule.
- **No tail calls into the prelude.** A call from user code to a prelude
  function always lowers to `call`, never `tail-call`, as `call-builtin` never
  is one: a tail call would replace the user's frame, and the span rule would
  lose the user's call. `return xs.each_slice(0)` in a user function reports the
  error at that call. A tail call from one prelude function to another may stay,
  since the frame it replaces is also a prelude frame. A prelude body never
  tail-calls the user's `Fn` either: `f.call(...)` in prelude code lowers to
  `call`, never `tail-call`, so the prelude frame stays under the user's block
  for the span rule.

**Cost contract, and why the prelude waits for 8d.** Every prelude function is
O(n) in its input, plus its callbacks, and each callback runs once per element
(`find`, `take_while` and `drop_while` stop early). On today's VM, lists are
flat arrays: `LIST_GET` is O(1), but `List.append`, `List.concat`, `List.take`
and `List.drop` copy (`builtin_list_concat` copies both lists, and `take` and
`drop` go through `list_slice`). So any Agentica loop that builds a list one
element at a time is O(n²) today, whatever the technique. Until faster lists
(8d) land, the existing native `List.map`, `List.filter` and `List.reduce` stay
the only list builders, and the prelude does not start.

After 8d, a list is a persistent vector
([`docs/vm/17-lists.md`](../vm/17-lists.md)): `push` (`List.append`), `set`
and indexing are O(log32 n), near constant. Section 12.4 states nothing for the
other list operations, so the prelude counts `concat`, `take`, `drop`,
`reverse`, `sort` and `sort_by` as O(n), as today. The bodies:

- build their result with `push` in one pass, or on `map`, `filter` and `reduce`
  where they fit (`each_with_index` walks with `reduce` and a counter);
- read with indexing or `List.at` where needed;
- never call `concat`, `take`, `drop`, `reverse`, `sort`, `sort_by`, `Map.keys`,
  `Map.values` or `Map.delete` inside a loop or a callback (all O(n)); once,
  outside any loop, they are fine.

The `grammar.md` table lists each function's cost, as it does for today's list
operations.

**VM and bytecode format.** This item changes the bytecode format, so it bumps
the format version (`docs/vm/03-ir-and-bytecode.md` §4):

- `src/bytecode.rkt` writes a prelude flag on each function, and the call span
  and argument spans on each call to a prelude function (as `call-builtin`
  already carries several spans).
- `__fail_arg` is a builtin in the VM's builtin table, called with
  `call-builtin`, not a new opcode: that is the simplest, since a builtin can
  already read the current frames and raise a diagnostic, and the interpreter
  loop does not change. With `__float_fixed` (25.11), it is one of the guarded
  exceptions to "no internal helper builtins" (`docs/vm/03-ir-and-bytecode.md`
  §4.5), and the loader guards both.
- The loader (`vm/loader.c`) checks the flag (0 or 1) and rejects a file that
  calls a prelude-only builtin (`__fail_arg`, `__float_fixed`) from a function
  without the prelude flag (`docs/vm/08-loader-and-cli.md`).
- **Static spans.** Prelude source text is not embedded. Each prelude file gets
  one entry in the Sources section with its name (`<prelude>/list.agc`) and
  empty text, and one span on it, `1:1-1:1`; that span is each prelude
  function's declaration span and the span of all its instructions. The loader
  accepts it as it is: an empty text has one line of length 0, and column 1 is
  valid (`docs/vm/08-loader-and-cli.md`, "Spans"). Span index 0 was the other
  choice, but it is the program's span and would point into user code.
- **The VM always replaces that span at run time** with the span rule above.
  Every reader of an instruction's span applies the rule when the frame is a
  prelude frame: `RUNTIME-STEP-LIMIT` at a `STEP` (including the extra spans
  `s + k` of a merged step) and at the step a counting native frame charges at
  its call's span, `RUNTIME-INTERNAL`, every other runtime diagnostic
  (`agc_fail`), 14a tracing where a trace line names a place, and 14b stack
  traces (which skip prelude frames). If the rule finds no user frame (a crafted
  `.agcb` that puts the prelude flag on `main`, or on the entry of a task
  spawned from user code), the VM falls back to the static prelude span; a VM
  test loads such a file and checks that the run fails with that span and does
  not crash. Other crafted inputs, each with a VM or loader test: `__fail_arg`'s
  index is checked at run time, and an index past the call's argument spans
  falls back to the call span, or to the static prelude span when there is no
  call span; its code must start with `RUNTIME-`, or the result is
  `RUNTIME-INTERNAL`; the loader rejects argument spans on a `CALL` whose target
  lacks the prelude flag; and a prelude-flagged function reached through
  `CALL_VALUE` or `TAIL_CALL` from a non-prelude frame uses the call-span
  fallback. A test runs a prelude function with `--max-steps` small enough to
  stop inside it and checks the span. Golden tests also cover an overflow inside
  a `reduce`-based `sum` (the run is `sum`, the native `reduce`, the prelude
  block: the error points at the user's `sum` call) and a step limit hit inside
  an `Int.times` or `Range.each` loop of a prelude body.

These, with the span rule, are the only VM changes of this item: the prelude
flag, the argument spans on prelude calls, the name-only sources, `__fail_arg`,
and the public builtin `String.compare`.

This is not user generics: only files that ship with the compiler use type
variables, and only behind catalog signatures. A function moves to C later only
when a measurement shows it is hot, as the std-first rule says; its catalog
entry stays the same.

**Tests:** each function on lists of `Int`, `String` and structs, empty lists
and the edge cases above, golden fixtures, the site examples, and checker tests
for the restricted type variables and for a prelude body that misuses an opaque
type. Runtime errors, with fixed expected stderr (span and stack):
`each_slice(0)` (count error at the argument), an `Int` `sum` that overflows (at
the call), and an error inside the user's block reached through a prelude
function (the block's frame, then the user's call; no prelude frame).
`return xs.each_slice(0)` inside a user function (the error at that call, not
lost to a tail call). Cost: a golden fixture runs each function on a
100,000-element list and records the step count, so a body that loops more than
once per element changes the golden; and a test reads the prelude sources and
rejects `concat`, `take`, `drop`, `reverse`, `sort`, `sort_by`, `Map.keys`,
`Map.values` and `Map.delete` inside a loop, a block or a callback, since an
O(n) builtin in a loop is quadratic in time but not in steps. Checker tests for
the hints: `select`, `collect`, `detect`, `inject` and `reject`
(`CHECK-UNKNOWN-METHOD` with the canonical name), and a block after `each_slice`
(`CHECK-BLOCK-TARGET`). `min_by` and `max_by` with ties (first wins), with NaN
keys (NaN never wins unless all keys are NaN) and with String keys;
`String.compare` on equal strings, prefixes and non-ASCII text against Python's
code-point order. The nested case of the span rule (user, `each_with_index`,
block, `each_slice(0)`). A test that `__fail_arg` in user code is
`CHECK-UNKNOWN-NAME`, and a loader test that rejects a file calling it from a
function without the prelude flag. **Docs:** `grammar.md` (the `List` and `Map`
tables with each function's cost, and the §7 hint table), the programming skill
(`references/builtins.md`), `site/content/library/data-structures/list.md`,
`map.md` and `string.md` (`String.compare`), the development skill (the
prelude), `docs/vm/03-ir-and-bytecode.md` (the prelude flag, the call spans,
`__fail_arg`, the format version, and the §4.5 sentence "There are no internal
helper builtins", which gains the guarded exceptions) and
`docs/vm/08-loader-and-cli.md` (the loader checks).

**As built (2026-10-16, roadmap item 15f, in `compiler/`, `stdlib/prelude/` and
the VM).** The design above stands, with these choices where it left room or
named the Racket front end:

- The prelude is checked and attached for each program that calls a prelude
  method, not linked into every program and cached at build time: the checker
  records the function each call runs (`St.bodies`), and `compiler/prelude.agc`
  then reads the prelude files, parses the functions the program calls, renames
  them `@prelude::file::name` and checks them, with the node ids after those of
  the program. A program that calls no prelude method reads no prelude file.
  The cost is a check of those functions on each compile, and a test compiles a
  program that calls every method.
- A type variable of a prelude body is an opaque type (`Type.Var`), which
  `Cx.prelude` allows as a `Map` key or `Set` element, so `group_by`, `tally`,
  `uniq`, `Map.each` and `Map.filter` are checked once, not once for each key
  type. The limit of a variable (`group_by` on an `Int` or `String`) is checked
  at the call, `CHECK-TYPE-MISMATCH` at the argument that fixed the variable.
  `sum`, `min_by` and `max_by` have one body for each allowed type (`sum_int`,
  `min_by_string` ...), chosen by the checker.
- The prelude flag is not a field of the IR: a function has it when its source
  is named `<prelude>/...`. Calls of a prelude function in the IR are `call`
  with the argument spans after the call span.
- The loader checks that the argument spans of a call of a prelude function are
  in range. It cannot tell, from the bytecode, a `CALL` that carries them from
  one that does not, so it does not reject spans on a call of a function
  without the flag.
- The loader reads format 5 together with format 6 (the format of the
  checked-in `bootstrap/stage0.agcb`, which the first binary of the bootstrap
  still writes), until stage0 is refreshed.

### 25.7 `unless` (moved to Part C)

Decided against by the one-way principle: `unless c` is a second way to write
`if !c`. See 25.13 for the hint that replaces it.

### 25.8 Statement modifiers (moved to Part C)

Decided against by the one-way principle: `S if c` is a second way to write an
`if` statement. Section 11's rejection stays, with its help. See 25.13.

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
`File.eof?(handle: FileHandle, timeout_ms: Int) -> Result[Bool]`, like `IO.eof?`
for a file handle. It peeks at the next byte without using it, with the timeout
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
  `main`, §37); the handle, owned by the task, is closed by the crash, or by the
  run's end in `main`, as today. A handle that leaves the block (returned inside
  the Result or captured by a lambda) is closed; using it gives the error
  `Result` of a closed handle, as today.
- The block's result must be `Result[T]`. `T` comes from the expected type of
  the call if there is one, or else from the body. Unlike `map`, `try` works in
  this block even when `T` is inferred: the outer type is always `Result`, so
  the checker knows what `try` returns from it. This is a small checker rule for
  builtins whose block result is `Result[T]` with `T` inferred. The first of
  `Task.map` ([section 27.1](27-iteration-and-concurrency.md#271-taskmap),
  roadmap 17a) and this item adds it, and the other reuses it. `try` in a block
  with a fixed `Result` type already works (`Test.test`, and `File.each_line`,
  [section
  27.4](27-iteration-and-concurrency.md#274-streams-fileeachline-and-streamt),
  roadmap 17d, which added only the completion-value check and its help).
- The strict rules of [section
  26](26-strict-diagnostics.md#26-strict-diagnostics) hold in the block: an
  unused handle parameter is `CHECK-UNUSED-VARIABLE` (`do |_|`), a statement
  after `return` is `CHECK-UNREACHABLE-CODE`, and a dropped `Result` inside it
  (`File.write_text(...)` without `try`) is `CHECK-UNUSED-RESULT`. The lowered
  `File.close` is not user code, so it is never reported.
- The same shape fits other handles that need a close: `TCP.connect`,
  `TLS.connect` and `Process.spawn` (where the close kills and reaps the
  process). Each is its own small item, added when a program needs it.

**Lowering:** `lower.rkt` expands the call into the existing `File.open`, a call
to the block's closure, `File.close` and the branches above. The block form
needs no new builtin and no VM change; the only VM change of this item is the
appended `File.eof?` builtin. It is a lowering, not a prelude function, because
25.9 lands at order step 7.6, before the prelude (8.2); a plain `std/` function
cannot do it either, since it would have to be generic in `T`.

**Tests:** golden fixtures on temporary files: read and write with `ok`;
`File.eof?` on an empty file, at the end, before a final line without a newline,
and on a closed or write-only handle; an early `error`; a failed `try`; a failed
open (block not run); the handle used after the block; checker tests for the
three section 26 codes inside the block. A failing close is hard to cause from a
test (it needs a full disk), so a test of the lowered code checks that each of
the four outcomes (block `ok` or `error`, close `ok` or `error`) gives the
result above. **Docs:** `grammar.md` ("Files and paths", with `File.eof?`), the
programming skill (`references/files.md`, which teaches the block form as
canonical, and says that `File.eof?` returns `Result[Bool]`, unlike `IO.eof?`,
so the loop needs `try`), `site/content/library/io-and-system/files.md`.

### 25.10 Heredocs

Ruby's squiggly heredoc: a multi-line string whose common indentation is
removed.

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

The value is
`"Usage: tool [options]\n\n  --verbose   print more\nExit code 0 on success.\n"`
for `name = "tool"`.

**One way:** a heredoc is the canonical form for text of two or more lines. A
heredoc with one body line (or none) is `LEX-HEREDOC-ONE-LINE`, with a help that
shows a normal string literal (`"text\n"`). Escapes such as `\n` in normal
strings stay: this is a deliberate, stated exception to the one-way rule for
short text. The threshold: a heredoc is never required (`"a\nb"` stays valid),
and a heredoc needs two or more body lines.

**Lexer, and two small checks.** The lexer turns a heredoc into today's token
kinds (`string`, `interp-start`, `interp-middle`, `interp-end`), with a
`heredoc?` field set on each token, so later stages can tell a heredoc apart.
The parser builds the usual string (or interpolation) node and carries the field
to it as a heredoc flag, so the flag is kept for the `case` pattern, import path
and `format` checks; 15j adds the flag. Lowering and the VM do not change.

- **Start:** `<<~` followed directly by an uppercase name (`[A-Z][A-Z0-9_]*`).
  The rest of the line is lexed as usual (`puts(<<~TEXT)` works); the body
  starts on the next line. Several heredocs on one line take their bodies one
  after the other, in order, as in Ruby.
- **End:** a line with only optional spaces and the same name. A tab before the
  name is `LEX-HEREDOC-INDENT`, as in the body. The body lines and the end line
  produce no `NL` tokens; the line that holds `<<~NAME` ends with its `NL`, when
  the lexer would emit one there (not inside delimiters).
- **Indentation:** the smallest number of leading spaces among the body lines
  that are not blank is removed from every line. A blank line (spaces only)
  becomes an empty line. A tab in a line's leading whitespace is
  `LEX-HEREDOC-INDENT`, with a help to use spaces, because tab widths make the
  result unclear. Each body line ends with `\n`, the last included. A CR before
  the LF of a body line is dropped, as the lexer already turns CRLF into LF.
- **Token order.** At the place of `<<~NAME`, the lexer emits the heredoc's
  tokens: one `string` token without interpolation, or `interp-start`, the
  tokens of each `#{...}` expression, `interp-middle` and `interp-end`, as for a
  normal string. Then come the tokens of the rest of the opener line, then its
  `NL`, when the lexer would emit one there, then the tokens after the end line.
  So the parser sees one string primary where `<<~NAME` stands.
- **Spans.** The string piece tokens (`string`, `interp-start`, `interp-middle`,
  `interp-end`) all take the span of `<<~NAME`, so every node that `span-from`
  builds in `src/parser.rkt` (the start of its first token to the end of the
  last consumed token) stays on the opener line, with start before end. The
  tokens inside `#{...}` keep their real line and column in the body: the lexer
  finds the indentation with a first pass over the body lines, then lexes each
  line from its real position after the indentation, so the indentation is cut
  from the text, not from the source positions. These spans lie after their
  parent's span, so spans are not monotonic here: a child may lie outside its
  parent. The PR checks that no code assumes a child span lies inside its
  parent's (diagnostics print each span on its own line, which works).
- **Inside parentheses:** `foo(<<~A, x)` works, and so does `foo(<<~A,` with the
  next argument on the line after the end line: inside delimiters no `NL` is
  emitted, the body is read when the opener line ends, and the call goes on
  after the end line, as in Ruby.
- **Escapes and interpolation** are those of a normal string: `\n`, `\r`, `\t`,
  `\"`, `\\`, `\#`, and `#{...}`, which must end on its line; a bad escape is
  `LEX-INVALID-ESCAPE`. A `"` needs no escape. The indentation is removed from
  the source text before escapes and interpolation, so an interpolated value is
  never re-indented.
- **Errors:** end of file before the end line is `LEX-UNTERMINATED-HEREDOC` at
  `<<~NAME`. A name that is not uppercase (`<<~text`) is `LEX-UNEXPECTED-CHAR`
  at `<<~`, with a help that shows `<<~TEXT`. Only the squiggly form exists:
  `<<NAME`, `<<-NAME` and the quoted forms (`<<~'NAME'`) are
  `LEX-UNEXPECTED-CHAR` with a help that shows `<<~NAME` (and `\#` for text
  without interpolation). Every other `<<` keeps today's tokens (two `<`).
  Ruby's push, `xs << x`, gets a new `grammar.md` §7 hint row:
  `xs = xs.push(x)`.
- `case` patterns and `import` paths take plain string literals only: a heredoc
  there is `PARSE-UNEXPECTED-TOKEN`, with a help to use a `"..."` literal.
  `format` rejects a heredoc format string with `CHECK-FORMAT-LITERAL` (25.11),
  because spans inside a heredoc are not exact columns of a one-line literal.

**Tests:** in `tests/lexer-test.rkt`: indentation, blank lines, interpolation
and escapes, two heredocs on one line, a heredoc inside a call,
`LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT`, `LEX-HEREDOC-ONE-LINE` (for
one body line and for none) and `LEX-UNEXPECTED-CHAR` (`<<~text`, `<<NAME`,
`<<-NAME`, `<<~'NAME'`) with their spans, a CRLF body, a tab before the end
name, a heredoc as a `case` pattern and an import path; a golden fixture; a site
example. **Docs:** `grammar.md` (Literals: "no multiline strings" changes; the
§7 hint row for `xs << x`), the programming skill (`SKILL.md`, and
`references/diagnostics.md` for the new codes), `site/content/tour/strings.md`.

**As built** (post-bootstrap step 5, part A; the Racket front end was gone, so
all of it is in `compiler/`). The rules above hold. Where the design left room:

- No `heredoc?` field on the token and no flag on the string node. The lexeme
  of a heredoc token is its opener (`<<~NAME`) and the lexeme of a string
  literal starts with `"`, so `Base.heredoc?` tells them apart in the two
  places that need it today (the `case` pattern and the import path). The flag
  is added with `format` (15k), the only other reader.
- The lexer gives `<` a character class of its own (`CharClass.Less`), so the
  hot operator arm does not test for `<<`. The main loop became `lex_from`,
  which `lex` calls once; a heredoc calls it again for each `#{...}` of its
  body, started on the body line with the `#` frame pushed, and it returns at
  the `}` that closes that frame. So the tokens inside an interpolation are the
  ones of a normal string, with real positions.
- The jump over the bodies is a `resume` point of the main loop: the heredoc
  sets it, and the line break of the opener line emits its `NL` and goes to
  it. A second heredoc on the same line starts at the point the first left.
- The end line is exact: optional spaces, the name, then the line break (or the
  end of the file). Text after the name makes it a body line. Body lines count
  for the "two or more lines" rule when blank, too.
- `<<NAME` is `LEX-UNEXPECTED-CHAR` when a capital follows `<<` (or `<<-`);
  `<<` before anything else is two `<` tokens, as before. The span of
  `<<NAME` is `<<`, of `<<-NAME` and `<<~text` the three characters.
- A heredoc inside any `#{...}` is `LEX-UNTERMINATED-STRING`, as the line
  break that ends the interpolation would be.
- `xs << x` gets its help in `primary_help` of the parser (the second `<` is
  where an expression should start).
- No `format` exists yet (15k), so `CHECK-FORMAT-LITERAL` for a heredoc waits
  for it.
- Spans inside a body lie after the spans of the nodes that hold them. The
  parser, the checker, the lowering and the diagnostic printers take each span
  as it is, and the goldens `heredoc`, `heredoc-type-error` and
  `tests/fixtures/vm/heredoc-error` show a diagnostic inside a body.

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

- `format` has a catalog entry in `src/builtins.rkt` with a "checker-handled,
  variadic" marker: the number of arguments depends on the literal, so the
  checker checks the call itself, not against a fixed signature. The entry is
  needed because the linker's `resolve` (`src/modules.rkt`) keeps a call name
  unchanged only when `builtin-ref` finds it, and otherwise adds the module
  prefix (`@N::`), so `format` in an imported module would be renamed. The one
  entry covers linking, the name reservation (the linker's duplicate check uses
  `builtin-ref`) and `agentica help format`. Only the function name is reserved:
  a user `def format` is `CHECK-REDEFINED-NAME`, a breaking change accepted
  before 1.0. Variables, parameters and fields named `format` stay valid, since
  `format(...)` is a call and a variable is not callable.
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

**Where the code lives.** It waits for 8d with the prelude (25.6). By the
std-first rule, padding, decimal and hex text are Agentica code in a prelude
file, `stdlib/prelude/format.agc` (25.6; these functions use no type variables).
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
padding (`%021d`) as well as for `%x`.

**Lowering:** `lower.rkt` turns each call into a concatenation of the literal
parts and calls to the prelude functions, one per conversion, so no format
string is parsed at run time. For each `%s` argument, `lower.rkt` emits the
`to_s` call at the call site, as interpolation does, and passes the resulting
`String` to the prelude padding function. A `%s` argument without `to_s` (an
`Fn`, a task, a handle) is `CHECK-TYPE-MISMATCH` at the argument, with a
secondary span on its conversion. No VM change other than the new builtin.

**Tests:** checker tests for each code with spans inside the literal; `format`
called inside an imported module and inside a `std/` module (the linker keeps
the name); the one-way help for `format("%s is %d", ...)` and for a string with
no conversion, and `x.to_fixed(2)` (`CHECK-UNKNOWN-METHOD`); golden fixtures for
every type, flag, width and precision, negative numbers, the smallest `Int`, NaN
and the infinities, `%%`; `__float_fixed`, through `format("%.Nf", x)` (NaN and
the infinities included), against vectors from a checked-in Python script
(standard library only), including halfway cases such as `0.125` and `2.675`.
**Docs:** `grammar.md` (builtin functions, §7 hints), the programming skill
(`references/builtins.md`, and `references/diagnostics.md` for the new codes),
`site/content/library/text-and-data/string.md` and `numbers.md`, and
`docs/vm/03-ir-and-bytecode.md` §4.5 ("There are no internal helper builtins"
gains `__float_fixed`).

### 25.12 To evaluate later (Part B)

These may help, but each needs more design, a real program that asks for it, or
another feature first. None is planned; each needs its own spec before a phase
takes it, and each must also pass the one-way principle (top of this section)
before it is planned.

#### 25.12.1 `case/in` pattern matching

**What:** Ruby 3's `case value in pattern`: nested patterns
(`Shape.Box(Point(x, 0), _)`), struct patterns by field (`User(name:, age:)`),
list patterns (`[first, *rest]`), and guards (`in x if x > 0`). **Why:** the
most valuable item of this part; it removes nested `case` statements and lets
agents write the Ruby they know. Before step 5, patterns were one level deep
with no guards. **Why not now:** high complexity: exhaustiveness and
unreachable-arm checks for nested patterns, list patterns with a rest,
bindings in guards, and the lowering to a decision tree. **Open questions:**
keep `->` arms or take `in`; how list rests fit immutable lists; which patterns
`Map` gets; whether `case ... in` becomes an expression.

**As decided (post-bootstrap step 5).** Guards and nested patterns are built,
in `compiler/` only, as a smaller form of this idea; the rest stays "to
evaluate later" and out of scope: struct patterns by field, list patterns with a
rest, `case ... in` and `case` as an expression. The owner approved guards and
nested patterns on 2026-10-15 ("multi-clause Elixir-style functions are not
wanted; a case with guards covers them"); the details below were decided under
the owner's delegation.

1. **Guards.** `pattern if condition -> ...`, like Ruby's `in x if x > 0`.
   `if` is already a keyword, so there is no new reserved word, and `when`
   stays unreserved. The condition is a `Bool` (`CHECK-TYPE-MISMATCH`) and may
   use the bindings of its arm. A guarded arm never counts toward
   exhaustiveness, and the same pattern may come again in a later arm, guarded
   or not, without `CHECK-UNREACHABLE-CASE-ARM`. A guarded catch-all
   `_ if c ->` is allowed and does not make the case exhaustive; a catch-all
   must be last only when it has no guard. The parser looks for the guard of an
   arm up to the first `->` of its line.
2. **Nested patterns.** In a payload position (of a qualified variant,
   `ok(...)` or `error(...)`) any pattern may appear: a literal (a negative
   number too), `_`, a name, or a nested variant, `ok(...)` or `error(...)`,
   to any depth, within the parser's nesting limit (a nested variant is one
   level). Payloads stay positional. A name may appear once in an arm
   (`CHECK-SHADOWED-NAME`, the code that a repeated binding already had).
3. **Exhaustiveness and reachability** stay simple and conservative. An arm
   covers its top-level variant only when it has no guard and every
   sub-pattern is irrefutable (a name or `_`); an arm with a literal or a
   nested variant is treated like a guarded one. An arm is unreachable when an
   earlier unguarded arm already covers its variant with irrefutable
   sub-patterns, or after an unguarded catch-all. There is no deeper analysis:
   a case on `ok(Option.Some(n))` and `ok(Option.None)` still needs `ok(_)`.
4. **Lowering.** The sequential test-and-jump chain of each arm gains the
   nested tests (the payload is read into a temporary register, then its tag
   or literal is tested) and the guard, after the bindings, as one more
   condition. A failed test falls through to the next arm. The bytecode and
   the VM do not change.

**Built (2026-10-16).** The grammar is in `docs/grammar/05-syntax.md` and
`06-semantics.md`; the example is `examples/case-guards.agc`. `compiler/` does
not use the syntax yet, because stage0 cannot compile it (the two-step refresh
of §18.2, a later PR).

#### 25.12.2 Keyword arguments (moved to Part C)

Decided against by the one-way test: a second way to pass the same argument. See
25.13.

#### 25.12.3 `loop do ... end` (moved to Part C)

Decided against by the one-way test: `while true` already does it. See 25.13.

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
all, and how it relates to user `Option[T]` and to `JsonField` (§17).

#### 25.12.6 Destructuring

**What:** `a, b = pair`, block parameters `|(k, v)|`, multiple return values.
**Why:** `partition`, `zip` and `Map` iteration read better. **Why not now:** it
needs tuples (roadmap 8's "Later" list). **Open
questions:** tuple syntax and types, and whether lists can be destructured with
a length check.

#### 25.12.7 Lazy enumerators and generators

**What:** `(1..).lazy.select { ... }.first(3)`, `Enumerator.new`. **Why:**
streams of unknown length without building lists. **Now in [section
27](27-iteration-and-concurrency.md#27-iteration-and-concurrent-collections):**
`File.each_line` reads a big file line by line in bounded memory (§27.4, step 1,
order row 7.2.1h), and a lazy `Stream[T]` is planned for after the prelude of
25.6 (§27.4, step 2, order step 8.2); generators with `yield` (`Enumerator.new`,
fibers) are decided against (§27.5), since a task that sends into a channel
(§27.2) is the producer, and `xs.lazy` gets a help.

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
- **Reflection:** `instance_variable_get`/`set`, listing fields or methods: it
  breaks static checking and makes the VM keep names at run time; `JSON.from`
  shows a value's fields.
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
  pattern. For chaining user functions, use `|>` (§25.14).
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
  stay positional; `with` (25.3) and struct construction stay the only places
  with named arguments.
- **`loop do ... end`** (was 25.12.3): `while true ... end` already does it, and
  `break` cannot leave a block, so it would be a statement that looks like a
  block. Section 11's help stays.
- **`unless`** (was 25.7): a second way to write `if !c`. `unless` is not a
  reserved word, so `unless c` is a name followed by more tokens. The parser
  picks the help when a statement starts with the name `unless` and more of the
  expression follows on that line: `PARSE-UNEXPECTED-TOKEN` with a help that
  shows `if !c ... end`. Tests: `unless x`, `unless -x`, `unless [i]` and
  `unless.foo` (each gets the help or, for `unless.foo`, today's diagnostic for
  that name), and a variable named `unless` on its own still works.
- **Statement modifiers** (was 25.8): `return x if c`, `break if c`,
  `puts(x) if v` are a second way to write `if`. Section 11's rejection stays as
  it is, with its existing help (`if x`, then the statement on its own line,
  then `end`).
- **New method aliases** (`select`, `collect`, `detect`, `inject`) and **second
  ways** (`reject`, the `Range` Enumerable methods, the block form of
  `each_slice`): see 25.6; each gets `CHECK-UNKNOWN-METHOD` (or
  `CHECK-BLOCK-TARGET`) with the canonical form.
- **`*args` and `**opts` splats:** a `List` or a struct parameter, and defaults
  (25.1).
- **`%w[...]`:** a list literal.
- **`raise`/`rescue`/`ensure`:** errors are `Result` values with `try`;
  `File.open` with a block (25.9) covers `ensure`.
- **User operator overloading, and overloading by argument type or by arity:**
  it breaks the inference of blocks and of empty literals (`[]`, `{}`) from the
  expected parameter type, makes diagnostics worse (which overload did you
  mean), and needs name mangling in the VM and the linker; defaults (25.1) cover
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
   `def logged(base: Storage) -> Storage` returns `base.with(get: ...)` (25.3),
   where the new `get` logs and then calls `base.get`.
3. A facade module passes on names from other modules with re-exports (25.2),
   like Elixir's `defdelegate`.

### 25.14 Pipe operator `|>`

**What.** `x |> f(a, b)` means `f(x, a, b)`: the left value becomes the first
argument of the call on the right. Example:

```agentica
def parse(text: String) -> Result[Int]
  return text.trim.to_int
end

def validate(n: Int) -> Result[Int]
  if n < 0
    return error("negative")
  end
  return ok(n)
end

def load(path: String) -> Result[Int]
  return path |> try File.read_text(1000) |> try parse() |> validate()
end
```

**Why.** Builtins already chain with `.`: `s.trim.split(",")`. User functions
cannot be called as methods, so code nests: `validate(parse(s.trim))`. `|>`
reads left to right, with no change to types or the VM. Ruby tried `|>` in its
2.7 development (Feature #15799) and took it out before the release, because
there it only repeated `.`. Here user functions have no method form, so `|>`
adds what `.` cannot.

**Rules:**

- The right side is a call with parentheses: `name(args)` or `Alias.name(args)`
  (a user function, an imported function or a builtin), optionally preceded by
  `try`: `x |> try f(a)` means `try f(x, a)`. Anything else on the right (a bare
  name, a field, an index, a method chain such as `f(1).g`, a literal) is
  `PARSE-PIPE-TARGET` at the right side, a new code. Its help says to wrap the
  expression in parentheses and use `.` on the result, for example
  `(x |> f()).unwrap!`.
- A call with a trailing block works: `xs |> each_pair() do |a, b| ... end`
  passes `xs` first. Here `each_pair` is a user function whose last parameter is
  a `Fn` that takes two values.
- **One way.** A builtin call that has a method form for the left value's type
  is `CHECK-PIPE-METHOD`, a new code, at the right side. Its help shows the
  method form: `x |> String.trim()` gives the help `x.trim`. So a builtin with a
  method form is always written with `.`, and `|>` is for user functions and for
  builtins without a method form. Mixing is fine:
  `s.trim |> try parse() |> try validate()`.
- **Precedence.** `|>` binds lower than `+` and `-`, and higher than the
  comparisons `<`, `<=`, `>` and `>=`. So `a + 1 |> f()` is `f(a + 1)`, and
  `x |> f() == y` is `f(x) == y`. It groups from left to right:
  `x |> f() |> g()` is `g(f(x))`. `try` and unary operators bind tighter:
  `try x |> f()` is `f(try x)`. To propagate a step's error, put `try` on the
  right: `s |> try parse() |> try validate()` is `try validate(try parse(s))`.
- **Evaluation order** is the call's: the left value first, then the other
  arguments left to right, as in `f(x, a, b)`.
- **Lines.** No implicit continuation
  ([docs/grammar/04-lexical.md](../grammar/04-lexical.md), section 4): a chain
  over several lines goes in parentheses, one step per line:

  ```agentica
  config = (path
    |> try File.read_text(1000)
    |> try parse()
    |> try validate())
  ```

- **Diagnostics** of the call (arity, types, unknown name) are the normal ones
  for `f(x, a, b)`. The inserted argument's span is the left expression's span,
  so a type error on it points at the left side.

**Left out:** a placeholder for other argument positions (`x |> f(a, _)`); `|>`
into a bare function value (`x |> f`); a reverse pipe. Each waits for a real
need.

**Where it lives.** Lexer: a new `|>` token (longest match, next to `|` and
`||`; block parameters `do |x|` are unaffected). Parser: a binary level between
`+ -` and the comparisons; it builds the ordinary call node with the left
expression as argument 0 and a `piped` flag (or an equivalent marker), so the
checker can apply `CHECK-PIPE-METHOD`; `PARSE-PIPE-TARGET` comes from the
parser. Checker: the method-form rule only. No change to lowering, bytecode or
the VM.

**Tests** (codes and spans, not message text): in `tests/lexer-test.rkt`, the
token, and that `do |x|` and `||` still lex; in `tests/parser-test.rkt`,
precedence against `+`, `==`, `try` and unary minus, left associativity, a
trailing block, and `PARSE-PIPE-TARGET` for a bare name, a field, an index and
`f(1).g`, with spans; in `tests/checker-test.rkt`, `CHECK-PIPE-METHOD` with its
span and help for `s |> String.trim()`, no error for a builtin without a method
form, a type error on the piped value at the left span, and an arity error; one
golden VM fixture in `tests/fixtures/vm/` with a chain of user functions, a
`try` step and a multi-line parenthesized chain; and a site example, which
`tests/site-examples-test.rkt` checks. **Docs** when it lands:
`docs/grammar/04-lexical.md` (the token), `docs/grammar/05-syntax.md` (the
precedence table and the rule), `docs/grammar/07-diagnostics.md` (the two
codes), the programming skill (`.agents/skills/agentica-programming/SKILL.md`:
its precedence table and one short paragraph; `references/diagnostics.md` for
the two codes), and a site page (`site/content/tour/functions.md`) with a
runnable example.
