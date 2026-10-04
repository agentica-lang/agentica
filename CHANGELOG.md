# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-10-04

First tagged release of the Agentica interpreter: a small statically typed
language, written in Racket, designed so an AI agent can write, run, and repair
programs from stable diagnostics.

### Added

- **Pipeline and CLI.** Lexer, parser, checker, and evaluator as separate
  modules, driven by `agentica`. Run a program, `check` it without running,
  `--dump` the checked tree, and query a builtin with
  `agentica help NAME --json`. Exit codes: `0` ran, `1` a diagnostic, `2` bad
  usage or an unreadable file.
- **Language core.** `Int`, `Float`, `Bool`, `String`, `Void`, and `Nil`;
  `List[T]`, `Map[K, V]`, `Result[T]`, and `Json`; structs with named fields;
  functions with `Fn[A, ..., R]` values; `if`/`elsif`/`else`, `while`, and
  `for`; full operator precedence; block scopes with a no-shadowing rule; and
  return analysis that requires every reachable path to return.
- **Builtin modules.** `String`, `List`, `Map`, `Result`, `IO`, `System`,
  `File`, `Dir`, `Path`, `JSON`, `TCP`, `TLS`, `HTTP`, `Process`, `Task`, and
  `BDD`, documented from one shared catalog that also types and executes them.
- **Typed JSON.** Decode JSON into declared structs and type expressions,
  encode structs, maps, and lists, extract values with located-path `Result`
  errors, build dynamic documents, and generate JSON schemas.
- **Result and propagation.** `ok`/`error`, the `Result` module, and `try`,
  which unwraps a success or returns the error from the enclosing
  `Result`-returning function.
- **File modules and imports.** Relative `.agc` imports with uppercase aliases,
  explicit `export`, private unexported names, canonical-path deduplication,
  and cycle rejection. Imported declarations share one evaluation, budget, and
  resource ownership.
- **Diagnostics for agents.** Stable stage-prefixed codes (`LEX-`, `PARSE-`,
  `CHECK-`, `RUNTIME-`), file/line/column, a source excerpt with a caret,
  secondary labels, and grounded `= help:` suggestions. `--ai` and `--json`
  print the same diagnostic as compact text or one JSON object.
- **Execution budget.** `--max-steps N` bounds expression and statement
  entries, including loop conditions; exhaustion is `RUNTIME-STEP-LIMIT`.
- **Concurrency.** Lightweight `Task.spawn`/`Task.await`/`Task.sleep` with
  supervision, cached results, cancellation, and a shared step budget.
- **Networking.** TCP, TLS, and a streaming HTTP/1.1 client and server, with
  bounded framing, connection pooling, trailers, and no transparent retries.
- **Processes.** `Process.spawn` and streamed stdin/stdout/stderr behind
  `--allow-run`, with timeouts, 1 MiB per-call bounds, and cleanup on every
  evaluation outcome.
- **BDD.** Gherkin `.feature` specs with typed Agentica step handlers, JSON
  scenario state, and supervised programs under test.
- **Files and paths.** Streamed and whole-file text/byte I/O, metadata,
  recursive `Dir.mkdir`, sorted `Dir.list`, and lexical `Path` helpers.
- **Examples.** `hello`, `classify`, `tasks`, `inventory`, `strings`, `echo`,
  `result`, `json`, `json-config`, `json-expenses`, `json-lines`,
  `knight-tour`, `traveling-salesman`, `maze-bfs`, `dispatch`, `concurrency`,
  `http_get`, `http_server`, `tcp_echo`, `process-tool`, and `json-modules`.
- **Agent tooling.** The `agentica-programming` skill (self-contained language
  reference for writing `.agc` programs), the `agentica-development` skill for
  changing the interpreter, and a Docker/Firejail evaluation harness under
  `tests/eval/`.
- **Release tooling.** `agentica --version`, a `make version` target, and a
  release workflow that builds a distributed executable and publishes a GitHub
  Release when a version tag is pushed.

### Changed

- Diagnostics name the operator token for unary and binary errors, and report
  internal checker states as `CHECK-INTERNAL`.
- `main()` returns `Void`; `nil` remains data and JSON null.
- Maps keep insertion order with immutable hashes; `Map.get/2` returns a
  `Result` and `Map.get/3` an eagerly evaluated default.

[unreleased]: https://github.com/sonic182/agentica/compare/0.1.0...HEAD
[0.1.0]: https://github.com/sonic182/agentica/releases/tag/0.1.0
