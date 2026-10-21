# Asking the compiler about code

From an Agentica program, `std/analysis` gives the same answers as structs
(`references/analysis.md`).

`agentica outline FILE`, `agentica type-at FILE:LINE:COL`, `agentica refs
FILE:LINE:COL` and `agentica symbol NAME [PATH...]` ask the compiler about code
without reading whole files. `outline` lists what one file declares, so you do
not read the whole file to learn its signatures. It only lexes and parses the
file: its imports need not exist, and it needs no `main`. FILE is a source file
or a `std/` module (`agentica outline std/queue`).

```sh
agentica outline src/orders.agc          # one line per declaration
agentica outline --json src/orders.agc   # one JSON object on stdout
cat buffer.agc | agentica outline --stdin src/orders.agc
```

The text form is `file:line:column` first, like `rg`:

```text
src/orders.agc:1:1 import Models from "models"
src/orders.agc:3:1 export struct Order
src/orders.agc:4:3 field Order.id: Int
src/orders.agc:8:1 export def total(order: Order) -> Int
src/orders.agc:14:1 def round_cents(value: Float) -> Int
```

Private declarations are listed too (`agentica doc` shows only the exported
API). `--stdin FILE` stands in for the FILE argument: the text on standard
input is FILE, whether or not the disk has it, so you can ask about a buffer you
have not saved. The file is named by its canonical path, relative to the working
folder when it is below it (`std/NAME.agc` for a `std/` module). A diagnostic
keeps the name as typed, like `check`; only an answer's `file` is canonical. A
symlink answers with its target's name; from `/` the name has no leading slash;
a file outside the working folder is absolute. A user file under a `std/` folder
read with `--stdin` is named `./std/NAME`, never like an embedded module.

## JSON

`{version: 1, command: "outline", file, doc, imports, items}`.

- `imports`: `{path, alias, names, span}`. `alias` is null for
  `import {a, B as C} from "p"`, whose `names` are `{name, local, span}`.
- `items`, in source order: `{kind, name, exported, signature, doc, summary,
  span, name_span}`. `kind` is `function`, `struct`, `enum`, `alias` or
  `constant`; `summary` is the first paragraph of the `##` doc or null.
  - a function adds `parameters` (`{name, type, default}`) and `result`;
  - a struct adds `fields` (`{name, type, doc, name_span}`);
  - an enum adds `variants` (`{name, payload, doc, name_span}`).
- A span is `{file, range: {start: {line, column}, end: {line, column}}}`, lines
  and columns from 1, the end exclusive. `span` is the whole declaration,
  `export` included; `name_span` is the name alone, the place to edit.

Types are written as in the file (`Models.User`).

`--partial` is accepted and changes nothing: `outline` never checks.

## Exit codes of outline

- 0: the answer.
- 1: a `LEX-` or `PARSE-` error in the file; fix the file first.
- 2: `QUERY-USAGE`, at the pseudo-file `<arguments>`: a missing or extra
  argument, an unknown option, `--stdin` without a file, or a path that cannot
  be read. Fix the question.

# The type at a position

`agentica type-at FILE:LINE:COL` gives the checked type of the innermost
expression at a position, and where what it names is defined. Line and column
count from 1, in characters, as in a diagnostic, so `outline` and `check`
positions work as they are.

```sh
agentica type-at src/orders.agc:22:14
agentica --json type-at src/orders.agc:22:14
cat buffer.agc | agentica type-at --stdin src/orders.agc:22:14
```

```text
src/orders.agc:22:9-22:19 user.email: String
src/models.agc:4:3 field email
```

The first line is the span of the expression, its text and its type; the second,
if there is one, the name of the definition. On a builtin the second line is
`builtin` and its signature (one line for each form); docs are in the JSON only.
On the name of a field or a method the expression is the whole access
(`user.email`). The file and what it imports are linked and checked, but it
needs no `main`, so a library file works.
`--stdin FILE:LINE:COL` takes the text of FILE from standard input (the buffer
you have not saved); FILE is a path of the disk, never a `std/` module.

A type of another file is written as the file writes it: `Models.User` through
`import Models from "models"`, a bare name when the file does not import it
under an alias. Line and column count code points (an emoji is one column; an
editor that counts UTF-16 units converts). A type argument (`Models.User` in
`List[Models.User]`) is not answered yet.

## JSON of type-at

`{version: 1, command: "type-at", position: {file, line, column}, kind, text,
type, span, definition, help}`.

- `kind` is `builtin` when the position is on the name of a builtin (`split` in
  `xs.split(",")`, `puts`), `name` when it is on another name (a variable, a
  constant, the callee of a call, the field or method after the dot, the name
  where a local is bound) and `expression` otherwise. It is an open set (later
  versions add values): accept a value you do not know. `span` is always the
  whole expression and `text` its source.
