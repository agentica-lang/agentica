# Asking the compiler about code

`agentica outline FILE` and `agentica type-at FILE:LINE:COL` ask the compiler
about code without reading whole files. `outline` lists what one file declares,
so you do not read the whole file to learn its signatures. It only lexes and
parses the file: its imports need not exist, and it needs no `main`. FILE is a
source file or a `std/` module (`agentica outline std/queue`).

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
  constant, the callee of a call, the field or method after the dot) and
  `expression` otherwise. It is an open set (later versions add values):
  accept a value you do not know. `span` is always the whole expression and
  `text` its source.
- `definition` is null, or the span of the declaration (`{file, range}`) with
  `kind` (`function`, `struct`, `enum`, `variant`, `field` or `constant`),
  `name`, `name_span` (the span of the name), `signature` (`make(name: String)
  -> User`, `age: Int` for a field, `Circle(Float)` for a variant) and `doc`
  (the whole `##` text, or null). It is null for a local (a parameter, a
  binding, a loop variable or a pattern name) and for a builtin; both still
  have their type.
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
