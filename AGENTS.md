# Agentica

Interpreter for the Agentica language, written in Racket. The language is defined in `docs/Agentica-gramatica.md`; the phased plan and the checklist of what is done live in `docs/Agentica-roadmap.md`.

## Commands

- Run all tests in parallel: `make test` (defaults to `raco test -j $(nproc) tests/`).
- Run a subset: `make test TESTS="tests/lexer-test.rkt tests/parser-test.rkt"`.
- Control workers: `make test JOBS=8`.
- Run a program: `racket src/main.rkt examples/hello.agc`
- CI runs `make test` and the example smoke tests (`.github/workflows/ci.yml`), on Racket CS 9.3.

`make test` wraps `raco test`; a single stage still works directly with `raco test tests/<stage>-test.rkt`.

## Layout

- `src/` is flat, one module per stage: `lexer.rkt` → `parser.rkt` (with `ast.rkt`) → `checker.rkt` → `evaluator.rkt`.
- `source.rkt`, `token.rkt`, `diagnostic.rkt` hold shared data (positions/spans, tokens, diagnostics).
- `main.rkt` is a thin CLI driver. Printing and exit codes belong there only.
- `tests/<stage>-test.rkt` holds the focused tests for each stage.
- `.agents/skills/agentica-development/` has stage-by-stage notes. Read it before changing a stage.

## Conventions

- Each stage takes the previous stage's output and returns data or exactly one `diagnostic`. It stops at the first error, never prints, and never lets a Racket exception escape.
- Diagnostic codes are stable and prefixed by stage: `LEX-`, `PARSE-`, `CHECK-`, `RUNTIME-`. Every diagnostic carries a source span.
- Keep to the core grammar (sections 4–6). No enums, user generics, or user modules; the builtin generics `List[T]` and `Map[K, V]` and the builtin modules `Map` and `List` are core. Planned syntax stays in the grammar's section 8 until its phase lands. No placeholder files or nodes for later phases.
- Use only Racket's built-in test support (`rackunit`). Add no dependencies.
- Network and process tests stay hermetic by default (Racket-only, port 0). Optional Node.js fixtures in `tests/fixtures/` may check interoperability: Node standard library only, and the test skips itself when `node` is missing. See "Integration fixtures in Node.js" in the roadmap.
- Tests assert the diagnostic code (and the span when it matters), not message text.
- When a phase item is finished, tick it in the roadmap and update the development skill.

## Working style

- Think briefly. If something is unclear, try it, see what fails, then fix it.
- Use simple words.
