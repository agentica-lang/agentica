## Phase 26: Semantic CLI for agents

Specified in [`docs/future/39-semantic-cli.md` section 39](../future/39-semantic-cli.md#39-semantic-cli-for-agents). Phase 26 adds four commands that answer questions about checked code, JSON first: `agentica outline`, `agentica symbol`, `agentica refs` and `agentica type-at`. It is front end and CLI only: no language change, no lowering or VM change. It comes after doc comments ([phase 22](22-doc-comments.md)) and digit separators ([phase 23](23-digit-separators.md)), at order step 7.2b of the [roadmap](README.md), and before the full 6c round (order step 10), which measures it (§39.12). It has three PRs. Each one has its own tests and docs.

- [ ] **26a: `agentica outline` (§39.3, §39.5, §39.6).**
  - **CLI:** `agentica outline FILE [--json]`, `FILE` a source file or a `std/` module. `src/main.rkt` only parses the arguments and prints; the work is in a new `src/query.rkt`.
  - **Parse only:** lex and parse the one file, as `agentica doc` does (22b); no linking and no checking.
  - **JSON:** the `outline` object of §39.5, with `version` and `command`; the item fields shared with `agentica doc` come from one function.
  - **Exit codes:** 0, 1 for a lex or parse error, 2 for an unreadable file or unknown `std/` module (§39.7).
  - **Tests** (`tests/query-test.rkt`, fixtures in `tests/fixtures/query/`): the `outline` cases of §39.13.
  - **Docs:** `docs/grammar.md` §6 (a short "Code queries" paragraph next to "Builtin discovery and execution budget"); the programming skill (a new `references/queries.md` and its row in "When to read a reference"); `site/content/getting-started.md` (the command); the development skill.
- [ ] **26b: `agentica symbol` and `agentica refs` (§39.3, §39.4, §39.7, §39.8, §39.9).**
  - **Front end:** `check` gets `#:require-main? #f` (no `CHECK-MAIN` for a queried module) and an optional `#:uses` table: each name use to its declaration, with the module and the name before linking.
  - **Query** (`src/query.rkt`): `PATH...` expansion (files, directories without `agc_libs/`, default `.`), one link and check per root with shared module identities, the name forms of §39.4, builtins from the `help` catalog, `std/MOD.NAME`.
  - **Diagnostics:** `QUERY-NOT-FOUND` and `QUERY-AMBIGUOUS-NAME`, with their spans and helps; exit codes of §39.7.
  - **Tests:** the `symbol` and `refs` cases of §39.13.
  - **Docs:** `docs/grammar.md` (the commands and the new codes), the programming skill (`references/queries.md`, `references/diagnostics.md`), the site page of 26a, the development skill.
- [ ] **26c: `agentica type-at` and the position form of `refs` (§39.3).**
  - **Query:** the innermost expression or name at a position, its type from the `#:types` table, its definition from the `#:uses` table or the local binding.
  - **Diagnostics:** `QUERY-NO-EXPRESSION` at the position.
  - **Tests:** the `type-at` cases of §39.13 and the position form of `refs`.
  - **Docs:** as in 26b.
- No CHANGELOG: the project adds none in the private alpha.

**Done when:** an agent can list a file's declarations, find where a name is defined, list every reference to a declaration across a program, and get the checked type at a position, each in text and in JSON with `version` 1; a program that does not check gives its first diagnostic and exit 1; the `QUERY-` codes and exit codes of §39.7 hold; and the tests of §39.13 pass. LSP, rename and refactor commands, editor integration and a daemon stay out (§39.11).
