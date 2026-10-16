# Agentica

Interpreter for the Agentica language. One binary, `dist/agentica`: a C VM that
runs every program, with the front end (written in Agentica, compiled to
bytecode) and the `std/` sources inside. The build starts from the checked-in
`bootstrap/stage0.agcb` and needs no Racket.

## Map

```text
VERSION             the version, one line (read by the Makefile and src/version.rkt)
src/                Racket front end, one module per stage; a development oracle
                    until Racket is deleted, not the product
  lexer.rkt → parser.rkt (ast.rkt) → modules.rkt (imports) → checker.rkt → lower.rkt → bytecode.rkt
  builtins.rkt      every builtin described once (signatures, effects, docs)
  stdlib.rkt        embeds stdlib/ as std/
  source.rkt token.rkt diagnostic.rkt   shared data: spans, tokens, diagnostics
  main.rkt          thin CLI: printing and exit codes live only here; runs
                    programs with `dist/agentica run`
compiler/           the front end in Agentica (§35): lexer, parser, modules,
                    builtin catalog, checker, lowering, bytecode writer, BDD
                    driver, CLI; front_end.agc is the program the binary carries
bootstrap/          stage0.agcb: a checked-in front end that the build starts from
vm/                 C11 VM: values, interpreter, loader, GC, tasks, I/O, HTTP, JSON;
                    agentica.c is the main of the binary (`run`, front end, hand-off)
  tests/            C tests (make vm-test)
  third_party/      submodules: bdwgc, yyjson, libuv, picohttpparser, openssl
stdlib/             std/ modules written in Agentica (http, binary, queue, bdd, test runner)
tests/              unittest: test_<area>.py (agentica_test.py is the shared helper);
                    test_spec_<area>.py are the language rules through the CLI;
                    fixtures/ (goldens, Node/Python peers)
examples/           small programs per feature (README.md lists them)
docs/
  grammar/          the language definition (index: docs/grammar.md)
  future/           planned syntax, one file per section (§N)
  roadmap/          phases and the done checklist (README.md: current order)
  vm/               VM design: bytecode, loader, layers (§15), core invariants (§14)
site/content/       Hugo documentation site
benchmarks/         make bench programs and Python twins
.agents/skills/     agentica-development (working on this repo), agentica-programming
                    (writing .agc), vm-c-critic (C VM PR review)
```

Each of `docs/grammar/`, `docs/future/`, `docs/roadmap/` and `docs/vm/` has a
`README.md` index; files keep their section and phase numbers (`§10.4`,
phase 13).

## Commands

- `make`: build `dist/agentica` (`git submodule update --init` first). It links
  a first binary with `bootstrap/stage0.agcb`, compiles the front end three
  times and links the final binary. `make fixed-point` checks it once more.
  `make vm-test`: the C tests. `make test-cli`: the command line tests on the
  binary. `make stage0` refreshes `bootstrap/stage0.agcb` (see `references/ci.md`
  of the development skill).
- `make test TESTS="tests/test_vm_bits.py"`: a subset. `make test` alone runs
  everything (`JOBS=8` sets the workers). The tests need no Racket.
- `dist/agentica file.agc` runs a program; `... check file.agc` checks;
  `dist/agentica run -- file.agcb` runs compiled bytecode. `racket src/main.rkt`
  takes the same words (it goes with `src/`, post-bootstrap step 2).
- `make test TESTS="tests/test_vm_bits.py tests/test_spec_checker.py"`: each
  `tests/test_<area>.py` file runs as one unittest process.
- `make test-slow`: the `@slow` cases; CI only.
- `make smoke`, `make site` (before merging a site change).
- `make goldens` rewrites the VM goldens, the CLI output golden
  (`tests/fixtures/cli/forms.json`) and the fast-tier front-end goldens; commit
  them. The slow-tier manifests of `tests/fixtures/frontend/frozen/` need the
  full `python3 tools/refreeze.py`.
- CI steps of `ci.yml`, `sweep.yml` and the tests of `release.yml` are make
  targets, so they run locally the same way.

## Where to read

