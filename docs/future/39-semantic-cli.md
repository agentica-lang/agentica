## 39. Semantic CLI for agents

**Status:** `outline`, `type-at` and `symbol` built (types, definitions with
`doc` and `signature`, builtins and locals at a position; the workspace
search). `refs FILE:LINE:COL` built for the files that `FILE` links; the `NAME`
form, `PATH...`, `skipped` and answers from a program that does not check
(§39.6) are planned, as is `--partial`. Row 7.2b. Agreed with the owner on
2026-10-13: agents program better when they can ask the compiler about the
code, not only read the docs. The front end already builds a linked and checked
program with types and spans; four CLI commands expose it, JSON first. No
language change; front end and CLI only, nothing reaches lowering or the VM.

```text
agentica outline FILE [--ai|--json]
agentica symbol NAME [PATH...] [--ai|--json]
agentica refs NAME|FILE:LINE:COL [PATH...] [--ai|--json]
agentica type-at FILE:LINE:COL [--ai|--json]
agentica type-at --stdin FILE:LINE:COL [--ai|--json]
```

The options may also come before the command, as for every command. After the
command they are parsed by hand, as `help` and `doc` do.

**Why.** An agent that changes a field type or an enum variant finds its uses
with `rg`, reads whole files to learn a signature, and guesses the type of an
expression from the code around it. `rg` cannot tell `Models.User` from a
local `User`, a field `name` from a variable `name`, or an import alias from a
module. The linker and the checker know all of this. The 6c task "a type change
that crosses a program" (roadmap phase 6c) is the case these commands are for.

### 39.1 Today

What the design starts from:

- `Linker.link_file` links one root. It gives each dependency the prefix `@N::`,
  numbered per call in visit order; the root keeps its names without a prefix.
  It drops the import declarations from the linked program, so the checker
  never sees module keys or aliases. Each call starts from empty tables.
- Dependency spans carry the canonical absolute path of their file; the root
  keeps the path as typed. So one file can appear under two names.
- `Checked.types` holds the type of each expression and block by node id. A
  struct field read records nothing else, but its target is checked first, so
  the target's type, and with it the struct, is in `Checked.types`.
  `Checked.resolved` is set only on the builtin-method path; it is not a
  field's struct.
- `LinkedModule.aliases` is each module's alias table, alias to module key.
  `Types.display_name` strips the `@N::` prefix, so diagnostics print an
  imported type as `User`; `Types.to_text_as` takes the map from a prefix to
  the alias of the asking file and prints `Models.User`.
- `Checker.check_query` checks without the rule that `main` exists and with
  every other (a declared `main` keeps its signature). `agentica check` uses it
  too.
- Some names have no span of their own: the loop variable of `ForStmt` and the
  slots of `VariantPattern` hold plain strings. Functions, structs, enums,
  fields, variants, constants, type aliases, `FieldAccess` and `MethodCall`
  have a `name_span`.
- `Modules.enter` adds each module to the link tables before its own imports are
  read. The loader raises some link errors while it reads the imports. The name
  errors (`CHECK-IMPORT-NAME` for a member, `CHECK-UNKNOWN-NAME`, a name of the
  wrong kind) come later, when `rewrite_all` rewrites the names after every
  module is loaded, and often inside a dependency.
- `agentica doc PATH [--json]` prints the exported API of one module, parse
  only, with a signature printer and a JSON item shape (§32.5).

### 39.2 Shape

