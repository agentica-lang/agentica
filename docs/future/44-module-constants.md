## 44. Module constants

**Status:** planned, roadmap row 7.2.8. Requested by the owner on 2026-10-15
and wanted before the bootstrap, so the Agentica front end (`compiler/`) can
use them. It relaxes the freeze of the Racket front end (row 7.2.7,
[§35](35-self-hosting.md)) in both front ends, as `Set[T]` (8b) and
`value.with(...)` (15c) did. This section is the design; the implementation
PRs are listed in 44.11.

### 44.1 Goal

A module can name a value once, at the top level, and every function reads it:

```ruby
MAX_DEPTH = 1000
export GREETING: String = "hello"
```

The owner asked for what Python has (`FOO = 1234`) and what Elixir has
(`@asdf "ghij"`): a value that is fixed for the whole run, written in the
module and not rebuilt by the program each time it is used.

Why now. `compiler/` has no way to keep a table. Today it writes each table as
a function with no parameters (`keyword_table()`, `char_classes()`,
`nesting_limit()`, `graphic_ranges()`, `Tables.reserved_type_names()`) or as a
struct built once and passed to every call (the lexer's `Input`, the linker's
`Settings`, the checker's `Catalog` in the step-4a PR). Both cost something:

- A zero-argument function builds its value again on every call.
  `Unicode.graphic?` builds a list of about 1,900 numbers each time it runs.
- A struct that carries tables adds a parameter to every function between the
  place that builds it and the place that reads it, and it is built again for
  every `lex` call, so the linker builds the lexer's tables once per imported
  file.

Constants fix both: one value per run, read where it is needed.

### 44.2 Syntax

A constant is a declaration at the top level of a file, Ruby style:

```ebnf
constant_decl = [ DOC, NL ], [ "export" ], CONST_NAME, [ ":", type ],
                "=", expression, NL ;
```

- `CONST_NAME` is a `TYPE_NAME` token whose text is `UPPER_SNAKE_CASE`: capital
  letters, digits and `_`, starting with a capital letter, at least two
  characters. Anything else, such as `Limit = 1` or `X = 1`, is
  `PARSE-CONSTANT-NAME` (the help says to use `LIMIT`). The two-character
  minimum keeps constants apart from type parameters (`T`, `K`, `V`), and the
  all-capitals rule keeps them apart from types, which are `CamelCase`
  (`HttpRequest`). The built-in all-capitals names (`JSON`, `IO`) are reserved
  type names and so cannot be constants.
- The type is optional. `NAME = expr` takes the type of `expr`, as a local
  binding does. `NAME: Type = expr` checks `expr` against `Type`, and gives
  the empty forms `[]`, `{}` and `Set.new([])` the type they need, as it does
  for a local.
- The value is one expression. It may span lines inside brackets (`(`, `[`,
  `{`) or a `do ... end` block. It cannot start on the line after `=`, as for a
  local binding.
- `export NAME = ...` makes the constant visible to importers.
- A `##` doc block above a constant documents it (§32).
- Constants follow each other, and the imports before them, with no blank line
  (as imports do). A blank line is needed before the next `struct`, `enum` or
  `def` and after any other declaration (`PARSE-MISSING-BLANK-LINE`).

**Reading a constant.** `NAME` in its own file, `Alias.NAME` from an importing
file. Both are expressions, so everything that works on a value works on them:
`KEYWORDS.include?(word)`, `LEVELS.get(kind, 0)`, `CLASSES[code]`,
`"#{LIMIT}"`, `Lexer.KEYWORDS.size`.

How the parser sees these forms matters, because a constant looks like a type
or a module (`Models.User`, `JSON.decode`):

- `NAME` and `Alias.NAME` already parse as a `type-expression` (the node that
  holds a bare type name, a nullary variant such as `CharClass.Other`, or a JSON
  type argument). No change.
- `NAME.method(args)` and `NAME.size` parse today as a module call
  `call "NAME.method"`, which is also what `JSON.parse(x)` is. The parser cannot
  tell them apart, because an import alias may also be all capitals
  (`import "std/http" as HTTP`). The linker decides: a name that is a constant
  of the file and not an alias or builtin module turns the call into the same
  method call that `xs.size` gives, with the constant as the receiver. This is
  how the linker already turns `Enum.Variant` into an enum value.
- `Alias.NAME.method(args)` fails today (`Alias.TypeName` followed by `.` wants
  a variant name). The parser change: after `Alias.TYPE_NAME` and a `.`, a
  lowercase name starts a method call on the constant `Alias.NAME`. A type name
  after the second dot is still a variant.

Local variables, parameters, block parameters and `for` variables are
lowercase names, and a constant is never lowercase, so **a local can never
shadow a constant**. There is nothing to resolve and no shadowing rule. A
statement `NAME = 1` or `NAME += 1` inside a function is
`PARSE-UNEXPECTED-TOKEN` today; the PR adds a help line, "constants are set at
the top level and never change". A constant cannot be reassigned because no
syntax assigns to one.

**Not in the syntax.** Case patterns (`case x` with `LIMIT -> ...`): patterns
are literals and variants, and a constant would make them depend on values
(decided against for v1, 44.13). Default parameter values do not exist yet
(row 7.5a); when they land, a constant is a valid default, because it is a
value fixed for the run. No `static`, `const` or `final` keyword and no
`@name` form: the capitals are the marker. No module state: a constant never
changes, so "no module state" in `docs/grammar/05b-modules.md` stays true
(44a2 words it "no mutable module state").

### 44.3 Semantics

- **Scope.** A constant belongs to its file. It is visible in the whole file,
  before and after its line. `export` makes `Alias.NAME` work in a file that
  imports this one; without it, `Alias.NAME` is `CHECK-IMPORT-NAME` ("unknown
  or private imported name", with the did-you-mean help, which lists only
  exports). Imports still cannot be re-exported.
- **One namespace with types.** A constant cannot have the name of a struct, an
  enum, an import alias, a builtin or a reserved type name:
  `CHECK-REDEFINED-NAME`. Two constants of one file with one name are the same
  error.
- **Order of evaluation.** The initializers run once, before `main`, in
  dependency order (44.6, "Order"). A constant may use constants of its own file
  and of imported files. Cycles are `CHECK-CONSTANT-CYCLE`. Imports cannot form
  a cycle (`CHECK-IMPORT-CYCLE`), so a cycle is always inside one file.
- **Types.** A constant has one type, known from the initializer and the
  annotation. The type must be fully known (no unresolved `[]`) and made of data
  types only (44.4). Constants are not generic.
- **Values are immutable and shared.** Lists, maps, sets and structs are
  persistent values in Agentica. `KEYWORDS.add("x")` gives a new set and leaves
  `KEYWORDS` unchanged, and no copy is made to protect it. All tasks read the
  same value. The initializers finish before `main` starts, so no task is
  running while a constant is being set.
- **Errors in an initializer.** The checker proves an initializer has no
  effects and ends (44.4), but not that it succeeds. `[1, 2][5]`, `1 / 0`,
  `"x".to_i!` and an `Int` overflow are runtime errors, with the usual
  `RUNTIME-*` code, the span of the expression and the stack trace, and they
  stop the program before `main` runs and before it prints anything. They are
  the same on every run, so the first run finds them. `agentica check` does not
  run initializers and does not find them.
- **Unused constants.** A constant that no function and no other kept constant
  reads is not set and not even emitted (44.6). The checker still checks it.
- **`agentica test` and the BDD driver** load the same bytecode, so a constant
  is set at the start of each test child as in any program.

### 44.4 Value rules

The goal says "fixed at compile time". The design keeps what can be fixed in the
bytecode there, and does the rest once at load. Two kinds of constant:

1. **A literal constant.** The initializer is an `Int`, `Float`, `String`,
   `Bool` or `nil` literal, or `-` and a number literal. The compiler puts the
   value in the constant pool of every function that reads it, as a literal in
   its place (`CONST`). The constant needs no slot and no set-up. This is the
   "hardcoded in the bytecode" case, and it is free.
2. **Every other constant** (a collection, a struct, an operation, a call of a
   builtin) is **a constant expression**: the bytecode holds the code of the
   initializer, the VM runs it once at load, and every read afterwards is one
   table access (44.7).

**What a constant expression may contain.** The rule is a list of what is
allowed, so a new language form is out until someone adds it:

- Literals, string interpolation, list, map and `Set.new` literals, ranges.
- Construction of structs, enum variants and `ok`/`error` values, including the
  builtin records and enums.
- Unary and binary operators, field access, indexing, `==` and the rest of
  the operators on their usual types.
- Reading another constant (same file or `Alias.NAME`).
- Calls of builtins whose row in the builtin catalog has **no effects**
  (`effects: []` in `src/builtins.rkt`), as functions or methods: `Set.new`,
  `List.map`, `List.reduce`, `List.concat`, `Map.put`, `Range.to_a`,
  `String.split`, `String.code`, `Int.bit_and`, `Float.from_bits`, and the
  rest of the 108 effect-free rows (the count in
  `compiler/builtins_data.agc` of the step-4a PR).
- Block literals (`do |x| ... end`) passed to those builtins. The body may use
  assignments, `if`, `case`, `for`, `break`, `next` and `return`, and the same
  expressions and calls, and nothing else.

**What it may not contain** (`CHECK-CONSTANT-EXPRESSION`, located at the form,
with a help that says why):

- A call of a function declared in a program (`def`). No user function calls
  in v1 (see "Why no user functions" below).
- `&name` function values, and a block that is stored or returned instead of
  passed to a builtin.
- `while` loops. (`for` over a collection, a range or a builtin that counts is
  fine: it ends because the collection ends.)
- A call of a builtin with effects: any of `stdout`, `stdin`, `filesystem`,
  `network`, `subprocess`, `process`, `logging`, `concurrency`, `clock`,
  `random`, `test`.

**What its types may be** (`CHECK-CONSTANT-TYPE`): every expression inside a
constant expression, not only the result, has a data type: `Int`, `Float`,
`Bool`, `String`, `Nil`, `List`, `Map`, `Set`, `Range`, `Result` and `JSON` of
data types, and the structs and enums (user and builtin) whose fields and
payloads are data types. A `Fn`, `Channel`, `Task` or handle type (`Socket`,
`Listener`, `HttpServer`, `FileHandle`, `Process`), `HttpClient` and `TestCase`
are not data types. This closes the cases the effect list misses: `Channel.new`
has `effects: []`, but it makes a value with identity and state, and its result
is not a data type.

**Why this is pure, deterministic and ends.** No effect means the value depends
only on the program. No `while`, no user calls and no recursion means every
loop runs over a finite value and every call is a builtin, so the initializer
ends in time bounded by the size of its data. Memory and the step budget
still apply, as to any code (`List.repeat(0, 1_000_000_000)` is a runtime
error, not a hang of the checker). The PR that adds a builtin with empty
effects must be deterministic and bounded, and a test lists every effect-free
row that has a non-data type in its signature (today `Channel.new`,
`Channel.closed?`, `Test.test`) and asserts that the checker rejects it.

**Why no user functions (v1).** Allowing `def` calls would make the rule depend
on a purity and termination analysis of the call graph (recursion, higher
order calls through `Fn`, mutual recursion across files), which has to be
written twice, in Racket and in Agentica, and then kept equal. The tables of
`compiler/` do not need it (44.8): where a table is built by a helper
function today, the helper's logic fits a block or becomes data. If a real use
appears, the smallest safe addition is a call of a user function that the
checker proves has no `while`, no recursion and calls only builtins and
such functions; it is an additive change.

**Why the VM evaluates and not the compiler.** Folding in the compiler
means writing the semantics of every allowed builtin and operator a second time
in `src/` (Racket) and a third time in `compiler/` (Agentica), and keeping the
three equal. The project rule is the opposite: the VM is the one semantics
("New features are VM-only"). The cost is that a runtime error in an initializer
shows when the program starts and not when it is compiled, and that
loading builds the values. 44.9 measures the second. Question 1 (44.13) asks
the owner to confirm.

### 44.5 Diagnostics

New codes, stable, with the span of the form named:

- `PARSE-CONSTANT-NAME`: a top-level `Name = ...` or `Name: T = ...` whose
  name is not `UPPER_SNAKE_CASE` of two or more characters. Span: the name.
- `CHECK-CONSTANT-CYCLE`: a constant reads itself, directly or through other
  constants. Span: the reference that closes the cycle; the help lists
  `A -> B -> A`.
- `CHECK-CONSTANT-EXPRESSION`: the initializer uses a form that 44.4 does not
  allow. Span: that form.
- `CHECK-CONSTANT-TYPE`: an expression of the initializer has a type that is
  not a data type. Span: that expression.

Reused codes: `CHECK-REDEFINED-NAME` (duplicate or reserved name),
`CHECK-DECL-ORDER` (44.6), `CHECK-IMPORT-NAME` (a private or unknown
`Alias.NAME`), `CHECK-TYPE-MISMATCH` (annotation or use), `CHECK-EMPTY-SET-TYPE`
and the other empty-collection codes (`NAME = []` without a type), and
`CHECK-UNKNOWN-NAME` for an unknown `NAME` with the did-you-mean help over the
constants in scope. `CHECK-INT-RANGE` and the rest of the expression rules
apply inside initializers as everywhere. `PARSE-TOO-DEEP` counts initializers
too.

Cycle detection: depth-first over the constants in linked order, following
references in source order; the first reference that reaches a constant already
on the path is the error. Both checkers do exactly this, so they agree on the
span.

### 44.6 Front end

**Parser (both).** `ast.rkt` and `compiler/ast.agc` get one declaration node
(`const-decl`: name, optional type, value, `exported`, span; docs as for other
declarations). `parse-program` accepts a `TYPE_NAME` token followed by `=` or
`:` where it accepts `def`, `struct` and `enum`. The `Alias.NAME.method` change
of 44.2 is in `parse-construct`. The depth rule counts the initializer. The
text forms of the parser goldens print `const` nodes (the line of a declaration,
then `type:` and `value:` children), with `export` as for other declarations.

**Declaration order.** `CHECK-DECL-ORDER` becomes: imports, then constants,
then `struct` and `enum`, then `export def`, then `def`. Constants come right
after the imports because a reader looks for the tables of a file first, as in
Ruby and Python, and because they are data, not code. The order is a style
rule, as it is now: a constant may use a struct or enum declared below it
(`ClassRange(...)` in 44.8). The help text for a constant out of place says
"constants come right after the imports". The rank function lives in
`src/modules.rkt` (`declaration-order-error`) and in
`compiler/declarations.agc`.

**Linker (both).** `modules.rkt`/`modules.agc` collect constants as a kind of
declaration, exported or not, in the same name table as types and functions
(`Declarations.Kind` gets `Constant`). The rewrite turns a `type-expression`
or a qualified `call` that names a constant into a new node
`const-ref` with the linked name (`@2::NAME` for a file with prefix `@2::`;
the root file has no prefix, as now). It rewrites the `const-decl` name the
same way. A name that is neither a constant nor a type keeps today's path, so
no existing program changes meaning. `const-ref` has an `id` in
`compiler/ast.agc` like any expression, and the linked text form prints it.

**Checker (Racket now; the Agentica port in 4b/4c).**

1. Collect struct and enum declarations and function signatures as now.
2. Order the constants (below), check cycles, then check each initializer
   in that order against its annotation, in an environment with no locals, and
   record the constant's type. Apply the 44.4 rules while walking the
   initializer: forms, builtin effects, data types.
3. Check function bodies. A `const-ref` has the recorded type.

*Order.* Visit the constants in linked order; to visit one, first visit the
constants its initializer reads, in source order, then emit it. A constant
that is already emitted is skipped. This order is deterministic, so both
front ends and both bytecode writers agree. `check` returns it with the
types, and lowering reads it (it does not sort again).

**Lowering (Racket now; step 5 later).**

- A literal constant (44.4, kind 1) is replaced by its literal at each read.
- Every other constant that is read by a function, or by a constant that is
  read, becomes a function with no parameters named by its linked name, whose
  body is `return <initializer>`. The existing code that lowers a function body
  lowers it, blocks and all. Its spans are those of the constant's source.
- If there is at least one such constant, lowering adds a function `<start>`
  with no parameters. For each kept constant, in order: `CALL` its function and
  `GLOBAL_SET` the result into slot `i` (the position in the order). Then it
  tail-calls `main`. `<start>` is the entry of the file. With no kept constants
  there is no `<start>`, the entry is `main`, and the output is as today (apart
  from the format version).
- A read of a kept constant is `GLOBAL a i`.
- Constants nobody reads, and constants read only by other unread constants,
  are dropped.

### 44.7 Bytecode and VM

**Format version 5.** Version 4 is `STRUCT_WITH` (15c). Two things change the
layout, so the version goes to 5:

- A new section **Globals** after Updates and before Builtins: a `u32` count of
  slots. Nothing else: the initializers are ordinary functions called by the
  entry.
- Two opcodes appended after `STRUCT_WITH` (an appended opcode alone would not
  change the version, the section does):
  - `GLOBAL a bx`: `R[a] = G[bx]`.
  - `GLOBAL_SET a bx`: `G[bx] = R[a]`.

**Versions of other designs.** §41 and §42 each reserved version 5 for their
type-table kinds. Module constants come first, by the owner's request, so
this design takes 5. §42 now takes 6, or 7 if §41 lands first; §41 takes 6,
or 7 if §42 lands first. 41.18 and 42.11 say so (changed in the same PR as
this section).

**Loader.** The loader reads the count and allocates the slot array in the
`agc_program`, as it does for the constant pool, so the array is reachable
from the same roots and the collector keeps its values. It rejects (`BYTECODE-`
rejection, as for other bad operands):

- a count above 65,535 (`BYTECODE-LIMIT` in the writer, as for structs);
- a `GLOBAL` or `GLOBAL_SET` whose slot is not below the count;
- a `GLOBAL_SET` in any function except the entry. Only the entry, which runs
  first and has no loops, writes slots. After it returns the table is
  read-only, which keeps a future multicore scheduler (step 11) free of races
  on it.

**Run time.** Slots start unset. `GLOBAL` of an unset slot is `RUNTIME-INTERNAL`
(only a hand-made file can do it; the front end orders the reads). Each read is
a checked array access and a register copy. Initializers run under the normal
step budget (`--max-steps`) and the normal limits, in the main task, with no
scheduler involvement, because the checker allows no effects and no
waiting. A hostile file that does wait or loop in the entry is the same case as
a hostile `main`: memory safe, bounded by the budget.

**Traces.** An error in an initializer shows the function named by the
constant, then `<start>`. The call depth limit (10,000) sees one frame for each.

**Bytes.** Programs without constants differ from today only in the version
number. Programs with constants differ only by the new section, the two
opcodes, the functions and `<start>`. The Racket writer and the Agentica writer
(step 6) must give the same bytes, which the order of 44.6 guarantees.

**The `docs/vm` pages that change** (in 44a1): `03-ir-and-bytecode.md` (4.2
opcodes, 4.6 table and the version in the header row and the last bullet),
`08-loader-and-cli.md` (header check and new rejections).

### 44.8 The tables of `compiler/`, rewritten

The test the design must pass: the real tables of `compiler/` fit. Every
example below uses only what 44.4 allows. The snippets use forms the current
Racket front end already accepts (the expressions were checked with
`racket src/main.rkt check` inside functions; the constant line is the only
new syntax).

**The lexer (`compiler/lexer.agc`).** Today `new_input` builds eight tables on
every `lex` call and `Input` carries them to every `scan_*` function.

```ruby
# Keyword, block opener and operator tables: literals and Set.new.
KEYWORDS = Set.new([
  "import", "export", "def", "struct", "enum", "case", "do", "end", "if",
  "elsif", "else", "while", "for", "in", "return", "try", "true", "false",
  "nil", "and", "or", "not"
])
BLOCK_OPENERS = Set.new(["def", "struct", "enum", "if", "while", "for", "do"])
OPERATORS = {
  "->": "arrow", "==": "equal", "!=": "not-equal", "<=": "less-equal",
  ">=": "greater-equal", "&&": "and", "||": "or", "!": "not",
  "+=": "plus-assign", "-=": "minus-assign", "*=": "multiply-assign",
  "/=": "divide-assign", "%=": "modulo-assign", "(": "left-paren",
  ")": "right-paren", "[": "left-bracket", "]": "right-bracket",
  "{": "left-brace", "}": "right-brace", ",": "comma", ":": "colon",
  ".": "dot", "..": "dot-dot", "...": "dot-dot-dot", "=": "assign",
  "+": "plus", "-": "minus", "*": "multiply", "/": "divide", "%": "modulo",
  "<": "less", ">": "greater", "&": "ampersand", "|": "pipe",
  "|>": "pipe-forward"
}

# Character sets: ranges of codes instead of `code_set("abc...")`.
LINE_ENDS = Set.new([10, 13])
STRING_STOPS = Set.new([34, 35, 92, 10, 13])
NUMBER_CODES = Set.new((48..57).to_a.push(95))
NAME_CODES = Set.new(
  (65..90).to_a.concat((97..122).to_a).concat((48..57).to_a).push(95)
)
```

The character classes are the table that a literal cannot hold well:
`char_classes()` loops over 0..127 and calls `classify`, a user function. Under
44.4 the same table is data plus a fold, with no user function:

```ruby
struct ClassRange
  kind: CharClass
  first: Int
  last: Int
end

# The ranges do not overlap; a code in no range is CharClass.Other.
CLASS_RANGES = [
  ClassRange(kind: CharClass.Blank, first: 9, last: 9),
  ClassRange(kind: CharClass.Blank, first: 32, last: 32),
  ClassRange(kind: CharClass.Newline, first: 10, last: 10),
  ClassRange(kind: CharClass.Newline, first: 13, last: 13),
  ClassRange(kind: CharClass.Hash, first: 35, last: 35),
  ClassRange(kind: CharClass.NameStart, first: 65, last: 90),
  ClassRange(kind: CharClass.NameStart, first: 95, last: 95),
  ClassRange(kind: CharClass.NameStart, first: 97, last: 122),
  ClassRange(kind: CharClass.Digit, first: 48, last: 57),
  ClassRange(kind: CharClass.Quote, first: 34, last: 34),
  ClassRange(kind: CharClass.Opening, first: 40, last: 40),
  ClassRange(kind: CharClass.Opening, first: 91, last: 91),
  ClassRange(kind: CharClass.Opening, first: 123, last: 123),
  ClassRange(kind: CharClass.Closing, first: 41, last: 41),
  ClassRange(kind: CharClass.Closing, first: 93, last: 93),
  ClassRange(kind: CharClass.Closing, first: 125, last: 125)
]
CLASSES: Map[Int, CharClass] = CLASS_RANGES.reduce({}) do |all, range|
  (range.first..range.last).to_a.reduce(all) do |found, code|
    found.put(code, range.kind)
  end
end
```

Then `Input` shrinks to what changes per call:

```ruby
struct Input
  text: String
  codes: List[Int]
  size: Int
end
```

and `input.classes.get(code, CharClass.Other)` becomes
`CLASSES.get(code, CharClass.Other)`, `input.keywords` becomes `KEYWORDS`, and
so on. `new_input`, `code_set`, `keyword_table`, `operator_table`,
`char_classes` and `classify` are deleted (`blank?`, `newline?`, `letter?` and
`digit?` stay: other code calls them). The lexer's own comment says Set and
Map lookups are 2.5 times faster than predicate chains; a constant read adds
one array access and removes a struct field read, so the hot loop does not
get slower. 44b measures it before it merges (the `make bench` lexer program
or the `compiler/lex.agc` time over `compiler/`).

**The parser (`compiler/parse_base.agc`, `compiler/parser.agc`).**

```ruby
## The deepest nesting the parser accepts (PARSE-TOO-DEEP beyond it).
export NESTING_LIMIT = 1000

# The binding level of a binary operator: 1 or, 2 and, 3 equality,
# 4 comparison, 5 |>, 6 + -, 7 * / %. A token that is not one is level 0.
LEVELS: Map[String, Int] = {
  "or": 1, "and": 2, "equal": 3, "not-equal": 3, "less": 4,
  "less-equal": 4, "greater": 4, "greater-equal": 4, "pipe-forward": 5,
  "plus": 6, "minus": 6, "multiply": 7, "divide": 7, "modulo": 7
}
COMPOUND_OPERATORS: Map[String, String] = {
  "plus-assign": "plus", "minus-assign": "minus",
  "multiply-assign": "multiply", "divide-assign": "divide",
  "modulo-assign": "modulo"
}
LITERAL_KINDS = Set.new(["integer", "float", "string", "true", "false", "nil"])
```

`nesting_limit()` becomes `NESTING_LIMIT`; `level_of(kind)` becomes
`LEVELS.get(kind, 0)` and `compound_operator(kind)` becomes
`COMPOUND_OPERATORS.get(kind, "")`; the chains
`kind == "integer" or kind == "float" or ...` in `parse_base.agc` become
`LITERAL_KINDS.include?(kind)`. The parser's `Env` is not a table holder
(its fields change as parsing goes) and stays as it is.

**Unicode (`compiler/unicode_table.agc`).** The generated file emits a constant
and `Unicode.graphic?` and `written_text` read it instead of calling
`Table.graphic_ranges()`, which builds the 1,900-number list on every call:

```ruby
export GRAPHIC_RANGES = [
  33, 126, 161, 172, 174, 887, 890, 895, 900, 906,
  ...
]
```

The generator (`tools/gen-lexer-unicode.rkt`) changes its output header and
one line; the fast test that compares the generated file stays.

**The linker (`compiler/link_env.agc`, `compiler/module_names.agc`).**
`Settings` carries four tables that never change (`reserved`, `bare_builtins`,
`builtin_enums`, `std_only`) beside the two real inputs (the `stdlib/` folder
and the environment). The generated file becomes constants and `Settings`
keeps the inputs:

```ruby
# module_names.agc (generated by tools/gen-module-names.rkt)
export RESERVED_TYPE_NAMES = Set.new(["Await", "Bool", "Channel", "Dir", ...])
export BARE_BUILTIN_NAMES = Set.new(["error", "gets", "gets!", "ok", ...])
export BUILTIN_ENUM_NAMES = Set.new(["Await", "LogLevel"])
export STD_ONLY: Map[String, StdOnly] = {
  "HttpWire": StdOnly(std_path: "std/http", alias: "HTTP"),
  "LogRegistry": StdOnly(std_path: "std/logger", alias: "Logger")
}
```

```ruby
# link_env.agc
export IO_TIMEOUT_MS = 10000

export struct Settings
  stdlib: String
  env: Env
end
```

`std_only_modules()`, `io_timeout()` and the table fields are gone; every
function that took `settings` only for a table reads the constant, and the
ones that need the folder or the environment keep the parameter.

**The builtin catalog (the step-4a PR, `compiler/builtins_data.agc` and
`compiler/builtins.agc`).** The generated rows are constructor calls and
literals, which is exactly the allowed set (the rows use `Model.Builtin(...)`,
`Types.Type.List(...)`, `Model.Rule.Plain`, and so on). The six helper
functions `rows_1()` ... `rows_6()` exist to keep each literal small; they
become constants, and the lookup tables become folds over them:

```ruby
# builtins_data.agc (generated by tools/gen-builtins-data.rkt)
ROWS_1: List[Model.Builtin] = [
  Model.Builtin(name: "Channel.close", ...),
  ...
]
# ... ROWS_2 to ROWS_6 ...
export ROWS = ROWS_1.concat(ROWS_2).concat(ROWS_3).concat(ROWS_4)
  .concat(ROWS_5).concat(ROWS_6)
export RECORDS: List[Model.Record] = [ Model.Record(name: "FileInfo", ...) ]
export ENUMS: List[Model.EnumDef] = [ ... ]
export STD_ONLY_IMPORTS: Map[String, List[String]] = {
  "HttpWire": ["std/http", "HTTP"], "LogRegistry": ["std/logger", "Logger"]
}
```

```ruby
# builtins.agc: the Catalog struct and catalog() disappear.
export ENTRIES: Map[String, Model.Builtin] = Data.ROWS.reduce({}) do |m, row|
  m.put(row.name, row)
end

# The module of a name is the text before its first dot. A name without a
# dot is its own "module", which is never std-only, as module_of("puts") == "".
export PUBLIC_NAMES = ENTRIES.keys.filter do |name|
  !STD_ONLY.has_key?(name.split(".")[0])
end
```

(`module_of` is a user function, so it is written inline in the block.)
`lookup(catalog, name)`, `ref(catalog, ...)` and `std_only_name?(catalog, ...)`
lose their `catalog` parameter, and so does every checker function that
threads it. The step-4b/4c checker is written against constants from the
start (44.12).

What the examples show about the rules: every table was a literal, a
constructor call or a `reduce`/`filter` over another table, and the one place
that needed more than builtins (`char_classes`) became data. Nothing needed a
user function.

### 44.9 Cost model

- **A read** is `GLOBAL a i`: one bounds-checked array access and a copy of a
  16-byte value (a pointer for a collection). It is not a call and builds
  nothing. A literal constant is a `CONST`, the same cost as the literal itself.
- **No rebuild.** A zero-argument function rebuilds on each call; a constant is
  built once per process. For the Agentica compiler that is once per run, not
  once per `lex` call (one per imported file) or once per `graphic?` call.
- **Start-up.** The cost is the sum of the initializers of the kept constants,
  paid before `main`. For the lexer, parser and linker tables it is a few
  thousand instructions. The big one is the builtin catalog (about 190 rows of
  nested constructors): the checker builds the same value today, in
  `catalog()`, and so the cost moves and does not grow. Row 8.3 (VM start-up
  cost) has a target of the order of 6 ms for the whole VM; 44d measures the
  compiler's start before and after and records the numbers in the PR. The
  pruning of unread constants keeps `import "std/http"` from paying for
  tables it does not use.
- **Memory.** Kept constants live for the whole run. Collections are shared by
  structure; nothing is copied on a read or a `put`.
- **If start-up shows up in the numbers**, a later PR (44e, gated by that
  measurement) adds a data form for constants whose initializer has only
  literals and constructors: the Globals section would hold the encoded value
  tree (kinds as the Constants section, plus list, map, set, struct, variant),
  the loader would build it without running code, and the checker's rules
  would not change. It is not planned until a number asks for it, because it
  adds a value decoder to the loader, which is hostile-input code.

### 44.10 Alternatives considered

- **Literals only (option A).** No evaluation at all: scalars, and list, map
  and set literals. It cannot hold the lexer's tables: `Set.new(...)` is a
  call, the character classes are a fold, the builtin rows are struct
  constructors. A literal map of 100 entries for the classes would be
  unreadable. Rejected: it does not express the tables.
- **Compile-time evaluation in both front ends.** Needs the semantics of every
  allowed builtin in `src/`, in `compiler/` and in the VM (44.4). Rejected;
  the load-time design gives the same program behavior with one
  implementation.
- **Lazy initialization (first read).** Saves start-up for rarely read
  constants. Rejected: errors would appear in the middle of a run, a read would
  need a check and a branch, and tasks could race on the first read.
- **Calls of user functions.** Powerful (`char_classes()` stays as it is) and
  rejected for v1 (44.4). It stays open (question 4).
- **Module attributes `@name` like Elixir.** A new sigil and a new token. The
  capitals already mark a constant and need no lexer change.
- **A `const` keyword.** One more reserved word for what the name already says.
- **A struct of tables passed to every function (today).** The cost in 44.1.

### 44.11 Implementation plan

Small PRs, in this order. Each updates its own tests, goldens and docs (the
rules of `AGENTS.md`: language rules in `docs/grammar/`, the site page and the
programming skill together; the user-visible change in `CHANGELOG.md` under
`## [Unreleased]`).

1. **44a1: VM and writer, no language change.** Bytecode format 5: the Globals
   section (a count), `GLOBAL` and `GLOBAL_SET` (`agc_opcode` in `vm/value.h`
   and `opcodes` in `src/bytecode.rkt`, same order), loader checks and
   run-time behavior (44.7), `docs/vm/03` and `08`. The Racket writer emits
   version 5 and a zero count; the front ends do not use the feature yet. Tests:
   the C tests build `.agcb` files by hand (valid use, slot out of range,
   `GLOBAL_SET` outside the entry, unset read, count over the limit); all
   existing goldens still pass; `make vm-test`. A C change, so the
   `vm-c-critic` review applies. This is the "new format" step of 35.3 done
   before anything uses it.
2. **44a2: the language, both front ends.** `src/lexer.rkt`: no change.
   `src/parser.rkt`, `src/ast.rkt`; `src/modules.rkt` (collect, rank in
   `declaration-order-error`, rewrite to `const-ref`); `src/checker.rkt`
   (order, cycle, forms, types, `const-ref`); `src/lower.rkt` and
   `src/bytecode.rkt` (literals, functions, `<start>`, slot reads). In
   `compiler/`: `ast.agc`, `parse_base.agc`/`parser.agc`, `parse_text.agc`,
   `declarations.agc`, `modules.agc`, `resolve.agc`, `rewrite.agc`,
   `link_text.agc`. Tests: parser goldens (`const-*` valid files, one `err-*`
   per site, `PARSE-CONSTANT-NAME`, the `Alias.NAME.method` form), linker
   goldens (a fixture folder with an exported and a private constant, an
   `Alias.NAME`, a name clash, a bad order), checker tests in
   `tests/checker-test.rkt` (each rule of 44.4 and 44.5 with its code and
   span, the effect-list audit), VM fixtures in `tests/fixtures/vm/` with
   `.expected` (use, dependency order across two files, a constant of structs
   and enums, a runtime error in an initializer, an unread constant that would
   fail), and a round-trip: the linked text form of a program with constants
   links again to the same output. Docs, all in this PR (owner request of
   2026-10-15):
   - `docs/grammar/`: `05-syntax.md` (the constant rule and the new
     declaration order), `05b-modules.md` (`export NAME`, `Alias.NAME`, and
     "no mutable module state"), `06-semantics.md` (evaluation, types, the
     value rules), `07-diagnostics.md` (the four new codes and the new
     `CHECK-DECL-ORDER` help). One line per paragraph.
   - The Hugo site: the tour page for modules
     (`site/content/tour/modules.md`) or a new tour page for constants, plus
     the diagnostics page if the site lists codes. Run `make site` before
     the merge.
   - The `agentica-programming` skill: a short mention in the core rules of
     `SKILL.md` (keep it near 2,000 tokens), the detail in
     `references/language.md`, and in `references/performance.md` the advice
     "build a table once as a module constant, not in a function that runs
     per call". That file comes from the `docs/perf-guide` branch; if it has
     not merged when 44a2 is ready, 44a2 waits for it or adds the paragraph to
     the PR that creates it.
   - The `agentica-development` skill: `references/frontend.md` says that
     `compiler/` keeps its tables as module constants (and lists constants
     among the relaxations of the freeze), `stages.md` (the nodes, codes and
     the order), `vm-lowering.md` (the opcodes and the section).
   - `examples/constants.agc` with its README row, roadmap row 7.2.7 ("Relaxed
     so far") and row 7.2.8 ticked, and `CHANGELOG.md`.

   The PR states which rule it relaxes (the freeze, row 7.2.7) and why (the
   owner's decision of 2026-10-15 and this section).
3. **44b: the lexer.** `compiler/lexer.agc` as in 44.8. The goldens do not
   change. Measure the lexer before and after (the same program over
   `compiler/`), and put the numbers in the PR.
4. **44c: the parser and unicode.** `NESTING_LIMIT`, `LEVELS`,
   `COMPOUND_OPERATORS`, `LITERAL_KINDS`, `GRAPHIC_RANGES` and the generator
   change. Goldens unchanged.
5. **44d: the linker and the catalog.** `module_names.agc`, `link_env.agc`
   (`Settings`), `tools/gen-module-names.rkt`, and, if the step-4a PR (#258) has
   merged, `builtins_data.agc`, `builtins.agc` and
   `tools/gen-builtins-data.rkt` (otherwise 4a is rebased onto 44d's style, or
   44d follows 4a). Goldens unchanged. Start-up numbers in the PR.
6. **44e (only if 44d's numbers ask for it): static data for literal
   constants** (44.9).

44b to 44d are independent of each other after 44a2. Each deletes the zero-
argument functions and threaded structs it replaces and no other code.

### 44.12 Interaction with §35

- **The freeze.** Row 7.2.7 allows only bug fixes and data. 44a1 and 44a2
  relax it, like `Set[T]` (8b) and `.with` (15c): new syntax in both parsers,
  new checker rules, a lowering change and a bytecode change. The owner
  decided on 2026-10-15 (row 7.2.8). This is the last relaxation planned
  before the bootstrap.
- **Order against the port.** Step 3 is done and step 4a (PR #258, the builtin
  catalog as data) is open. 35.7 says no language change touches a stage while
  its port is open; steps 4b and 4c have not started. So 44a1 and 44a2 land
  between 4a and 4b, and the checker port starts from a `src/checker.rkt`
  that already has constants, which is the rule of `Set[T]` and `.with`
  again ("the checker port carries it"). If the owner prefers the other order,
  4b would port the checker and 44a2 would change both checkers in one PR
  (the bug-fix rule). Question 5.
- **What each ported step carries.**
  - Step 2 (parser, done): 44a2 changes `compiler/parser.agc`, `ast.agc` and
    the golden printer in the same PR as `src/parser.rkt`.
  - Step 3 (modules, done): 44a2 changes the `compiler/` linker and
    `src/modules.rkt` together: the constant kind, `CHECK-DECL-ORDER` with
    the constant rank, the `const-ref` rewrite, `CHECK-IMPORT-NAME` and
    `CHECK-REDEFINED-NAME` for constants.
  - Step 4 (checker, 4b/4c): carries 44.4 and 44.5 completely:
    `CHECK-CONSTANT-CYCLE`, `CHECK-CONSTANT-EXPRESSION`, `CHECK-CONSTANT-TYPE`,
    the order, the data-type rule, the effect check from the catalog, the
    type of `const-ref`, and `check` returning the order. It reads the builtin
    effects from the catalog constants (44.8).
  - Step 5 (lowering) carries literal inlining, constant functions, pruning,
    `<start>` and `GLOBAL` reads.
  - Step 6 (bytecode writer) carries the Globals section, version 5 and the
    two opcodes, and must equal the Racket bytes.
  - Steps 7 and 8 do not change.
- **stage0.** There is no `stage0` yet, and `compiler/` is compiled by Racket
  (35.3), so 44b to 44d can use constants as soon as 44a2 merges, with no
  two-step refresh. The first `stage0` is made by a compiler that already uses
  them. The format change needs no extra step for the same reason (the "new
  `.agcb` format" case of 35.3 applies once `stage0` exists).
- **35.4, step 4** gets one sentence that points here (changed in this PR).

### 44.13 Open questions for the owner

1. **Evaluate at load, not at compile time.** The values of constants other
   than plain literals are computed by the VM once before `main` and not folded
   by the compiler (44.4). The visible differences: a runtime error in an
   initializer shows at start, and `agentica check` does not run it.
   *Recommendation:* load time, because folding would put the semantics of the
   builtins in three places; plain literals are inlined and so are in the
   bytecode as asked. 44e adds a static data form if the start-up numbers need
   it.
2. **Constants in `case` patterns.** *Recommendation:* not in v1. Patterns are
   literals and variants; revisit if the compiler's `case` arms on token kinds
   ask for named strings.
3. **Annotation on exported constants.** *Recommendation:* optional, as for
   local bindings; the checker knows the type, and `agentica outline` (§39)
   shows it.
4. **Calls of user functions in an initializer.** *Recommendation:* no in v1
   (44.4). Revisit after 44d with the list of tables that still need a helper.
5. **Order against the checker port.** *Recommendation:* 44a1 and 44a2 land
   after 4a and before 4b, so the Agentica checker is written once, with
   constants.
