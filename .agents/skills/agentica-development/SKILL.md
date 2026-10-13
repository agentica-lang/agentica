---
name: agentica-development
description: "Develops the Agentica interpreter: the Racket front end (lexer, parser, module linker, checker, lowering, bytecode) and the C11 bytecode VM that runs every program (vm/ with the Boehm GC, the runtime libraries, loader safety, golden tests). Covers where code goes, how to add tokens, AST nodes, syntax, diagnostics, builtins, opcodes and tests, the Racket and C gotchas of this repo, and the VM build, CI, release, documentation site, benchmarks and copy-paste check. Use when working in the agentica repository on src/, vm/, tests/, site/, the Makefile or CI. Don't use for writing Agentica programs (agentica-programming), for the grammar or roadmap documents alone, or for other Racket or C projects."
---

# Agentica development

Agentica is a small statically typed language: a Racket front end compiles it to bytecode for a C VM. The grammar is `docs/grammar.md`; planned syntax is in `docs/future/`; the phases and the active checklist are `docs/roadmap/`.

Read the active phase in the roadmap before adding code. Implement only what that phase asks for: the roadmap explicitly forbids placeholder modules and empty nodes for later phases.

## Commands

```sh
make test                                 # builds the VM, then raco test -j $(nproc) tests/
make test JOBS=8                          # set the number of workers
make test TESTS="tests/lexer-test.rkt"    # one stage while iterating
racket src/main.rkt examples/hello.agc    # CLI smoke test; exits 0 on success
racket src/main.rkt check examples/blocks.agc
make vm vm-test                           # the C VM and its loader tests (references/vm.md)
make goldens                              # rewrite the VM golden files (references/vm.md)
make vm-latency                           # task latency test, run alone (references/vm.md)
make dup-check                            # jscpd copy-paste check over src/*.rkt and vm/ C code (references/ci.md)
make site                                 # build the documentation site (references/site.md)
```

Run the stage tests the change touches and a smoke run of the affected examples. CI (`.github/workflows/ci.yml`, Racket CS 9.3) runs the full `make test`, `make test-bdd`, the process and module tests against the compiled executable, and every example smoke run; it is the source of truth for that list. It also runs `make dup-check` (`references/ci.md`): a new clone that is not in `.jscpd-baseline.json` fails CI, so share a helper instead of copying it. After removing old clones, refresh the baseline with `make dup-baseline` and commit it; a reviewer must reject a PR that grows the baseline instead of removing a copy. Runtime and test code use the standard library only; the only dev-tool dependency is the pinned jscpd in `tools/jscpd`.

## Repository map