```text
$ agentica outline src/orders.agc
src/orders.agc:1:1 import Models from "models"
src/orders.agc:3:1 export struct Order
src/orders.agc:4:3 field Order.id: Int
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

- **`outline FILE`** (built, `docs/grammar/06b-builtins.md`): the top-level
  declarations of one file in source order, private ones too, which is the
  difference from `agentica doc`. `FILE` may also be a `std/` module name.
  Parse only (§39.6).
- **`--stdin FILE`**, on every command that reads a file: the text of `FILE` is
  the standard input, as for `agentica check --stdin FILE`. It stands in for the
  `FILE` argument (`outline --stdin FILE`, not `outline FILE --stdin FILE`); the
  file need not exist; commands that resolve imports need its folder, `outline`
  does not. With `--stdin`, `std/...` is a path of the disk.
- **`symbol NAME [PATH...]`** (built): where a name is defined, with its
  signature or type. Names are written as in §39.4. A builtin answers with the
  same object as `agentica help NAME --json`, under `help`, with no span; so one
  command answers for user code and builtins alike. A bare name can match
  declarations in several modules: all matches are listed. A private
  declaration is found by its bare name only, since no alias reaches it. With
  `--stdin FILE` the buffer is `FILE`, searched as one more root, the first.
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
  empty list, exit 0. Built so far: the position form, for `FILE` and what it
  imports (`PATH...` is not read); a position on the name where a declaration is
  written picks it too; the program is always checked (exit 1 on an error); a
  `with` argument is a `construct` and a constant read a `value`.
  Planned for PR9: a position on an import selects the imported declaration
  (today it is `QUERY-NO-EXPRESSION`: an import is not a reference).
- **`type-at FILE:LINE:COL`** (built, `docs/grammar/06b-builtins.md`): the
  checked type of the innermost expression or name at the position, and the
  definition of what it names, with the `doc` and the `signature` of the
  declaration, so one hover is one process. A builtin answers `kind` `builtin`
  with its `help` object and no definition. A local (a parameter of a function
  or a block, a binding, a `for` variable, a name in a `case` pattern) answers
  with its type and a definition at its binding, on a use of the name and on the
  binding itself. Planned: a type argument (`Models.User` in
  `List[Models.User]`) with the definition of a type alias. `FILE` is
  a path of the disk, never a `std/` module, checked with its imports; it needs
  no `main` (§39.6).

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
  one name (the rules of the answer's `file` are in the programming skill,
  `references/queries.md`). A `FILE` in `FILE:LINE:COL` is canonicalized the
  same way before it is matched. A diagnostic keeps the name as typed, like
  `check`; only an answer's `file` is canonical.
- **Result order:** by file, in the order the files were linked, then by
  position.

### 39.5 JSON

Every object has `"version": 1` and `"command"`. A field that changes meaning
gets a new version; new fields can be added within a version. Types and
signatures are strings.

- **A span** is the object
  `{file, range: {start: {line, column}, end: {line, column}}}`.
  `DiagnosticJson.json` puts the same two keys, `file` and `range`, at the top
  level of a diagnostic; a span here is those two keys in an object of their
  own. `file` follows the rule of §39.4.
- **Types** in a signature are printed as written in their own module (the rule
  of §32.5), so they read correctly next to `module`. In `type-at`, a type from
  another module is printed through the alias `FILE` uses for it
  (`Models.User`); a type from a module `FILE` does not import (a private type
  of a dependency, or one that reaches it through another module) is printed by
  its bare name, as diagnostics do.
- `outline` and `type-at` (built): the shapes are in the programming skill
  (`references/queries.md`). `outline` builds its items with `compiler/docs/`,
  which `agentica doc` uses, so the two commands share the signature printer
  and the item fields and cannot drift. The `type-at` `definition` has the
  `doc` (the whole `##` text or null) and the `signature` of its declaration,
  read from the parsed file, since the linker drops the doc of an `export`; it
  will carry `kind` `alias` with the answer for a type argument. A local has a
  definition too, of `kind` `parameter` (of a function or a block), `local` (an
  assignment that introduces the name), `loop` (a `for` variable) or `pattern`
  (a name in a `case` pattern), with the `signature` `name: Type` and no `doc`;
  its `span` is the parameter or the binding, or the name alone for a `for`
  variable and a pattern name, and `name_span` is the name at the binding. The
  top-level `kind` of `type-at` is an open set (`expression`, `name`,
  `builtin`; later versions may add values) and a client accepts a value it
  does not know, so `builtin` needed no new `version`. A `builtin` answer has
  `definition` null and `help`, the object of `agentica help NAME --json`
  (`CatalogJson`, which `help` uses too); `help` is null for every other kind.
  `to_s` and `inspect` answer a builtin only where the checker resolves them to
  one (numbers).
- `symbol`: `{version, command, query, matches: [...], skipped: [...]}`. Each
  match is `{kind, name, module, exported, signature, doc, span, name_span}`;
  `kind` adds `"field"` (with `type` and `struct`), `"variant"` (with `payload`
  and `enum`) and `"builtin"` (with `help`). `module` is the module's file name
  (§39.4). `doc` is the whole `##` text or null, as in `type-at`; `name` is the
  name alone (`email`), with `struct` or `enum` for a member; a builtin has
  `module`, `span`, `name_span` and `doc` null. `span` is the whole
  declaration, `export` included, as in `outline`; the `range` of a `type-at`
  definition starts at the keyword after `export`, so compare `name_span`.
- `refs`:
  `{version, command, query, definition, references: [{kind, function, span}],
skipped: [...]}`,
  with `definition` a `symbol` match, or `null` for a builtin. `function` is the
  name of the enclosing function, or `null` at the top level. Built so far:
  `query` is the `FILE:LINE:COL` asked, `definition` adds `name_span`, the
  `struct` of a field or the `enum` of a variant, `builtin` names a builtin
  (else null), `references` do not hold the definition, a reference `span` is
  the name alone (`total` of `Models.total`) and `skipped` is empty.
- `skipped`: the roots left out (§39.6), each as `{file, diagnostic}`,
  `diagnostic` being the `--json` diagnostic object.

