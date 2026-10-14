# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.0] - 2026-10-14

Every program now runs on a new C bytecode VM, the Racket evaluator is gone, and the language gained a Ruby-style surface, tasks that isolate crashes, channels, a unit test framework, and TCP, TLS and HTTP on the VM.

### Added

- **Ruby-style forms.** `!`, `&&` and `||` as `not`, `and` and `or`; compound assignment `+=`, `-=`, `*=`, `/=`, `%=` (#25).
- **String interpolation:** `"total: #{n + 1}"`, with `\#` for a literal `#` (#27).
- **Methods on builtin values** (`s.strip.size`, `xs.push(1)`, `r.ok?`), resolved by type, with Ruby aliases such as `to_i`, `to_s`, `size`, `include?` and `join`; unknown names are `CHECK-UNKNOWN-METHOD` (#26).
- **Blocks and closures:** `xs.map do |x| x * 2 end`, `&name` function values and `f.call(...)`, usable anywhere a `Fn` is (#28, #74). New `List.each`, `List.any?` and `List.all?`.
- **`break` and `next`** in `while` and `for` loops; outside a loop they are `CHECK-LOOP-CONTROL` (#34).
- **Printing and text of any value:** `puts`, `print`, `IO.puts`, `IO.print` and `IO.warn` take any value with `to_s`, and every data value has `x.to_s` and `x.inspect` (#36, #37).
- **Accepted spellings from agent runs:** `Result.Ok(x)` and `Result.Err(m)` as values and `ok(v)`/`error(m)` as `case` patterns, nullary enum variants without parentheses (`Command.Show`), top-level `print`, `gets` and `gets!`, an optional `do` after `case`, `while` and `for` headers, and one-line `case` arms (#33, #35).
- **Ranges:** `a..b` and `a...b`, `for x in range` without building a list, `Range` methods, and `Int.times`, `Int.upto` and `Int.downto` with a block (#76).
- **Pipe operator:** `x |> f(a, b)` means `f(x, a, b)`; new `PARSE-PIPE-TARGET` and `CHECK-PIPE-METHOD` (#182).
- **Digit separators:** `1_000` and `1_000.000_5`; a bad `_` is the new `LEX-INVALID-NUMBER` (#203).
- **Doc comments:** a line that starts with `##` documents the next `def`, `struct`, `enum`, field or variant, or the module when it comes first; a block that documents nothing is `PARSE-DETACHED-DOC`. Every `std/` module now has a module doc and a doc on each export (#208).
- **Everyday library:** `List.sort` and `List.sort_by`, `String.index_of`, `at`, `reverse`, `code` and `from_code`, `Float.from_int`, `Float.to_int` and `to_int!`, `Time.now_ms`, `Time.monotonic_ms`, `Random.int` and `Random.float`, and `--seed N` for repeatable runs (#22).
- **Modules:** the embedded standard library with `std/queue`, and `pkg/` imports from project-local, `AGENTICA_PATH`, user-data and system roots (#19).
- **`Channel[T]`:** bounded channels between tasks with `Channel.new`, `send`, `recv`, `close` and `closed?`, with timeouts; `Task.await` cycles are `RUNTIME-TASK-AWAIT-CYCLE` (#179).
- **Tasks:** `Task.pending_count()` (#129), `Task.unobserved_crash()` (#139), and `Task.spawn_owning` to hand a handle to a task (#197).
- **Unit tests:** the builtin `Test` module (`Test.test`, `Test.run`, `Test.eq`, `Test.ok?`, `Test.error?`, `Test.assert`), and `agentica test` now also runs `*_test.agc` files, with `--only TEXT`, a default `test/` folder and one report with the BDD features (#147, #151, #155, #158).
- **BDD in Agentica:** `import "std/bdd"` provides the step API, and `Process.spawn_captured` and `Process.output` support it; Gherkin parsing, step matching and the report are written in Agentica (#128, #129, #130, #131, #132, #133, #134).
- **Process channel:** `Process.spawn_channel` and the child-side `Process.parent_read_line` and `Process.parent_send` open a private line channel to a child on fd 3, with `channel_read_line`, `channel_send`, `channel_close` and `read_available` on the parent side (#193).
- **`File.each_line(path, buffer_bytes, timeout_ms) do |line| ... end`** reads a big file one line at a time (#190).
- **Networking on the VM:** TCP (#106), TLS on OpenSSL 3 (#117), and `std/http` with an HTTP/1.1 client with pooled keep-alive connections (#118) and a server with `listen` and `listen_tls` (#165, #166). `examples/http_server.agc` shows the server.
- **VM options:** `--flush-timeout MS` and `AGENTICA_FLUSH_TIMEOUT_MS` bound the wait for file data and buffered output at the end of a run (default 30000) (#177); `AGENTICA_VM_TRACE=sched,io,proc,loader,gc,tls` (or `all`) traces VM internals, and `AGENTICA_VM` names the VM binary (#102, #103).
- **`agentica compile file.agc -o file.agcb`** and `--dump-ir` for the bytecode, and the VM tail-calls `return f(...)` of a user function, so tail recursion runs at any depth (#40, #54).
- **Better help for agents:** `agentica --help` and `agentica help` list the subcommands and five core rules (#198), and many diagnostics got concrete `help` text for habits from other languages, semicolons and braces, comments, `s[0]`, Int/Float mixing and captured assignment (#30, #195, #200, #201). `CHECK-UNUSED-VALUE` flags an ignored builtin result (#26).
- **Documentation site** built with Hugo: getting started, a language tour, one page per library module with runnable examples that CI checks, search, a "Copy page" button, `llms.txt`, and pages on the VM and on design decisions. It shows the current version and links to its GitHub release (#50, #56, #141, #152, #153, #186, #188, #206).
- **Release archive** ships `agentica-vm` next to `agentica`, built against glibc 2.28, with the licenses of the bundled libraries (#103, #117).

### Changed

- **Breaking:** the Racket evaluator is deleted and every program runs on the C bytecode VM (`agentica-vm`, found next to `agentica`, in `dist/`, or from `AGENTICA_VM`; a missing VM exits 2). The fallbacks for `TCP`, `TLS`, `HTTP` and `BDD` and the interim `--vm` and `--legacy-eval` flags are gone with it. Seeded `Random` values differ from 0.1.0 for the same seed, and each task has its own generator (#55, #103, #137).
- **Breaking:** the builtin `HTTP` module is removed. Use `import "std/http" as HTTP` (`HTTP` is now a free alias, no longer reserved). The API changed: a handler returns `ok(HttpResponse(...))`, and the streaming calls (`request_stream`, `read`, `text`, `close_body`, `trailers`, `begin`, `write`, `write_bytes`, `finish`, `respond`) are gone; the checker hints at the replacement (#137, #118, #165, #166).
- **Breaking:** the `BDD.*` builtins are removed. Step programs `import "std/bdd" as BDD` and use its context API (`BDD.step(pattern, handler)` with `Fn[Context, List[String], Context]`, `BDD.run`); `--steps` takes one program, not several. `docs/bdd.md` lists the differences (#133).
- **Breaking:** a runtime error in a task other than `main` now ends only that task. `Task.await` of it gives `error("task crashed: ...")` for a `Result` and otherwise halts with `RUNTIME-TASK-CRASHED`; if `main` returns and no await saw a crash, the run exits 1 with one summary line (#139).
- **Breaking:** a handle (file, TCP/TLS socket, listener, process, HTTP server) belongs to the task that opened it and is closed when that task ends, also on return. A handle opened in a helper and returned through `Task.await` is closed; hand it over with `Task.spawn_owning(&f, handle)`, which fails with `RUNTIME-HANDLE-NOT-OWNED` when the caller does not own it, and `CHECK-NOT-A-HANDLE` when the argument is not a handle. Plain `Task.spawn(&f, handle)` moves nothing (#197).
- **Breaking:** the line protocol of `agentica test` and BDD between the runner and its child moved from stdin and stdout to a private pipe on fd 3 (`AGENTICA_CHANNEL=3`). A test's stdin and stdout are its own again, the run token and record marker are gone, a second `Test.run` is `RUNTIME-TEST-RUN`, and a child process sees only stdin, stdout and stderr (plus the channel when it asks for one) (#193).
- **Breaking:** reserved names. New: `Range` (#76), `Channel` (#179), `Time` and `Random` (#22), `Test` and `TestCase` (#147), `HttpWire` and `HttpResponse` (#118), and `ProcessOutput` (#128). A user struct, enum, function or import alias with one of these names is `CHECK-REDEFINED-NAME`. `print`, `gets` and `gets!` can no longer be declared as functions, variables, parameters or loop variables (#33). `BDD` is free again.
- **Breaking:** imports name the module without `.agc`: `import "models" as Models`. A path ending in `.agc`, an empty path, a trailing `/` or a dot in the last part is `CHECK-IMPORT-PATH` (#116).
- **Breaking:** each `def`, `struct` or `enum` must be followed by a blank line before the next declaration (`PARSE-MISSING-BLANK-LINE`) (#29).
- **Breaking:** a line that starts with `##` is now a doc comment; one inside a function body or not followed by a declaration is `PARSE-DETACHED-DOC`. `##` after code and inside strings stays plain text (#208).
- **Breaking:** `#{` inside a string starts an interpolation; write `\#{` for the old text (#27).
- **Breaking:** `String.split` keeps every empty part, so `"a\n".split("\n")` is `["a", ""]` (#57).
- **Breaking:** field access on a non-struct value is a method call and unknown names are `CHECK-UNKNOWN-METHOD` (replaces `CHECK-NOT-A-STRUCT`); `IO.puts`, `IO.print` and `IO.warn` take any value, not only `String`; interpolating a `Json` value inserts its JSON text; functions, tasks and resource handles have no `to_s` and are `CHECK-TYPE-MISMATCH` (#26, #36).
- **Breaking:** a named CA file that is missing or empty is now an error at connect (the evaluator ignored it) (#117).
- **Breaking:** `Process.spawn` looks a bare command name up in `PATH` only and never adds the current directory; a name with `/` is a path from the working directory (#98).
- **Breaking:** TCP, TLS, `Process`, `Channel` waits and the other loop-based I/O run on Linux only; other systems have no such builtins in the VM, and the evaluator that ran them there is gone (#98, #106, #117, #179).
- Runtime messages for file calls say `filesystem:` instead of `network:` for a bad timeout (#190).
- The programming skill is split into `SKILL.md` and on-demand references, with its token cost cut (#32, #204).
- License: Apache-2.0 with LLVM exception (#97).
- A default build links the system OpenSSL 3 and libgc 8.2 or newer (`AGENTICA_OPENSSL` and `AGENTICA_GC` choose `vendored`); the release archive is built with both vendored (#146, #185).
- Internal: CI, the golden test harness, the C style and layer checks, fuzzing, sanitizers, benchmarks, the evaluation harness, the plan documents and the roadmap restructure changed with no effect on programs.

### Fixed

- A stop signal (`SIGINT`, `SIGTERM`, `SIGHUP`) ends the VM through one bounded exit path that kills children and flushes output; reading `/proc/self/fd/N` of the VM's own pipe no longer hangs it at exit (#162).
- Pipes, FIFOs, terminals and stdin are read on the event loop, so a silent FIFO no longer holds a thread or the exit (#164).
- `puts`, `print`, `IO.inspect` and `IO.warn` no longer block the whole VM on a full stdout or stderr pipe; only the printing tasks wait (#187).
- `Process.close` no longer blocks the VM while it waits for the child (#176).
- Imported structs and enums print by their declared names (`Point(x: 2)`), and checker messages name imported types and functions the same way, instead of the linker's `@2::Point` (#73).

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

[unreleased]: https://github.com/sonic182/agentica/compare/0.2.0...HEAD
[0.2.0]: https://github.com/sonic182/agentica/compare/0.1.0...0.2.0
[0.1.0]: https://github.com/sonic182/agentica/releases/tag/0.1.0