```text
src/
  source.rkt      # source, source-position, source-span (span end is exclusive)
  diagnostic.rkt  # diagnostic struct and format-diagnostic
  token.rkt       # token struct
  lexer.rkt       # lex: source -> (listof token) | diagnostic
  ast.rkt         # syntax tree nodes (including enums and case patterns); every node carries a span
  parser.rkt      # parse: (listof token) -> program | diagnostic
  builtins.rkt    # shared signatures, type-rule tags, dispatch keys, effects, descriptions
  checker.rkt     # check: program -> program | diagnostic
  modules.rkt     # import linking: std/, pkg/ and relative files, aliases, exports, cycles; runs before check
  stdlib.rkt      # std/ Agentica sources embedded at compile time
  builtin-types.rkt # opaque handle types and builtin record layouts (Header, HttpResponse, FileInfo, ...)
  version.rkt     # the version string
  lower.rkt       # lower: checked program + #:types table -> IR | diagnostic (LOWER-); format-ir for --dump-ir
  bytecode.rkt    # ir->bytecode and write-bytecode (BYTECODE-LIMIT, BYTECODE-INTERNAL): the .agcb format of docs/vm/03-ir-and-bytecode.md 4.6; the C loader is the only reader
  bdd-driver.rkt  # agentica test: compiles the step program and the embedded std/test/runner, runs the runner VM, infrastructure report
  vm-launch.rkt   # find-vm, stop-vm, call-noting-break and running-executable, shared by main.rkt and bdd-driver.rkt
  main.rkt        # thin CLI driver: lex, parse, link, check, lower, then run bytecode from a temp file on dist/agentica-vm (`check` only, --dump the tree, --dump-ir, `compile -o`; `test` parses its options and calls bdd-driver.rkt); exit 1 on a diagnostic, 2 on usage, a missing file or a missing VM
vm/               # the C11 bytecode VM (dist/agentica-vm); see references/vm.md
  agc.h           # shared types and agc_ API: values, instructions, program, VM
  value.c text.c map.c loader.c interp.c builtins.c numbers.c random.c json.c diag.c main.c  # values+memory, text/debug forms, persistent HAMT maps, loader validation, loop, builtin table, Float/Time/Random, xoshiro256** generator, Json and the JSON builtins, diagnostics (plain, --ai, --json), CLI
  loop.c files.c  # libuv event loop and resource registry; File, Dir and Path builtins (Linux)
  process.c       # Process builtins on libuv pipes, behind the VM's --allow-run (Linux)
  tcp.c stream.c  # TCP and TLS builtins on libuv TCP handles (Linux); input buffer, write path and lock helper shared with process.c
  tls.h tls_openssl.c  # TLS adapter: our types in tls.h, the only file that includes OpenSSL (memory BIOs)
  net.h           # tcp.c's connection object (agc_conn) for other C modules
  http_parse.h http_pico.c http_body.c  # HTTP head adapter (the only file that includes picohttpparser) and body decoder
  http_fields.h http_fields.c  # header lists and byte buffers shared by the HTTP client and server
  http_client.c   # HttpWire client builtins: the pool, called only by stdlib/http.agc (Linux)
  http_server.c   # HttpWire server builtins: read_request, write_response and the HttpServer task group (Linux)
  task.c          # scheduler (run queue, turns, park and wake), task cancellation and the Task builtins
  testing.c equal.c # the Test builtins (unit tests, roadmap 25a); agc_equal, the deep value compare Test.eq uses
  unicode_data.c  # committed output of tools/gen-unicode.rkt (write-escape ranges)
  tools/gen-unicode.rkt  # Racket generator of unicode_data.c (make vm-unicode)
  fuzz.c fuzz_main.c tests/  # agc_fuzz_one, the mutation driver, plain-assert C tests
  third_party/bdwgc        # Boehm GC submodule pinned to v8.2.12, built from extra/gc.c
  third_party/yyjson       # yyjson submodule pinned to 0.13.0, only its reader (JSON.parse)
  third_party/libuv        # libuv submodule pinned to v1.53.0, built by the Makefile on Linux
  third_party/picohttpparser # picohttpparser submodule pinned to v1.4 (HTTP heads)
  third_party/openssl      # OpenSSL submodule pinned to openssl-3.5.9; AGENTICA_OPENSSL=vendored builds it static per mode into build/vm/<mode>/openssl (needs Perl); the default links the system OpenSSL 3
tests/
  <stage>-test.rkt      # lexer, parser, checker, modules, bdd; filesystem and process run programs on the VM
  diagnostic-test.rkt   # excerpt and caret format
  examples-test.rkt     # examples/*.agc, rejected fragments, CLI exit codes
  bytecode-test.rkt     # step merging, opcode list vs vm/agc.h, every builtin in vm-builtins, compile exit codes
  vm-diff-{1..8}-test.rkt # shards of vm-diff-common.rkt: tests/fixtures/vm/*.agc on dist/agentica-vm in three formats against their <name>.expected goldens (make goldens), with a --max-steps sweep
  site-examples-test.rkt # every agentica block in site/content runs or checks; a builtin change updates its site page
  stdlib-distribution-test.rkt # the relocated executable still finds std/
  bdd-test.rkt, bdd-integration.rkt # agentica test over the CLI (in-process main): step programs, isolation, programs under test
  unit-test-test.rkt    # agentica test on *_test.agc files (fixtures in fixtures/unit/) and the std/ unit tests in std/
  std/                  # *_test.agc unit tests of the std/ modules
  fixtures/             # golden fixtures and independent Node.js and Python peers
  vm-tcp-test.rkt       # the VM's TCP builtins against Node peers (fixtures/tcp-peer.js): errors, timeouts, concurrent clients, cleanup at exit
  vm-http-test.rkt      # std/http against independent peers: the client against Python servers (fixtures/http-peer.py), the server against Python raw sockets, http.client and Node http (fixtures/http-server-peer.py, .js)
  vm-stop-test.rkt      # the exit path under stop signals (fixtures/stop-peer.py): children, flush, second signal, dead driver, full stdout, Ctrl-C through the CLI
  bdd/                  # feature specs and step handlers run by make test-bdd
  eval/                 # agent evaluation runner (not part of make test)
stdlib/                 # std/ modules written in Agentica, embedded by src/stdlib.rkt (an explicit registry keyed "std/<path>.agc")
  queue.agc http.agc    # std/queue, std/http
  bdd.agc         # std/bdd: the step API of agentica test (BDD.step, BDD.run, the context, the predefined steps)
  bdd/gherkin.agc bdd/match.agc  # internal to agentica test: Gherkin parsing and step matching; see references/stages.md
  test/report.agc test/runner.agc test/units.agc test/child.agc  # internal to agentica test: the report, the runner, the test-file runner and the child-protocol helpers, shared by unit tests and BDD
examples/               # small programs per feature; examples/README.md lists them
docs/
  grammar.md   # language grammar, the source of truth
  future/      # planned syntax, not implemented (one file per section)
  roadmap/     # phases and the active checklist (README.md: current order and rules)
  vm/          # bytecode VM design (phase 7): IR, bytecode, C values, safety rules, PR plan
```

