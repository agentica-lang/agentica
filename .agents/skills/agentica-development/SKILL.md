---
name: agentica-development
description: "Develops the Agentica interpreter: the Racket front end (lexer, parser, module linker, checker, lowering, bytecode) and the C11 bytecode VM that runs every program (vm/ with the Boehm GC, the runtime libraries, loader safety, golden tests). Covers where code goes, how to add tokens, AST nodes, syntax, diagnostics, builtins, opcodes and tests, the Racket and C gotchas of this repo, and the VM build, CI, release, documentation site, benchmarks and copy-paste check. Use when working in the agentica repository on src/, compiler/, vm/, tests/, site/, the Makefile or CI. Don't use for writing Agentica programs (agentica-programming), for the grammar or roadmap documents alone, or for other Racket or C projects."
---

# Agentica development

A Racket front end compiles Agentica to bytecode for a C VM. The short repo
tree is in `AGENTS.md`. This file says how to work and which reference to
read; load only the references your change needs.

By default `src/` is frozen (roadmap row 7.2.7): bug fixes and the data that row 7.2.7 lists (builtin table rows, builtin record and enum entries, registry lines, std-only and reserved names, message texts); language changes go into `compiler/` (`references/frontend.md`). They may be relaxed when following them costs more than it saves; the PR says which rule it relaxes and why.

Read the active phase in `docs/roadmap/` before adding code. Build only what
that phase asks for: no placeholder modules or empty nodes for later phases.

## Finding code

- gmem code tools first, when listed: `find_symbol` (definition by name),
  `code_outline` (a file's symbols), `code_imports`, `code_diff` (symbols
  changed between revisions).
- They index top-level definitions only. Most front-end helpers are nested
  `define`s inside `parse`, `check` and `lower`: an empty `find_symbol` does
  not mean the helper is gone; use `rg -n "\(define \(name" src/`.
- `rg` for text, call sites and references. For `.agc` structure:
  `ast-grep run --lang ruby -p 'File.open($$$)' stdlib/ tests/` (Agentica is
  Ruby-like, not Ruby: check each hit).
- Which file owns what: `references/repo-map.md`; inside `vm/`: the "Read
  next" table of `references/vm.md`.

## Commands while you work

```sh
make                                      # build dist/agentica, the one binary, from bootstrap/stage0.agcb (git submodule update --init first; no Racket)
make test TESTS="tests/test_vm_bits.py tests/test_spec_checker.py"  # unittest modules, one process each; no Racket
dist/agentica examples/hello.agc          # run a program; `check file.agc` only checks; `run -- file.agcb` runs bytecode
racket src/main.rkt examples/hello.agc    # the Racket oracle (until src/ goes): the same words; no test uses it
make test-cli                             # the product command line tests on dist/agentica
make vm-test                              # the C tests; one: make build/vm/release/<name>-test
make fixed-point                          # stage2 == stage3, and dist/agentica compiles the front end to stage2 again (about 25 s)
make stage0                               # refresh bootstrap/stage0.agcb from stage2 (references/ci.md, "Refreshing stage0")
make goldens                              # rewrite VM and front-end goldens after an intended change; review the diff
python3 tools/refreeze.py                  # rewrite the frozen goldens of tests/fixtures/frontend/ from the Agentica stages (no Racket), fast and slow tier, and print what changed; --stage, --fast-only
make vm-golden-check FIXTURES="a b"       # CI golden check of only those fixtures; make goldens FIXTURES="a b" rewrites only them
make dup-check                            # jscpd: a new copy fails CI; share a helper instead
make site                                 # before merging a site change
```

Run the tests the change touches (`make test TESTS=...`, which builds the
binary first) and run the affected example with `dist/agentica`. Two tiers:
put fast cases in a `tests/test_<area>.py` module (unittest,
`references/ci.md`) and slow ones (frozen corpus, generated inputs, stress)
marked `@slow`. Locally run only the fast tier; CI runs the slow tier with `make test-slow` after `make test`. CI
runs everything else (`references/ci.md`, "What CI runs").

## Stage contract

- One entry point per stage: `(lex input)`, `(parse tokens)`,
  `(check program)`, `(lower program types)`.
