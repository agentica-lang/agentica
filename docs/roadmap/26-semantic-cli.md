## Phase 26: Semantic CLI for agents

Specified in [`docs/future/39-semantic-cli.md` section
39](../future/39-semantic-cli.md#39-semantic-cli-for-agents). Phase 26 adds four
commands that answer questions about the code, JSON first: `agentica outline`,
`agentica symbol`, `agentica refs` and `agentica type-at`. It is front end and
CLI only: no language change, nothing in lowering or the VM. It comes after row
22b of [phase 22](22-doc-comments.md), whose docs engine (22b) it reuses,
and after
digit separators ([phase 23](23-digit-separators.md)), at order step 7.2b of the
[roadmap](README.md). It waits until after the bootstrap,
because it extends the front end in `compiler/`, and it comes before the
full 6c round
(order step 10), which measures it (§39.12). It has three PRs. Each one has its
own tests and docs.

- [ ] **26a: `agentica outline` (§39.3, §39.5, §39.6).**
  - **CLI:** `agentica outline FILE [--ai|--json]`, `FILE` a source file or a
    `std/` module; options after the command parsed by hand, as for `help` and
    `test`. The CLI only parses the arguments and prints; the work is in the
    front end in `compiler/`, building the items with the 22b docs engine.
  - **Parse only:** lex and parse the one file, as `agentica doc` does; no
    linking and no checking.
  - **JSON:** the `outline` object of §39.5, with `version`, `command` and each
    item's `summary`; the span object and the file-name rule of §39.4 and §39.5.
  - **Diagnostics:** `QUERY-USAGE` at `<arguments>`; exit codes of §39.7 (1 for
    a lex or parse error, 2 for `QUERY-USAGE`).
  - **Tests** (fixtures in `tests/fixtures/query/`): the
    `outline` and `QUERY-USAGE` cases of §39.13, `summary` included.
  - **Docs:**
    - `docs/grammar/06b-builtins.md`: a short "Code queries" paragraph next to
      "Builtin discovery and execution budget"; and
      `docs/grammar/07-diagnostics.md`: `QUERY-` in the list of stage prefixes;
    - `AGENTS.md` (the diagnostic prefixes under "Conventions");
    - the programming skill (a new `references/queries.md`, its row in "When to
      read a reference", `references/diagnostics.md`);
    - `site/content/getting-started.md` (the command);
    - the development skill (`SKILL.md`, the diagnostic-code row;
      `references/stages.md`, the codes by stage).
- [ ] **26b: `agentica symbol` and `agentica refs` on declarations (§39.3,
  §39.4, §39.6 to §39.9).**
  - **Linker:** several roots into one program with shared tables, each
    root linked as a transaction (§39.8); side tables of origins (linked
    identity to module, name and span) and uses (each name use to its
    identity and span), plus each module's alias table for 26c. Mapping
    to the `compiler/` linker decided in the implementation PR.
  - **Parser and AST:** spans on every name occurrence the query needs
    (field reads, construction fields, `for` variables, pattern bindings).
  - **Query:** `PATH...` expansion (§39.4), the name forms with `std/`
    forms, builtins from the `help` catalog, references from the uses
    table, the file-name rule, `skipped`.
  - **Field refs** need a check that runs without `main`, resolving a
    field read's struct from the checked types.
  - **Diagnostics:** `QUERY-NOT-FOUND` and `QUERY-AMBIGUOUS-NAME` at
    `<arguments>`, with their helps.
  - **Tests:** the `symbol` and `refs` cases of §39.13.
  - **Docs:** `docs/grammar.md` (the commands and the new codes), the
    programming skill (`references/queries.md`, with "run `refs` before the
    edit"; `references/diagnostics.md`), the site page of 26a, the development
    skill (`references/stages.md`: the linker's side tables).
- [ ] **26c: `agentica type-at` and the position form of `refs` (§39.3,
  §39.5).**
  - **Spans:** the `for` loop variable and each `variant-pattern`
    binding carry spans.
  - **Checker:** a locals table, each use of a parameter or local to its
    binding span, for the position form of `refs` and `type-at`.
  - **Query:** the innermost expression or name at a position, its type
    from the checker's types, printed through `FILE`'s import aliases
    (§39.5); its definition from the uses table, the target's struct
    from the checked types for a field, or the locals table; checks only
    `FILE` and its imports.
  - **Diagnostics:** `QUERY-NO-EXPRESSION` at the position, clamped to the end
    of the line or of the file (§39.7).
  - **Tests:** the `type-at` and position-form cases of §39.13.
  - **Docs:** as in 26b.
- CHANGELOG: an entry under `[Unreleased]` for any user-visible change.

**Done when:** an agent can list a file's declarations, find where a name is
defined, list every reference to a declaration across a program (functions,
types and variants even while the program does not check), and get the checked
type at a position, each in text and in JSON with `version` 1; a broken root is
`skipped`, not fatal; a command that needs a check gives the first diagnostic
and exit 1; the `QUERY-` codes and exit codes of §39.7 hold; and the tests of
§39.13 pass. The LSP is not in this phase: a separate, unscheduled idea,
[§43](../future/43-language-server.md). Rename and refactor commands, editor
integration and a daemon stay out (§39.11).
