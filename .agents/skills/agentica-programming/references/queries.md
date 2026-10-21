# Asking the compiler about code

`agentica outline FILE` lists what one file declares, so you do not read the
whole file to learn its signatures. It only lexes and parses the file: its
imports need not exist, and it needs no `main`. FILE is a source file or a
`std/` module (`agentica outline std/queue`).

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

## Exit codes

- 0: the answer.
- 1: a `LEX-` or `PARSE-` error in the file; fix the file first.
- 2: `QUERY-USAGE`, at the pseudo-file `<arguments>`: a missing or extra
  argument, an unknown option, `--stdin` without a file, or a path that cannot
  be read. Fix the question.
