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

`compiler/` (Agentica) compiles programs to bytecode; `vm/` (C11) runs them.
Both are linked into one binary. The repo tree is in `AGENTS.md`; this file
says how to work and which reference to read. Load only the references your
change needs.

- Every language change goes in `compiler/` (`references/frontend.md`). The
  data files `compiler/catalog/builtins_data.agc`, `check_tables.agc`,
  `unicode_table.agc` and `vm/unicode_data.c` are edited by hand.
- Read the active phase in `docs/roadmap/` first. Build only what it asks: no
  placeholder modules or nodes for later phases.
- One way per thing, and it is the Ruby form (name, method form, syntax), which
  LLMs already know. A different Agentica name is only the internal builtin
  name, with the Ruby name as its alias (`method_aliases` in
  `check_tables.agc`); every user-facing text (help, diagnostics, docs, site,
  skills) shows only the Ruby form (`s.strip`, not `String.trim`). A non-Ruby
  habit gets a `help:` hint, not a second accepted form. Exception: Ruby's own
  synonyms for one small cosmetic thing (`length`, `size`) are all accepted.
  Issue #574 makes the Ruby name the only accepted name.
- Rules in `AGENTS.md` are defaults; a PR may relax one if it says which and
  why.

## Finding code

- gmem tools when listed: `find_symbol`, `code_outline`, `code_imports`,
  `code_diff`. They index top-level definitions only.
- `rg` for text, call sites and references.
- `.agc` structure:
  `ast-grep run --lang ruby -p 'File.open($$$)' stdlib/ tests/`
  (Agentica is Ruby-like, not Ruby: check each hit).
- Ownership: `references/repo-map.md`; inside `vm/`, the "Read next" table of
  `references/vm.md`.

## Commands while you work

`AGENTS.md` ("Commands") lists the build and test commands. The others:

```sh
AGENTICA_VM_TRACE=profile dist/agentica check FILE   # step profile (references/vm-build.md)
make vm-test                  # C tests; one: make build/vm/release/<name>-test
make fixed-point              # stage2 == stage3 (about 25 s)
make stage0                   # refresh bootstrap/stage0.agcb (references/ci.md)
poetry run python tools/refreeze.py  # rewrite frozen goldens; --stage, --fast-only
make vm-golden-check FIXTURES="a b"   # check only those fixtures; make goldens FIXTURES=... rewrites them
make dup-check                # jscpd: a new copy fails CI; share a helper instead
```

Run what the change touches and the affected example with `dist/agentica`.
Make runs one pytest process per module, so keep xdist off. Fast cases go in
`tests/test_<area>.py`; slow ones (`@slow` on unittest, `pytest.mark.slow` on
pytest) run only in CI (`make test-slow`). Destructive filesystem cases never
run on the host (`references/ci.md`).

## Stage contract

- One entry per stage: `Lexer.lex`, `Parser.parse`, `Linker.link_file`,
  `Checker.check`, `Lowering.lower`, `Writer.write` (`references/stages.md`).
- Return the next data or one diagnostic; stop at the first error.
- Never print or crash. `compiler/app/cli.agc` prints the diagnostic and exits
  1.
- Thread spans through. A runtime error inside a stage is a bug: make it a
  diagnostic (`*-INTERNAL` for an impossible state).

## Where new code goes

Recipes for each kind are in `references/frontend.md` ("Common tasks"); this
list gives the homes.

- Keyword, operator, AST node, syntax: `compiler/syntax/` (lexer tables,
  `ast.agc`, the parser), with a golden. Use the Ruby syntax when Ruby has one.
- Diagnostic code: where the problem is found, with its stage prefix (`LEX-`,
  `PARSE-`, `CHECK-`, `RUNTIME-`, `LOWER-`, `BYTECODE-`, `stages.md`), or
  `PKG-` (`Failure.fail_key` for a key path in `agentica.toml` or
  `agentica.lock`). Its `help:` names the Ruby form.
