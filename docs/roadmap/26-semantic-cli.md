## Phase 26: Semantic CLI for agents

Specified in [`docs/future/39-semantic-cli.md` section 39](../future/39-semantic-cli.md#39-semantic-cli-for-agents). Phase 26 adds four commands that answer questions about the code, JSON first: `agentica outline`, `agentica symbol`, `agentica refs` and `agentica type-at`. It is front end and CLI only: no language change, nothing in lowering or the VM. It comes after doc comments ([phase 22](22-doc-comments.md), whose `src/docs.rkt` it reuses) and digit separators ([phase 23](23-digit-separators.md)), at order step 7.2b of the [roadmap](README.md), and before the full 6c round (order step 10), which measures it (§39.12). It has three PRs. Each one has its own tests and docs.

- [ ] **26a: `agentica outline` (§39.3, §39.5, §39.6).**
  - **CLI:** `agentica outline FILE [--ai|--json]`, `FILE` a source file or a `std/` module; options after the command parsed by hand, as for `help` and `test`. `src/main.rkt` only parses the arguments and prints; the work is in a new `src/query.rkt`, which builds the items with `src/docs.rkt` (22b).
  - **Parse only:** lex and parse the one file, as `agentica doc` does; no linking and no checking.
  - **JSON:** the `outline` object of §39.5, with `version`, `command` and each item's `summary`; the span object and the file-name rule of §39.4 and §39.5.
  - **Diagnostics:** `QUERY-USAGE` at `<arguments>`; exit codes of §39.7 (1 for a lex or parse error, 2 for `QUERY-USAGE`).
  - **Tests** (`tests/query-test.rkt`, fixtures in `tests/fixtures/query/`): the `outline` and `QUERY-USAGE` cases of §39.13, `summary` included.
  - **Docs:**
    - `docs/grammar/06b-builtins.md`: a short "Code queries" paragraph next to "Builtin discovery and execution budget"; and `docs/grammar/07-diagnostics.md`: `QUERY-` in the list of stage prefixes;
    - `AGENTS.md` (the diagnostic prefixes under "Conventions");
    - the programming skill (a new `references/queries.md`, its row in "When to read a reference", `references/diagnostics.md`);
    - `site/content/getting-started.md` (the command);
    - the development skill (`SKILL.md`, the diagnostic-code row around line 105; `references/stages.md`, the codes by stage around line 57, and a note on `src/query.rkt`).
- [ ] **26b: `agentica symbol` and `agentica refs` on declarations (§39.3, §39.4, §39.6 to §39.9).**
  - **Linker** (`src/modules.rkt`):
    - `link-programs`: several roots into one program with shared tables, each module visited once, every module prefixed `@N::`, roots included; each root linked as a transaction (§39.8): a root whose lex, parse or link fails, in its file or a dependency, is left out with its diagnostic, its added modules are dropped, and later roots that reach a failed module are skipped with the same diagnostic; `link-program` keeps its behavior;
    - modules keyed by canonical path, the roots included, so one file has one name;
    - the side tables `#:origins` (linked identity to module key, source name and declaration span) and `#:uses` (each name use to its linked identity, with the name's span), and each module's alias table (`imports`) returned for 26c.
  - **Parser and AST** (`src/parser.rkt`, `src/ast.rkt`): a `name-span` on `field-access` and `method-call`, for the field name of a read. The field names of a construction are `named-arg` nodes, whose span already starts at the name.
  - **Query** (`src/query.rkt`): `PATH...` expansion (§39.4), the name forms of §39.4 with `std/` forms, builtins from the `help` catalog, references of functions, structs, enums and variants from `#:uses`, the file-name rule, `skipped`.
  - **Field refs** need a check: `check` gets `#:require-main? #f`, and the struct of a field read is the `#:types` entry of the access's target (`check-struct-field` records nothing; the `resolved` field is for builtin methods only).
  - **Diagnostics:** `QUERY-NOT-FOUND` and `QUERY-AMBIGUOUS-NAME` at `<arguments>`, with their helps.
  - **Tests:** the `symbol` and `refs` cases of §39.13.
  - **Docs:** `docs/grammar.md` (the commands and the new codes), the programming skill (`references/queries.md`, with "run `refs` before the edit"; `references/diagnostics.md`), the site page of 26a, the development skill (`references/stages.md`: the linker's side tables).
- [ ] **26c: `agentica type-at` and the position form of `refs` (§39.3, §39.5).**
  - **Parser and AST:** a span for the `for` loop variable and for each `variant-pattern` binding.
  - **Checker:** a `#:locals` table, each use of a parameter or local to its binding span, for the position form of `refs` on a local and for `type-at`'s definition.
  - **Query:** the innermost expression or name at a position, its type from the `#:types` table, printed through `FILE`'s import aliases from the linker's alias table (§39.5); its definition from `#:uses`, the target's struct in `#:types` for a field, or `#:locals`; checks only `FILE` and its imports.
  - **Diagnostics:** `QUERY-NO-EXPRESSION` at the position, clamped to the end of the line or of the file (§39.7).
  - **Tests:** the `type-at` and position-form cases of §39.13.
  - **Docs:** as in 26b.
- No CHANGELOG: the project adds none in the private alpha.

**Done when:** an agent can list a file's declarations, find where a name is defined, list every reference to a declaration across a program (functions, types and variants even while the program does not check), and get the checked type at a position, each in text and in JSON with `version` 1; a broken root is `skipped`, not fatal; a command that needs a check gives the first diagnostic and exit 1; the `QUERY-` codes and exit codes of §39.7 hold; and the tests of §39.13 pass. LSP, rename and refactor commands, editor integration and a daemon stay out (§39.11).