## Where new code goes

| Add | Location |
| --- | --- |
| keyword, operator, or literal form | `src/lexer.rkt` lookup tables |
| AST node | `src/ast.rkt` struct plus `provide`; construct it from `src/parser.rkt` |
| syntax, statement, or expression form | `src/parser.rkt` |
| builtin | `src/builtins.rkt` metadata; checker generic rule; the VM implementation (`vm-builtins` in `src/lower.rkt`, `vm/`, see `references/vm.md`) with a golden fixture; exercise a real checked call |
| diagnostic code | raise it where the problem is detected; prefix by stage (`LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`; the VM toolchain adds `LOWER-` and `BYTECODE-`) |
| pipeline stage | new `src/<stage>.rkt`, wired into `src/main.rkt`, tested by `tests/<stage>-test.rkt` |
| language rule or example | `docs/grammar.md`; phase scope in `docs/roadmap/`; also update the programming skill (`.agents/skills/agentica-programming/`): core language in its `SKILL.md`, library areas in `references/<area>.md`; evaluators read it instead of the grammar |
| test | `tests/<stage>-test.rkt` |
| VM form or opcode | `src/lower.rkt`, `opcodes` in `src/bytecode.rkt` and `agc_opcode` in `vm/agc.h` (same order), `vm/loader.c`, `vm/interp.c`, a fixture in `tests/fixtures/vm/`; see `references/vm.md` |
| VM builtin | `src/lower.rkt` (accept the call, emit `call-builtin` with the catalog implementation key and arity), `vm/builtins.c`, a fixture in `tests/fixtures/vm/`; see `references/vm.md` |

## Stage contract

Every stage follows the same shape; keep new stages consistent with it.

- Entry point is one function: `(lex input)`, `(parse tokens)`, `(check program)`, `(lower program types)`.
- Return either the next data or a single `diagnostic`. Stop at the first error; do not collect several.
- Never print and never raise from a stage. `main.rkt` owns presentation and exit codes.
- `main.rkt` guards with `diagnostic?` between stages, prints `format-diagnostic` on stderr, and exits 1.
- Thread spans through everything so diagnostics point at the source.

## Common tasks

### Add a keyword or operator

1. Add it to the `keywords` hash (reserved words) or the operator hash in `src/lexer.rkt`.
2. If the parser must act on it, add the kind to the relevant `case`/`memq` in `src/parser.rkt`.
3. Add a test in `tests/lexer-test.rkt` (kinds) and, when it affects syntax, `tests/parser-test.rkt`.
4. Run `raco test tests/`.

### Add an AST node

1. Add a `#:transparent` struct in `src/ast.rkt` with `span` as the last field, and add `(struct-out <node>)` to `provide`.
2. Construct it in `src/parser.rkt` and set the span from the first token to the last consumed token (the existing `span-from` helper).
3. Test the node's fields and its span line/column.

### Add syntax

1. Add tokens first if the syntax needs them.
2. Add the AST node if no existing node fits.
3. Write a parse function and call it from the right place: `parse-statement` for statements, `parse-primary` for expressions, `parse-program` for declarations.
4. Add one valid test and one rejection test asserting the diagnostic code.
5. Run `raco test tests/` and the smoke test.

### Add a diagnostic code

1. Choose the stage prefix: `LEX-`, `PARSE-`, later `CHECK-` or `RUNTIME-`.
2. Raise it with the stage's `bail`/`fail` helper and a token or position span.
3. Test both the code and the location (`source-position-line`/`-column` of the diagnostic span), as `tests/parser-test.rkt` does.

