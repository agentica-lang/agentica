## 39. Semantic CLI for agents

**Status:** planned (roadmap [phase 26](../roadmap/26-semantic-cli.md), order step 7.2b, after doc comments and digit separators). Agreed with the owner on 2026-10-13: agents program better when they can ask the compiler about the code, not only read the docs. The front end already builds a checked program with types and spans; four CLI commands expose it, JSON first. No language change, no VM change.

```text
agentica outline FILE [--json]
agentica symbol NAME [PATH...] [--json]
agentica refs NAME|FILE:LINE:COL [PATH...] [--json]
agentica type-at FILE:LINE:COL [--json]
```

**Why.** Today an agent that changes a field type or an enum variant finds its uses with `rg`, reads whole files to learn a signature, and guesses the type of an expression from the code around it. `rg` cannot tell `Models.User` from a local `User`, a field `name` from a variable `name`, or an import alias from a module. The checker knows all of this. The 6c task "a type change that crosses a program" (phase 6c) is the case these commands are for.

### 39.1 Today

Checked at `29d64d2`:

- `src/main.rkt` runs lex → parse → link (`link-program`, `src/modules.rkt`) → check (`check`, `src/checker.rkt:207`) for `agentica check FILE`, and prints the first diagnostic in text, `--ai` or `--json` (`diagnostic->jsexpr`, `src/diagnostic.rkt:130`) with exit 1.
- `check` takes an optional `#:types` table and fills it with the type of each expression (`src/checker.rkt:531`) and block (`src/checker.rkt:1277`). Lowering reads it. Nothing else does.
- Linking gives each dependency its own identities and keeps the spans in their own files (`src/modules.rkt`, the comment above `link-program`).
- The checker requires exactly one `main() -> Void` in the root file (`CHECK-MAIN`, `src/checker.rkt:450`).
- `agentica help NAME [--json]` prints a builtin from the catalog (`builtin->jsexpr`); an unknown name prints a line on stderr and exits 2.
- Phase 22b plans `agentica doc PATH [--json]` (§32.5): the exported API of one module, parse only, with a stable JSON shape for items and spans.

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
src/orders.agc:22:15 read
src/report.agc:9:30 read
src/report.agc:31:5 construct