### 39.6 Programs that do not check

Agents ask these questions while a program is half edited, so the commands ask
for as little as they can:

- **Command:** `outline`
  - **Needs:** parse of `FILE`
  - **Why:** declarations are syntax

- **Command:** `symbol`
  - **Needs:** parse and link
  - **Why:** declarations, fields and variants are syntax; aliases are resolved
    by the linker

- **Command:** `refs` on a function, struct, enum or variant
  - **Needs:** parse and link
  - **Why:** the linker resolves every top-level and alias-qualified name

- **Command:** `refs` on a field, the position form on a local
  - **Needs:** check
  - **Why:** `user.email` needs the type of `user`

- **Command:** `type-at`
  - **Needs:** check of `FILE` and its imports
  - **Why:** it is a type

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
- A queried file does not need `main`: the query checks with the rule that
  `main` exists off (`Checker.check_query`), as `agentica check` does. A
  declared `main` still needs its signature. Everything else is the same
  checker.

### 39.7 Diagnostics and exit codes

The commands are a front-end stage, `compiler/query/`, so its codes have their
own prefix, `QUERY-`. They are stable, carry a span, and print on stderr in the
usual three formats.

- **Code:** `QUERY-USAGE`
  - **When:** a missing or extra argument, an unknown option, a bad
    `FILE:LINE:COL`, an unreadable path, a `PATH...` with no `*.agc` file
  - **Span:** `<arguments>`, line 1, column 1

- **Code:** `QUERY-NOT-FOUND`
  - **When:** `symbol` or `refs` names nothing in the linked modules or the
    catalog; the help has "did you mean"
  - **Span:** `<arguments>`, line 1, column 1

- **Code:** `QUERY-AMBIGUOUS-NAME`
  - **When:** `refs` NAME matches more than one declaration; the help lists the
    candidates
  - **Span:** `<arguments>`, line 1, column 1

- **Code:** `QUERY-NO-EXPRESSION`
  - **When:** `type-at` or `refs` at a position outside the file or not on an
    expression or name (between tokens, on a comment, on the body text of a
    heredoc or on a keyword that is part of no expression)
  - **Span:** the one character at the position, in `FILE`; past the end of a
    line, the empty span at the line's end; past the last line, the empty span
    at the end of the file

- The `<arguments>` span follows `RUNTIME-BDD-USAGE`: a name typed on the
  command line has no place in a file. Usage errors are diagnostics, as in
  `agentica test`, not a plain line as in `help`, so `--json` always gives JSON.
- Exit 0: an answer, including an empty list of references and answers with
  `skipped` roots.
- Exit 1: the program has an error (a `LEX-`, `PARSE-` or `CHECK-` diagnostic)
  that the command needs to be free of (§39.6), or every root was skipped.
- Exit 2: every `QUERY-` code, as `help` and `doc` exit 2 for an unknown name;
  so is a position on no expression. Exit 1 always means "fix the program", exit
  2 "fix the question". A program with an error is checked first: its
  diagnostic wins over a position that is on no expression.
- **Alternatives, not chosen:** `CHECK-` codes (the program is fine; the
  question is wrong), and a plain stderr line as `help` prints today (agents
  parse JSON; a diagnostic has a span and a help).

### 39.8 Linking, checking and performance

- **Built for `symbol` without it.** `symbol` links each root with
  `Linker.link_file` and merges the modules by key; a root whose module an
  earlier root linked is not linked again. That saves a link only when the
  importer sorts before the file it imports; when the imported file sorts first
  (a chain where each file imports the one before it) every root links its
  closure, so a directory costs at worst one link of the closure per root (a
  chain of 60 files takes 1.0 s, 120 files 4.3 s; `compiler/`: 11 s for 145
  files, 1.9 s for `front_end.agc` alone). `Linker.link_programs` below, or a
  cache kept between commands, is the real fix; `origins` and `uses` stay
  planned for `refs`. The file given with `--stdin` is the first root.
- **One link for all roots.** A new linker entry point, `Linker.link_programs`,
  links several roots into one program with shared tables: each module is
  visited once, whichever root imports it. Every module gets a `@N::` prefix,
  roots included, so two roots can both declare `main` or `parse`; names print
  through `Types.display_name` as today. `Linker.link_file` keeps its behavior
  for `check` and runs.
- **A root is a transaction.** `Linker.link_programs` visits one root and
  resolves and rewrites its modules before the next root. The tables it adds
  (trees, prefixes, aliases, origins, uses) are kept only if that whole root
  links; if any step fails, in its own file or in a dependency, they are dropped
  and the root is skipped. A module that failed is remembered with its
  diagnostic, so a later root that reaches it is skipped with that diagnostic
  without linking it again. Modules already linked by an earlier root stay
  linked.