### Add a pipeline stage

1. Create `src/<stage>.rkt` with one entry point and a `provide`.
2. Require the previous stage's data modules only; do not reach back into the CLI.
3. Wire it into `src/main.rkt` after the previous stage, behind a `diagnostic?` guard.
4. Add `tests/<stage>-test.rkt`. `raco test tests/` discovers it automatically; CI needs no change.

### Add tests

- Use `#lang racket`, `rackunit`, and `module+ test` with `test-case` blocks.
- Require sources with relative paths (`"../src/lexer.rkt"`); they resolve from the test file.
- Keep the small helpers pattern from `tests/parser-test.rkt`: `parse-ok` fails loudly when a valid input returns a diagnostic, and `parse-code` returns the code or fails when invalid input parses.
- Cover the happy path, the error path, and the specific behavior the change introduces.

## Racket gotchas

- `define` is not allowed in an expression context, and `(begin ...)` is an expression. `(begin (define x 1) ...)` fails with `define: not allowed in an expression context`. Use `(let () ...)` to open a body that allows internal defines. `cond`/`case` clause bodies, `let/ec` bodies, and lambda bodies already allow them.
- `define` binds like `letrec`. A local named the same as the accessor it calls, such as `(define param-type (param-type x))`, fails with `undefined; cannot use before initialization`. Name locals distinctly.
- `source` is opaque (no `#:transparent`), so printing a tree shows `#<source>` instead of repeating the file text; every other struct is `#:transparent`. Keep any struct that holds the whole source text opaque.
- The lexer and parser are single mutable-pass scanners driven by `set!`. The parser cursor is capped at the last token (`EOF`), so `advance!` never runs past the end and `current`/`peek-token` stay safe at EOF.
- Early exit uses `let/ec` with a `bail`/`return` helper that escapes with a `diagnostic`. This is how a stage stops at the first error.
- `provide (struct-out name)` exports the constructor, predicate, and accessors in one line.
- `#lang racket` provides `pretty-print`; `src/main.rkt` uses it for `--dump`.
- `unary` and `binary` carry `op-span` (the operator token) beside `span`. Operator diagnostics use `op-span`; `node-span` in `ast.rkt` returns any node's span.
- Racket `equal?` treats `+nan.0` as equal to itself and `0.0` unequal to `-0.0`; compare numbers with `=` so `==` follows IEEE 754.
- Positions count Racket string characters, line and column are 1-based, and span ends are exclusive. Keep that convention in new spans.

## Lexer gotcha: stray NL tokens

The lexer emits one `NL` per LF/CRLF outside `()`, `[]`, and `{}`, including every blank/comment line, so extra lines between statements can leave more than one `NL` token. The grammar's `program` and `block` rules do not model this. The parser therefore skips stray `NL` at the top level and between statements. Keep that skip when adding statement forms, or valid files with comments between statements will fail to parse.

Top-level declarations need a blank line after their `end` (`PARSE-MISSING-BLANK-LINE`, checked in `parse-program` from the NL tokens). The rule only fires when the next token starts a declaration or import, so stray text after `end` stays `PARSE-TOP-LEVEL-STATEMENT`. Inline test programs end each top-level `end` with `end\n\n`, so fragments can be joined safely.

## Error handling

- `raco test tests/` failure: read the failing `test-case` name and the message from the `parse-ok`/`parse-code` helper. A `parse-ok` failure prints the diagnostic the stage returned.
- Smoke test exits 1: `main.rkt` printed `file:line:column error[CODE]`, the message, and a source excerpt with a caret on stderr. That is a stage diagnostic, not a crash.
- A Racket traceback instead of a diagnostic means a stage raised or indexed out of range. Find the token or index and turn it into a `bail`/`fail`; the roadmap requires Agentica diagnostics, never host tracebacks.
- A stage unexpectedly returns a diagnostic: check the first-error rule and that `main.rkt` guards with `diagnostic?` before passing data to the next stage.

## Bytecode VM (phase 7)

