---
name: agentica-development
description: >-
  Develops the Agentica interpreter: the front end written in Agentica
  (compiler/: lexer, parser, linker, checker, lowering, bytecode writer) and
  the C11 bytecode VM (vm/ with the Boehm GC, runtime libraries, loader
  safety, golden tests). Covers where code goes, how to add tokens, AST nodes,
  syntax, diagnostics, builtins, opcodes and tests, the gotchas of this repo,
  and the VM build, CI, site, benchmarks and copy-paste check. Use
  when working in the agentica repository on compiler/, vm/, tests/, site/,
  the Makefile or CI. Don't use for writing Agentica programs
  (agentica-programming), for the grammar documents alone, or for other C
  projects.
---

# Agentica development

This file says how to work and which reference to read; the tree is in
`AGENTS.md`. Load only the references your change needs.

- The rules of `AGENTS.md` apply. Read the GitHub issue of the work first
  (`gh issue view N -R agentica-lang/agentica`) and build only what it asks;
  `docs/future/` keeps the designs that issues point to.
- One way per thing, and it is the Ruby form (name, method form, syntax). A
  builtin row has the Ruby name (`String.strip`, `Int.to_s`, `List.join`); a
  few keep an older Agentica name with the Ruby name as its alias
  (`List.filter` and `select`; `method_aliases` in `check_tables.agc`). Every
  user-facing text (help, diagnostics, docs, site, skills) shows only the
  Ruby form (`list.select`, not `List.filter`). A habit from another
  language (`trim`, `len`) gets a `help:` hint (`foreign_kind_methods`,
  `foreign_names`), not a second accepted form; an old Agentica name gets no
  hint, it is an unknown name with the usual did-you-mean. The VM keys
  (`implementation`) keep the old names: stage0 and compiled bytecode import
  them. Exception: Ruby's own synonyms are all accepted (`length`/`size`,
  `collect`, `inject`, `detect`, `member?`; `ruby_synonyms`), and texts show
  only the most common one.

## Finding code

- gmem tools when listed (`find_symbol`, `code_outline`, `code_imports`,
  `code_diff`); they index top-level definitions only.
- `rg` for text, call sites and references.
- `.agc` structure:
  `ast-grep run --lang ruby -p 'File.open($$$)' stdlib/ tests/`
  (Agentica is Ruby-like, not Ruby: check each hit).
- Ownership: `references/repo-map.md`; inside `vm/`, the "Read next" table of
  `references/vm.md`.

## Commands while you work

`AGENTS.md` ("Commands") and `make help` list the build and test commands.
Beyond them:

```sh
AGENTICA_VM_TRACE=profile dist/agentica check FILE   # step profile (references/vm-build.md)
make build/vm/release/<name>-test     # one C test (vm/tests/<name>_test.c)
make vm-golden-check FIXTURES="a b"   # only those fixtures; make goldens FIXTURES=... rewrites them
make dup-check                        # jscpd: a new copy fails CI; share a helper
```

Run what the change touches and the affected example with `dist/agentica`.
One pytest process runs per module, so keep xdist off.

## Stage contract

The contract is in `AGENTS.md` ("Stages"); the entry points (`Lexer.lex` ...
`Writer.write`) are in `references/stages.md`. `compiler/app/cli.agc` prints
the diagnostic and exits 1. Thread spans through; an impossible state is a
`*-INTERNAL` diagnostic.

## Where new code goes

Recipes: `references/frontend.md` ("Common tasks"). Homes:

- Keyword, operator, AST node, syntax: `compiler/syntax/` (lexer tables,
  `ast.agc`, the parser), with a golden. Prefer the Ruby syntax.
- Diagnostic code: where the problem is found, with its stage prefix (`LEX-`,
  `PARSE-`, `CHECK-`, `RUNTIME-`, `LOWER-`, `BYTECODE-`, `stages.md`), or
  `PKG-` (`Failure.fail_key` for a key path in `agentica.toml` or
  `agentica.lock`). Its `help:` names the Ruby form.
- Builtin: catalog row in `compiler/catalog/builtins_<module>.agc` (golden in
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
  `builtins_<module>.agc`, an entry in `compiler/catalog/prelude_data.agc`, and a
  body in `stdlib/prelude/` (`references/stages.md`, "Compiler prelude").
- `std/` module: `stdlib/<name>.agc`, listed in `stdlib/MODULES`, with a doc on
  the module and each export (`references/library-notes.md`).
- Test: `tests/test_<area>.py`; a language rule in
  `tests/test_spec_<area>.py` (`AGENTS.md`); VM behavior: a fixture in
  `tests/fixtures/vm/` with its `.expected`.
- `.agc` style: `agentica-code-guidelines`.

## VM rules in short

- Goldens are the contract; every `.agcb` is untrusted (`references/vm.md`).
- A change to the VM core (scheduler, loop, I/O, end of run) is checked against
  `docs/vm/14-core-invariants.md` (wait, timeout, cancel, end, handle owner) and
  the thread model of `docs/vm/16-architecture.md`. No new `vm/` subsystem
  without a demonstrated use case (§14.6).
- Details: `references/vm.md`, then the file its "Read next" table names.

## When to read a reference

| `references/` | When |
|---|---|
| `repo-map.md` | which file in `compiler/`, `vm/`, `tests/` or `stdlib/` owns something |
| `frontend.md` | compiler edit recipes, the stage and golden contract, gotchas, refreeze; differential checks for speed changes |
| `stages.md` | token kinds, diagnostic codes, AST nodes, per-stage notes, the command line |
| `language-notes.md` | core language rules: Result and `try`, collections, ranges, modules, methods, interpolation, blocks, hints, enums |
| `library-notes.md` | a library area (stdio, JSON, tasks, TCP/TLS/HTTP, logging, files, processes, bits, std/binary, std/toml) or `stdlib/` style |
| `bdd.md` | `agentica test`: the driver, `std/bdd`, `stdlib/test/`, step programs |
| `vm.md` | any VM work: pipeline, layers, rules, index of `vm-*.md` |
| `ci.md` | `.github/workflows/`, Makefile and `mk/`, new VM files, peers, fixtures, jscpd, releases, stage0 |
| `property-tests.md` | when to add a Hypothesis property test, and how |
| `site.md` | `site/`, or a language rule or builtin shown on a site page |
| `bench-eval.md` | `benchmarks/`, `make bench`, `tests/eval/`, measuring speed |
