# Agentica

Interpreter for the Agentica language, written in Racket. The language is defined in `docs/grammar.md`; planned syntax lives in `docs/future.md`; the phased plan and the checklist of what is done live in `docs/roadmap.md`; the bytecode VM design (phase 7) is `docs/vm.md`.

## Commands

- Run all tests in parallel: `make test` (defaults to `raco test -j $(nproc) tests/`).
- Run a subset: `make test TESTS="tests/lexer-test.rkt tests/parser-test.rkt"`.
- Control workers: `make test JOBS=8`.
- Run a program: `racket src/main.rkt examples/hello.agc`; check only: `racket src/main.rkt check file.agc`
- Bytecode VM (`docs/vm.md`): `make vm` builds `dist/agentica-vm` (libgc comes from the `vm/third_party/bdwgc` submodule: `git submodule update --init`); `make vm-test` runs the C tests; `make vm SANITIZE=1` builds with ASan+UBSan; `make vm-fuzz` runs the loader fuzzer; `make vm-gc-stress` runs the C and differential tests on a build that collects often; `make vm-unicode` regenerates `vm/unicode_data.c` from Racket (use Racket CS 9.3, the CI version). Compile with `racket src/main.rkt compile file.agc -o file.agcb`, run with `dist/agentica-vm -- file.agcb`. `tests/vm-diff-test.rkt` compares the VM with the evaluator.
- Agent evaluation (not part of `make test`): `python3 tests/eval/run.py --help`. Docker is the default; its image is built automatically when missing. Allow provider credentials with repeatable `--pass-env NAME`. Optional Firejail requires `--sandbox firejail --chroot-root PATH`. `--jobs N` runs in parallel.
- CI runs `make vm vm-test`, `make test` and the example smoke tests, a check that `vm/unicode_data.c` is up to date, plus a VM sanitizer job that also runs the GC stress build (`.github/workflows/ci.yml`), on Racket CS 9.3.

`make test` wraps `raco test`; a single stage still works directly with `raco test tests/<stage>-test.rkt`.

## Layout

- `src/` is flat, one module per stage: `lexer.rkt` → `parser.rkt` (with `ast.rkt`) → `modules.rkt` (import linking) → `checker.rkt` → `evaluator.rkt`; for the VM, `checker.rkt` → `lower.rkt` → `bytecode.rkt`, run by the C VM in `vm/`. Builtins are described once in `builtins.rkt`; runtime libraries (tasks, files, processes, network, HTTP, JSON, BDD) have their own modules.
- `source.rkt`, `token.rkt`, `diagnostic.rkt` hold shared data (positions/spans, tokens, diagnostics).
- `main.rkt` is a thin CLI driver. Printing and exit codes belong there only.
- `tests/<stage>-test.rkt` holds the focused tests for each stage.
- `.agents/skills/agentica-development/` has stage-by-stage notes. Read it before changing a stage.

## Conventions

- Each stage takes the previous stage's output and returns data or exactly one `diagnostic`. It stops at the first error, never prints, and never lets a Racket exception escape.
- Diagnostic codes are stable and prefixed by stage: `LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`; the VM compiler stages use `LOWER-` and `BYTECODE-`. Every diagnostic carries a source span.
- Keep to the core grammar (sections 4–6). User enums (generic only through enum declarations) and `case` pattern matching are core; there are no other user generics. File modules with explicit imports/exports are core; the builtin generics `List[T]`, `Map[K, V]`, and `Result[T]` and their builtin modules are core. `try` is builtin error propagation. Planned syntax stays in `docs/future.md` until its phase lands. No placeholder files or nodes for later phases.
- Use Racket's built-in test support (`rackunit`) as the test framework. Independent integration counterparts may use Node.js, Python, or curl; use standard libraries and add no third-party libraries or test frameworks.
- Network and process tests must stay hermetic: localhost, dynamically assigned ports (port 0), no external services, and cleanup of processes and resources. TCP/HTTP interoperability tests must use an independent protocol implementation as the counterpart, rather than relying only on the Agentica client and server testing each other. Put fixtures in `tests/fixtures/`. These tests are required in CI: install their chosen tools and fail if they are missing. Local runs may explicitly report a skip when a required tool is unavailable. Racket-only tests may complement this coverage; they are not required as the base layer.
- Tests assert the diagnostic code (and the span when it matters), not message text.
- When a phase item is finished, tick it in the roadmap and update the development skill.
- When the language changes, update `docs/grammar.md` and the programming skill together: the core language is in `.agents/skills/agentica-programming/SKILL.md`, and each library area has its own file in `references/` (builtins, modules, JSON, files, processes, tasks, network, BDD, diagnostics, examples). The skill is self-contained and does not read the grammar. Keep `SKILL.md` near 5,000 tokens; put new library detail in the matching reference and its row in the "When to read a reference" table.

## Working style

- Think briefly. If something is unclear, try it, see what fails, then fix it.
- Use simple words.
