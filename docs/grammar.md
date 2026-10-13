# Agentica: grammar and language design

This is the index of the language definition. The text is split by section into the files of `grammar/`; every file keeps the section numbers and headings of the whole, so `§6` or "Ranges" still finds its place: look it up below. Status: implemented by the interpreter (a Racket front end that compiles to bytecode for the C VM); remaining proposals live in [`future/`](future/README.md). The documentation site shows these files in order as one page.

| § | Topic | File |
|---|---|---|
| 1 | What we want to validate | [`grammar/01-overview.md`](grammar/01-overview.md#1-what-we-want-to-validate) |
| 2 | Design decisions: the rules at a glance | [`grammar/01-overview.md`](grammar/01-overview.md#2-design-decisions) |
| 3 | A core program | [`grammar/01-overview.md`](grammar/01-overview.md#3-a-core-program) |
| 4 | Lexical conventions: comments, newlines, reserved words, literals, interpolation | [`grammar/04-lexical.md`](grammar/04-lexical.md) |
| 5 | Core EBNF: declarations, statements, expressions, precedence | [`grammar/05-syntax.md`](grammar/05-syntax.md) |
| 5 | File modules and imports, `std/` and `pkg/` resolution, `std/queue`, `std/bdd` | [`grammar/05b-modules.md`](grammar/05b-modules.md) |
| 6 | Semantic rules: types, operators, scope, Void, functions, enums and `case`, structs, ranges, maps, `Result` and `try`, function values, blocks | [`grammar/06-semantics.md`](grammar/06-semantics.md) |
| 6 | Builtin library: methods on builtin types, `List`, `Map`, `String`, `IO`, `System`, `Time`, `Random`, `JSON`, help and the execution budget | [`grammar/06b-builtins.md`](grammar/06b-builtins.md) |
| 6 | Lightweight tasks, unit tests (`Test`), `agentica test` | [`grammar/06c-tasks-and-tests.md`](grammar/06c-tasks-and-tests.md) |
| 6 | TCP, TLS and HTTP (`std/http` client and server), files and paths, processes | [`grammar/06d-io-and-network.md`](grammar/06d-io-and-network.md) |
| 7 | Diagnostics for agents: format, codes, hints for other languages | [`grammar/07-diagnostics.md`](grammar/07-diagnostics.md) |
| 8 | Examples to review the design | [`grammar/08-examples.md`](grammar/08-examples.md#8-examples-to-review-the-design) |

When the language changes, update the matching file here, the programming skill and the site together (see [`AGENTS.md`](../AGENTS.md)).
