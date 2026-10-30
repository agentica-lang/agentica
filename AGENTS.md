# Agentica

Interpreter for the Agentica language. One binary, `dist/agentica`: a C VM that
runs every program, with the front end (written in Agentica, compiled to
bytecode) and the `std/` sources inside. The build starts from the checked-in
`bootstrap/stage0.agcb` and needs only a C toolchain (and the `std/` sources).

## Map

```text
VERSION             the version, one line (read by the Makefile)
compiler/           the front end in Agentica (§18), one folder per context
                    (`ls compiler/`): app (CLI, pipeline), io (the only I/O of
                    the stages), packages (manifest, lock, cache), catalog
                    (builtins, prelude), analysis (queries shared by the CLI
                    and std/analysis); front_end.agc is the program the binary
                    carries
Makefile, mk/       the build (`help` in the root); one mk/*.mk per area,
                    included in a fixed order
bootstrap/          stage0.agcb: a checked-in front end that the build starts from
vm/                 C11 VM: values, interpreter, loader, GC, tasks, I/O, HTTP, JSON;
                    agentica.c is the main of the binary (`run`, front end, hand-off)
stdlib/             std/ modules written in Agentica (http, binary, queue, bdd, test runner,
                    analysis); CORE lists the compiler/ files that std/analysis embeds
tests/              pytest: test_<area>.py; test_spec_<area>.py are the language
                    rules through the CLI; fixtures/ (goldens, Node/Python peers)
examples/           small programs per feature (README.md lists them)
docs/               grammar/ (the language definition, index: docs/grammar.md),
                    future/ (planned syntax, one file per section), roadmap/
                    (phases and the done checklist), vm/ (VM design)
site/content/       Hugo documentation site
benchmarks/         make bench programs and Python twins
.agents/skills/     agent skills; also documentation-pruning (shrinking docs)
```

Each of `docs/grammar/`, `docs/future/`, `docs/roadmap/` and `docs/vm/` has a
`README.md` index; files keep their section and phase numbers (`§10.4`,
phase 13).

## Commands

- `poetry install --only test --no-root`: the pytest environment.
- `make`: build `dist/agentica` (`git submodule update --init` first). Linux
  uses system libgc, OpenSSL and zlib (`pkg-config`);
  `make AGENTICA_GC=vendored AGENTICA_OPENSSL=vendored AGENTICA_ZLIB=vendored` links them
  statically. The build bootstraps from `bootstrap/stage0.agcb`, compiling
  the front end three times. `make fixed-point` checks it once more;
  `make stage0` refreshes the seed (`references/ci.md` of the development
  skill).
- `make test TESTS="tests/test_vm_bits.py tests/test_spec_checker.py"`: a
  subset. `make test` alone runs everything (`JOBS=8` sets the workers).
- `make vm-test`: the C tests. `make test-cli`: the command line tests.
  `make smoke`; `make site` before merging a site change.
- `dist/agentica file.agc` runs a program; `... check file.agc` checks;
  `dist/agentica run -- file.agcb` runs compiled bytecode.
- `make test-slow`: the `@slow` cases (sets `AGENTICA_TEST_SLOW=1`); CI only.
- `make vm-tsan`: the C tests of the code that threads share under
  ThreadSanitizer, in a build without libgc. `make test-shared`: the binary
  test modules with every lock and held check of the shared state on. Run
  both for shared-state C changes.
- `make tests KIND=files` (the destructive filesystem cases) runs only in the
  Docker sandbox or an ephemeral CI runner, never on the host
  (`references/ci.md` of the development skill).
- `make goldens` rewrites the VM goldens, `tests/fixtures/cli/forms.json` and
  the fast-tier front-end goldens; commit them. The slow-tier manifests of
  `tests/fixtures/frontend/frozen/` need the full `python3 tools/refreeze.py`.
- The steps of `ci.yml`, `sweep.yml` and the tests of `release.yml` are
  make targets; run them locally the same way.

## Where to read

| Task | Read |
|---|---|
| any change to compiler/, vm/, tests/, CI, `site/` or `benchmarks/` | `.agents/skills/agentica-development/SKILL.md`, then only the references it names |
| a C VM PR review | `.agents/skills/vm-c-critic/` |
| a PR from branch to merge (reviews, fixes, CI, merge) | `.agents/skills/agentica-dev-workflow/` |
| a release or beta (version bump, tag, notes, Pages) | `.agents/skills/agentica-release/` |
| docs, a site page, a skill, a CHANGELOG entry, a doc comment or a PR body | `.agents/skills/documentation-writing/` |
| an audit of builtin or std/ signatures (defaults, simpler APIs) | `.agents/skills/api-simplification-audit/` |
| language rules | `docs/grammar/` |
| builtin functions and `std/` modules | `site/content/library/` |
| writing `.agc` programs | `.agents/skills/agentica-programming/` |
| writing or reviewing `.agc` style | `.agents/skills/agentica-code-guidelines/` (`site/content/style.md` is its page for people) |
| what is planned or done | `docs/roadmap/README.md` |