- `definition` is null, or the span of the declaration (`{file, range}`) with
  `kind` (`function`, `struct`, `enum`, `variant`, `field` or `constant`; for a
  local see below), `name`, `name_span` (the span of the name), `signature`
  (`make(name: String) -> User`, `age: Int` for a field, `Circle(Float)` for a
  variant) and `doc` (the whole `##` text, or null). It is null for a builtin,
  which still has its type.
- A local answers with its type and a `definition` at its binding, on a use of
  the name and on the binding itself (the answer is then the same on both). Its
  `kind` is `parameter` (of a function or a block), `local` (the assignment that
  introduces the name), `loop` (a `for` variable) or `pattern` (a name in a
  `case` pattern); `signature` is `name: Type` and `doc` null. The top-level
  `span` and `text` are the name alone. The definition's `range` is the binding
  node when it has one (the whole parameter or assignment), else the name (a
  `loop` and a `pattern`); `name_span` is the name where it is bound, the place
  to navigate to. The binding is the one whose scope holds
  the position, so a name bound in sibling blocks (two `for i` loops, `note` in
  each branch of an `if`) answers its own, and a use inside a block of a local
  outside it answers the outer binding. An assignment to a name already bound
  (`total += 1`) is a use of that binding. A `_` binds nothing and is on no
  expression. `kind` is an open set: accept a value you do not know.
- `help` is null, except for `kind` `builtin`: then it is the object of
  `agentica help NAME --json` for that builtin (`name`, `signature`,
  `description`, `parameters`, `effects`; `overloads` for a builtin with
  several forms). `to_s` on an Int answers `String.from_int`; `to_s` and
  `inspect` answer a builtin only where the checker resolves them to one
  (numbers).

## Exit codes of type-at

- 0: the answer.
- 1: the program has an error (`LEX-`, `PARSE-` or `CHECK-`), in the file or in
  an import; it is printed as `check` prints it. Fix the program first.
- 2: `QUERY-USAGE` (a bad `FILE:LINE:COL`, an unreadable file) or
  `QUERY-NO-EXPRESSION`: the position is not on a token of an expression (a
  blank between tokens, a comment, a keyword that is part of no expression such
  as `return`, `end` or `case`, the body text of a heredoc, past the end of a
  line or of the file). Its span is the position. Move onto the expression; a
  keyword of an expression (`try`, `do`, `and`, `!`) answers that expression.

## Partial answers

While you edit, the program often does not check. `type-at --partial` and `refs
--partial` answer anyway when only some functions fail to check: exit 0, the
usual JSON plus `"partial": true` and `diagnostics` (the `--json` objects of the
functions that failed, in program order). A complete answer has neither key, so
without errors the bytes are those of the command without the option.

- `type-at` in a function that checked gives its type and definition. On a name
  written in a function that did not check (a call, a constructor, a variant, a
  type, a constant, a builtin) it gives `kind` `name` (`builtin`), the span of
  the written name, the definition from the link, and `type` null (text form:
  `?`). A field, a method call and a local there give the first problem.
- `refs` on a function, struct, enum, alias, constant or variant lists every
  use, those in the functions that failed too. A local of a function that
  checked works. A field or a builtin gives the first problem (exit 1): its uses
  are told by types.
- A program that does not lex, parse or link, and one whose declarations fail
  (their types, `main`, a constant), are the first problem, exit 1, with or
  without the option. So is a field, a local or a keyword in a function that
  did not check; any other position on no expression (a blank, a comment, an
  import line) is QUERY-NO-EXPRESSION, exit 2, as in a program that checks. In text form each problem
  of a partial answer is a stderr line `partial FILE:LINE:COL: CODE`.

Use it to run `refs --partial` on a function or type again after you edit its
signature, and `type-at --partial` to read a definition in the function you are
fixing. Fix the `diagnostics` before you trust a field or a type.

# Where a name is defined

`agentica symbol NAME [PATH...]` finds the declarations that NAME names in the
modules linked from the files under PATH (a file or a folder; default `.`), so
you do not `rg` for a definition or read a file for a signature.

```sh
agentica symbol Models.User.email src/
agentica --json symbol total src/orders.agc
cat buffer.agc | agentica symbol total --stdin src/orders.agc
```

```text
src/models.agc:4:3 field User.email: String
```

NAME is written as the code writes it:

- `total`: a function, struct, enum, alias or constant, private ones too; a
  bare name lists every module that declares it;
- `Models.total`, `Models.User`: through an import alias of a file under PATH
  (exported names only; the same alias for two modules lists both). Aliases
  come only from whole-module imports (`import M from "m"`): after
  `import {make as mk} from "m"`, `symbol mk` is QUERY-NOT-FOUND and `symbol
  make` finds the declaration;
