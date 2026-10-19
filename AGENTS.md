# Agentica

Interpreter for the Agentica language. One binary, `dist/agentica`: a C VM that
runs every program, with the front end (written in Agentica, compiled to
bytecode) and the `std/` sources inside. The build starts from the checked-in
`bootstrap/stage0.agcb` and needs only a C toolchain (and the `std/` sources).

## Map

```text
VERSION             the version, one line (read by the Makefile)
compiler/           the front end in Agentica (§18): lexer, parser, modules,
                    builtin catalog, checker, lowering, bytecode writer, BDD
                    driver, CLI; front_end.agc is the program the binary carries
bootstrap/          stage0.agcb: a checked-in front end that the build starts from
vm/                 C11 VM: values, interpreter, loader, GC, tasks, I/O, HTTP, JSON;
                    agentica.c is the main of the binary (`run`, front end, hand-off)
  tests/            C tests (make vm-test)
  third_party/      submodules: bdwgc, yyjson, libuv, picohttpparser, openssl
stdlib/             std/ modules written in Agentica (http, binary, queue, bdd, test runner)
tests/              pytest: test_<area>.py (conftest.py fixtures; agentica_test.py
                    still supports unittest.TestCase modules); test_spec_<area>.py
                    are the language rules through the CLI; fixtures/ (goldens,
                    Node/Python peers)
examples/           small programs per feature (README.md lists them)
docs/
  grammar/          the language definition (index: docs/grammar.md)
  future/           planned syntax, one file per section (§N)
  roadmap/          phases and the done checklist (README.md: current order)
  vm/               VM design: bytecode, loader, layers (§15), core invariants (§14)
site/content/       Hugo documentation site
benchmarks/         make bench programs and Python twins
.agents/skills/     agentica-development (working on this repo), agentica-programming
                    (writing .agc), agentica-code-guidelines (.agc style and
                    speed), vm-c-critic (C VM PR review), agentica-dev-workflow
                    (the PR loop: review, fix, CI, merge)
```

Each of `docs/grammar/`, `docs/future/`, `docs/roadmap/` and `docs/vm/` has a
`README.md` index; files keep their section and phase numbers (`§10.4`,
phase 13).

## Commands

- `poetry install --only test --no-root`: install the pytest test environment.
- `make`: build `dist/agentica` (`git submodule update --init` first). On Linux
  it uses system libgc and OpenSSL by default; the Makefile checks them with
  `pkg-config`. Use `make AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored` to
  link the vendored versions of those two libraries statically. This is not a
  fully static binary. The build links a first binary with
  `bootstrap/stage0.agcb`, compiles the front end three times and links the
  final binary. `make fixed-point` checks it once more. `make vm-test`: the C
  tests. `make test-cli`: the command line tests on the binary. `make stage0`
  refreshes `bootstrap/stage0.agcb` (see `references/ci.md` of the development
  skill).
- `make test TESTS="tests/test_vm_bits.py"`: a subset. `make test` alone runs
  everything (`JOBS=8` sets the workers).
- `dist/agentica file.agc` runs a program; `... check file.agc` checks;
  `dist/agentica run -- file.agcb` runs compiled bytecode.
- `make test TESTS="tests/test_vm_bits.py tests/test_spec_checker.py"`: each
  `tests/test_<area>.py` file runs in one pytest process.
- `make test-slow`: the `@slow` cases; CI only.
- `make tests KIND=fast|files|slow|all` selects a whole group: `files` holds
  the destructive filesystem cases, which run only in the local Docker sandbox
  (`DOCKER=1` puts any group there, `WINE=1` runs its Windows checks under
  Wine) and in the scratch of an ephemeral CI runner. Encapsulation and the
  Actions route: `references/ci.md` of the development skill.
- `make vm-task-map`: the timing cases of `Task.map`
  (`tests/test_vm_task_map.py`), alone like `make vm-latency`.
- `make smoke`, `make site` (before merging a site change).
- `make goldens` rewrites the VM goldens, the CLI output golden
  (`tests/fixtures/cli/forms.json`) and the fast-tier front-end goldens; commit
  them. The slow-tier manifests of `tests/fixtures/frontend/frozen/` need the
  full `python3 tools/refreeze.py`.
