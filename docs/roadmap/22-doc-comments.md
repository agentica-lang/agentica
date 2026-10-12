## Phase 22: Doc comments

Specified in [`docs/future/32-doc-comments.md` section 32](../future/32-doc-comments.md#32-doc-comments). Phase 22 is front end only: the lexer, the parser, `src/modules.rkt` and the CLI. It does not change the evaluator, lowering or the VM, so it goes before 7i (§32.7): right after HTTP 20a and the two small PRs queued behind it, and before 20b. It has two PRs. Each one has its own tests and docs.

- [ ] **22a: `##` doc comments (§32.2 to §32.4).**
  - **Lexer** (`src/lexer.rkt`): one `DOC` token per doc block, with its text and span. `##` after code on a line stays an ordinary comment.
  - **Parser** (`src/parser.rkt`):
    - attaches each block to the next declaration, field or variant, or makes it the module doc;
    - stores the docs in a side table on `program`, so the existing AST structs keep their shape;
    - reports `PARSE-DETACHED-DOC` at the first line of any other block;
    - doc lines do not count as blank for `PARSE-MISSING-BLANK-LINE`.
  - **Modules** (`src/modules.rkt`): keeps each module's doc table.
  - **Stdlib:** every export of `stdlib/*.agc` gets a doc (`queue.agc`, and `http.agc` from 20a), plus a module doc.
  - **Tests:**
    - `tests/lexer-test.rkt`: `DOC` tokens and spans, `##` after code, `###`, `##` inside strings.
    - `tests/parser-test.rkt`: attachment to `def`, `struct`, `enum`, fields, variants and the module doc; each `PARSE-DETACHED-DOC` case of §32.2 with its span; the blank-line rule with doc blocks.
    - A test that every export of `stdlib/*.agc` has a doc.
    - A golden fixture with doc comments everywhere, which shows that the VM runs it unchanged.
  - **Docs:**
    - `docs/grammar.md`: lexical rules, the blank-line rule, the new code;
    - the programming skill (`SKILL.md`: one short rule, with the example, in the lexical section) and `references/diagnostics.md`;
    - `site/content` (the tour's first page that shows comments);
    - the development skill (`references/stages.md`).
- [ ] **22b: `agentica doc` and `help` for `std/` (§32.5, §32.6).**
  - **CLI:** `agentica doc PATH [--json]` for a file or a `std/` module, and `agentica help std/MODULE[.NAME] [--json]`. `src/main.rkt` only parses and prints; the work is in a new `src/docs.rkt`.
  - **JSON:** the object of §32.5.
  - **Exit codes:** 1 for a lex or parse error, 2 for an unknown path or name.
  - **Tests** (`tests/docs-test.rkt`):
    - Markdown and JSON for a fixture module (documented and undocumented exports, a private declaration left out, struct fields and enum variants);
    - `help std/http.get` and `help std/http`;
    - the exit codes and "did you mean".
  - **Docs:**
    - `docs/grammar.md` (the CLI section, next to `help`);
    - the programming skill (how to read a `std/` module's API: `agentica doc std/http`);
    - `site/content/getting-started.md` (the commands);
    - the development skill.

**Done when:** every export of `stdlib/` has a doc, `agentica doc std/http` prints its API, and the doc tests of 22a and 22b pass. Doctests, generated site pages and editor hover stay in §32.8.
