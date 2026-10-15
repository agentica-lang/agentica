## 44. Module constants

**Status:** planned, roadmap row 7.2.8. Requested by the owner on 2026-10-15
and wanted before the bootstrap, so the Agentica front end (`compiler/`) can
use them. It relaxes the freeze of the Racket front end (row 7.2.7,
[§35](35-self-hosting.md)) in both front ends, as `Set[T]` (8b) and
`value.with(...)` (15c) did. The same owner decision of 2026-10-15 changes
the import syntax (44.2), which lands first. This section is the design; the
implementation PRs are listed in 44.12.

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
`nesting_limit()`, `graphic_ranges()`, `Data.reserved_type_names()`) or as a
struct built once and passed to every call (the lexer's `Input`, the linker's
`Settings`, which holds the `Catalog` of step 4a). Both cost something:

- A zero-argument function builds its value again on every call.
  `Unicode.graphic?` builds a list of about 1,900 numbers each time it runs.
- A struct that carries tables adds a parameter to every function between the
  place that builds it and the place that reads it, and it is built again for
  every `lex` call, so the linker builds the lexer's tables once per imported
  file.

Constants fix both: one value per run, read where it is needed.

### 44.2 Imports

The owner decided on 2026-10-15 to change the import syntax together with
constants, and to land it first (44a0). Constants, functions, structs and enums
read best when a file can name what it uses. Two changes, and one thing that
stays. A constant of another module is reached only through a named import
(decision 3 below).

```ebnf
import_decl = "import", ( TYPE_NAME | name_list ), "from", STRING, NL ;
name_list = "{", import_name, { ",", import_name }, [ "," ], "}" ;
import_name = ( NAME | TYPE_NAME ), [ "as", ( NAME | TYPE_NAME ) ] ;
```

```ruby
import Lexer from "compiler/lexer"
import {MAX_DEPTH, Token, lex} from "compiler/lexer"
import {lex as lex_text, Token as Tok} from "compiler/lexer"
```

1. **The alias form changes.** `import Mod from "path"` replaces
   `import "path" as Mod`. This is breaking: the old form is
   `PARSE-UNEXPECTED-TOKEN` at the string, with the help "write
   `import Alias from "path"`". The alias is a `TYPE_NAME`, as today. The path
   rules do not change (relative, `std/`, `pkg/`, no extension, the
   `CHECK-IMPORT-*` codes).
2. **Named imports.** `import {A, B} from "path"` brings the exported names `A`
   and `B` into the file, to be used bare, for everything a module can export:
   functions (`lex(text)`, `&lex`, `x |> lex()`), structs (`Token(...)`, the
   type `Token`, `Token` in a signature), enums (`Color.Red`, `Color.Red(x)`,
   the type `Color` and `Color[T]`, and `Color.Red` in a `case` pattern) and
   constants (`MAX_DEPTH`, and after 44a2). Variants are not imported on their
   own: import the enum. A list may span lines (it is inside braces), may end
   with a comma, and may not be empty. An entry may rename: `A as B` binds
   `B` in this file for the exported `A` (decision "Rename" below).
3. **`Mod.name` stays for functions, structs and enums, and is not valid for
   constants.** A module imported with an alias is used as before: `Mod.f()`,
   `Mod.Token(...)`, `Mod.Color.Red`. Both import forms work in one file. A
   module imported only by names has no alias, so `Mod.` is not available for
   it. A constant is never written `Mod.MAX_DEPTH`: the file must import it,
   `import {MAX_DEPTH} from "x"`, and then write `MAX_DEPTH`. The module may
   also offer a getter, `export def max_depth() -> Int`, which is read like any
   function.

**Decisions.**

- **`from` is a contextual word, not a keyword.** `compiler/lexer.agc` has
  parameters named `from` (`scan_doc`, `skip_blanks`, `skip_in`,
  `skip_until`), and a keyword would break them. The parser reads `from` as an
  ordinary name token whose text is `from`, right after the alias or the closing
  brace, as `as` is read today ("`as` is contextual in imports").
- **One line does one thing.** `import Mod, {A} from "x"` is not accepted.
  Two lines with the same path are allowed (`import Mod from "x"` and
  `import {A} from "x"`): the file is loaded once, and today's linker already
  accepts two aliases for one path. Reason: one way to write each thing, and a
  smaller grammar; the cost is one extra line.
- **A named import acts as a declaration of this file.** It takes the same
  place in the name table as a `def`, `struct`, `enum` or constant that the file
  declares, and it is checked the same way:
  - against a declaration of this file with the same name, against an import
    alias, against another named import (also in the same list, and also the
    same name from the same module twice), against a builtin function name
    (`puts`, `ok`) and against a reserved type name (`Int`, `JSON`, `Set`):
    `CHECK-REDEFINED-NAME`, located at the name in the braces (the name after
    `as` for a rename, since the clash is on the local name). The linker
    collects the declarations before it reads the imports, so a clash with a
    declaration is found when its import is read, and a clash between two
    imports at the later one; an alias is also checked against the names
    imported before it. No new code.
  - A local variable or parameter named like an imported function behaves as
    for a function of the file: nothing new.
- **Unknown or private names:** `CHECK-IMPORT-NAME` at the name in the braces
  ("unknown or private imported name"), with the did-you-mean help over the
  module's exports only (the help `Mod.nme` gets today). A path that cannot be
  loaded is still `CHECK-IMPORT-IO`, `-PATH` or `-CYCLE` at the import.
- **Std-only modules are unchanged.** `HttpWire` and `LogRegistry` are reserved
  names that only `std/` may call, so they can be neither an alias nor an
  imported name (`CHECK-REDEFINED-NAME`), and their help text now says
  `import HTTP from "std/http"`. A named import from a `std/` module works as
  from any module.
- **`Mod.NAME` on a constant** is `CHECK-IMPORT-NAME`, located at the
  expression `Mod.NAME`, when the module exports the constant: no new code,
  because the problem is the same as for a name the alias does not offer. The
  message says that a constant is read by name, not through the alias, and the
  help shows the line to write, with the path as it was written in the alias
  import: `import {NAME} from "path"`, and then `NAME`; a second line says that
  the module can export a function instead. If the module has no such export,
  the usual unknown-or-private message and did-you-mean apply (the suggestion
  list holds the exports of the module; a constant is suggested only as
  `import {NAME}`). `Mod.NAME.method(...)` is a parse error today (a type name
  must follow the second dot) and stays one, with today's message and no
  import help: the parser knows neither the path of the import nor that `NAME`
  is a constant.
- **`CHECK-DECL-ORDER` does not change.** A named import is an import: imports
  come first.