The C VM lives in `vm/` and runs `.agcb` files produced by `src/lower.rkt` and `src/bytecode.rkt`; `docs/vm/` is its contract. Read `references/vm.md` before touching `src/lower.rkt`, `src/bytecode.rkt`, `vm/`, the VM Makefile targets or the VM CI jobs. In short: keep the goldens (exit code, stdout, the program's own stderr and the diagnostic code; messages, spans and step counts may differ, and a runaway program still stops with `RUNTIME-STEP-LIMIT`; `docs/vm/README.md` §1), treat every `.agcb` as untrusted, keep opcodes in the same order in Racket and C, and fail out-of-subset programs with `LOWER-UNSUPPORTED`. A PR that touches the VM core (the scheduler, the loop, files, stdin, processes, sockets, the end of the run) is checked against the core invariants of `docs/vm/14-core-invariants.md` (§14): one way to wait, time out, cancel, end and own a handle, and no new subsystem without a use case.

Speed check (7g): `make bench` (or `python3 benchmarks/run.py --runs N --size S --only NAMES --runners exe,vm,python`) times `benchmarks/programs/*.agc` on each runner against the CPython versions in `benchmarks/python/`, checks that every runner prints the same output, reports `LOWER-UNSUPPORTED` programs as unsupported, and times `hello.agc` start-up apart. It is outside `make test` and CI; `BENCH_ARGS="--runs 3 --size 2"` passes options through `make bench`; record new numbers in `docs/vm-benchmarks.md`. A new program needs `def scale() -> Int` returning 1 (the script rewrites it for `--size`), a deterministic checksum line, and a Python twin that takes the size as `argv[1]`. The HTTP sanity check (20c) is apart: `python3 benchmarks/http_bench.py` (Python 3.10 or newer) compares `examples/http_server.agc serve` on `dist/agentica-vm` with Node `http`, a Python asyncio server and Python's `ThreadingHTTPServer` (servers in `benchmarks/http.js` and `--serve`), all loaded by the same Node keep-alive client (`benchmarks/http.js client`, 4 processes), interleaved per round, pinned with `taskset`, and each round starts only after a 5 s `/proc/stat` sample shows `--min-idle` of all CPUs idle (repeated otherwise) and is marked disturbed when outside CPU use during it is above `--max-outside`; record numbers only from an idle machine, in the last section of `docs/vm-benchmarks.md`.

Agent evaluation (not part of `make test`): `python3 tests/eval/run.py --help`. Docker is the default; its image is built automatically when missing. Allow provider credentials with repeatable `--pass-env NAME`. Optional Firejail requires `--sandbox firejail --chroot-root PATH`. `--jobs N` runs in parallel.

## Releases

- `src/version.rkt` is the single source of the version: `make version` prints it and `agentica --version` reports it. Keep it in sync with `CHANGELOG.md` and the Git tag.
- `CHANGELOG.md` follows Keep a Changelog and Semantic Versioning. Add user-visible entries under `## [Unreleased]` as work lands, and move them into a dated version section when tagging.
- Tag releases with the bare version (`0.1.0`, no `v` prefix). `.github/workflows/release.yml` validates the tag against `src/version.rkt`, builds `dist/agentica`, packages a `raco distribute` bundle with `LICENSE`, `NOTICE` and, in `licenses/racket/`, Racket's license files (from its share directory) and Chez Scheme's `NOTICE` (checked in at `licenses/racket/ChezScheme-NOTICE`, from Racket v9.3's source; update it when the Racket version changes), checks that the archive has them, and publishes a GitHub Release with generated notes. How it builds and checks `agentica-vm` is in `references/ci.md`.

## When to read a reference

| Read | When |
|---|---|
| `references/stages.md` | adding or renaming tokens, AST nodes or diagnostic codes; you need the token-kind table, the code list, the AST node list or a module's public API |
| `references/runtime-notes.md` | changing a language rule or a library area: Result and `try`, stdio, JSON, collections, modules, methods, interpolation, blocks, hints, enums, function values and BDD, tasks, TCP/TLS/HTTP, files, Void and processes |
| `references/vm.md` | working on the bytecode VM: lowering, bytecode, `vm/` C code, the VM build and its submodules, Boehm GC, the loader, golden tests, the latency test, sanitizers, lint, fuzzing, or libuv/OpenSSL work |
| `references/ci.md` | changing `.github/workflows/`, the Makefile, or adding VM files, test peers or fixtures: CI jobs, the `changes` path list, caches and warm jobs, manual workflows, macOS and Windows (paused), the release build, jscpd |
| `references/site.md` | changing `site/` or a language rule or builtin shown on a site page: Hugo and Dart Sass, content layout, the site-examples test and its fence attributes, deploy |
