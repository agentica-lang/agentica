## 39. Semantic CLI for agents

**Status:** planned (roadmap [phase 26](../roadmap/26-semantic-cli.md), order
step 7.2b, after doc comments and digit separators). Agreed with the owner on
2026-10-13: agents program better when they can ask the compiler about the code,
not only read the docs. The front end already builds a linked and checked
program with types and spans; four CLI commands expose it, JSON first. No
language change; front end and CLI only, nothing reaches lowering or the VM.

```text
agentica outline FILE [--ai|--json]
agentica symbol NAME [PATH...] [--ai|--json]
agentica refs NAME|FILE:LINE:COL [PATH...] [--ai|--json]
agentica type-at FILE:LINE:COL [--ai|--json]
```

The options may also come before the command, as for every command. After the
command they are parsed by hand, as `help` and `test` do today
(`src/main.rkt:132-182`).

**Why.** Today an agent that changes a field type or an enum variant finds its
uses with `rg`, reads whole files to learn a signature, and guesses the type of
an expression from the code around it. `rg` cannot tell `Models.User` from a
local `User`, a field `name` from a variable `name`, or an import alias from a
module. The linker and the checker know all of this. The 6c task "a type change
that crosses a program" (roadmap phase 6c) is the case these commands are for.

### 39.1 Today

Checked at `29d64d2`:

- `src/main.rkt` runs lex → parse → link (`link-program`, `src/modules.rkt`) →
  check (`check`, `src/checker.rkt:207`) for `agentica check FILE`, and prints
  the first diagnostic in text, `--ai` or `--json` (`diagnostic->jsexpr`,
  `src/diagnostic.rkt:130`) on stderr with exit 1.
- `link-program` links one root. It gives each dependency the prefix `@N::`,
  numbered per call in visit order (set at `src/modules.rkt:128`, `identity` at
  `:171`); the root keeps its names without a prefix. It drops the import
  declarations from the linked program (`src/modules.rkt:292`), so the checker
  never sees module keys or aliases. Each call starts from empty tables.
- Dependency spans carry the canonical absolute path of their file; the root
  keeps the path as typed. So one file can appear under two names.
- `check` takes an optional `#:types` table and fills it with the type of each
  expression (`src/checker.rkt:531`) and block (`:1277`). A struct field read
  goes through `check-struct-field` (`src/checker.rkt:1292`), which returns the
  field's type and records nothing else; its target goes through
  `check-expression`, so the target's type, and with it the struct, is in
  `#:types`. The mutable `resolved` field of `field-access` and `method-call`
  (`src/ast.rkt:91-92`) is set only on the builtin-method path (`check-method`,
  set at `src/checker.rkt:522` and `:1290`) and holds a rewritten node for
  lowering (`src/lower.rkt:317-318`); it is not a field's struct.
- The linker keeps each module's alias table (`imports`, `src/modules.rkt:113`,
  filled at `:155`) but does not return it.
- `type->string` strips the `@N::` prefix (`display-name`,
  `src/builtins.rkt:11`), so diagnostics print an imported type as `User`, not
  `Models.User`.
- The checker requires exactly one `main() -> Void` (`CHECK-MAIN`,
  `src/checker.rkt:450`).
- Some names have no span of their own: a `field-access` and a `method-call`
  span starts at the target (`src/parser.rkt:674`), and the loop variable of
  `for-stmt` and the bindings of `variant-pattern` are plain strings
  (`src/ast.rkt:72`, `:78`).
- `agentica help NAME [--json]` prints a builtin from the catalog
  (`builtin->jsexpr`); an unknown name prints a plain line on stderr and
  exits 2. `agentica test` reports a usage error as the diagnostic
  `RUNTIME-BDD-USAGE` at the pseudo-file `<arguments>`, line 1, column 1
  (`first-line-span`, `src/bdd-driver.rkt:20`, `:37`).
- `visit` adds each module to the link tables before its own imports are read
  (`src/modules.rkt:124-169`), and most link errors (`CHECK-IMPORT-NAME`, an
  unknown alias, a name of the wrong kind) are raised later, in `resolve` and
  the rewrite (`:172-208`), after every module is visited, often inside a
  dependency.
- Phase 22b plans `agentica doc PATH [--json]` and `src/docs.rkt` (§32.5): the
  exported API of one module, parse only, with a signature printer and a JSON
  item shape.

### 39.2 Shape