## Rules

- Stages: each takes the previous stage's output and returns data or exactly
  one `diagnostic`; it stops at the first error, never prints, and never lets
  a runtime error of the front end escape: a failure is a diagnostic.
- Pure core: every folder of `compiler/` except `io/`, `app/`, `bdd/` and
  `embedded/` never calls `File`, `Dir`, `Path` (except `Path.join`),
  `System`, `Process`, `FrontEnd`, `IO`, `TCP`, `TLS`, `HttpWire`, `Time`,
  `Random`, `Task`, `Channel`, `Profile`, `LogRegistry` or `puts`, and never
  imports `io/`, `app/`, `bdd/` or an impure `std/` module. They reach the
  machine through the `Workspace` record (`modules/workspace.agc`), which
  `io/host.agc` builds and `app/` passes in. `app/`, `bdd/` and `io/` may do
  I/O. `tests/test_style_core_purity.py` enforces it.
- Diagnostic codes are stable, prefixed by stage (`LEX-`, `PARSE-`, `CHECK-`,
  `RUNTIME-`, `LOWER-`, `BYTECODE-`) or by area (`PKG-`: the manifest, the lock
  and the package cache; `QUERY-`: the query commands, exit 2), and carry a
  source span. A `PKG-` error about `agentica.toml` or `agentica.lock` carries
  the file and the key path instead (`key_path` in `--json`; a missing or
  unreadable file has the file alone). Tests assert the code (and the span, or
  the file and key path, when it matters), never message text.
- `compiler/` is the front end: every language change (syntax, checker rule,
  builtin row, builtin record or enum entry, message text) goes there, with its
  golden. The files `builtins_data.agc`, `check_tables.agc` and
  `unicode_table.agc` are edited by hand. `vm/unicode_data.c` is frozen
  checked-in data (see its header). These rules are defaults, which a PR may
  relax when following them costs more than it saves; the PR says which rule it
  relaxes and why.
- One way per thing, and it is the Ruby form (name, method form, syntax). A
  non-Ruby internal name has the Ruby name as alias, and every user-facing
  text shows only the Ruby form (rule and exception: the development skill).
- Core grammar only (sections 4–6): user enums, structs, functions and type
  aliases (all may be generic), `case`, file modules with explicit
  imports/exports, builtin `List[T]`, `Map[K, V]`, `Result[T]`, and `try`.
  Planned syntax stays in `docs/future/` until its phase lands. No placeholder
  files or nodes for later phases.
- New features are VM-only, tested with golden outputs and independent
  Node/Python peers.
- Python tests use pytest (a test-only Poetry dependency) and live in
  `tests/test_<area>.py`; `make test` runs each module in its own process.
  `unittest.TestCase` modules (from `tests.agentica_test.TestCase`) are
  collected too. Node and Python peers (curl included) use the standard
  library only. Dependencies: the C submodules in `vm/third_party`, the
  pinned jscpd in `tools/jscpd` and the site highlighter in `site/highlight`;
  nothing else.
- A language rule is tested through the CLI, in `tests/test_spec_<area>.py`:
  `--json check FILE`, asserting the code and the span, never the message.
- Network and process tests are hermetic: localhost, port 0, no external
  services, everything cleaned up. TCP/HTTP interop uses an independent
  protocol implementation as the peer. Fixtures go in `tests/fixtures/`.
  CI installs the tools and fails if one is missing; local runs may skip.
- Two test tiers: fast is the default; slow cases (frozen corpus, generated
  inputs, stress) use `@slow` (unittest) or `pytest.mark.slow` and run only
  in CI. Sanitizers, gc-stress, fuzz and full sweeps are slow by nature.
- When a phase item is done, tick it in the roadmap and update the
  development skill.
- When the language changes, update `docs/grammar/`, the site page and the
  programming skill together. When a builtin or a `std/` module changes,
  update its page in `site/content/library/`, the only home of the library
  reference, and the programming skill. Keep
  `.agents/skills/agentica-programming/SKILL.md` as short as possible (the
  table of references and what nearly every task needs): language rules go in
  its `references/language-*.md`, library detail in `references/<area>.md`.
  The skill is self-contained and does not read the grammar.
- A user-visible change adds an entry under `## [Unreleased]` in
  `CHANGELOG.md`: one short line per change, for users (details belong in the
  PR and docs); mark a breaking change `**Breaking:**`.
- Do not create new files under `docs/` (outside Hugo's `site/content/`)
  unless the user asks for one or accepts your suggestion. Progress and
  evidence go in the PR, the roadmap checklist or the CHANGELOG. Change docs
  only when strictly necessary (`.agents/skills/documentation-writing/`).
- Prose wrapping: `site/content/` keeps one line per paragraph or list item.
  Markdown prose in `docs/` and `.agents/skills/` wraps at 80 characters;
  code blocks keep their line breaks.

## Working style

- Think briefly. If something is unclear, try it, see what fails, then fix it.
- Use simple words.