$ agentica type-at src/orders.agc:22:15
src/orders.agc:22:9-22:28 user.email: String
```

Text output is one line per result, `file:line:column` first, so it reads like `rg` output. `--json` prints one object (§39.5).

### 39.3 Commands

- **`outline FILE`**: the top-level declarations of one file in source order: imports (path and alias), structs (with fields), enums (with variants), functions (with their signature), each with `exported` and its span. Private declarations are listed too; this is the difference from `agentica doc`, which shows only the exported API. `FILE` may also be a `std/` module name (`std/http`), read from `stdlib-sources` as `agentica doc` does. Parse only (§39.6). Once phase 22 lands, each item also carries its doc summary.
- **`symbol NAME [PATH...]`**: where a name is defined, with its signature or type. Names are written as in §39.4. A builtin answers with the same object as `agentica help NAME --json`, under `help`, with no span; so one command answers for user code and builtins alike. A bare name can match declarations in several modules: all matches are listed.
- **`refs NAME|FILE:LINE:COL [PATH...]`**: every reference to one declaration across the linked modules of `PATH...`, in file and position order, each with its span, its kind (`call`, `value`, `type`, `construct`, `read`, `pattern`, `import`) and the function it is in. The definition comes first. The position form picks the declaration of the name at that position, which always resolves to one declaration. Builtins work too (`refs File.read src/`), with no definition. No references is not an error: an empty list, exit 0.
- **`type-at FILE:LINE:COL`**: the checked type of the innermost expression or name whose span contains the position, with that span and its source text. For a name it also gives the definition's span (a declaration, a field, a variant, a parameter or a local binding). Line and column are 1-based, the same units as diagnostics.

`PATH...` are files or directories; a directory means every `*.agc` file under it, without `agc_libs/`. The default is the current directory.

### 39.4 How names are written

- **Decided:** a name is written as the code writes it, so an agent can copy it from the file it is reading:
  - `total`: a top-level function, struct or enum, in any module of `PATH...`;
  - `Models.total`, `Models.User`: through an import alias as written in one of the files of `PATH...`;
  - `User.email`, `Models.User.email`: a struct field;
  - `Option.Some`, `Domain.Option.Some`: an enum variant;
  - `Map.get`, `puts`: a builtin, as in `agentica help`.
- `X.y` is never ambiguous inside one file: import aliases cannot collide with declarations or builtin names (`docs/grammar.md`, "File modules and imports").
- Across files, the same alias can name different modules. Then `symbol` lists every match, and `refs` needs exactly one declaration: two or more give `QUERY-AMBIGUOUS-NAME`, with a help that lists each candidate as `FILE:LINE:COL`, ready for the position form.
- `std/MOD.NAME` (`std/http.get`) is also accepted, with the spelling of §32.6, since `std/` modules have no fixed alias.
- Local variables and parameters are not names for `symbol` and `refs`; `type-at` and the position form of `refs` reach them.
- **Alternative, not chosen:** names qualified by module path (`models.agc:User.email`). It does not depend on the alias, but agents do not see it in the code, and a path inside a name is hard to quote. If aliases turn out to confuse agents in 6c, it can be added as a second form.

### 39.5 JSON

Every object has `"version": 1` and `"command"`. A field that changes meaning gets a new version; new fields can be added within a version. Spans are the object `diagnostic->jsexpr` uses: `{file, range: {start: {line, column}, end: {line, column}}}`. Types and signatures are strings printed as written, as in §32.5.

- `outline`: `{version, command, file, imports: [{path, alias, span}], items: [...]}`. Each item is `{kind, name, exported, signature, span}`, `kind` being `"function"`, `"struct"` or `"enum"`, with the extra fields of §32.5 (`parameters` and `result`, `fields`, `variants`) and `summary` once phase 22 lands.
- `symbol`: `{version, command, query, matches: [...]}`. Each match is `{kind, name, module, exported, signature, span}`; `kind` adds `"field"` (with `type` and `struct`), `"variant"` (with `payload` and `enum`) and `"builtin"` (with `help`, and `span` and `module` set to `null`). `module` is the module's name as diagnostics print it (`src/models.agc`, `std/queue.agc`).
- `refs`: `{version, command, query, definition, references: [{kind, function, span}]}`, with `definition` a `symbol` match.
- `type-at`: `{version, command, position: {file, line, column}, kind, text, type, span, definition}`. `kind` is `"expression"` or `"name"`; `definition` is a span or `null`.

The shared item fields of `outline` and `agentica doc` come from one function in `src/query.rkt`, so the two commands cannot drift.

### 39.6 Programs that do not check

- `outline` lexes and parses one file. It does not link or check, so it works on a file whose imports are missing or whose types are wrong. A lex or parse error gives that diagnostic and exit 1.
- `symbol`, `refs` and `type-at` need a checked program. If any file of `PATH...` (or `FILE`) does not lex, parse, link or check, the command prints the first diagnostic in the usual format (text, `--ai` or `--json`) and exits 1, as `agentica check` does. The agent fixes that first; the answer would be wrong anyway.
- **Alternative, not chosen:** answering from a partly checked program. It needs a checker that recovers from errors, which the front end does not have (each stage stops at the first error, AGENTS.md).
- A queried file does not need `main`: the commands check each file of `PATH...` as a root with the `CHECK-MAIN` rule off (a new `#:require-main? #f` argument to `check`). Everything else is the same checker.

### 39.7 Diagnostics and exit codes

The commands are a new front-end stage, `src/query.rkt`, so its codes have their own prefix, `QUERY-`. They are stable, carry a span, and print in the usual three formats.

| Code | When | Span |
|---|---|---|
| `QUERY-NOT-FOUND` | `symbol` or `refs` names nothing in `PATH...` or the catalog; the help has "did you mean" | the start of the first file of `PATH...` |
| `QUERY-AMBIGUOUS-NAME` | `refs` NAME matches more than one declaration; the help lists the candidates | the start of the first file of `PATH...` |
| `QUERY-NO-EXPRESSION` | `type-at` or `refs` at a position outside the file or not on an expression or name | the position |

