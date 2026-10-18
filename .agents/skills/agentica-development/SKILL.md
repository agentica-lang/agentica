---
name: agentica-development
description: >-
  Develops the Agentica interpreter: the front end written in Agentica
  (compiler/: lexer, parser, module linker, checker, lowering, bytecode writer)
  and the C11 bytecode VM that runs every program (vm/ with the Boehm GC, the
  runtime libraries, loader safety, golden tests). Covers where code goes, how
  to add tokens, AST nodes, syntax, diagnostics, builtins, opcodes and tests,
  the Agentica and C gotchas of this repo, and the VM build, CI, release,
  documentation site, benchmarks and copy-paste check. Use when working in the
  agentica repository on compiler/, vm/, tests/, site/, the Makefile or CI.
  Don't use for writing Agentica programs (agentica-programming), for the
  grammar or roadmap documents alone, or for other C projects.
---

# Agentica development

A front end written in Agentica (`compiler/`) compiles Agentica to bytecode for
a
C VM, and the two are linked into one binary. The short repo tree is in
`AGENTS.md`. This file says how to work and which reference to
read; load only the references your change needs.

The front end is `compiler/` only: every language change goes there
(`references/frontend.md`). The Racket front end was deleted after the bootstrap
(the git tag `bootstrap-racket` keeps it). The data files
`compiler/builtins_data.agc`, `check_tables.agc` and `unicode_table.agc` and
`vm/unicode_data.c` are edited by hand. The rules are defaults, which a PR may
relax when following them costs more than it saves; the PR says which rule it
relaxes and why.

Read the active phase in `docs/roadmap/` before adding code. Build only what
that phase asks for: no placeholder modules or empty nodes for later phases.

## Finding code

- gmem code tools first, when listed: `find_symbol` (definition by name),
  `code_outline` (a file's symbols), `code_imports`, `code_diff` (symbols
  changed between revisions).
- They index top-level definitions only (the functions of `compiler/`, `stdlib/`
  and `vm/` are top-level); call sites and references need `rg`.
- `rg` for text, call sites and references. For `.agc` structure:
  `ast-grep run --lang ruby -p 'File.open($$$)' stdlib/ tests/` (Agentica is
  Ruby-like, not Ruby: check each hit).
- Which file owns what: `references/repo-map.md`; inside `vm/`: the "Read
  next" table of `references/vm.md`.

## Commands while you work

```sh
make                                      # build dist/agentica, the one binary, from bootstrap/stage0.agcb (git submodule update --init first; needs only a C toolchain)
make test TESTS="tests/test_vm_bits.py tests/test_spec_checker.py"  # unittest modules, one process each
make tests KIND=files                     # the filesystem-destructive group, only in Docker (locally) or Actions scratch (CI)
make tests KIND=fast DOCKER=1             # a group in the Ubuntu test container (tools/ubuntu-test.Dockerfile); KIND=slow, all too
make tests KIND=files WINE=1              # the Windows removal refusal under Wine, optional local compatibility coverage
dist/agentica examples/hello.agc          # run a program; `check file.agc` only checks; `run -- file.agcb` runs bytecode
make test-cli                             # the product command line tests on dist/agentica
AGENTICA_VM_TRACE=profile dist/agentica check FILE   # where a run spends its steps: per function, source file and builtin (references/vm-build.md)
make vm-test                              # the C tests; one: make build/vm/release/<name>-test
make fixed-point                          # stage2 == stage3, and dist/agentica compiles the front end to stage2 again (about 25 s)
make stage0                               # refresh bootstrap/stage0.agcb from stage2 (references/ci.md, "Refreshing stage0")
make goldens                              # rewrite VM and front-end goldens after an intended change; review the diff
python3 tools/refreeze.py                  # rewrite the frozen goldens of tests/fixtures/frontend/ from the Agentica stages, fast and slow tier, and print what changed; --stage, --fast-only
make vm-golden-check FIXTURES="a b"       # CI golden check of only those fixtures; make goldens FIXTURES="a b" rewrites only them
make dup-check                            # jscpd: a new copy fails CI; share a helper instead
make site                                 # before merging a site change
```