```text
$ agentica outline src/orders.agc
src/orders.agc:1:1 import "models" as Models
src/orders.agc:3:1 export struct Order
src/orders.agc:8:1 export def total(order: Order) -> Int
src/orders.agc:14:1 def round_cents(value: Float) -> Int

$ agentica symbol Models.User.email src/
src/models.agc:4:3 field User.email: String

$ agentica refs Models.User.email src/
src/models.agc:4:3 definition field User.email: String
src/orders.agc:22:14 read in total
src/report.agc:9:30 read in render
src/report.agc:31:5 construct in sample

$ agentica type-at src/orders.agc:22:14
src/orders.agc:22:9-22:19 user.email: String
```

Line 22 of `src/orders.agc` is `  cents = user.email.size` with `user` at column
9 and `email` at column 14. Answers go to stdout, one line per result,
`file:line:column` first, so they read like `rg` output. `--json` prints one
object on stdout (§39.5). Diagnostics go to stderr, as for `check`. `--ai`
changes only how diagnostics print; answers keep the text form.

### 39.3 Commands

- **`outline FILE`**: the top-level declarations of one file in source order:
  imports (path and alias), structs (with fields), enums (with variants),
  functions (with their signature), each with `exported`, its doc summary and
  its span. Private declarations are listed too; this is the difference from
  `agentica doc`, which shows only the exported API. `FILE` may also be a `std/`
  module name (`std/http`), read from `stdlib-sources` as `agentica doc` does.
  Parse only (§39.6).
- **`symbol NAME [PATH...]`**: where a name is defined, with its signature or
  type. Names are written as in §39.4. A builtin answers with the same object as
  `agentica help NAME --json`, under `help`, with no span; so one command
  answers for user code and builtins alike. A bare name can match declarations
  in several modules: all matches are listed.
- **`refs NAME|FILE:LINE:COL [PATH...]`**: every reference to one declaration in
  the modules linked from `PATH...`, each with its span, its kind and the
  function it is in. The definition comes first. The kinds are `call`, `value`
  (a name used as a value, such as `&f`), `type` (in an annotation or a type
  argument), `construct` (a struct construction or a variant constructor, with
  the field name's span for a field), `read` (a field read), `pattern` (a
  variant in a `case` arm) and `binding` (a use of a local). An import is not a
  reference: it names a module, not a declaration. The position form picks the
  declaration of the name at that position, which always resolves to one
  declaration, local bindings included. Builtins work too
  (`refs File.read src/`), with no definition. No references is not an error: an
  empty list, exit 0.
- **`type-at FILE:LINE:COL`**: the checked type of the innermost expression or
  name whose span contains the position, with that span and its source text. On
  the name of a field access, it is the whole access (`user.email` above). For a
  name it also gives the definition's span (a declaration, a field, a variant, a
  parameter or a local binding). Line and column are 1-based, in the units of
  diagnostics.

### 39.4 Names, paths and files

- **Decided:** a name is written as the code writes it, so an agent can copy it
  from the file it is reading:
  - `total`: a top-level function, struct or enum;
  - `Models.total`, `Models.User`: through an import alias as written in a file
    of `PATH...`;
  - `User.email`, `Models.User.email`: a struct field;
  - `Option.Some`, `Domain.Option.Some`: an enum variant;
  - `Map.get`, `puts`: a builtin, as in `agentica help`.
- `X.y` is never ambiguous inside one file: import aliases cannot collide with
  declarations or builtin names (`docs/grammar.md`, "File modules and imports").
- Across files, the same alias can name different modules. Then `symbol` lists
  every match, and `refs` needs exactly one declaration: two or more give
  `QUERY-AMBIGUOUS-NAME`, with a help that lists each candidate as
  `FILE:LINE:COL`, ready for the position form.
- `std/MOD.NAME`, `std/MOD.Type.field` and `std/MOD.Enum.Variant`
  (`std/http.get`) are also accepted, with the spelling of §32.6, since `std/`
  modules have no fixed alias.
- **Which modules.** Names are looked up in every module linked from `PATH...`:
  the files of `PATH...` and everything they import, `std/`, `pkg/` and relative
  imports outside `PATH...` included. A reference in a file that nothing in
  `PATH...` reaches is not found.
- **Alternative, not chosen:** names qualified by module path
  (`models.agc:User.email`). It does not depend on the alias, but agents do not
  see it in the code, and a path inside a name is hard to quote. If aliases turn
  out to confuse agents in 6c, it can be added as a second form.
- **`PATH...`** are files or directories. A directory means every `*.agc` file
  under it, recursively, without `agc_libs/` and hidden directories, in bytewise
  order of the path. Arguments keep their order. The default is `.` for `symbol`
  and `refs`; `type-at` uses `FILE` alone.
