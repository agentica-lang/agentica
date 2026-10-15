# Agentica

Interpreter for the Agentica language: a Racket front end compiles `.agc` to
bytecode, and a C VM runs every program.

## Map

```text
src/                Racket front end, one module per stage
  lexer.rkt → parser.rkt (ast.rkt) → modules.rkt (imports) → checker.rkt → lower.rkt → bytecode.rkt
  builtins.rkt      every builtin described once (signatures, effects, docs)
  stdlib.rkt        embeds stdlib/ as std/
  source.rkt token.rkt diagnostic.rkt   shared data: spans, tokens, diagnostics
  main.rkt          thin CLI: printing and exit codes live only here
  bdd-driver.rkt    `agentica test`
compiler/           front end ported to Agentica, one stage per PR (§35):
                    lexer, parser
vm/                 C11 VM (dist/agentica-vm): values, interpreter, loader, GC, tasks, I/O, HTTP, JSON
  tests/            C tests (make vm-test)
  third_party/      submodules: bdwgc, yyjson, libuv, picohttpparser, openssl
stdlib/             std/ modules written in Agentica (http, binary, queue, bdd, test runner)
tests/              rackunit: <stage>-test.rkt, vm-*-test.rkt; fixtures/ (goldens, Node/Python peers)
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

- `make vm`: build `dist/agentica-vm` (`git submodule update --init` first).
  `make vm-test`: the C tests.
- `make test TESTS="tests/lexer-test.rkt"`: a subset. `make test` alone runs
  everything (`JOBS=8` sets the workers).
- `racket src/main.rkt file.agc` runs a program; `... check file.agc` checks.
- `make smoke`, `make goldens` (rewrite the VM and front-end goldens; commit
  them), `make site` (before merging a site change).
- CI steps of `ci.yml`, `sweep.yml` and the tests of `release.yml` are make
  targets, so they run locally the same way.

## Where to read

| Task | Read |
|---|---|
| any change to src/, vm/, tests/, CI | `.agents/skills/agentica-development/SKILL.md`, then only the references it names |
| a C VM PR review | `.agents/skills/vm-c-critic/` |
| language rules | `docs/grammar/` |
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
- Tests: `rackunit`. Peers may use Node.js, Python or curl with standard
  libraries only; no third-party libraries or test frameworks.
- Network and process tests are hermetic: localhost, port 0, no external
  services, everything cleaned up. TCP/HTTP interop uses an independent
  protocol implementation as the peer. Fixtures go in `tests/fixtures/`.
  CI installs the tools and fails if one is missing; local runs may report a
  skip. Racket-only tests may add coverage but are not the base layer.
- Two test tiers: the fast tier is `(module+ test ...)`; slow cases (live
  corpus, generated inputs, stress) go in `(module+ slow ...)`, which CI runs
  with `make test-slow`. Local runs use only the fast tier
  (`make test TESTS=...`). Sanitizers, gc-stress, fuzz, smoke and full
  sweeps are slow by nature.
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