- **Rename: `import {A as B} from "path"`** (owner decision of 2026-10-15,
  part of 44a0-1). It exists so that two modules that export the same name can
  both be imported by name, and so that a long name can be shortened.
  - `as` is contextual here too: after the original name, a name token whose
    text is `as` starts the rename. The original always comes first, so a
    function called `as` can still be imported (`{as}`, `{as as as_text}`).
  - The local name follows the case rules of what it names, and the linker
    checks them because only the linker knows the kind of `A`: a struct or an
    enum is renamed to a `TYPE_NAME`, a function to a lowercase name, and a
    constant stays `UPPER_SNAKE_CASE` (the rule of 44.3; constants arrive in
    44a2, so that case and its test are 44a2's). Anything else is the new
    `CHECK-IMPORT-RENAME`, located at the local name, with the help "a
    constant is renamed to another constant name" (or the matching text for the
    other kinds). A new code, because no existing one says this: it is not a
    clash and not an unknown name.
  - Collisions are checked on the local name; the original name is not bound
    in the file unless it is imported by another entry. `{A as B, A as C}` is
    allowed (two local names for one export).
  - An unknown or private `A` is `CHECK-IMPORT-NAME` located at `A`, with the
    same did-you-mean help.
  - The linker maps `B` to the linked name of `A` (`@2::A`), so everything after
    the import is as for an unrenamed name. The `.with` privacy rule does not
    change: it depends on the module, not on the names. Messages that print a
    declaration's name show the original name (the display name of the linked
    name), not the local one.
- **Order and places of the checks (as built in 44a0-1).** The names of a
  list are checked once the module they come from is loaded (they need its
  exports), so a failure inside that module, or in the modules it imports,
  comes first. Then, entry by entry in source order: `CHECK-IMPORT-NAME` at the
  original name, `CHECK-IMPORT-RENAME` at the local name, then
  `CHECK-REDEFINED-NAME` at the local name (the name after `as`, or the only
  name when there is no `as`). An alias is also checked against the names
  imported before it. The `CHECK-IMPORT-PATH` helps of a name list show the
  line as `import {A, B as C} from "path"`. The text form of the parser prints
  `names=["A"@SPAN,"B"@SPAN as "C"@SPAN]`.
- **Re-exports stay out of scope** (§25, 15b). An imported name is not
  exported; `export` still cannot precede `import`. Unused names are not
  reported: that is `CHECK-UNUSED-IMPORT` of §26.
- **A bare imported function needs parentheses**, as a local function does:
  the rule that drops them is for module functions reached through an alias
  (`Util.reset`).

**Why not `Mod.NAME` (the Elixir rule).** In Elixir a module attribute
(`@attr`) is read only inside the module that sets it, and there is no
`Mod.@attr`: another module calls a function (`Mod.attr()`) or defines its own
attribute. The owner chose the same line, for two reasons that hold here. A
dot form would make a constant look like a zero-argument module function
(`Util.reset` already drops its parentheses, so `Mod.MAX` and `Mod.max` would
read alike) and like state of the module. And a named import binds the name
in the file that uses it, so the reader of a file sees at the top which
constants it depends on, and the compiler checks that the module exports it.
Python's `mod.FOO` is the other model and is not followed.

**How the linker names them.** The parse rules do not change for uses:
`NAME` and `Alias.NAME` already parse as a `type-expression` (the second is
then `CHECK-IMPORT-NAME` when it names a constant, as above), `Token(...)` as a
`construct`, `lex(text)` as a `call`, `Color.Red` as a `type-expression` and
`Color.Red(x)` as an enum value. The only parser change is `import-decl`. The
linker, which already turns `Enum.Variant` of a local enum into an enum value,
does the rest. Each file gets a table `named`: name to the file that exports it
(built where the aliases are, with the checks above). Then:

- a name without a dot that is in `named` (under its local name, 44.2 "Rename")
  is renamed to the linked name of the declaration in its file (`@2::lex`),
  exactly the name the declaration has in the linked program, wherever the name
  is written: a type, a `construct`, a `call`, a function reference `&lex`, an
  enum in a type, a pattern or an enum value;
- the same check on the kind that the qualified form makes applies: a name used
  as a function must be a function, as a type a struct or enum, and a wrong kind
  is `CHECK-TYPE-MISMATCH`, as for `Mod.name` today;
- `Color.Red` and `Color.Red(x)` with `Color` in `named` as an enum become the
  enum value of the linked enum, as `Mod.Color.Red` does;
- `NAME.x` and `NAME.x(...)` with `NAME` in `named` as a constant are
  rewritten with the constant as the receiver (44.3);
- the checks come before the rewrite, so an unknown or private name is reported
  at the import, not at the first use.

**The privacy rule of `.with`.** The rule is: a file may update its own structs
and the exported structs of the modules it imports. A module imported by name
counts as imported, with all its exported structs, not only the ones named:
the file could add an alias import of the same module and construct any of
them, so naming adds no protection. In `src/modules.rkt` the `constructible`
set is built from the targets of aliases and of `named`; in `compiler/`
`Modules.Module` gets the targets of its named imports and `visible_structs`
(`compiler/linker.agc`) takes both. The text form of the linker keeps printing
the sorted `visible` list.

**What changes in the front ends (44a0).** `import-decl` (`src/ast.rkt`,
`compiler/ast.agc`) has `path`, an `alias` (or none) and a list of imported
names, each with the original name, the local name (equal when there is no `as`)
and the span of each; exactly one of alias and names is present. Parsers:
`src/parser.rkt` (`parse-program`) and `compiler/parser.agc` (the import
parser). Text forms of the parser and linker goldens print the new shape
(`alias=` or `names=[...]`). Linkers: `src/modules.rkt` and
`compiler/modules.agc`, `declarations.agc`, `resolve.agc`, `rewrite.agc`. The
checker does not see imports (the linker rewrote them), but two of its help
texts show the import form (`src/checker.rkt`, the unknown-function help for
`BDD.` and `HTTP.` names: `import BDD from "std/bdd"`, `import HTTP from
"std/http"`). So 44a0-2 edits `src/checker.rkt` (message text only) and
`src/modules.rkt` and `compiler/` (more help texts), and the goldens that hold
messages. A checker port that exists by then carries the new text (44.13).

**The migration.** One script, not committed (the PR text records the regular
expression), rewrites every occurrence in the repository: `.agc` files in
`stdlib/`, `compiler/`, `examples/`, `tests/` (the VM and front-end fixtures,
`tests/std`, `tests/eval`), `benchmarks/`, `site/content/`,
the skills, `docs/` and `README` files, and the program texts inside Racket and
other test sources (escaped quotes, `src/bdd-driver.rkt`). At the time of
writing (counting hidden folders such as `.agents/`): 563 occurrences in 307
files. It works on bytes, so `.input` files keep
their bytes and line endings. The new form is two characters longer, so every
span in the goldens moves: `make goldens` rewrites them and the diff is
reviewed. After the script, `rg --hidden 'import\s+\\?"[^"]*\\?"\s+as'` finds
nothing. The CHANGELOG entry is marked `**Breaking:**`. External `pkg/`
libraries written with the old form stop loading: the first PR of the split
accepts both forms so their authors can move before the old form goes (44.12).

### 44.3 Syntax

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
  (`HttpRequest`). The built-in all-capitals names (`IO`, `JSON`, `TCP`, `TLS`)
  are reserved type names and so cannot be constants.
- The type is optional. `NAME = expr` takes the type of `expr`, as a local
  binding does. `NAME: Type = expr` checks `expr` against `Type`, and gives
  the empty forms `[]`, `{}` and `Set.new([])` the type they need, as it does
  for a local.