- **File names.** The query canonicalizes every file it reads, the files of
  `PATH...` included, and keys modules by the canonical path, so one file has
  one name. It prints a path relative to the current directory when the file is
  under it, the absolute path otherwise, and `std/MOD.agc` for an embedded
  module. A `FILE` in `FILE:LINE:COL` is canonicalized the same way before it is
  matched.
- **Result order:** by file, in the order the files were linked, then by
  position.

### 39.5 JSON

Every object has `"version": 1` and `"command"`. A field that changes meaning
gets a new version; new fields can be added within a version. Types and
signatures are strings.

- **A span** is the object
  `{file, range: {start: {line, column}, end: {line, column}}}`.
  `diagnostic->jsexpr` puts the same two keys, `file` and `range`, at the top
  level of a diagnostic; a span here is those two keys in an object of their
  own. `file` follows the rule of §39.4.
- **Types** in a signature are printed as written in their own module (the rule
  of §32.5), so they read correctly next to `module`. In `type-at`, a type from
  another module is printed through the alias `FILE` uses for it
  (`Models.User`); a type from a module `FILE` does not import (a private type
  of a dependency, or one that reaches it through another module) is printed by
  its bare name, as diagnostics do.
- `outline`:
  `{version, command, file, imports: [{path, alias, span}], items: [...]}`. Each
  item is `{kind, name, exported, signature, summary, span}`, `kind` being
  `"function"`, `"struct"` or `"enum"`, with the extra fields of §32.5
  (`parameters` and `result`, `fields`, `variants`). `summary` is the first
  paragraph of the doc (phase 22), or `null`.
- `symbol`: `{version, command, query, matches: [...], skipped: [...]}`. Each
  match is `{kind, name, module, exported, signature, span}`; `kind` adds
  `"field"` (with `type` and `struct`), `"variant"` (with `payload` and `enum`)
  and `"builtin"` (with `help`, and `span` and `module` set to `null`). `module`
  is the module's file name (§39.4).
- `refs`:
  `{version, command, query, definition, references: [{kind, function, span}], skipped: [...]}`,
  with `definition` a `symbol` match, or `null` for a builtin. `function` is the
  name of the enclosing function, or `null` at the top level.
- `type-at`:
  `{version, command, position: {file, line, column}, kind, text, type, span, definition}`.
  `kind` is `"expression"` or `"name"`; `definition` is a span or `null`.
- `skipped`: the roots left out (§39.6), each as `{file, diagnostic}`,
  `diagnostic` being the `--json` diagnostic object.

`src/query.rkt` builds the `outline` items with `src/docs.rkt`, which 22b adds
for `agentica doc`, so the two commands share the signature printer and the item
fields and cannot drift.

### 39.6 Programs that do not check

Agents ask these questions while a program is half edited, so the commands ask
for as little as they can:

| Command | Needs | Why |
|---|---|---|
| `outline` | parse of `FILE` | declarations are syntax |
| `symbol` | parse and link | declarations, fields and variants are syntax; aliases are resolved by the linker |
| `refs` on a function, struct, enum or variant | parse and link | the linker resolves every top-level and alias-qualified name |
| `refs` on a field, the position form on a local | check | `user.email` needs the type of `user` |
| `type-at` | check of `FILE` and its imports | it is a type |

- **Linking each root on its own.** `symbol` and `refs` link the roots one at a
  time into shared tables (§39.8). A root whose own lex, parse or link fails is
  left out and listed in `skipped` with its first diagnostic; the others still
  answer, with exit 0. Linking one root is a transaction (§39.8): if it fails,
  the modules it added are dropped, and any later root that reaches a module
  that failed is skipped with the same diagnostic. If every root is skipped, or
  the one `FILE` of the position form is, there is nothing to answer from: the
  command prints the first skipped diagnostic and exits 1, as `check` would. So
  a broken fixture somewhere under `.` does not block a query. In text mode each
  skipped root prints one line on stderr: `skipped FILE: CODE`.
- **When a check is needed**, the command checks the linked modules it needs
  (for `type-at`, `FILE` and its imports; for field refs, every linked module).
  If that fails, it prints the first diagnostic in the usual format and exits 1,
  as `agentica check` does.
- **Edit order.** In a type change across a program, the program stops checking
  after the first edit. The programming skill says: run `refs` before the edit
  and keep the list. Function, type and variant refs keep working after the
  edit, since they need only linking.
