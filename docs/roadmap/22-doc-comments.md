## Phase 22: Doc comments

Specified in [`docs/future/32-doc-comments.md` section 32](../future/32-doc-comments.md#32-doc-comments). Phase 22 is front end only: the lexer, the parser and the CLI. It does not change lowering or the VM. It comes after 7i, as the first new feature (order step 7.2a, §32.7). It has two PRs. Each one has its own tests and docs.

- [ ] **22a: `##` doc comments (§32.2 to §32.4).**
  - **Lexer** (`src/lexer.rkt`): one `DOC` token per doc block, with its text and span. `##` after code on a line stays an ordinary comment.
  - **Parser** (`src/parser.rkt`):
    - attaches each block to the next declaration, field or variant, or makes it the module doc;
    - stores the docs in a side table on `program`, from the span of each documented declaration, field or variant to its doc, so the existing AST structs keep their shape;
    - reports `PARSE-DETACHED-DOC` at the first line of any other block;
    - doc lines do not count as blank for `PARSE-MISSING-BLANK-LINE`; a doc block right after a declaration's `end` gives that error at the doc block's first line.
  - **Stdlib:** every `stdlib/*.agc` gets a module doc and a doc on every export (`queue.agc`, and `http.agc`).
  - **Tests:**
    - `tests/lexer-test.rkt`: `DOC` tokens and spans, `##` after code, `###`, `##` inside strings.
    - `tests/parser-test.rkt`:
      - attachment to `def`, `struct`, `enum`, fields, variants and the module doc;
      - a module doc after blank lines and `#` comment lines;
      - each `PARSE-DETACHED-DOC` case of §32.2 with its span, including a module doc followed by a `#` comment line;
      - the blank-line rule with doc blocks, including `PARSE-MISSING-BLANK-LINE` at the first line of a doc block right after `end`.
    - A test that every `stdlib/*.agc` has a module doc and a doc on every export.
    - A golden fixture with doc comments everywhere, which shows that the VM runs it unchanged.
  - **Docs:**
    - `docs/grammar.md`:
      - lexical rules, the blank-line rule, the new code;
      - the EBNF of §5: an optional `DOC` before `declaration` (its `def`, `struct` and `enum` forms), `field_decl` and `variant_decl`, and an optional module doc in `program`;
    - the programming skill (`SKILL.md`: one short rule, with the example, in the lexical section) and `references/diagnostics.md`;
    - `site/content` (the tour's first page that shows comments);
    - the development skill (`references/stages.md`).
- [ ] **22b: `agentica doc` and `help` for `std/` (§32.5, §32.6).**
  - **CLI:** `agentica doc PATH [--json]` for a file or a `std/` module, and `agentica help std/MODULE[.NAME] [--json]`. `src/main.rkt` only parses and prints; the work is in a new `src/docs.rkt`.
  - **Parse only:** lex and parse the one module, with no linking and no import resolution. A `std/` source comes from `stdlib-sources`.
  - **JSON:** the objects of §32.5 and §32.6.
  - **Exit codes:** 1 for a lex or parse error; 2 for an unknown file, `std/` module or name. A missing import is not an error, because nothing is linked.
  - **Tests** (`tests/docs-test.rkt`):
    - Markdown and JSON for a fixture module (documented and undocumented exports, a private declaration left out, struct fields and enum variants, an import alias in a signature);
    - a file whose import does not exist still prints its docs;
    - `help std/http.get` and `help std/http`, in text and JSON;
    - the exit codes and "did you mean".
  - **Docs:**
    - `docs/grammar.md` §6: the `agentica help` paragraph under "Builtin discovery and execution budget" (around line 1015);
    - the programming skill (how to read a `std/` module's API: `agentica doc std/http`);
    - `site/content/getting-started.md` (the commands);
    - the development skill.

**Done when:** every `stdlib/*.agc` has a module doc and a doc on every export, `agentica doc std/http` prints its API, and the doc tests of 22a and 22b pass. Doctests, generated site pages and editor hover stay in §32.8.
