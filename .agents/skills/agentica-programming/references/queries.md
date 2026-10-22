# Asking the compiler about code

`agentica outline FILE`, `type-at FILE:LINE:COL`, `refs NAME|FILE:LINE:COL
[PATH...]` and `symbol NAME [PATH...]` answer questions about code without
reading whole files. Each takes `--json` (one object on stdout) and `--stdin
FILE` (the text on standard input is FILE, saved or not; `type-at` and `refs`
take `--stdin FILE:LINE:COL`, before the position). `--stdin FILE` takes the
place of the FILE argument (`outline --stdin FILE`, not `outline FILE --stdin
FILE`); FILE need not exist, but imports are found from its folder, and
`std/...` is then a path of the disk, not a `std/` module. Options may come
before the command (`agentica --json refs ...`) or after it. Answers go to
stdout and diagnostics to stderr; `--ai` changes only how diagnostics print.
The text form starts with `file:line:column`, like `rg`. Lines and columns
count from 1, in code points. Every JSON answer has `"version": 1` and
`"command"`; a field that changes meaning gets a new version, new fields can
appear within a version (ignore keys you do not know), and types and
signatures are strings. From a program, `std/analysis` gives the same answers
as structs (`references/analysis.md`).

Exit codes: 2 is a bad question, 1 a program that does not check.

| Command   | Exit 1: fix the program | Exit 2: fix the question |
| --------- | ----------------------- | ------------------------ |
| `outline` | `LEX-`, `PARSE-` in the file | `QUERY-USAGE` |
| `type-at` | `LEX-`, `PARSE-`, `PKG-`, `CHECK-` in the file or its imports | `QUERY-USAGE`, `QUERY-NO-EXPRESSION` |
| `symbol`  | no file links | `QUERY-USAGE`, `QUERY-NOT-FOUND` |
| `refs`    | any error in the program, or FILE (or every file of PATH) does not link | `QUERY-USAGE`, `QUERY-NOT-FOUND`, `QUERY-AMBIGUOUS-NAME`, `QUERY-NO-EXPRESSION` |

`QUERY-USAGE` is at `<arguments>` (a missing or extra argument, an unknown
option, `--stdin` without a file, a bad `FILE:LINE:COL`, an unreadable path, a
folder with no `*.agc`). Errors print as `check` prints them.

## outline

```sh
agentica outline src/orders.agc          # one line per declaration
agentica outline --json src/orders.agc
cat buffer.agc | agentica outline --stdin src/orders.agc
```

```text
src/orders.agc:1:1 import Models from "models"
src/orders.agc:3:1 export struct Order
src/orders.agc:4:3 field Order.id: Int
src/orders.agc:8:1 export def total(order: Order) -> Int
src/orders.agc:14:1 def round_cents(value: Float) -> Int
```

It parses only: imports need not exist and no `main` is needed. FILE may be a
`std/` module (`agentica outline std/queue`). Private declarations are listed
too (`agentica doc` shows only the exported API). `--partial` is accepted and
changes nothing.

JSON: `{version: 1, command: "outline", file, doc, imports, items}`.

- `imports`: `{path, alias, names, span}`. `alias` is null for `import {a, B as
  C} from "p"`, whose `names` are `{name, local, span}`.
- `items`, in source order: `{kind, name, exported, signature, doc, summary,
  span, name_span}`. `kind` is `function`, `struct`, `enum`, `alias`, `resource`
  or `constant`; `summary` is the first paragraph of the `##` doc, or null. A
  function adds `parameters` (`{name, type, default}`) and `result`; a struct
  `fields` (`{name, type, doc, name_span}`); an enum `variants` (`{name,
  payload, doc, name_span}`).
- A span is `{file, range: {start: {line, column}, end: {line, column}}}`, end
  exclusive. `span` covers the whole declaration (`export` included);
  `name_span` is the name alone, the place to edit.
- `file` is canonical: relative to the working folder when below it
  (`std/NAME.agc` for a `std/` module), absolute otherwise. A diagnostic keeps
  the name as typed.

## type-at

```sh
agentica type-at src/orders.agc:22:14
agentica --json type-at src/orders.agc:22:14
cat buffer.agc | agentica type-at --stdin src/orders.agc:22:14
```