- Exit 0: an answer, including an empty list of references.
- Exit 1: the program has an error (a `LEX-`, `PARSE-`, `CHECK-` diagnostic).
- Exit 2: usage errors, an unreadable path, and every `QUERY-` code, as `help` and `doc` exit 2 for an unknown name. Exit 1 always means "fix the program", exit 2 "fix the question".
- **Alternatives, not chosen:** `CHECK-` codes (the program is fine; the question is wrong), and a plain stderr line as `help` prints today (agents parse JSON; a diagnostic has a span and a help).

### 39.8 Performance

- One front-end pass per command: lex, parse, link and check, with no lowering, no bytecode and no VM. A command costs about one `agentica check` of the same files.
- `refs` and `type-at` read two tables the checker fills when asked: the `#:types` table that exists, and a new `#:uses` table from each name use to the declaration it resolves to, with the module and the name before linking, so a dependency's linked identity maps back to its source name.
- No daemon, no cache, no watch mode. Start-up is the Racket start-up of every command today; the single binary of §35 makes it faster for all of them.

### 39.9 Builtins and `agentica help`

`symbol` and `refs` read builtins from the same catalog as `agentica help` and do not repeat it: a builtin match embeds the `help --json` object as it is. `std/` exports are ordinary user declarations from `stdlib-sources`. `agentica help` does not change.

### 39.10 Order

- Order step 7.2b of the [roadmap](../roadmap/README.md): after doc comments (phase 22) and digit separators (phase 23), before iteration and concurrent collections (row 7.3). VM-independent: front end and CLI only.
- After phase 22, so `outline` shares `agentica doc`'s signature printer and item shape (22b) and shows doc summaries.
- Before the full 6c round (order step 10), so it can measure the commands (§39.12).
- One PR per command group: `outline` first, then `symbol` and `refs` (they share name resolution and the `#:uses` table), then `type-at`.

### 39.11 Decided against

- **LSP.** A language server needs a long-lived process, incremental checking and an editor protocol. Agents call commands in a shell; JSON on stdout is enough.
- **Rename and refactor commands.** Agents edit files well; what they lack is the list of places to edit, which `refs` gives.
- **Editor integration, a daemon, a cache.** See §39.8.
- **Partial answers for programs that do not check.** See §39.6.

### 39.12 Measuring it: the 6c round

- The full 6c round (roadmap order step 10, [phase 6c](../roadmap/06-validation.md#phase-6c-agentica-against-typed-python)) runs with the commands available and documented in the programming skill.
- `tests/eval/run.py` counts each command call per run, next to file reads (`cat`, `rg`, `sed`) and `agentica check` calls.
- On the tasks that cross a program (a field type, an enum variant, a Result in place of a plain value), one extra Agentica arm runs without the commands in the skill, with the same model and budget. The comparison is hidden tests passed, tokens, repair attempts and time to a correct solution.
- Keep the commands in the skill if agents call them and the arm with them is not worse; if agents never call them, change how the skill presents them before the next round, not the commands.

### 39.13 Tests

- `tests/query-test.rkt` (rackunit), running the CLI in process (`tests/cli-in-process.rkt`), with fixtures in `tests/fixtures/query/`: a root file that imports two modules under aliases and `std/queue`; a struct, an enum with a payload, a private function, a field used in a read and in a construction, a variant in a `case` pattern; the same alias for different modules in two files.
- Each test asserts the exit code, the diagnostic code, and the JSON fields and spans, not message text:
  - `outline`: items, `exported`, signatures and spans; a file with a missing import still answers; a parse error gives exit 1 and its code; `std/queue`.
  - `symbol`: each name form of §39.4; a builtin carries the `help` object; several matches; `QUERY-NOT-FOUND`.
  - `refs`: each reference kind; a reference through an alias; the position form; an empty list (exit 0); `QUERY-AMBIGUOUS-NAME`; a program with a `CHECK-` error gives exit 1.
  - `type-at`: an expression, a name with its definition, a local binding, a position between tokens and past the end (`QUERY-NO-EXPRESSION`).
- No golden fixtures: nothing runs on the VM.

The docs to update are listed in [phase 26](../roadmap/26-semantic-cli.md).