- **Alternative, not chosen:** answering from a partly checked program. It needs
  a checker that recovers from errors, which the front end does not have (each
  stage stops at the first error, AGENTS.md).
- A queried file does not need `main`: the query checks with the `CHECK-MAIN`
  rule off (a new `#:require-main? #f` argument to `check`). Everything else is
  the same checker.

### 39.7 Diagnostics and exit codes

The commands are a new front-end stage, `src/query.rkt`, so its codes have their
own prefix, `QUERY-`. They are stable, carry a span, and print on stderr in the
usual three formats.

| Code | When | Span |
|---|---|---|
| `QUERY-USAGE` | a missing or extra argument, an unknown option, a bad `FILE:LINE:COL`, an unreadable path, a `PATH...` with no `*.agc` file | `<arguments>`, line 1, column 1 |
| `QUERY-NOT-FOUND` | `symbol` or `refs` names nothing in the linked modules or the catalog; the help has "did you mean" | `<arguments>`, line 1, column 1 |
| `QUERY-AMBIGUOUS-NAME` | `refs` NAME matches more than one declaration; the help lists the candidates | `<arguments>`, line 1, column 1 |
| `QUERY-NO-EXPRESSION` | `type-at` or `refs` at a position outside the file or not on an expression or name | the position; past the end of a line, the line's end; past the last line, the end of the file |

- The `<arguments>` span follows `RUNTIME-BDD-USAGE` (`src/bdd-driver.rkt:20`,
  `:37`): a name typed on the command line has no place in a file. Usage errors
  are diagnostics, as in `agentica test`, not a plain line as in `help`, so
  `--json` always gives JSON.
- Exit 0: an answer, including an empty list of references and answers with
  `skipped` roots.
- Exit 1: the program has an error (a `LEX-`, `PARSE-` or `CHECK-` diagnostic)
  that the command needs to be free of (§39.6), or every root was skipped.
- Exit 2: every `QUERY-` code, as `help` and `doc` exit 2 for an unknown name.
  Exit 1 always means "fix the program", exit 2 "fix the question".
- **Alternatives, not chosen:** `CHECK-` codes (the program is fine; the
  question is wrong), and a plain stderr line as `help` prints today (agents
  parse JSON; a diagnostic has a span and a help).

### 39.8 Linking, checking and performance

- **One link for all roots.** A new linker entry point, `link-programs`, links
  several roots into one program with shared tables: each module is visited
  once, whichever root imports it. Every module gets a `@N::` prefix, roots
  included, so two roots can both declare `main` or `parse`; names print through
  `display-name` as today. `link-program` keeps its behavior for `check` and
  runs.
- **A root is a transaction.** `link-programs` visits one root and resolves and
  rewrites its modules before the next root. The tables it adds (trees,
  prefixes, aliases, origins, uses) are kept only if that whole root links; if
  any step fails, in its own file or in a dependency, they are dropped and the
  root is skipped. A module that failed is remembered with its diagnostic, so a
  later root that reaches it is skipped with that diagnostic without linking it
  again. Modules already linked by an earlier root stay linked.
- **Aliases.** `link-programs` also returns each module's alias table
  (`imports`, module key to alias to module key), so `type-at` can print a type
  through `FILE`'s own aliases.
- **Origins.** The linker fills a side table, `#:origins`: each linked identity
  (`@N::name`) to its module key, its source name and its declaration span. It
  also fills `#:uses`: each name use (call, value, type, construction, variant)
  to the linked identity it resolves to, with the span of the name. The checker
  never sees module keys, so this table belongs to the linker, which is where
  the names are resolved.
- **Fields and locals** come from the checker: field reads from the checker's
  `#:types` entry of each field access's target, which names the struct (§39.1);
  `check-struct-field` does not change, and local bindings from a new `#:locals`
  table (each use of a parameter or local to its binding span).
- **Name spans.** For `refs` and `type-at` to point at a name, the parser gives
  `field-access` and `method-call` a `name-span`, and the `for` loop variable
  and the `variant-pattern` bindings a span each.
- **Cost.** One lex and parse of each file, one link of the whole set, and at
  most one check of what §39.6 needs, with no lowering, no bytecode and no VM.
  Shared dependencies are linked and checked once. So a command costs about one
  `agentica check` of the files of `PATH...` together, less when no check is
  needed.
- No daemon, no cache, no watch mode. Start-up is the Racket start-up of every
  command today; the single binary of §35 makes it faster for all of them.

### 39.9 Builtins and `agentica help`