Run the tests the change touches (`make test TESTS=...`, which builds the
binary first) and run the affected example with `dist/agentica`. Two tiers:
put fast cases in a `tests/test_<area>.py` module (unittest,
`references/ci.md`) and slow ones (frozen corpus, generated inputs, stress)
marked `@slow`. Locally run only the fast tier; CI runs the slow tier with `make
test-slow` after `make test`. The
destructive filesystem cases never run on the host: `make tests KIND=files`
uses the local Docker sandbox and CI uses its own scratch runner
(`references/ci.md`). CI runs everything else (`references/ci.md`, "What CI
runs").

## Stage contract

- One entry point per stage: `Lexer.lex`, `Parser.parse`, `Linker.link_file`,
  `Checker.check`, `Lowering.lower`, `Writer.write` (`references/stages.md`).
- Return the next data or one diagnostic (an `Outcome` or a `Result` with a
  packed diagnostic); stop at the first error.
- Never print, never crash. `compiler/cli.agc` prints the diagnostic on stderr
  and exits 1.
- Thread spans through everything. A runtime error inside a stage is a bug:
  turn it into a diagnostic (`*-INTERNAL` when the cause is an impossible
  state).

## Where new code goes

- **Add:** keyword, operator, literal form
  - **Location:** `compiler/lexer.agc` tables, with a golden case
    (`references/frontend.md`)

- **Add:** AST node
  - **Location:** `compiler/ast.agc`, the parser, and the passes that walk the
    tree (`references/frontend.md`)

- **Add:** syntax form
  - **Location:** `compiler/parser.agc` and `ast.agc`, with a parser golden
    (`references/frontend.md`)

- **Add:** diagnostic code
  - **Location:** where the problem is found; prefix `LEX-`, `PARSE-`, `CHECK-`,
    `RUNTIME-`, `LOWER-`, `BYTECODE-` (`references/stages.md` lists them)

- **Add:** builtin
  - **Location:** the Agentica catalog data (`compiler/builtins_data.agc`,
    golden in `tests/fixtures/frontend/catalog/`), the checker rule,
    `VM_BUILTINS` in `compiler/lower_tables.agc`
    (`tests/test_frontend_catalog.py` checks every catalog key is in it), C in
    `vm/`, a golden(`references/vm-builtins.md`; `references/vm.md` and
    `references/vm-c.md` for the rules)

- **Add:** VM form or opcode
  - **Location:** `compiler/lower_*.agc`, `OPCODES` in
    `compiler/bytecode_tables.agc` = `agc_opcode` in `vm/value.h` (same order),
    `vm/loader.c`, `vm/interp.c`, a golden (`references/vm-lowering.md`;
    `references/vm.md` and `references/vm-c.md` for the rules)

- **Add:** pipeline stage
  - **Location:** `compiler/<stage>.agc`, wired in `compiler/front_end.agc`,
    with `tests/test_spec_<area>.py` for its rules and a golden test in
    `tests/test_frontend_<stage>.py`

- **Add:** prelude method (a `List`, `Map` or `String` method written in
  Agentica)
  - **Location:** a `Rule.Prelude` row in `compiler/builtins_data.agc`, its
    entry in `compiler/prelude_data.agc`, the body in `stdlib/prelude/`
    (`references/stages.md`, "Compiler prelude"), and the tests of 25.6

- **Add:** `std/` module
  - **Location:** `stdlib/<name>.agc`, listed in `stdlib/MODULES` (what the
    single binary embeds), a doc on the module and every export, comments and
    code style (line width, strings) as `references/library-notes.md` says

- **Add:** test
  - **Location:** `tests/test_<area>.py` (unittest, only; a language rule is
    `tests/test_spec_<area>.py` through `--json check FILE`, code and span, no
    message text; `tests/agentica_test.py` helpers, product CLI as a child:
    `cli()`, `AGENTICA_TEST_EXECUTABLE`); VM behavior: a fixture in
    `tests/fixtures/vm/` with its `.expected`

- **Add:** language rule
  - **Location:** `docs/grammar/`, the site page, and the programming skill
    (`.agents/skills/agentica-programming/`)

- **Add:** style or idiom of `.agc` code (naming, pipes, `case`, errors, speed)
  - **Location:** the code guidelines skill
    (`.agents/skills/agentica-code-guidelines/`)

## VM rules in short

- Goldens are the contract: exit code, stdout, the program's stderr and the
  diagnostic code. Messages, spans and step counts may change.
- Every `.agcb` is untrusted: no memory error or UB whatever it holds.
- Out-of-subset programs fail with `LOWER-UNSUPPORTED`.
- A PR that touches the VM core (scheduler, loop, I/O, the end of the run) is
  checked against `docs/vm/14-core-invariants.md` (one way to wait, time out,
  cancel, end, own a handle) and the thread model of
  `docs/vm/16-architecture.md`.
- No new `vm/` subsystem without a demonstrated use case
  (`docs/vm/14-core-invariants.md` 14.6).
- Details: `references/vm.md`, then the file its "Read next" table names.

## When to read a reference

- **Read:** `references/repo-map.md`
  - **When:** finding which file in `compiler/`, `vm/`, `tests/` or `stdlib/`
    owns something

- **Read:** `references/frontend.md`
  - **When:** editing `compiler/`: the stages and their goldens, recipes
    (keyword, AST node, syntax, diagnostic, stage, tests), a speed change to a
    stage (differential run against master), gotchas, stray `NL` tokens, reading
    a failure, comments and code style (line width, strings) in `compiler/` and
    `tests/`

- **Read:** `references/stages.md`
  - **When:** the token kinds, the diagnostic code list, the AST nodes, the
    notes of each stage (lexer, parser, linker, checker, lowering, bytecode
    writer, builtin catalog, command line)

- **Read:** `references/language-notes.md`
  - **When:** changing a core language rule: Result and `try`, collections,
    ranges, file modules, methods, interpolation, blocks, hints, enums, function
    values

- **Read:** `references/library-notes.md`
  - **When:** changing a library area (stdio, JSON, tasks, TCP/TLS/HTTP, files
    and paths, processes, Int and Float bits, std/binary) or the comments and
    code style (line width, strings) of a `stdlib/` module

- **Read:** `references/bdd.md`
  - **When:** `agentica test`: the driver `compiler/bdd_driver.agc` (part of the
    front end), `std/bdd`, `stdlib/test/`, step programs and their handler
    rules, unit test files

- **Read:** `references/vm.md`
  - **When:** any VM work: pipeline, layers, the rules every change keeps, and
    the index of the `vm-*.md` files

- **Read:** `references/ci.md`
  - **When:** `.github/workflows/`, the Makefile, new VM files, peers or
    fixtures, jscpd, what CI runs, releases and `CHANGELOG.md`

- **Read:** `references/site.md`
  - **When:** `site/`, or a language rule or builtin shown on a site page

- **Read:** `references/bench-eval.md`
  - **When:** `benchmarks/`, `make bench`, the HTTP benchmark, `tests/eval/`,
    measuring a speed change (the profiler, A/B runs against master)