- The value is one expression. It may span lines inside brackets (`(`, `[`,
  `{`) or a `do ... end` block. It cannot start on the line after `=`, as for a
  local binding.
- `export NAME = ...` makes the constant visible to importers.
- A `##` doc block above a constant documents it (§32).
- Constants follow each other, and the imports before them, with no blank line,
  also when a constant has a doc block or `export`. `parse-program` today
  raises `PARSE-MISSING-BLANK-LINE` when a declaration that is not an import is
  followed by `def`, `struct`, `enum`, `export`, `import` or a doc block, so
  the rule gets one exemption: no blank line is needed between a constant and
  the next declaration when that declaration (after its optional doc block and
  `export`) is a constant too. The parser looks ahead for it. A blank line is
  still needed between a constant and a `struct`, `enum` or `def`
  (`PARSE-MISSING-BLANK-LINE`), and after any other declaration.

**Reading a constant.** `NAME`, in the file that declares it, or in a file
that imports it by name (`import {NAME} from "path"`, 44.2). `Mod.NAME` is not
a form: see 44.2. It is an expression, so everything that works on a value
works on it: `KEYWORDS.include?(word)`, `LEVELS.get(kind, 0)`, `CLASSES[code]`,
`"#{LIMIT}"`.

How the parser sees these forms matters, because a constant looks like a type
or a module (`Models.User`, `JSON.decode`):

- `NAME` already parses as a `type-expression` (the node that holds a bare type
  name, a nullary variant such as `CharClass.Other`, or a JSON type argument).
  No change.
- `NAME.x(args)` and `NAME.x` parse today as a module call
  `call "NAME.x"` (parenthesized or not), which is also what `JSON.parse(x)`
  and `Util.reset` are. The parser cannot tell them apart, because an import
  alias may also be all capitals (`import HTTP from "std/http"`). The linker
  decides: a name that is a constant of the file (declared or imported by
  name) and not an alias or builtin module becomes the receiver of the same
  nodes that `xs.size` and `xs.get(k, d)` give. With
  parentheses or with a block argument (`LEVELS.get(kind, 0)`,
  `KEYWORDS.include?(word)`, `KEYWORDS.each do |k| ... end`, which has no
  parentheses but is a call, and the parser records it as not parenthesized)
  the call becomes a `method-call`. The rule is: no parentheses and no
  arguments, a block being an argument, gives a `field-access`
  (`KEYWORDS.size`, `CONFIG.port`); anything else a `method-call`. The
  `field-access` is the node a builtin property or a struct field gets. A struct
  constant with parentheses (`CONFIG.port()`) is then the usual
  `CHECK-UNKNOWN-METHOD`. This is how the linker already turns `Enum.Variant`
  into an enum value.
- The linker needs one bit that the parse tree must keep: whether the call was
  written with parentheses. The Agentica `Call` node has it (`parenthesized`).
  The Racket parser keeps it only in a weak table private to `parse`
  (`parenthesized-calls`, `src/parser.rkt`); 44a2 makes that table a module
  level one and exports a predicate `parenthesized-call?`, and the Racket
  linker asks it for the original node before it rebuilds the call.
- A chain on an enum value, `Color.Red.to_s`, is a parse error today and stays
  one; this design does not add it. The same holds for a constant of an
  enum: write `DEFAULT_COLOR.to_s`, which is a constant read.

No parser change is needed for reads: the only parser change of this part is
the declaration (44.7).

Local variables, parameters, block parameters and `for` variables are lowercase
names, and a constant is never lowercase, so **a local can never shadow a
constant**. There is nothing to resolve and no shadowing rule. A statement `NAME
= 1` or `NAME += 1` inside a function is `PARSE-INVALID-ASSIGNMENT-TARGET` today
(the target is not a name); the PR adds a help line, "constants are set at the
top level and never change". A constant cannot be reassigned because no syntax
assigns to one.

**Not in the syntax.** Case patterns (`case x` with `LIMIT -> ...`): patterns
are literals and variants, and a constant would make them depend on values
(decided against for v1, 44.14). Default parameter values do not exist yet
(row 7.5a); when they land, a constant is a valid default, because it is a
value fixed for the run. No `static`, `const` or `final` keyword and no
`@name` form: the capitals are the marker. No module state: a constant never
changes, so "no module state" in `docs/grammar/05b-modules.md` stays true
(44a2 words it "no mutable module state").

### 44.4 Semantics

- **Scope.** A constant belongs to its file. It is visible in the whole file,
  before and after its line. `export` lets a file that imports this one name
  it in `import {NAME} from "path"`; without it, that import is
  `CHECK-IMPORT-NAME` ("unknown or private imported name", with the
  did-you-mean help, which lists only exports). Imports still cannot be
  re-exported.
- **One namespace with types.** A constant cannot have the name of a struct, an
  enum, an import alias, a builtin or a reserved type name:
  `CHECK-REDEFINED-NAME`. Two constants of one file with one name are the same
  error.
- **Order of evaluation.** The initializers run once, before `main`, in
  dependency order (44.7, "Order"). A constant may use constants of its own file
  and of imported files. Cycles are `CHECK-CONSTANT-CYCLE`. Imports cannot form
  a cycle (`CHECK-IMPORT-CYCLE`), so a cycle is always inside one file.
- **Types.** A constant has one type, known from the initializer and the
  annotation. The type must be fully known (no unresolved `[]`) and made of data
  types only (44.5). Constants are not generic.
- **Values are immutable and shared.** Lists, maps, sets and structs are
  persistent values in Agentica. `KEYWORDS.add("x")` gives a new set and leaves
  `KEYWORDS` unchanged, and no copy is made to protect it. All tasks read the
  same value. The initializers finish before `main` starts, so no task is
  running while a constant is being set.
- **Errors in an initializer.** The checker proves an initializer has no
  effects and ends (44.5), but not that it succeeds. `[1, 2][5]`, `1 / 0`,
  `"x".to_i!` and an `Int` overflow are runtime errors, with the usual
  `RUNTIME-*` code, the span of the expression and the stack trace, and they
  stop the program before `main` runs and before it prints anything. They are
  the same on every run, so the first run finds them. `agentica check` does not
  run initializers and does not find them.
- **Unused constants.** A constant that no function reachable from `main`
  reads, directly or through another constant, is not set (44.7). The checker
  still checks it, so a type error in it is reported; a runtime error in its
  initializer is not, because it never runs.
- **`agentica test` and the BDD driver** load the same bytecode, so a constant
  is set at the start of each test child as in any program.

### 44.5 Value rules

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
   table access (44.8).

**Decided: no folding of literal arithmetic, no aliasing of literals.** A
constant is a literal constant only when its initializer is one literal (or `-`
and a number literal). `SECONDS = 60 * 60` and `LIMIT = OTHER_LIMIT` are
ordinary constant expressions, set once at load, and a read of them is one slot
access just as a read of a folded value would be. Folding would put the
arithmetic of `Int` and `Float` (overflow, division, float text) in three
places, Racket, Agentica and the VM. Folding may come later, with 44e, if
start-up numbers ask for it.