`symbol` and `refs` read builtins from the same catalog as `agentica help` and
do not repeat it: a builtin match embeds the `help --json` object as it is.
`std/` exports are ordinary user declarations from `stdlib-sources`.
`agentica help` does not change.

### 39.10 Order

- Order step 7.2b of the [roadmap](../roadmap/README.md): after row 22b
  (`agentica doc`, phase 22), before iteration and concurrent collections
  (row 7.3). Front end and CLI only, VM-only in the sense of the
  roadmap rule (no Racket twin of anything; nothing to run).
- After row 22b, so `outline` uses `src/docs.rkt` and shows doc summaries.
- Before the full 6c round (order step 10), so it can measure the commands
  (§39.12). The 6c pilot (order step 7.2.2) comes before it and does not have
  them.
- One PR per command group: `outline` first, then `symbol` and `refs` on
  declarations (the linker work), then `type-at` with field and local refs (the
  checker work).

### 39.11 Decided against

- **LSP, not in this phase.** A language server needs a long-lived process,
  incremental checking and an editor protocol. Agents call commands in a shell;
  JSON on stdout is enough. A language server is a separate item, see
  [§43](43-language-server.md) (not scheduled).
- **Rename and refactor commands.** Agents edit files well; what they lack is
  the list of places to edit, which `refs` gives.
- **Editor integration, a daemon, a cache.** See §39.8.
- **Partial answers from a program that does not check.** See §39.6.

### 39.12 Measuring it: the 6c round

- The full 6c round (roadmap order step 10, [phase
  6c](../roadmap/06-validation.md#phase-6c-agentica-against-typed-python)) runs
  with the commands documented in the programming skill.
- `tests/eval/run.py` counts each command call per run, next to file reads
  (`cat`, `rg`, `sed`) and `agentica check` calls.
- On the tasks that cross a program (a field type, an enum variant, a Result in
  place of a plain value), one extra Agentica arm runs without the commands,
  with the same model and budget. The binary still has them, so the arm hides
  them: its skill has no `references/queries.md` and no row for it, and `run.py`
  puts a wrapper `agentica` first in the workspace `PATH` (`/workspace/bin`, as
  today) that answers the four commands with an unknown-command error and exit
  2, and passes everything else to the real binary. Each refused call is
  counted. The usage text still names the commands; that is recorded, not
  hidden.
- The comparison is hidden tests passed, tokens, repair attempts and time to a
  correct solution.
- Keep the commands in the skill if agents call them and the arm with them is
  not worse; if agents never call them, change how the skill presents them
  before the next round, not the commands.

### 39.13 Tests

- `tests/query-test.rkt` (rackunit), running the CLI in process
  (`tests/cli-in-process.rkt`), with fixtures in `tests/fixtures/query/`: a root
  file that imports two modules under aliases and `std/queue`; a struct, an enum
  with a payload, a private function, a field used in a read and in a
  construction, a variant in a `case` pattern, a `for` loop; the same alias for
  different modules in two files; a second root that imports the same module; a
  broken module (an unknown name inside it) imported by two roots, next to a
  third root that does not import it; a file with a parse error and a file with
  a check error.
- Each test asserts the exit code, the diagnostic code, and the JSON fields and
  spans, not message text:
  - `outline`: items, `exported`, signatures, `summary` and spans; a file with a
    missing import still answers; a parse error gives exit 1 and its code;
    `std/queue`.
  - `symbol`: each name form of §39.4, `std/` forms included; a builtin carries
    the `help` object; several matches; `QUERY-NOT-FOUND`; a directory with the
    broken file answers with it in `skipped`; both roots that import the broken
    module are skipped with the same diagnostic and the third answers;
    `refs total broken.agc` with only a broken root gives exit 1 and its
    diagnostic; a file given by a relative and an absolute path prints one name.
  - `refs`: each reference kind; a reference through an alias; a shared module
    is reported once; an empty list (exit 0); `QUERY-AMBIGUOUS-NAME`; function
    refs in a program with a check error still answer; field refs in it give
    exit 1.
  - `type-at` and the position form of `refs`: an expression, the name of a
    field access, a name with its definition, a local binding, a `for` variable,
    a pattern binding, an imported type printed with its alias, a position
    between tokens and past the end (`QUERY-NO-EXPRESSION`).
  - `QUERY-USAGE` for each case of §39.7, with the `<arguments>` span.
- No golden fixtures: nothing runs on the VM.

The docs to update are listed in [phase 26](../roadmap/26-semantic-cli.md).