```text
src/orders.agc:22:9-22:19 user.email: String
src/models.agc:4:3 field email
```

Line 1: the span of the innermost expression at the position, its text and its
type. Line 2, if any: the definition. On a builtin, line 2 is `builtin` and its
signature. On a field or method name the expression is the whole access
(`user.email`). It checks the file and its imports, but needs no `main` (a
`main` with the wrong signature is still `CHECK-MAIN`). A type of another file
is written as the file writes it (`Models.User` through the import alias); one
from a module the file does not import is written by its bare name. A type name
in an annotation (`xs: Models.User`), in a type argument (`Models.User` in
`List[Models.User]`) or in a field or variant payload has the `kind` `type`: the
span is the name (`Models.User` is one span), the `type` field is that name
alone as written (`List` on `List[Models.User]`, the alias name for an alias
use), not the whole annotation, and the definition is the struct, enum, alias
(kind `alias`) or resource it names, also from an imported file. A builtin type
(`Int`, `List`) has no definition. `refs` lists these uses as `type`.

A keyword of an expression (`try`, `do`, `and`, `!`) answers that expression;
`return`, `end` and `case` are on no expression.

JSON: `{version: 1, command: "type-at", position: {file, line, column}, kind,
text, type, span, definition, help}`.

- `kind`: `builtin` (on a builtin's name, `split` in `xs.split(",")`; `to_s`
  and `inspect` only where the checker resolves them to one, as on a number),
  `name` (a variable, constant, callee, field or method name, or the name that
  binds a local), `type` (a type name in an annotation or a type argument) or
  `expression`. An open set: accept values you do not know.
  `span` is always the whole expression; `text` is its source.
- `definition`: null, or `{file, range, kind, name, name_span, signature, doc}`.
  `kind` is `function`, `struct`, `enum`, `alias`, `resource`, `variant`,
  `field` or `constant` (`signature` is e.g. `make(name: String) -> User`, `age:
  Int`, `Circle(Float)`; `doc` is the whole `##` text or null). A local answers
  with `kind` `parameter`, `local`, `loop` or `pattern`, `signature` `name:
  Type` and `doc` null; its `range` is the binding node (the whole parameter or
  assignment), else the name, and `name_span` is where it is bound. A use and
  the binding give the same answer. A name bound in sibling blocks answers its
  own binding; `total += 1` is a use of the binding of `total`; `_` is on no
  expression.
- `help`: null, except for `builtin`, where it is the object of `agentica help
  NAME --json` (`name`, `signature`, `description`, `parameters`, `effects`, and
  `overloads` for several forms).

## refs

```sh
agentica refs Models.User.email src/
agentica refs src/orders.agc:22:14 src/
agentica --json refs src/orders.agc:22:14 src/
```

```text
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:31:5 construct in sample
```

Run it before you change a field, a variant or a function, and keep the list.
It tells `Models.User` from a local `User`, and one struct's field `name` from
another's, which `rg` cannot. The program is checked. The files searched are
linked together with what they import, so a use in a file that only imports the
declaration is found if that file is among them. A position links FILE and
`PATH...`, and FILE alone when there is no PATH, so pass the folder that holds
the uses. A NAME searches `PATH...` (default `.`).

The position is on a use, or on the name where a declaration is written, or on
a name of an import list (`make` of `import {make as create} from "models"`, or
`create`), which selects the imported declaration. Two different declarations
never mix (the `i` of two loops, the `note` of two branches). A position on the
module alias of `Models.total(u)` selects `total`, not `Models`. A position on a
module alias or a path in an import line is `QUERY-NO-EXPRESSION`.

A NAME is resolved as for `symbol` and must pick one declaration: a `total` or
`Models.total` that two files declare is `QUERY-AMBIGUOUS-NAME`, and the help
lists each candidate as `FILE:LINE:COL`, ready for the position form. A builtin
(`puts`, `List.map`) is a name too.

JSON: `{version: 1, command: "refs", query, definition, builtin, references,
skipped}`.

- `definition`: null for a builtin, else a `symbol` match (below). A local is
  `parameter`, `local`, `loop` or `pattern`, with no doc. It is not repeated in
  `references`.