**What a constant expression may contain.** The rule is a list of what is
allowed, so a new language form is out until someone adds it:

- Literals, string interpolation, list, map and `Set.new` literals, ranges.
- Construction of structs, enum variants and `ok`/`error` values, including the
  builtin records and enums.
- Unary and binary operators, field access, indexing, `==` and the rest of
  the operators on their usual types.
- Reading another constant (of the same file, or imported by name).
- Calls of builtins whose row in the builtin catalog has **no effects**
  (`effects: []` in `src/builtins.rkt`), as functions or methods: `Set.new`,
  `List.map`, `List.reduce`, `List.concat`, `Map.put`, `Range.to_a`,
  `String.split`, `String.code`, `Int.bit_and`, `Float.from_bits`, and the
  rest of the effect-free rows (`effects: []` in about half of the 210 rows
  of `compiler/builtins_data.agc`).
- Block literals (`do |x| ... end`) passed to those builtins. The body may use
  assignments, `if`, `case`, `for`, `break`, `next` and `return`, and the same
  expressions and calls, and nothing else.

**What it may not contain** (`CHECK-CONSTANT-EXPRESSION`, located at the form,
with a help that says why):

- A call of a function declared in a program (`def`). No user function calls
  in v1 (see "Why no user functions" below).
- `&name` function values, and a block that is stored or returned instead of
  passed to a builtin.
- `while` loops. (`for` over a collection or a range, and the builtins that
  count, are fine: see "Why this ends" below.)
- A call of a builtin with effects: any of `stdout`, `stderr`, `stdin`,
  `filesystem`, `network`, `subprocess`, `process`, `logging`, `concurrency`,
  `clock`, `random`, `test`.

**What its types may be** (`CHECK-CONSTANT-TYPE`): every expression inside a
constant expression, not only the result, has a data type: `Int`, `Float`,
`Bool`, `String`, `Nil` (not `Void`), `List`, `Map`, `Set`, `Range`, `Result`
and `JSON` of data types, and the structs and enums (user and builtin) whose
fields and payloads are data types. A `Fn`, `Channel`, `Task` or handle type
(`Socket`, `Listener`, `HttpServer`, `FileHandle`, `Process`), `HttpClient` and
`TestCase` are not data types. This closes the cases the effect list misses:
`Channel.new` has `effects: []`, but it makes a value with identity and state,
and its result is not a data type.

**Why this is pure, deterministic and ends.** No effect means the value
depends only on the program. No `while`, no user calls and no recursion means
the initializer has no loop that tests a condition and no call that can come
back to itself: every loop runs over a finite collection or counts to an `Int`,
and every call is a builtin. So it **terminates**. It is not bounded by the
size of its data: `Int.times(n)`, `Int.upto`, `Int.downto`, `Range.each` and
`for i in 0..N` run `N` times for any `Int` `N`, and the default step budget is
`INT64_MAX` (`vm/main.c`), so `for i in 0..1_000_000_000_000` hangs the start
of the program unless `--max-steps` is set. The checker never runs the
initializer, so `check` does not hang; only the run does, as a long `main`
would. Memory limits apply as to any code. The PR that adds a builtin with
empty effects must make it deterministic and terminating. A test audits the
catalog: it lists every effect-free row whose result, or a parameter other than
a block (`Fn`) parameter, has a type that is not a data type (today
`Channel.new`, `Channel.closed?` and `Test.test`; the audit finds any other)
and asserts that the checker rejects a call of each. Rows that only take
a block, such as `List.map`, are not on the list.

**Why no user functions (v1).** Allowing `def` calls would make the rule depend
on a purity and termination analysis of the call graph (recursion, higher
order calls through `Fn`, mutual recursion across files), which has to be
written twice, in Racket and in Agentica, and then kept equal. The tables of
`compiler/` do not need it (44.9): where a table is built by a helper
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
loading builds the values. 44.10 measures the second. Question 1 (44.14) asks
the owner to confirm.

### 44.6 Diagnostics

New codes, stable, with the span of the form named:

- `PARSE-CONSTANT-NAME`: a top-level `Name = ...` or `Name: T = ...` whose
  name is not `UPPER_SNAKE_CASE` of two or more characters. Span: the name.
- `CHECK-CONSTANT-CYCLE`: a constant reads itself, directly or through other
  constants. Span: the reference that closes the cycle; the help lists
  `A -> B -> A`.
- `CHECK-CONSTANT-EXPRESSION`: the initializer uses a form that 44.5 does not
  allow. Span: that form.
- `CHECK-CONSTANT-TYPE`: an expression of the initializer has a type that is
  not a data type. Span: that expression.
- `CHECK-IMPORT-RENAME`: `import {A as B}` where `B` does not follow the case
  rule of what `A` is (44.2). Span: `B`. (An import diagnostic, not a
  constant one; listed here with the other new codes. 44a0-1 adds it for
  functions, structs and enums, 44a2 for constants.)

Reused codes: `CHECK-REDEFINED-NAME` (duplicate or reserved name),
`CHECK-DECL-ORDER` (44.7), `CHECK-IMPORT-NAME` (a private or unknown name in an
import list, and `Mod.NAME` on a constant, 44.2), `CHECK-TYPE-MISMATCH`
(annotation or use), `CHECK-EMPTY-SET-TYPE` and the other empty-collection codes
(`NAME = []` without a type), and `CHECK-UNKNOWN-NAME` for an unknown `NAME`
with the did-you-mean help over the constants in scope. `CHECK-INT-RANGE` and
the rest of the expression rules apply inside initializers as everywhere.
`PARSE-TOO-DEEP` counts initializers too.

Cycle detection: depth-first over the constants in linked order, following
references **in the order of their start offsets in the source text** of the
initializer (so a map literal gives a key before its value, a call its
receiver, its arguments and then its block, an interpolation its parts left to
right, whatever the node shapes of the two trees); the first reference that
reaches a constant already on the path is the error. Both checkers do exactly
this, so they agree on the span. The same order of references gives the
initialization order (below).

### 44.7 Front end

**Parser (both).** `ast.rkt` and `compiler/ast.agc` get one declaration node
(`const-decl`: name, optional type, value, `exported`, span; docs as for other
declarations). `parse-program` accepts a `TYPE_NAME` token followed by `=` or
`:` where it accepts `def`, `struct` and `enum`. That is the whole parser
change. The depth rule counts the initializer. The
text forms of the parser goldens print `const` nodes (the line of a declaration,
then `type:` and `value:` children), with `export` as for other declarations.

**Declaration order.** `CHECK-DECL-ORDER` becomes: imports, then constants,
then `struct` and `enum`, then `export def`, then `def`. Constants come right
after the imports because a reader looks for the tables of a file first, as in
Ruby and Python, and because they are data, not code. The order is a style
rule, as it is now: a constant may use a struct or enum declared below it
(`ClassRange(...)` in 44.9). The help text for a constant out of place says
"constants come right after the imports". The rank function lives in
`src/modules.rkt` (`declaration-order-error`) and in
`compiler/declarations.agc`.