- Builtin: catalog row in `compiler/catalog/builtins_data.agc` (golden in
  `tests/fixtures/frontend/catalog/`), checker rule, `VM_BUILTINS` in
  `compiler/lower/lower_tables.agc` (`tests/test_frontend_catalog.py` checks
  every key), C in `vm/`, a golden (`references/vm-builtins.md`). Name it as
  Ruby does; if the name differs, add the Ruby alias (`help` and the
  diagnostics then show the Ruby form).
- VM form or opcode: `compiler/lower/lower_*.agc`; `OPCODES` in
  `compiler/bytecode/bytecode_tables.agc` mirrors `agc_opcode` in
  `vm/value.h` (same order); `vm/loader.c`, `vm/interp.c`; a golden
  (`references/vm-lowering.md`).
- Pipeline stage: `compiler/<context>/<stage>.agc`, wired in
  `compiler/app/pipeline.agc`, with `tests/test_spec_<area>.py` and
  `tests/test_frontend_<stage>.py`.
- Prelude method (List, Map, Lazy): a `Rule.Prelude` row in
  `builtins_data.agc`, an entry in `compiler/catalog/prelude_data.agc`, and a
  body in `stdlib/prelude/` (`references/stages.md`, "Compiler prelude").
- `std/` module: `stdlib/<name>.agc`, listed in `stdlib/MODULES`, with a doc on
  the module and each export (`references/library-notes.md`).
- Test: `tests/test_<area>.py`. A language rule goes in
  `tests/test_spec_<area>.py` through `--json check FILE`, asserting the code
  and the span, never the message. VM behavior: a fixture in
  `tests/fixtures/vm/` with its `.expected`.
- Language rule: `docs/grammar/`, the site page and
  `.agents/skills/agentica-programming/` change together. `.agc` style:
  `agentica-code-guidelines`.

## VM rules in short

- Goldens are the contract: exit code, stdout, the program's stderr and the
  diagnostic code. Messages, spans and step counts may change.
- Every `.agcb` is untrusted: no memory error or UB whatever it holds.
- Out-of-subset programs fail with `LOWER-UNSUPPORTED`.
- A change to the VM core (scheduler, loop, I/O, end of run) is checked against
  `docs/vm/14-core-invariants.md` (wait, timeout, cancel, end, handle owner) and
  the thread model of `docs/vm/16-architecture.md`.
- No new `vm/` subsystem without a demonstrated use case
  (`docs/vm/14-core-invariants.md` §14.6).
- Details: `references/vm.md`, then the file its "Read next" table names.

## When to read a reference

- `repo-map.md`: which file in `compiler/`, `vm/`, `tests/` or `stdlib/` owns
  something.
- `frontend.md`: compiler edit recipes, the stage and golden contract, gotchas,
  diagnostics; differential checks for performance changes.
- `stages.md`: token kinds, diagnostic codes, AST nodes, per-stage notes, the
  command line.
- `language-notes.md`: core language rules: Result and `try`, collections,
  ranges, file modules, methods, interpolation, blocks, hints, enums, functions.
- `library-notes.md`: a library area (stdio, JSON, tasks, TCP/TLS/HTTP, files,
  processes, Int and Float bits, std/binary) or `stdlib/` style.
- `bdd.md`: `agentica test`: `compiler/bdd/bdd_driver.agc`, `std/bdd`,
  `stdlib/test/`, step programs and handlers.
- `vm.md`: any VM work: pipeline, layers, rules, index of `vm-*.md`.
- `ci.md`: `.github/workflows/`, Makefile and `mk/`, new VM files, peers,
  fixtures, jscpd, CI jobs, releases, `CHANGELOG.md`.
- `site.md`: `site/`, or a language rule or builtin shown on a site page.
- `bench-eval.md`: `benchmarks/`, `make bench`, `tests/eval/`, measuring speed.
