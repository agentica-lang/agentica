# Asking the compiler about code

`agentica outline FILE`, `type-at FILE:LINE:COL`, `refs NAME|FILE:LINE:COL
[PATH...]` and `symbol NAME [PATH...]` answer questions about code without
reading whole files. Each takes `--json` (one object on stdout) and `--stdin
FILE` (standard input is FILE, saved or not; `type-at` and `refs` take `--stdin
FILE:LINE:COL`, before the position). `--stdin FILE` takes the place of the FILE
argument (`outline --stdin FILE`); FILE need not exist, but imports are found
from its folder, and `std/...` is then a path on disk, not a `std/` module.
Answers go to stdout and diagnostics to stderr. The text form starts with
`file:line:column`, like `rg`; lines and columns count from 1, in code points.
Every JSON answer has `"version": 1` and `"command"`; new fields can appear
(ignore unknown keys). From a program, `std/analysis` gives the same answers as
structs (`analysis.md`).

Exit 2 is a bad question, 1 a program that does not check:

| Command   | Exit 1: fix the program | Exit 2: fix the question |
| --------- | ----------------------- | ------------------------ |
| `outline` | `LEX-`, `PARSE-` in the file | `QUERY-USAGE` |
| `type-at` | `LEX-`, `PARSE-`, `PKG-`, `CHECK-` in the file or its imports | `QUERY-USAGE`, `QUERY-NO-EXPRESSION` |
| `symbol`  | no file links | `QUERY-USAGE`, `QUERY-NOT-FOUND` |
| `refs`    | any error in the program, or FILE (or every file of PATH) does not link | `QUERY-USAGE`, `QUERY-NOT-FOUND`, `QUERY-AMBIGUOUS-NAME`, `QUERY-NO-EXPRESSION` |

`QUERY-USAGE` is at `<arguments>` (a missing or extra argument, an unknown
option, `--stdin` without a file, a bad `FILE:LINE:COL`, an unreadable path, a
folder with no `*.agc`). Errors print as `check` prints them. A question about
a file does not report `CHECK-UNUSED-IMPORT` or `CHECK-UNUSED-VARIABLE` in
that file (it may be half written); one in a file it imports is reported, and
`CHECK-UNREACHABLE-CODE` always is.

## outline

```sh
agentica outline src/orders.agc          # one line per declaration
cat buffer.agc | agentica outline --stdin src/orders.agc
```

```text
src/orders.agc:1:1 import Models from "models"
src/orders.agc:3:1 export struct Order
src/orders.agc:4:3 field Order.id: Int
src/orders.agc:8:1 export def total(order: Order) -> Int
```

It parses: imports need not exist and no `main` is needed (only a file with
re-exports is linked, to list the original declarations). FILE may be a
`std/` module (`agentica outline std/queue`). Private declarations are listed
too (`agentica doc` shows only the exported API). `--partial` is accepted and
changes nothing.

JSON: `{version, command, file, doc, imports, items}`. `items`, in source order:
`{kind, name, exported, signature, doc, summary, span, name_span}`; `kind` is
`function`, `struct`, `enum`, `alias`, `resource` or `constant`; a function adds
`parameters` and `result`, a struct `fields`, an enum `variants`. A span is
`{file, range: {start: {line, column}, end: {line, column}}}`, end exclusive;
`span` covers the whole declaration (`export` included), `name_span` is the name
alone, the place to edit. `file` is relative to the working folder when below
it, absolute otherwise.

## type-at

```sh
agentica type-at src/orders.agc:22:14
cat buffer.agc | agentica type-at --stdin src/orders.agc:22:14
```

```text
src/orders.agc:22:9-22:19 user.email: String
src/models.agc:4:3 field email
```

Line 1: the span of the innermost expression at the position, its text and its
type. Line 2, if any: the definition (on a builtin, `builtin` and its
signature). On a field or method name the expression is the whole access
(`user.email`). It checks the file and its imports but needs no `main` (a `main`
with the wrong signature is still `CHECK-MAIN`). A type of another file is
written as the file writes it (`Models.User` through the import alias; a type
of a module block `Counter.State`, bare inside its block). A type name in an
annotation, a type argument or a field or variant payload has `kind`
`type`: the span is the name, and the definition is the struct, enum, alias or
resource it names; a builtin type (`Int`, `List`) has none. `refs` lists these
uses as `type`. A keyword of an expression (`try`, `do`, `and`, `!`) answers
that expression; `return`, `end` and `case` are on no expression.