- `User.email`, `Models.User.email`: a struct field; `Option.Some`: a variant;
- `std/queue.pop`, `std/queue.Popped.value`: a `std/` module that is linked;
- `Map.get`, `puts`: a builtin, with the `help` object and no place.

A folder is every `*.agc` file below it, in bytewise order of the path, without
hidden folders, `agc_libs/` and links. The files are linked on their own, so the
answer needs no `main` and no type check; a file that does not lex, parse or
link is under `skipped` and the rest still answer. Matches come in the order the
files were linked, then by position. `--stdin FILE` is the text of FILE (it need
not exist) and is searched too, first. Text form: `file:line:column` and the
declaration as `outline` prints it (`field`, `variant`); each skipped file is
`skipped FILE: CODE` on stderr.

## JSON of symbol

`{version: 1, command: "symbol", query, matches, skipped}`.

- `matches[]`: `{kind, name, module, exported, signature, doc, span,
  name_span}`. `kind` is `function`, `struct`, `enum`, `alias`, `constant`,
  `field`, `variant` or `builtin` (an open set). `name` is the name alone;
  `module` is the file's name; `doc` is the whole `##` text or null; `span` is
  the declaration, `export` included, as in `outline` (the `range` of a
  `type-at` definition starts after `export`: compare `name_span`).
- a field adds `type` and `struct`; a variant `payload` and `enum`; a builtin
  has `help` (the object of `agentica help NAME --json`) and null `module`,
  `span`, `name_span` and `doc`.
- `skipped[]`: `{file, diagnostic}`, the diagnostic being the `--json` object
  of the first problem of that file or of what it imports.

## Exit codes of symbol

- 0: the answer, `skipped` roots included.
- 1: no file links; the first diagnostic is printed as `check` prints it.
- 2: `QUERY-USAGE` (a missing NAME, an unknown option, a path that cannot be
  read, a folder with no `*.agc` file) or `QUERY-NOT-FOUND`: nothing declares
  NAME in the linked files, and the help names the closest name and the files
  that were skipped.

# References to a name

`agentica refs FILE:LINE:COL` lists every use of the declaration that the name
at a position stands for, in FILE and the files it imports. Run it before you
change a field, a variant or a function, and keep the list: it tells
`Models.User` from a local `User`, and a field `name` of one struct from that of
another, which `rg` cannot. Positions, `--stdin FILE:LINE:COL`, `file` names and
the exit codes are those of `type-at`; the program is checked (exit 1 on an
error), and a use in a file that only imports FILE is not seen, so ask from the
file that links everything you change.

```sh
agentica refs src/orders.agc:22:14
agentica --json refs src/orders.agc:22:14
```

```text
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:31:5 construct in sample
```

The position is on a use or on the name where a declaration is written. The
first line is the definition (none for a builtin) and each next line is a use
with its `kind` and the function it is in; the span of a use is the name alone
(`total` of `Models.total`), so it is the text to edit. Names of a function,
struct, enum, variant, field, constant, type alias, local, parameter or builtin
work; two names that look alike but are different declarations are never mixed
(the `i` of two loops, the `note` of two branches of an `if`).

A position on the module alias of `Models.total(u)` selects the function
`total`, not the module `Models`. A position on a name in an import line is
QUERY-NO-EXPRESSION: an import is not a reference, so ask from a use or from the
declaration.

`{version: 1, command: "refs", query, definition, builtin, references,
skipped}`.

- `definition` is null for a builtin, else
  `{kind, name, module, exported, signature, span, name_span}`: `kind` as in
  `type-at` (a local is `parameter`, `local`, `loop` or `pattern`), `span` the
  whole declaration and `name_span` the name; a field adds `struct`, a variant
  `enum`. The definition is not in `references`.
- `builtin` is the name of the builtin (`File.read`, `List.map`), else null.
- `references`: `{kind, function, span}`, files in the order they were linked
  (FILE first), then by position. `kind` is `call`, `value` (`&f`, a constant),
  `type` (an annotation), `construct` (a struct construction, a `with`, or a
  variant constructor, with the span of the field name for a field), `read` (a
  field read), `pattern` (a variant in a `case` arm) or `binding` (a use of a
  local, `x += 1` included). `function` is the enclosing function or null. It is
  an open set: accept a value you do not know. An empty list is an answer, exit
  0.
- `skipped` is always `[]` for now.

## Exit codes of refs

- 0: the answer.
- 1: the program has an error; fix it first, or ask with `--partial` for a
  function, type or variant.
- 2: `QUERY-USAGE` (a bad `FILE:LINE:COL`, an unreadable file, a name in place
  of a position) or `QUERY-NO-EXPRESSION`: the position is on no name, or on a
  name in an import line.
