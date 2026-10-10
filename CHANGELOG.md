# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Ruby forms seen in evaluations: an optional `do` after `case`, `while` and
  `for` headers; a one-line case arm (`1 -> puts("one")`); module functions
  without arguments, builtin or through an import alias, may drop the
  parentheses (`IO.gets!`, `IO.eof?`).
- Hints for `let`/`var`/`const`, `match`, `when`, `then`, `fn`/`lambda`, a
  `do` block with no call, `loop do`, `if x do`, trailing `if`/`while`
  modifiers, `Module.fn arg`, `Hash.new`/`Array.new`, `break`/`continue`/`next`
  (also `break if x`), `Result.Ok(x)` used as a value, and an enum variant
  without parentheses.
- Hints for habits from other languages: `len`, `str`, `print`, `input`,
  `range`, `int`/`float`, `None`/`null`, `elif`/`else if`, Python-style
  string methods, and a `Result[T]` used where `T` is expected.
- Blocks and closures: `xs.map do |x| x * 2 end` as the last argument of a
  call, capturing values when created; usable anywhere a `Fn` is, including
  `Task.spawn`, HTTP callbacks and `BDD.step`. New diagnostics
  `CHECK-BLOCK-TYPE`, `CHECK-BLOCK-TARGET` and `CHECK-CAPTURED-ASSIGNMENT`.
- `List.each`, `List.any?` and `List.all?`.
- String interpolation: `"total: #{n + 1}"`, with `\#` for a literal `#`.
- Methods on builtin values (`s.strip.size`, `xs.push(1)`, `r.ok?`), resolved
  by type to module functions, with Ruby aliases (`to_i`, `to_s`, `size`,
  `strip`, `include?`, `push`, `join`).
- `tests/eval/diagnostics.py` summarizes the diagnostics agents saw in
  evaluation runs.
- `!`, `&&` and `||` as spellings of `not`, `and` and `or`, and compound
  assignment `+=`, `-=`, `*=`, `/=`, `%=`.
- Embedded Agentica standard library with an immutable String FIFO at
  `std/queue.agc`; executable releases need no separate stdlib installation.
- `pkg/` imports with project-local, `AGENTICA_PATH`, user-data, and system
  library roots, deterministic precedence and path-containment checks.
- `List.sort` and `List.sort_by`: stable ascending sorts over `Int`, `Float`
  and `String` values or keys.
- `String.index_of`, `String.at`, `String.reverse`, `String.code`,
  `String.from_code`, `Float.from_int`, `Float.to_int` and `Float.to_int!`.
- `Time.now_ms`, `Time.monotonic_ms`, `Random.int` and `Random.float`, with
  `--seed N` for repeatable runs, also passed through `agentica test`.

### Changed

- The programming skill and the `inventory`, `strings` and `result` examples
  teach the Ruby forms (methods, `!`/`&&`, `+=`, interpolation, blocks).
- A declaration's `end` must be followed by a blank line before the next
  declaration (`PARSE-MISSING-BLANK-LINE`).
- `#{` inside a string now starts an interpolation; write `\#{` for the
  old literal text.
- Ignoring the result of a builtin without effects is `CHECK-UNUSED-VALUE`.
- Field access on a non-struct value is a method call; unknown names are
  `CHECK-UNKNOWN-METHOD` (replaces `CHECK-NOT-A-STRUCT`).
- The Int/Float type-mismatch help now suggests `Float.from_int` and
  `Float.to_int!`.
- `Time` and `Random` are reserved builtin module names; declarations or
  import aliases with those names no longer check.

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
