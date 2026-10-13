# Agentica

Interpreter for the Agentica language: a Racket front end and a C bytecode VM that runs every program. The language is defined in `docs/grammar.md`; planned syntax lives in `docs/future/`; the phased plan and the checklist of what is done live in `docs/roadmap/`; the bytecode VM design (phase 7) is `docs/vm/`. Each of these three folders has a `README.md` with an index, and its files keep the old section and phase numbers, so `§10.4` or phase 13 still finds its place.

## Commands

- `make test`: build the VM, then run all tests in parallel (`raco test -j $(nproc) tests/`; `JOBS=8` sets the workers).
- `make test TESTS="tests/lexer-test.rkt tests/parser-test.rkt"`: a subset. One stage: `raco test tests/<stage>-test.rkt`.
- `make smoke`: the example smoke runs of CI, in parallel (`tests/smoke.sh`; builds the VM and `dist/agentica` first if needed).
- `racket src/main.rkt examples/hello.agc`: run a program on the VM (after `make vm`). `racket src/main.rkt check file.agc`: check only.
- `make vm`: build `dist/agentica-vm` (run `git submodule update --init` first). `make vm-test`: the C tests.
- `make goldens`: rewrite the VM golden files after an intended change; commit them.
- `make site`: build the documentation site; run it before merging a site change.

## Layout

- `src/` is flat, one module per stage: `lexer.rkt` → `parser.rkt` (with `ast.rkt`) → `modules.rkt` (import linking) → `checker.rkt` → `lower.rkt` → `bytecode.rkt`, run by the C VM in `vm/`, which holds the runtime (tasks, files, processes, network, HTTP, JSON). Builtins are described once in `builtins.rkt`; `std/` modules written in Agentica live in `stdlib/`. `agentica test` is `bdd-driver.rkt` plus `std/bdd` in `stdlib/`.
- `source.rkt`, `token.rkt`, `diagnostic.rkt` hold shared data (positions/spans, tokens, diagnostics).
- `main.rkt` is a thin CLI driver. Printing and exit codes belong there only.
- `tests/<stage>-test.rkt` holds the focused tests for each stage.
- `.agents/skills/agentica-development/` has stage-by-stage notes and the details: the VM build and its third-party libraries, golden tests, CI, release, site, benchmarks, eval and jscpd. Read it before changing a stage, the VM, tests or CI.

## Conventions

- Each stage takes the previous stage's output and returns data or exactly one `diagnostic`. It stops at the first error, never prints, and never lets a Racket exception escape.
- Diagnostic codes are stable and prefixed by stage: `LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`; the VM compiler stages use `LOWER-` and `BYTECODE-`. Every diagnostic carries a source span.
- Keep to the core grammar (sections 4–6). User enums (generic only through enum declarations) and `case` pattern matching are core; there are no other user generics. File modules with explicit imports/exports are core; the builtin generics `List[T]`, `Map[K, V]`, and `Result[T]` and their builtin modules are core. `try` is builtin error propagation. Planned syntax stays in `docs/future/` until its phase lands. No placeholder files or nodes for later phases.
- Use Racket's built-in test support (`rackunit`) as the test framework. Independent integration counterparts may use Node.js, Python, or curl; use standard libraries and add no third-party libraries or test frameworks.
- Network and process tests must stay hermetic: localhost, dynamically assigned ports (port 0), no external services, and cleanup of processes and resources. TCP/HTTP interoperability tests must use an independent protocol implementation as the counterpart, rather than relying only on the Agentica client and server testing each other. Put fixtures in `tests/fixtures/`. These tests are required in CI: install their chosen tools and fail if they are missing. Local runs may explicitly report a skip when a required tool is unavailable. Racket-only tests may complement this coverage; they are not required as the base layer.
- Tests assert the diagnostic code (and the span when it matters), not message text.
- New features are VM-only. They are tested with golden outputs and independent Node/Python peers.
- When a phase item is finished, tick it in the roadmap and update the development skill.
- When the language or a builtin changes, update the matching site page too.
- Do not hard-wrap prose in `site/content/`: one line per paragraph or list item. Code blocks keep their line breaks.
- When the language changes, update `docs/grammar.md` and the programming skill together: the core language is in `.agents/skills/agentica-programming/SKILL.md`, and each library area has its own file in `references/` (builtins, modules, JSON, files, processes, tasks, network, BDD, diagnostics, examples). The skill is self-contained and does not read the grammar. Keep `SKILL.md` near 5,000 tokens; put new library detail in the matching reference and its row in the "When to read a reference" table.

## Working style

- Think briefly. If something is unclear, try it, see what fails, then fix it.
- Use simple words.