**Linker (both).** `modules.rkt`/`modules.agc` collect constants as a kind of
declaration, exported or not, in the same name table as types and functions
(`Declarations.Kind` gets `Constant`). The rewrite turns a `type-expression`
or a `call` `NAME.x` that names a constant of the file (declared or
imported by name, 44.2; the call becomes a `field-access` or a `method-call`
on the constant, 44.3) into a new node
`const-ref` with the linked name (`@2::NAME` for a file with prefix `@2::`;
the root file has no prefix, as now). It rewrites the `const-decl` name the
same way. A name that is neither a constant nor a type keeps today's path, so
no existing program changes meaning. `const-ref` has an `id` in
`compiler/ast.agc` like any expression, and the linked text form prints it.

**Checker (Racket now; the Agentica port in 4b/4c).**

1. Collect struct and enum declarations and function signatures as now.
2. Order the constants (below), check cycles, then check each initializer
   in that order against its annotation, in an environment with no locals, and
   record the constant's type. Apply the 44.5 rules while walking the
   initializer: forms, builtin effects, data types.
3. Check function bodies. A `const-ref` has the recorded type.

*Order.* Visit the constants in linked order; to visit one, first visit the
constants its initializer reads, in the order of their start offsets in the
source, then emit it. A constant
that is already emitted is skipped. This order is deterministic, so both
front ends and both bytecode writers agree. The order is shared code
(`constant-order` in `src/constants.rkt`, `compiler/check_const.agc`), not an
output of `check`: the Racket `check` keeps its API and returns the program, and
the lowering calls `constant-order` on the linked program. The Agentica
`Checked` has a `constants` list with the order, and the check text ends with
a `constant-order [...]` line when the program has constants.

**Lowering (Racket now; step 5 later).**

`src/lower.rkt` emits every function of every linked module, so a rule of the
form "read by a function" would count any function of any imported file: the
tables of `std/http` would be paid by every program that imports it, and a
failing initializer in an unused import would stop every importer. So lowering
decides what to initialize from the call graph:

- *Reachable functions.* Start at `main`; follow every call of a user function
  (`f(x)`, `Mod.f(x)`, `x |> f()`), every function reference `&f` and the
  blocks inside a body, to a fixed point. This is a walk over the linked tree
  of cost linear in its size.
- *Kept constants.* The constants read by a reachable function, then, to a
  fixed point, those read by a kept constant.
- A literal constant (44.5, kind 1) is replaced by its literal at each read and
  has no slot.
- *Slots.* Every non-literal constant read by any emitted function or by a
  constant that is read gets a slot, numbered by the order of 44.7. Only kept
  constants are initialized. A function that is not reachable reads a slot that
  nothing writes; it cannot run, because every call and `&f` is in the walk.
  (The alternative, to emit only reachable functions, would change the
  bytecode of every program.)
- Each kept constant becomes a function with no parameters named by its linked
  name, whose body is `return <initializer>`. The existing code that lowers a
  function body lowers it, blocks and all. Its spans are those of the
  constant's source.
- If there is at least one kept constant, lowering adds a function `<start>`
  with no parameters: for each kept constant, in order, `CALL` its function and
  `GLOBAL_SET` the result into its slot; then a tail call of `main`. `<start>`
  is the entry of the file. With no kept constants there is no `<start>` and
  the entry is `main`.
- A read of a constant that has a slot is `GLOBAL a i`.
- *Function table, for byte equality.* The functions are, in this order: the
  declared functions in program order (as now), the kept constants' functions
  in initialization order, `<start>`, and then the block functions, numbered in
  the order lowering creates them while it lowers the functions in that same
  order. Both lowerings and both writers use this layout, and the entry is the
  index of `<start>`.

### 44.8 Bytecode and VM

**Format version 5.** Version 4 is `STRUCT_WITH` (15c). Two things change the
layout, so the version goes to 5:

- A new section **Globals** after Updates and before Builtins: a `u32` count of
  slots (the constants that have a slot, kept or not). Nothing else: the
  initializers are ordinary functions called by the entry.
- Two opcodes appended after `STRUCT_WITH` (an appended opcode alone would not
  change the version, the section does):
  - `GLOBAL a bx`: `R[a] = G[bx]`.
  - `GLOBAL_SET a bx`: `G[bx] = R[a]`.

**Versions of other designs.** §41 and §42 each reserved version 5 for their
type-table kinds. Module constants come first, by the owner's request, so
this design takes 5. §42 now takes 6, or 7 if §41 lands first; §41 takes 6,
or 7 if §42 lands first. 41.18 and 42.11 say so (changed in the same PR as
this section).