| Task | Read |
|---|---|
| any change to src/, vm/, tests/, CI | `.agents/skills/agentica-development/SKILL.md`, then only the references it names |
| a C VM PR review | `.agents/skills/vm-c-critic/` |
| language rules | `docs/grammar/` |
| writing `.agc` programs | `.agents/skills/agentica-programming/` |
| `site/` or `benchmarks/` | `.agents/skills/agentica-development/SKILL.md` |
| what is planned or done | `docs/roadmap/README.md` |

## Rules

- Stages: each takes the previous stage's output and returns data or exactly
  one `diagnostic`; it stops at the first error, never prints, and never lets
  a Racket exception escape.
- Diagnostic codes are stable, prefixed by stage (`LEX-`, `PARSE-`, `CHECK-`,
  `RUNTIME-`, `LOWER-`, `BYTECODE-`), and carry a source span. Tests assert
  the code (and the span when it matters), never message text.
- By default the Racket front end in `src/` is frozen (roadmap row 7.2.7): no
  new syntax and no new checker rules. Only bug fixes, and the data that row
  7.2.7 lists (builtin table rows and their `vm-builtins` names, builtin record
  and enum entries, registry lines, std-only and reserved names, message texts).
  Every later language change goes into `compiler/`. A bug fix in a ported stage
  changes both front ends in the same PR. These rules are defaults, which a PR
  may relax when following them costs more than it saves; the PR says which
  rule it relaxes and why.
- Core grammar only (sections 4–6): user enums (the only user generics),
  `case`, file modules with explicit imports/exports, builtin `List[T]`,
  `Map[K, V]`, `Result[T]`, and `try`. Planned syntax stays in `docs/future/`
  until its phase lands. No placeholder files or nodes for later phases.
- New features are VM-only, tested with golden outputs and independent
  Node/Python peers.
- Tests: Python `unittest` only (no rackunit, no Racket in the tests). Node
  and Python test code and peers (curl included) use the standard library
  only, with no third-party libraries or test frameworks. The VM's C
  dependencies are the submodules in `vm/third_party`; the only dev-tool
  dependency is the pinned jscpd in `tools/jscpd`.
- A language rule is tested through the CLI, in `tests/test_spec_<area>.py`:
  `--json check FILE`, asserting the code and the span, never the message.
- Network and process tests are hermetic: localhost, port 0, no external
  services, everything cleaned up. TCP/HTTP interop uses an independent
  protocol implementation as the peer. Fixtures go in `tests/fixtures/`.
  CI installs the tools and fails if one is missing; local runs may report a
  skip.
- Python tests live in `tests/test_<area>.py` and derive from
  `tests.agentica_test.TestCase`; `make test` runs each module in its own
  process, `JOBS` at a time (standard library only, no pytest).
- Two test tiers: the fast tier is the default cases of a unittest module;
  slow cases (frozen corpus, generated inputs, stress) are marked `@slow` (run
  only with `AGENTICA_TEST_SLOW=1`, which `make test-slow` sets), and CI runs
  them with `make test-slow`. Local runs use only the fast tier
  (`make test TESTS=...`). Sanitizers, gc-stress, fuzz, smoke and full sweeps
  are slow by nature.
- When a phase item is done, tick it in the roadmap and update the
  development skill.
- When the language or a builtin changes, update `docs/grammar/`, the site
  page and the programming skill together: core rules in
  `.agents/skills/agentica-programming/SKILL.md` (keep it near 2,000 tokens)
  and `references/language.md`; library detail in its `references/<area>.md`
  plus its row in the "When to read a reference" table. The skill is
  self-contained and does not read the grammar.
- A user-visible change adds an entry under `## [Unreleased]` in
  `CHANGELOG.md`; mark a breaking change `**Breaking:**`.
- Prose wrapping: `site/content/` and `docs/grammar/` keep one line per
  paragraph or list item (code blocks keep their line breaks); other `docs/`
  files wrap at 80 characters.

## Working style

- Think briefly. If something is unclear, try it, see what fails, then fix it.
- Use simple words.