- **Aliases.** `LinkedModule.aliases` is kept for every module of several
  roots, so `type-at` prints a type through `FILE`'s own aliases.
- **Origins.** The linker fills a side table, `origins`: each linked identity
  (`@N::name`) to its module key, its source name and its declaration span. It
  also fills `uses`: each name use (call, value, type, construction, variant)
  to the linked identity it resolves to, with the span of the name. The checker
  never sees module keys, so this table belongs to the linker, which is where
  the names are resolved.
- **Fields and locals** come from the checker: field reads from the checker's
  `Checked.types` entry of each field access's target, which names the struct
  (§39.1; `type-at` reads it this way for the definition of a field);
  `check_struct_field` does not change, and local bindings from a new `locals`
  table (each use of a parameter or local to its binding span).
- **Name spans.** For `refs` and `type-at` to point at a name, the `for` loop
  variable and the `VariantPattern` bindings get a span each (planned);
  `FieldAccess` and `MethodCall` have a `name_span` (built).
- **Cost.** One lex and parse of each file, one link of the whole set, and at
  most one check of what §39.6 needs, with no lowering, no bytecode and no VM.
  Shared dependencies are linked and checked once. So a command costs about one
  `agentica check` of the files of `PATH...` together, less when no check is
  needed.
- No daemon, no cache, no watch mode. Start-up is the single binary's (§18).

### 39.9 Builtins and `agentica help`

`symbol` and `refs` read builtins from the same catalog as `agentica help` and
do not repeat it: a builtin match embeds the `help --json` object as it is.
`std/` exports are ordinary user declarations from `stdlib-sources`.
`agentica help` does not change.

### 39.10 Order

- Order step 7.2b of the [roadmap](../roadmap/README.md): after row 22b
  (`agentica doc`, phase 22), before iteration and concurrent collections
  (row 7.3). Front end and CLI only, VM-only in the sense of the
  roadmap rule (nothing to run).
- After row 22b, so `outline` uses the 22b docs engine and shows doc summaries.
- Before the full 6c round (order step 10), so it can measure the commands
  (§39.12). The 6c pilot (order step 7.2.2) comes before it and does not have
  them.
- One PR per step (issue #506), in this order: `doc` (row 22b, built),
  `outline` (built), `type-at` (the core and the docs and builtins built; then
  locals), the opt-in `--partial`, `symbol`, then `refs`. `type-at` is the
  checker work; `symbol` and `refs` on declarations are the linker work.

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
  puts a wrapper `agentica` first in the workspace `PATH` that answers the four
  commands with an unknown-command error and exit 2, and passes everything else
  to the real binary. Each refused call is counted. The usage text still names
  the commands; that is recorded, not hidden.
- The comparison is hidden tests passed, tokens, repair attempts and time to a
  correct solution.
- Keep the commands in the skill if agents call them and the arm with them is
  not worse; if agents never call them, change how the skill presents them
  before the next round, not the commands.

### 39.13 Tests

One module per command, `tests/test_spec_<command>.py` (`test_spec_outline.py`
and `test_spec_type_at.py` are built), running the binary with `--json` and
asserting the exit code, the diagnostic code, and the JSON fields and spans,
never message text. No golden fixtures: nothing runs on the VM. Cases the
planned commands must cover:

- `symbol`: each name form of §39.4, `std/` forms included; a builtin carries
  the `help` object; several matches; `QUERY-NOT-FOUND`; a directory with a
  broken file answers with it in `skipped`; two roots that import the same
  broken module are both skipped with the same diagnostic and a third root
  answers; `refs total broken.agc` with only a broken root gives exit 1 and its
  diagnostic; a file given by a relative and an absolute path prints one name.
- `refs`: each reference kind; a reference through an alias; a shared module is
  reported once; an empty list (exit 0); `QUERY-AMBIGUOUS-NAME`; function refs
  in a program with a check error still answer; field refs in it give exit 1.
- `type-at` and the position form of `refs`: still to cover are a local
  binding, a `for` variable and a pattern binding, with their definitions.
- The same alias for different modules in two files, and `QUERY-USAGE` for each
  case of §39.7 with the `<arguments>` span.

Docs to update with each command: the places AGENTS.md names for a language or
builtin change, and `QUERY-` in `docs/grammar/07-diagnostics.md`.

### 39.14 Implementation (row 7.2b)

Done when: an agent can list a file's declarations, find where a name is
defined, list every reference to a declaration across a program, and get the
checked type at a position, each in text and in JSON with `version` 1; a broken
root is `skipped`, not fatal; a command that needs a check gives the first
diagnostic and exit 1; the `QUERY-` codes and exit codes of §39.7 hold; and the
tests of §39.13 pass.