- CI steps of `ci.yml`, `sweep.yml` and the tests of `release.yml` are make
  targets, so they run locally the same way.

## Where to read

- **Task:** any change to compiler/, vm/, tests/, CI
  - **Read:** `.agents/skills/agentica-development/SKILL.md`, then only the
    references it names

- **Task:** a C VM PR review
  - **Read:** `.agents/skills/vm-c-critic/`

- **Task:** taking a PR from branch to merge (reviews, fixes, CI, merge)
  - **Read:** `.agents/skills/agentica-dev-workflow/`

- **Task:** language rules
  - **Read:** `docs/grammar/`

- **Task:** writing `.agc` programs
  - **Read:** `.agents/skills/agentica-programming/`

- **Task:** writing or reviewing `.agc` style
  - **Read:** `.agents/skills/agentica-code-guidelines/`

- **Task:** `site/` or `benchmarks/`
  - **Read:** `.agents/skills/agentica-development/SKILL.md`

- **Task:** what is planned or done
  - **Read:** `docs/roadmap/README.md`

## Rules

- Stages: each takes the previous stage's output and returns data or exactly
  one `diagnostic`; it stops at the first error, never prints, and never lets
  a runtime error of the front end escape: a failure is a diagnostic.
- Diagnostic codes are stable, prefixed by stage (`LEX-`, `PARSE-`, `CHECK-`,
  `RUNTIME-`, `LOWER-`, `BYTECODE-`), and carry a source span. Tests assert
  the code (and the span when it matters), never message text.
- `compiler/` is the front end: every language change (syntax, checker rule,
  builtin row, builtin record or enum entry, message text) goes there, with its
  golden. The files `builtins_data.agc`, `check_tables.agc` and
  `unicode_table.agc` are edited by hand. `vm/unicode_data.c` is frozen
  checked-in data (see its header). These rules are defaults, which a PR may
  relax when following them costs more than it saves; the PR says which rule it
  relaxes and why.
- Core grammar only (sections 4–6): user enums (the only user generics),
  `case`, file modules with explicit imports/exports, builtin `List[T]`,
  `Map[K, V]`, `Result[T]`, and `try`. Planned syntax stays in `docs/future/`
  until its phase lands. No placeholder files or nodes for later phases.
- New features are VM-only, tested with golden outputs and independent
  Node/Python peers.
- Python tests run with pytest; existing `unittest.TestCase` modules remain
  supported during migration. Pytest is a test-only Poetry dependency. Node
  and Python test peers (curl included) use the standard library only. The
  VM's C dependencies are the submodules in `vm/third_party`; the only other
  dev-tool dependency is the pinned jscpd in `tools/jscpd`.
- A language rule is tested through the CLI, in `tests/test_spec_<area>.py`:
  `--json check FILE`, asserting the code and the span, never the message.
- Network and process tests are hermetic: localhost, port 0, no external
  services, everything cleaned up. TCP/HTTP interop uses an independent
  protocol implementation as the peer. Fixtures go in `tests/fixtures/`.
  CI installs the tools and fails if one is missing; local runs may report a
  skip.
- Python tests live in `tests/test_<area>.py`; `make test` runs each module in
  its own pytest process, `JOBS` at a time. Existing unittest modules derive
  from `tests.agentica_test.TestCase` and are collected by pytest.
- Two test tiers: fast is the default; slow cases (frozen corpus, generated
  inputs, stress) use `@slow` on unittest classes or `pytest.mark.slow` on
  pytest functions. `make test-slow` sets `AGENTICA_TEST_SLOW=1`; CI runs it,
  while local runs use only fast tests (`make test TESTS=...`). Sanitizers,
  gc-stress, fuzz, smoke and full sweeps are slow by nature.
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
- Do not create new files under `docs/` (the Markdown tree outside Hugo's
  `site/content/`) unless the user asks for them or suggests one and accepts
  it. Record progress and evidence in the PR, the roadmap checklist or the
  CHANGELOG instead. Existing files are updated in place.
- Prose wrapping: `site/content/` keeps one line per paragraph or list item.
  Markdown prose in `docs/` and `.agents/skills/` wraps at 80 characters;
  code blocks keep their line breaks.

## Working style

- Think briefly. If something is unclear, try it, see what fails, then fix it.
- Use simple words.