- Return the next data or one `diagnostic`; stop at the first error.
- Never print, never raise. `main.rkt` guards with `diagnostic?`, prints
  `format-diagnostic` on stderr and exits 1.
- Thread spans through everything. A Racket traceback is a bug: turn it into
  a `bail`/`fail` diagnostic.

## Where new code goes

| Add | Location |
| --- | --- |
| keyword, operator, literal form | `compiler/lexer.agc` tables, with a golden case (`references/frontend.md`); `src/lexer.rkt` only for a bug fix, in the same PR |
| AST node | by default waits for the parser port (35.4 step 2); then `compiler/` |
| syntax form | by default waits for the parser port; `src/parser.rkt` only for a bug fix |
| diagnostic code | where the problem is found; prefix `LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`, `LOWER-`, `BYTECODE-` (`references/stages.md` lists them) |
| builtin | `src/builtins.rkt` metadata, checker rule, the `vm-builtins` table in `src/lower.rkt` and `VM_BUILTINS` in `compiler/lower_tables.agc` (a test enforces that they match), C in `vm/`, a golden (`references/vm-builtins.md`; `references/vm.md` and `references/vm-c.md` for the rules) |
| VM form or opcode | `src/lower.rkt`, `opcodes` in `src/bytecode.rkt` = `agc_opcode` in `vm/value.h` (same order), `vm/loader.c`, `vm/interp.c`, a golden (`references/vm-lowering.md`; `references/vm.md` and `references/vm-c.md` for the rules) |
| pipeline stage | `compiler/<stage>.agc`, wired in `compiler/front_end.agc`, with `tests/test_spec_<area>.py` for its rules and a golden test in `tests/test_frontend_<stage>.py` |
| `std/` module | `stdlib/<name>.agc`, listed in `stdlib/MODULES` (what `src/stdlib.rkt` and the single binary embed), a doc on the module and every export, comments and code style (line width, strings) as `references/library-notes.md` says |
| test | `tests/test_<area>.py` (unittest, only; a language rule is `tests/test_spec_<area>.py` through `--json check FILE`, code and span, no message text; `tests/agentica_test.py` helpers, product CLI as a child: `cli()`, `AGENTICA_TEST_EXECUTABLE`); VM behavior: a fixture in `tests/fixtures/vm/` with its `.expected` |
| language rule | `docs/grammar/`, the site page, and the programming skill (`.agents/skills/agentica-programming/`) |

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

| Read | When |
|---|---|
| `references/repo-map.md` | finding which file in `src/`, `vm/`, `tests/` or `stdlib/` owns something |
| `references/frontend.md` | editing `src/*.rkt` or `compiler/`: the freeze, the Agentica lexer and its goldens, recipes (keyword, AST node, syntax, diagnostic, stage, tests), Racket gotchas, stray `NL` tokens, reading a failure, comments and code style (line width, strings) in `compiler/`, `src/` and `tests/` |
| `references/stages.md` | the token kinds, the diagnostic code list, the AST nodes, a module's public API (`source`, `lexer`, `parser`, `modules`, `checker`, `lower`, `bytecode`, `builtins`, `main`) |
| `references/language-notes.md` | changing a core language rule: Result and `try`, collections, ranges, file modules, methods, interpolation, blocks, hints, enums, function values |
| `references/library-notes.md` | changing a library area (stdio, JSON, tasks, TCP/TLS/HTTP, files and paths, processes, Int and Float bits, std/binary) or the comments and code style (line width, strings) of a `stdlib/` module |
| `references/bdd.md` | `agentica test`: the driver `compiler/bdd_driver.agc` (part of the front end), `std/bdd`, `stdlib/test/`, step programs and their handler rules, unit test files |
| `references/vm.md` | any VM work: pipeline, layers, the rules every change keeps, and the index of the `vm-*.md` files |
| `references/ci.md` | `.github/workflows/`, the Makefile, new VM files, peers or fixtures, jscpd, what CI runs, releases and `CHANGELOG.md` |
| `references/site.md` | `site/`, or a language rule or builtin shown on a site page |
| `references/bench-eval.md` | `benchmarks/`, `make bench`, the HTTP benchmark, `tests/eval/` |
