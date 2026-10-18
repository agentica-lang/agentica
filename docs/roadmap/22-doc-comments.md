## Phase 22: Doc comments

Specified in [`docs/future/32-doc-comments.md` section
32](../future/32-doc-comments.md#32-doc-comments). Phase 22 is front end only:
the lexer, the parser and the CLI. It does not change lowering or the VM. Part
22a comes after 7i, HTTP 20b, task crash isolation ([phase
24](24-task-crash-isolation.md)), unit tests ([phase 25](25-unit-tests.md)) and
HTTP 20c (order step 7.2.1), and after the evaluation pilot (order step 7.2.2),
at order step 7.2a (§32.7). Part 22b (`agentica doc`) waits until after the
bootstrap (row 22b of the [roadmap](README.md)). The semantic CLI ([phase
26](26-semantic-cli.md)) comes after 22b and reuses its docs engine.
22a is done; 22b is one PR with its own tests and docs.

- [x] **22a: `##` doc comments (§32.2 to §32.4).** Done: `DOC` tokens in
  the lexer, attachment in the parser with `PARSE-DETACHED-DOC`, docs on
  every `stdlib/*.agc` export, goldens. Record: `docs/grammar.md` and §32.
- [ ] **22b: `agentica doc` and `help` for `std/` (§32.5, §32.6).**
  - **Deferred until after the bootstrap**, decided by the owner on
    2026-10-15 (row 22b of the [roadmap](README.md)).
  - **CLI:** `agentica doc PATH [--json]` for a file or a `std/` module, and
    `agentica help std/MODULE[.NAME] [--json]`. The CLI only parses and
    prints; the work is in the front end in `compiler/`.
  - **Parse only:** lex and parse the one module, with no linking and no import
    resolution. A `std/` source comes from the embedded `stdlib/`.
  - **JSON:** the objects of §32.5 and §32.6.
  - **Exit codes:** 1 for a lex or parse error; 2 for an unknown file, `std/`
    module or name. A missing import is not an error, because nothing is linked.
  - **Tests:**
    - Markdown and JSON for a fixture module (documented and undocumented
      exports, a private declaration left out, struct fields and enum variants,
      an import alias in a signature);
    - a file whose import does not exist still prints its docs;
    - `help std/http.get` and `help std/http`, in text and JSON;
    - the exit codes and "did you mean".
  - **Docs:**
    - `docs/grammar/06b-builtins.md`: the `agentica help` paragraph under
      "Builtin discovery and execution budget";
    - the programming skill (how to read a `std/` module's API:
      `agentica doc std/http`);
    - `site/content/getting-started.md` (the commands);
    - the development skill.

**Done when:** for 22a, every `stdlib/*.agc` has a module doc and a doc on every
export, and the doc tests of 22a pass. For 22b, `agentica doc std/http` prints
its API, and the doc tests of 22b pass.
Doctests, generated site pages and editor hover stay in §32.8.