JSON: `{version, command, position, kind, text, type, span, definition, help}`.

- `kind`: `builtin`, `name` (a variable, constant, callee, field or method
  name), `type` or `expression`; an open set. `span` is always the whole
  expression.
- `definition`: null, or `{file, range, kind, name, name_span, signature, doc}`
  with `kind` `function`, `struct`, `enum`, `alias`, `resource`, `variant`,
  `field` or `constant`. A local answers with `kind` `parameter`, `local`,
  `loop` or `pattern`, and `name_span` is where it is bound. A use and the
  binding give the same answer; `_` is on no expression.
- `help`: null, except for `builtin`, where it is the object of `agentica help
  NAME --json`.

## refs

```sh
agentica refs Models.User.email src/
agentica refs src/orders.agc:22:14 src/
```

```text
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:31:5 construct in sample
```

Run it before you change a field, a variant or a function, and keep the list. It
tells `Models.User` from a local `User`, and one struct's field `name` from
another's, which `rg` cannot. The program is checked. The files searched are
linked together with what they import, so a use in a file that only imports the
declaration is found if that file is among them. A position links FILE and
`PATH...` (FILE alone with no PATH), so pass the folder that holds the uses. A
NAME searches `PATH...` (default `.`).

The position is on a use, on the name where a declaration is written, or on a
name of an import list, which selects the imported declaration. Two different
declarations never mix (the `i` of two loops). A position on the module alias of
`Models.total(u)` selects `total`, not `Models`; on a module alias or a path in
an import line it is `QUERY-NO-EXPRESSION`.

A NAME is resolved as for `symbol` and must pick one declaration: a `total` or
`Models.total` that two files declare is `QUERY-AMBIGUOUS-NAME`, and the help
lists each candidate as `FILE:LINE:COL`, ready for the position form. A builtin
(`puts`, `List.map`) is a name too.

JSON: `{version, command, query, definition, builtin, references, skipped}`.

- `definition`: null for a builtin, else a `symbol` match (below); not repeated
  in `references`. `builtin`: the builtin's name, else null.
- `references`: `{kind, function, span}`, FILE's files first, then by position;
  `span` is the name alone. `kind` is `call`, `value` (`&f`, a constant), `type`
  (an annotation), `construct` (a struct construction, a `with`, or a variant
  constructor), `read` (a field read), `pattern` (a variant in a `case` arm) or
  `binding` (a use of a local, `x += 1` included); an open set. No references
  is an empty list, exit 0.
- `skipped`: files of `PATH...` that do not link, as for `symbol`.

## symbol

```sh
agentica symbol Models.User.email src/
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
  `import {make as mk} from "m"`, `symbol mk` is `QUERY-NOT-FOUND` and `symbol
  make` finds the declaration.
- `User.email`, `Models.User.email`: a struct field. `Level.Info`: a variant.
- `Counter.start`, `Agents.Counter.start`: an export of `module Counter`, in
  its file or through the alias of an importer; a private name of a block is
  found bare only.
- `std/queue.pop`, `std/queue.Popped.value`: a linked `std/` module.
- `Map.get`, `puts`: a builtin, with the `help` object and no place.

A folder is every `*.agc` file below it, bytewise by path, without hidden
folders, `agc_libs/` and links. The files link together, so no `main` and no
type check are needed. A file that does not lex, parse or link is in `skipped`
and the rest still answer; the text form prints `skipped FILE: CODE` on stderr
for each (`refs` too). A file that imports a failing module is skipped with the
same diagnostic. `--stdin FILE` is searched too, first, and need not exist on
disk.

JSON: `{version, command, query, matches, skipped}`. `matches[]`: `{kind, name,
module, exported, signature, doc, span, name_span}`; `kind` is `function`,
`struct`, `enum`, `alias`, `resource`, `constant`, `field`, `variant` or
`builtin`. `span` is the declaration (`export` included), so compare
`name_span`, not `range`, with a `type-at` definition. A field adds `type` and
`struct`; a variant `payload` and `enum`; a builtin has `help` and null
`module`. `skipped[]`: `{file, diagnostic}`.

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
- Still exit 1 with or without the option: a program that does not lex, parse or
  link, declarations that fail (their types, `main`, a constant), and a field,
  local or keyword in a failing function. Any other position on no expression is
  `QUERY-NO-EXPRESSION`, exit 2.

Run `refs --partial` on a function or type again after you edit its signature,
and `type-at --partial` to read a definition in the function you are fixing. Fix
the `diagnostics` before you trust a field or a type.