**Loader.** The loader reads the count and allocates the slot array through
`load_alloc` (`vm/loader.c`), so the memory budget of the load charges it. The
count cannot be bounded by the bytes left (`read_count` checks a minimum number
of bytes per entry, and a slot has none), so the cap below is what bounds it.
The array is part of the `agc_program`, as the constant pool is, so it is
reachable from the same roots and the collector keeps its values. It rejects
(with the loader's usual rejection, as for other bad operands):

- a count above 65,535 (`BYTECODE-LIMIT` in the writer, as for structs; the
  writer of 44a1 always writes 0, so that check comes with 44a2);
- a `GLOBAL` or `GLOBAL_SET` whose slot is not below the count;
- a `GLOBAL_SET` in a function that is not the entry, and a function that has
  a `GLOBAL_SET` and a backward jump (a jump whose target is not after it);
- when the Globals count is above zero, a `CALL`, `TAIL_CALL` or `CLOSURE`
  whose target is the entry function, so no task can run the entry again and
  write a slot after `main` started. With a count of zero the entry is `main`,
  which a program may call (`main()` inside `main`); nothing is rejected, and
  the rules about the entry apply only to a file that has slots. Only the
  entry writes, each `GLOBAL_SET` running at most once (no backward jump),
  before `main`. After the entry has tail-called `main` the table is read-only,
  which keeps a future multicore scheduler (step 11) free of races on it. The
  loader cannot stop a hand-made entry from spawning a task before its last
  write, so the multicore build must not run a second task on another scheduler
  until the entry has handed over to `main` (`docs/vm/10-io-multicore.md`
  §10.2.3, "The Globals table"); at one scheduler nothing is racy.

**Run time.** A slot starts as zeroed memory, which is tag 0, `AGC_T_VOID`
(`vm/value.h`). No module constant has type `Void` (44.5), so tag 0 means
"unset", and `GLOBAL` of a slot with tag 0 is `RUNTIME-INTERNAL` (only a
hand-made file can do it, or a `GLOBAL_SET` of a Void, which unsets the slot;
the front end orders the reads). The loader has checked every slot index, so a
read is an array access and a register copy, as `CONST` is, and neither
instruction charges cost beyond the `STEP`s of its function. Initializers run
under the normal step budget (`--max-steps`, which is `INT64_MAX` unless set)
and the normal limits, in the main task, with no scheduler involvement, because
the checker allows no effects and no waiting. A hostile file that does wait or
loop in the entry is the same case as a hostile `main`: memory safe, bounded by
the budget.

**Traces.** An error in an initializer shows the function named by the
constant, then `<start>`. The call depth limit (10,000) sees one frame for each.

**Bytes.** A program without constants differs from today in the version
number and in the new Globals section, a `u32` zero (4 bytes), and has the same
functions and entry. A program with constants adds the slots, the functions and
`<start>`. The Racket writer and the Agentica writer (step 6) must give the
same bytes, which the order and the function layout of 44.7 guarantee.

**The `docs/vm` pages that change** (in 44a1): `03-ir-and-bytecode.md` (4.2
opcodes, 4.6 table and the version in the header row and the last bullet),
`08-loader-and-cli.md` (header check and new rejections).

### 44.9 The tables of `compiler/`, rewritten

The test the design must pass: the real tables of `compiler/` fit. Every
example below uses only what 44.5 allows. The expressions of the snippets
were checked with `racket src/main.rkt check` inside functions of a scratch
file (the constant line itself is the new syntax); a method call may not
continue on a line that starts with a dot, so the list of rows is joined with
nested `concat` calls, as `builtin_rows()` does today.

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
44.5 the same table is data plus a fold, with no user function. The constants
come first in the file (44.7), so they sit above the `struct ClassRange` and the
`enum CharClass` that they use; the order is a style rule and does not matter
to the checker:

```ruby
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

# ... after the constants, with the other types of the file:
struct ClassRange
  kind: CharClass
  first: Int
  last: Int
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
`char_classes` and `classify` are deleted. `blank?` and `newline?` stay (other
code calls them); `letter?` and `digit?` were used only by `classify`, so they
are deleted too. The lexer's own comment says Set and
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
`COMPOUND_OPERATORS.get(kind, "")`; the six-kind
chain `kind == "integer" or ... or kind == "nil"` at `parse_base.agc:478`
becomes `LITERAL_KINDS.include?(kind)`. The chains of three kinds
(`integer`, `float`, `string`) at `parse_base.agc:276` and `parser.agc:764` are
a different set and stay as they are. The parser's `Env` is not a table holder
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

**The linker and the builtin catalog (step 4a, merged in PR #258).**
`Settings` (`compiler/link_env.agc`) holds the two real inputs of a link (the
`stdlib/` folder and the environment) and a `Builtins.Catalog`, which
`settings()` builds with `Builtins.catalog()` (210 rows, 2.6 ms) and which every
function that resolves a name reads through `cx.settings.catalog`. The catalog
is not an input: it is a table of the program. The generated rows are
constructor calls and literals, which is exactly the allowed set
(`Model.Builtin(...)`, `Types.Type.List(...)`, `Model.Rule.Plain`, and so on).
`builtins_data.agc` keeps its rows in six functions `rows_1()` ... `rows_6()`
of at most 40 rows, because of the 60-line limit of the style rule
(`tools/gen-builtins-data.rkt`). A constant is not a function, so that limit
does not apply to it. The generator keeps six literals all the same, because
one expression is lowered into one frame, which has a register limit:

```ruby
# builtins_data.agc (generated by tools/gen-builtins-data.rkt)
ROWS_1: List[Model.Builtin] = [
  Model.Builtin(name: "Channel.close", ...),
  ...
]
# ... ROWS_2 to ROWS_6 ...
export ROWS = ROWS_1.concat(ROWS_2.concat(ROWS_3.concat(ROWS_4.concat(
  ROWS_5.concat(ROWS_6)))))
export RECORDS: List[Model.Record] = [ Model.Record(name: "FileInfo", ...) ]
export ENUMS: List[Model.EnumDef] = [ ... ]
export RESERVED_TYPE_NAMES = ["Await", "Bool", "Channel", ...]
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

(`module_of` is a user function, so it is written inline in the block. The
other tables of `Catalog` (`bare_names`, `records`, `enums`, `opaque`,
`handles`, `reserved`, `std_only`) are written the same way.) `Settings` loses
`catalog`:

```ruby
# link_env.agc
export IO_TIMEOUT_MS = 10000

export struct Settings
  stdlib: String
  env: Env
end
```

`settings()` stops building anything. `lookup(catalog, name)`,
`ref(catalog, ...)` and `std_only_name?(catalog, ...)` lose their `catalog`
parameter, and so does every function that threads `cx.settings.catalog`
(`resolve.agc`, `rewrite.agc`, `modules.agc`) and the checker of 4b and 4c.
`io_timeout()` becomes `IO_TIMEOUT_MS`.

What the examples show about the rules: every table was a literal, a
constructor call or a `reduce`/`filter` over another table, and the one place
that needed more than builtins (`char_classes`) became data. Nothing needed a
user function.

### 44.10 Cost model

- **A read** is `GLOBAL a i`: one array access (the loader checked the index)
  and a copy of a 16-byte value (a pointer for a collection). It is not a call
  and builds nothing. A literal constant is a `CONST`, the same cost as the
  literal itself.
- **No rebuild.** A zero-argument function rebuilds on each call; a constant is
  built once per process. For the Agentica compiler that is once per run, not
  once per `lex` call (one per imported file) or once per `graphic?` call.
- **Start-up.** The cost is the sum of the initializers of the kept constants,
  paid before `main`. For the lexer, parser and linker tables it is a few
  thousand instructions. The big one is the builtin catalog (210 rows of nested
  constructors, 2.6 ms today): the linker builds the same value today, in
  `catalog()`, and so the cost moves and does not grow. Row 8.3 (VM start-up
  cost) has a target of the order of 6 ms for the whole VM; 44d measures the
  compiler's start before and after and records the numbers in the PR. The
  pruning of unread constants keeps `import HTTP from "std/http"` from
  paying for tables it does not use.
- **Memory.** Kept constants live for the whole run. Collections are shared by
  structure; nothing is copied on a read or a `put`.
- **If start-up shows up in the numbers**, a later PR (44e, gated by that
  measurement) adds a data form for constants whose initializer has only
  literals and constructors: the Globals section would hold the encoded value
  tree (kinds as the Constants section, plus list, map, set, struct, variant),
  the loader would build it without running code, and the checker's rules
  would not change. It is not planned until a number asks for it, because it
  adds a value decoder to the loader, which is hostile-input code.

### 44.11 Alternatives considered

- **Literals only (option A).** No evaluation at all: scalars, and list, map
  and set literals. It cannot hold the lexer's tables: `Set.new(...)` is a
  call, the character classes are a fold, the builtin rows are struct
  constructors. A literal map of 100 entries for the classes would be
  unreadable. Rejected: it does not express the tables.
- **Compile-time evaluation in both front ends.** Needs the semantics of every
  allowed builtin in `src/`, in `compiler/` and in the VM (44.5). Rejected;
  the load-time design gives the same program behavior with one
  implementation.
- **Lazy initialization (first read).** Saves start-up for rarely read
  constants. Rejected: errors would appear in the middle of a run, a read would
  need a check and a branch, and tasks could race on the first read.
- **Calls of user functions.** Powerful (`char_classes()` stays as it is) and
  rejected for v1 (44.5). It stays open (question 4).
- **Module attributes `@name` like Elixir.** A new sigil and a new token. The
  capitals already mark a constant and need no lexer change.
- **A `const` keyword.** One more reserved word for what the name already says.
- **A struct of tables passed to every function (today).** The cost in 44.1.

### 44.12 Implementation plan

Small PRs. 44a0 comes first, in two parts. 44a1 touches only `vm/` and the
bytecode writer, so it can run at the same time as 4b and 4c. 44a2 follows
44a0. Each updates its own tests, goldens and docs (the rules of `AGENTS.md`:
language rules in `docs/grammar/`, the site page and the programming skill
together; the user-visible change in `CHANGELOG.md` under `## [Unreleased]`).

1. **44a0-1: new import forms, both front ends** (44.2). Both the old alias form
   and the new forms are accepted, so nothing breaks and no file changes. The
   parsers (`src/parser.rkt`, `src/ast.rkt`; `compiler/parser.agc`, `ast.agc`,
   `parse_text.agc`) read `import Mod from "path"`, `import {A, B as C} from
   "path"`. The linkers (`src/modules.rkt`; `compiler/modules.agc`,
   `declarations.agc`, `resolve.agc`, `rewrite.agc`, `linker.agc`) keep the
   `named` table, apply the collision, `CHECK-IMPORT-NAME`,
   `CHECK-IMPORT-RENAME` and kind checks, rename bare names, and extend the
   `.with` privacy set. Tests: parser goldens (the alias form, a name list, a
   multi-line list, a trailing comma, an empty list, a rename, `from` and `as`
   as ordinary names); linker fixture folders (a function, a struct, an enum
   with its variants and patterns imported by name; `.with` on a struct of a
   module imported by name; each collision of 44.2; each rename rule; an unknown
   and a private name with the did-you-mean help; two lines with one path); a VM
   fixture that uses named imports; and the differential golden of both front
   ends (the Racket printer and the Agentica linker print the same text; the
   text form is not source, so there is no round trip). Docs, all in this PR,
   because 44a0-1 adds user-visible syntax and a code (`AGENTS.md`, and each
   PR of a stack holds its own docs): `docs/grammar/05-syntax.md` (the
   `import_decl` rule), `05b-modules.md` (the forms, `Mod.name`, collisions,
   rename) and `07-diagnostics.md` (`CHECK-IMPORT-RENAME` and the help rows);
   the Hugo site, the tour page `modules.md` and the diagnostics page if it
   lists codes (`make site` before the merge); the `agentica-programming`
   skill (`SKILL.md` core rules, which stay near 2,000 tokens, and
   `references/modules.md`); the `agentica-development` skill
   (`references/frontend.md`: the import forms and the linker's `named` table;
   `stages.md`: the new code and the new shape of the `import-decl` node);
   `CHANGELOG.md` with an "Added" entry. External `pkg/` libraries keep
   working.
2. **44a0-2: the migration and the end of the old form** (**Breaking:**). The
   migration script runs over the whole repository (563 occurrences in 307
   files at the time of writing), `make goldens` rewrites the goldens (the
   spans move), the old form becomes `PARSE-UNEXPECTED-TOKEN` with the help,
   and the help texts that show the import form change: `src/modules.rkt`,
   `compiler/` and also `src/checker.rkt` (the `BDD.` and `HTTP.` help of the
   unknown-function error, a message text). It carries only what the removal
   needs: the grammar and skill pages lose the old form, and the
   `**Breaking:**` entry of `CHANGELOG.md` is written. The two parts keep the
   final state at one form, as the owner decided; the split exists because of
   the size of the migration and so that `pkg/` authors can move first. Both
   parts state which rule they relax (the freeze, row 7.2.7: a syntax change in
   both parsers and both linkers) and why (the owner's decision of
   2026-10-15). They do not depend on 4b; the one checker line is a message
   text (44.13).
3. **44a1: VM and writer, no language change.** Bytecode format 5: the Globals
   section (a count), `GLOBAL` and `GLOBAL_SET` (`agc_opcode` in `vm/value.h`
   and `opcodes` in `src/bytecode.rkt`, same order), loader checks and
   run-time behavior (44.8), `docs/vm/03` and `08`. The Racket writer emits
   version 5 and a zero count; the front ends do not use the feature yet. Tests:
   the C tests build `.agcb` files by hand (valid use, slot out of range,
   `GLOBAL_SET` outside the entry, a jump back in the entry, a call of the
   entry when the count is above zero, a program with a zero count whose `main`
   calls `main`, which must load and run, an unset read, a count over the
   limit); all existing goldens still
   pass (their bytes change by the version and the zero count); `make vm-test`.
   A C change, so the `vm-c-critic` review applies. This is the "new format"
   step of 35.3 done before anything uses it.

   **44a1 relaxes two rules, on purpose.** The development skill
   (`references/vm-lowering.md`, "New opcode") says "No opcodes for later PRs",
   and `AGENTS.md` says "No placeholder files or nodes for later phases". 44a1
   adds two opcodes and a section that nothing emits yet. It stays a separate PR
   because the C part needs its own `vm-c-critic` review and because 44a2 is
   large; 44a2 follows right after, and uses them. The same recipe asks for a
   fixture in `tests/fixtures/vm/` for each new runtime code or span; 44a1 has
   only the hand-made C tests, because a `.agc` program cannot reach the new
   code before 44a2, and 44a2 adds the fixtures (an initializer that fails, a
   constant read, the order across two files). If 44a2 is delayed, the
   opcodes stay unused and the PR says so.
4. **44a2: the language, both front ends.** `src/lexer.rkt`: no change.
   `src/parser.rkt`, `src/ast.rkt`; `src/modules.rkt` (collect, rank in
   `declaration-order-error`, rewrite to `const-ref`); `src/checker.rkt` (order,
   cycle, forms, types, `const-ref`); `src/lower.rkt` and `src/bytecode.rkt`
   (literals, functions, `<start>`, slot reads). In `compiler/`: `ast.agc`,
   `parse_base.agc`/`parser.agc`, `parse_text.agc`, `declarations.agc`,
   `modules.agc`, `resolve.agc`, `rewrite.agc`, `link_text.agc`, and the
   Agentica checker if 4b has merged (44.13); in `src/parser.rkt` the table
   `parenthesized-calls` becomes module level with an exported predicate (44.3).
   Tests: parser goldens (`const-*` valid files, one `err-*` per site,
   `PARSE-CONSTANT-NAME`, the blank-line exemption, a documented and an exported
   constant after a constant), linker goldens (a fixture folder with an exported
   and a private constant, a named import of a constant, `Mod.NAME` on a
   constant, `NAME.size` and `CONFIG.port`, `LEVELS.get(k, 0)` and
   `KEYWORDS.each do |k| ... end` on constants, a name clash, a bad order), the
   rename of a constant (`CHECK-IMPORT-RENAME` for a non-UPPER_SNAKE local name,
   the case of 44.2 that 44a0-1 cannot test), checker tests in
   `tests/checker-test.rkt` (each rule of 44.5 and 44.6 with its code and span,
   the effect-list audit), VM fixtures in `tests/fixtures/vm/` with `.expected`
   (use, dependency order across two files, a constant of structs and enums, a
   runtime error in an initializer, an unread constant that would fail), and the
   differential golden of both front ends for the linked text of a program with
   constants (the text form is not source, so no round trip). Docs, all in this
   PR (owner request of 2026-10-15):
   - `docs/grammar/`: `05-syntax.md` (the constant rule, the blank-line
     exemption and the new declaration order), `05b-modules.md` (`export NAME`,
     importing a constant by name, `Mod.NAME` not valid, the rename of a
     constant, and "no mutable module state"),
     `06-semantics.md` (evaluation, types, the value rules),
     `07-diagnostics.md` (the four new codes and the new `CHECK-DECL-ORDER`
     help). One line per paragraph.
   - The Hugo site: the tour page for modules
     (`site/content/tour/modules.md`) or a new tour page for constants, plus
     the diagnostics page if the site lists codes. Run `make site` before
     the merge.
   - The `agentica-programming` skill: a short mention in the core rules of
     `SKILL.md` (keep it near 2,000 tokens), the detail in
     `references/language.md`, and in `references/performance.md` the advice
     "build a table once as a module constant, not in a function that runs
     per call" (the file exists since PR #257; its "Lookup tables" section is
     the place), and `references/modules.md` for the constant import.
   - The `agentica-development` skill: `references/frontend.md` says that
     `compiler/` keeps its tables as module constants (it also lists constants
     and the import forms of 44a0 among the relaxations of the freeze),
     `stages.md` (the nodes, codes and the order), `vm-lowering.md` (the opcodes
     and the section).
   - `examples/constants.agc` with its README row, roadmap row 7.2.7 ("Relaxed
     so far") and row 7.2.8 ticked, and `CHANGELOG.md`.

   The PR states which rule it relaxes (the freeze, row 7.2.7) and why (the
   owner's decision of 2026-10-15 and this section).
5. **44b: the lexer.** `compiler/lexer.agc` as in 44.9. The goldens do not
   change. Measure the lexer before and after (the same program over
   `compiler/`), and put the numbers in the PR.
6. **44c: the parser and unicode.** `NESTING_LIMIT`, `LEVELS`,
   `COMPOUND_OPERATORS`, `LITERAL_KINDS`, `GRAPHIC_RANGES` and the generator
   change. Goldens unchanged.
7. **44d: the linker and the catalog.** `link_env.agc` (`Settings`),
   `builtins_data.agc`, `builtins.agc`, `tools/gen-builtins-data.rkt`, and the
   functions that read `cx.settings.catalog` (`resolve.agc`, `rewrite.agc`,
   `modules.agc`). Goldens unchanged. Start-up numbers in the PR.
8. **44e (only if 44d's numbers ask for it): static data for literal
   constants** (44.10).

44b to 44d are independent of each other after 44a2. Each deletes the zero-
argument functions and threaded structs it replaces and no other code.

### 44.13 Interaction with §35

- **The freeze.** Row 7.2.7 allows only bug fixes and data. 44a0 (the import
  syntax) and 44a1 and 44a2 (constants) relax it, like `Set[T]` (8b) and
  `.with` (15c): new syntax in both parsers and both linkers, new checker
  rules, a lowering change and a bytecode change. The owner decided on
  2026-10-15 (row 7.2.8). This is the last relaxation planned before the
  bootstrap.
- **Where the port stands.** Step 4a (PR #258, the builtin catalog as data) and
  the performance guide (PR #257) are merged on master. Step 4b has started,
  in parallel with this design. 35.7 says no language change touches a stage
  while its port is open, so the rule for these PRs is the one of the
  bug-fix case:
  - 44a1 changes `vm/` and `src/bytecode.rkt` only (no ported stage), so it
    goes in parallel with 4b and 4c.
  - 44a0 changes the parsers and the linkers, which are ported (steps 2 and 3),
    so it changes `src/` and `compiler/` together. The checker never sees an
    import, but `src/checker.rkt` has one message text with the old form (the
    help of the unknown `BDD.` and `HTTP.` function): 44a0-2 changes it, and
    the Agentica checker, if 4b has merged by then, in the same PR; if not, 4b
    carries the new text.
  - 44a2 adds checker rules. It changes whichever checker exists when it lands.
    If 4b has merged, 44a2 changes `src/checker.rkt` and the Agentica checker
    in the same PR (the rule for a change in a ported stage). If 4b has not
    merged, 44a2 changes `src/checker.rkt` and 4b carries the rules when it
    merges master (the rule of `Set[T]` and `.with`: "the checker port carries
    it"). Whichever PR lands second ports the change; the goldens catch a miss.
  Question 5 asks the owner to confirm.
- **What each ported step carries.**
  - Step 2 (parser, done): 44a0 changes the import node and parser, and 44a2
    the declaration node and parser, in `compiler/parser.agc`, `ast.agc` and
    the golden printer, in the same PRs as `src/parser.rkt`.
  - Step 3 (modules, done): 44a0 changes the `compiler/` linker and
    `src/modules.rkt` together (named imports, rename, collisions, `named`
    table, `.with` privacy). 44a2 adds the constant kind, `CHECK-DECL-ORDER`
    with the constant rank, the `const-ref` rewrite, and `CHECK-IMPORT-NAME` for
    `Mod.NAME`.
  - Step 4 (checker, 4b/4c): carries 44.5 and 44.6: `CHECK-CONSTANT-CYCLE`,
    `CHECK-CONSTANT-EXPRESSION`, `CHECK-CONSTANT-TYPE`, the order, the data-type
    rule, the effect check from the catalog, the type of `const-ref`, and
    `check` returning the order. It reads the builtin effects from the catalog
    (44.9). From 44a0 it carries only the new import text of the
    unknown-function help.
  - Step 5 (lowering) carries literal inlining, constant functions, pruning,
    `<start>` and `GLOBAL` reads.
  - Step 6 (bytecode writer) carries the Globals section, version 5 and the
    two opcodes, and must equal the Racket bytes.
  - Steps 7 and 8 do not change (their help texts use the new import form
    through the migration of 44a0).
- **stage0.** There is no `stage0` yet, and `compiler/` is compiled by Racket
  (35.3), so 44b to 44d can use constants as soon as 44a2 merges, with no
  two-step refresh. The first `stage0` is made by a compiler that already uses
  them. The format change needs no extra step for the same reason (the "new
  `.agcb` format" case of 35.3 applies once `stage0` exists).
- **35.4, step 4** gets one sentence that points here (changed in this PR).

### 44.14 Open questions for the owner

Decided by the owner on 2026-10-15, so not open: the import forms and the
rename (44.2), constants only through a named import (44.2), and no folding of
literal arithmetic (44.5).

1. **Evaluate at load, not at compile time.** The values of constants other
   than plain literals are computed by the VM once before `main` and not folded
   by the compiler (44.5). The visible differences: a runtime error in an
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
   (44.5). Revisit after 44d with the list of tables that still need a helper.
5. **Order against the checker port.** 4b has started. *Recommendation:*
   44a1 in parallel with 4b; 44a0 as soon as it is ready; 44a2 right after
   44a0, changing whichever checker exists, so the later PR of each pair ports
   the change of the other.
6. **One line for both import forms** (`import Mod, {A} from "x"`).
   *Recommendation:* no (44.2); two lines with one path are allowed. One way to
   write each thing, and a smaller grammar.