- `builtin`: the builtin's name (`File.read_text`, `List.map`), else null.
- `references`: `{kind, function, span}`, FILE's files first, then by position.
  `span` is the name alone (`make` of `Models.make`). `query` is the NAME or the
  `FILE:LINE:COL` as asked. `kind` is `call`, `value` (`&f`, a constant), `type`
  (an annotation), `construct` (a struct construction, a `with`, or a variant
  constructor; the span of a field name for a field), `read` (a field read),
  `pattern` (a variant in a `case` arm) or `binding` (a use of a local, `x += 1`
  included). `function` is the enclosing function or null. An open set. No
  references is an empty list, exit 0.
- `skipped`: files of `PATH...` that do not link, as for `symbol`.

## symbol

```sh
agentica symbol Models.User.email src/
agentica --json symbol total src/orders.agc
cat buffer.agc | agentica symbol total --stdin src/orders.agc
```

```text
src/models.agc:4:3 field User.email: String
```

It finds where NAME is declared in the modules linked from PATH (a file or a
folder; default `.`). NAME is written as the code writes it:

- `total`: a function, struct, enum, alias, resource or constant, private ones
  too; a bare name lists every module that declares it.
- `Models.total`, `Models.User`: through the alias of a whole-module import
  (`import M from "m"`) in a file under PATH; exported names only. After
  `import {make as mk} from "m"`, `symbol mk` is `QUERY-NOT-FOUND`, and `symbol
  make` finds the declaration.
- `User.email`, `Models.User.email`: a struct field. `Option.Some`: a variant.
- `std/queue.pop`, `std/queue.Popped.value`: a linked `std/` module.
- `Map.get`, `puts`: a builtin, with the `help` object and no place.

A folder is every `*.agc` file below it, bytewise by path, without hidden
folders, `agc_libs/` and links. The files link together, so no `main` and no
type check are needed. A file that does not lex, parse or link is in `skipped`
and the rest still answer; the text form prints `skipped FILE: CODE` on stderr
for each (`refs` too). A file that imports a failing module is skipped with the
same diagnostic. `--stdin FILE` is searched too, first, and need not exist on
disk.

JSON: `{version: 1, command: "symbol", query, matches, skipped}`.

- `matches[]`: `{kind, name, module, exported, signature, doc, span,
  name_span}`. `kind` is `function`, `struct`, `enum`, `alias`, `resource`,
  `constant`, `field`, `variant` or `builtin` (an open set). `name` is the name
  alone; `module` is the file's name. A `signature` writes its types as the
  declaring module does. `span` is the declaration (`export` included), so
  compare `name_span`, not `range`, with a `type-at` definition (its `range`
  starts after `export`).
- A field adds `type` and `struct`; a variant adds `payload` and `enum`. A
  builtin has `help` and null `module`, `span`, `name_span` and `doc`.
- `skipped[]`: `{file, diagnostic}`, the diagnostic being the first problem of
  that file or of what it imports.

## Partial answers

While you edit, the program often does not check. `type-at --partial` and
`refs FILE:LINE:COL --partial` (no NAME or PATH; with one, `QUERY-USAGE`) still
answer when only some functions fail: exit 0, the usual JSON plus `"partial":
true` and `diagnostics` (the `--json` objects of the failing functions, in
program order). A complete answer has neither key. In text form each problem is
a stderr line `partial FILE:LINE:COL: CODE`.

- `type-at` in a function that checks gives its type and definition. On a name
  in a function that does not check (a call, constructor, variant, type,
  constant or builtin) it gives `kind` `name` (`builtin`), the span of the
  written name, the definition from the link, and `type` null (text `?`). A
  field, method call or local there gives the first problem.
- `refs` on a function, struct, enum, alias, resource, constant or variant lists
  every use, including those in failing functions. A local of a checking
  function works. A field or a builtin gives the first problem (exit 1).
- Still exit 1 with or without the option: a program that does not lex, parse
  or link, declarations that fail (their types, `main`, a constant), and a
  field, local or keyword in a failing function. Any other position on no
  expression is `QUERY-NO-EXPRESSION`, exit 2.

Run `refs --partial` on a function or type again after you edit its signature,
and `type-at --partial` to read a definition in the function you are fixing.
Fix the `diagnostics` before you trust a field or a type.
