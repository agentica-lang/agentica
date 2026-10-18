# Agentica: grammar and language design

This is the index of the language definition. The text is split by section into
the files of `grammar/`; every file keeps the section numbers and headings of
the whole, so `§6` or "Ranges" still finds its place: look it up below. Status:
implemented by the interpreter (a front end written in Agentica that compiles to
bytecode for the C VM); remaining proposals live in
[`future/`](future/README.md). The documentation site shows these files in order
as one page.

- **§:** 1
  - **Topic:** What we want to validate
  - **File:**
    [`grammar/01-overview.md`][agentica-link-1]

- **§:** 2
  - **Topic:** Design decisions: where each rule is stated
  - **File:**
    [`grammar/01-overview.md`](grammar/01-overview.md#2-design-decisions)

- **§:** 3
  - **Topic:** A core program
  - **File:**
    [`grammar/01-overview.md`](grammar/01-overview.md#3-a-core-program)

- **§:** 4
  - **Topic:** Lexical conventions: comments, newlines, reserved words,
    literals, interpolation
  - **File:** [`grammar/04-lexical.md`](grammar/04-lexical.md)

- **§:** 5
  - **Topic:** Core EBNF: declarations, statements, expressions, precedence
  - **File:** [`grammar/05-syntax.md`](grammar/05-syntax.md)

- **§:** 5
  - **Topic:** File modules and imports, `std/` and `pkg/` resolution,
    `std/queue`, `std/binary`, `std/toml`, `std/bdd`
  - **File:** [`grammar/05b-modules.md`](grammar/05b-modules.md)

- **§:** 6
  - **Topic:** Semantic rules: types, operators, scope, Void, functions, enums
    and `case`, structs, ranges, maps, `Result` and `try`, function values,
    blocks
  - **File:** [`grammar/06-semantics.md`](grammar/06-semantics.md)

- **§:** 6
  - **Topic:** Builtin library: methods on builtin types, the error behaviour of
    `List`, `Map`, `String`, `IO`, `Random`, `JSON`, help and the execution
    budget
  - **File:** [`grammar/06b-builtins.md`](grammar/06b-builtins.md)

- **§:** 6
  - **Topic:** Lightweight tasks, channels, unit tests (`Test`), `agentica test`
  - **File:** [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md)

- **§:** 6
  - **Topic:** TCP, TLS and HTTP (`std/http` client and server), files and
    paths, processes
  - **File:** [`grammar/06d-io-and-network.md`](grammar/06d-io-and-network.md)

- **§:** 7
  - **Topic:** Diagnostics for agents: format, codes, hints for other languages
  - **File:** [`grammar/07-diagnostics.md`](grammar/07-diagnostics.md)

- **§:** 8
  - **Topic:** Examples to review the design
  - **File:**
    [`grammar/08-examples.md`][agentica-link-2]

When the language changes, update the matching file here, the programming skill
and the site together (see [`AGENTS.md`](../AGENTS.md)).

[agentica-link-1]: grammar/01-overview.md#1-what-we-want-to-validate
[agentica-link-2]: grammar/08-examples.md#8-examples-to-review-the-design
