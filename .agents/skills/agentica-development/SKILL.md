---
name: agentica-development
description: "Develops the Agentica interpreter in Racket: where each pipeline stage lives, how to add tokens, AST nodes, syntax, diagnostics, and tests, plus the Racket and lexer gotchas specific to this repo. Use when working in the agentica Racket repository on src/, tests/, the lexer, parser, AST, diagnostics, or CI. Don't use for the grammar or roadmap documents alone, or for other Racket projects."
---

# Agentica development

Agentica is a Racket bootstrap for a small statically typed language. The grammar is `docs/Agentica-gramatica.md`; the phases and the active checklist are `docs/Agentica-roadmap.md`.

Read the active phase in the roadmap before adding code. Implement only what that phase asks for: the roadmap explicitly forbids placeholder modules and empty nodes for later phases.

## Commands

Run both before calling a change done:

```sh
raco test tests/                          # every stage test
racket src/main.rkt examples/hello.agc    # CLI smoke test; exits 0 on success
```

CI (`.github/workflows/ci.yml`) runs exactly these on Racket CS 9.3. Use the standard library only; the project adds no dependencies.

## Repository map

```text
src/
  source.rkt      # source, source-position, source-span (span end is exclusive)
  diagnostic.rkt  # diagnostic struct and format-diagnostic
  token.rkt       # token struct
  lexer.rkt       # lex: source -> (listof token) | diagnostic
  ast.rkt         # syntax tree nodes; every node carries a span
  parser.rkt      # parse: (listof token) -> program | diagnostic
  checker.rkt     # check: program -> program | diagnostic
  main.rkt        # thin CLI driver: lex, parse, check, then print the tree or the diagnostic
tests/
  lexer-test.rkt
  parser-test.rkt
  checker-test.rkt
docs/
  Agentica-gramatica.md   # language grammar, the source of truth
  Agentica-roadmap.md     # phases and the active checklist
```

## Where new code goes

| Add | Location |
| --- | --- |
| keyword, operator, or literal form | `src/lexer.rkt` lookup tables |
| AST node | `src/ast.rkt` struct plus `provide`; construct it from `src/parser.rkt` |
| syntax, statement, or expression form | `src/parser.rkt` |
| diagnostic code | raise it where the problem is detected; prefix by stage (`LEX-`, `PARSE-`, `CHECK-`) |
| pipeline stage (evaluator) | new `src/<stage>.rkt`, wired into `src/main.rkt`, tested by `tests/<stage>-test.rkt` |
| language rule or example | `docs/Agentica-gramatica.md`; phase scope in `docs/Agentica-roadmap.md` |
| test | `tests/<stage>-test.rkt` |

## Stage contract

Every stage follows the same shape; keep new stages consistent with it.

- Entry point is one function: `(lex input)`, `(parse tokens)`, later `(check program)`, `(evaluate program)`.
- Return either the next data or a single `diagnostic`. Stop at the first error; do not collect several.
- Never print and never raise from a stage. `main.rkt` owns presentation and exit codes.
- `main.rkt` guards with `diagnostic?` between stages, prints `format-diagnostic` on stderr, and exits 1.
- Thread spans through everything so diagnostics point at the source.

## Common tasks

### Add a keyword or operator

1. Add it to the `keywords` hash (reserved words) or the operator hash in `src/lexer.rkt`.
2. If the parser must act on it, add the kind to the relevant `case`/`memq` in `src/parser.rkt`.
3. Add a test in `tests/lexer-test.rkt` (kinds) and, when it affects syntax, `tests/parser-test.rkt`.
4. Run `raco test tests/`.

### Add an AST node

1. Add a `#:transparent` struct in `src/ast.rkt` with `span` as the last field, and add `(struct-out <node>)` to `provide`.
2. Construct it in `src/parser.rkt` and set the span from the first token to the last consumed token (the existing `span-from` helper).
3. Test the node's fields and its span line/column.

### Add syntax

1. Add tokens first if the syntax needs them.
2. Add the AST node if no existing node fits.
3. Write a parse function and call it from the right place: `parse-statement` for statements, `parse-primary` for expressions, `parse-program` for declarations.
4. Add one valid test and one rejection test asserting the diagnostic code.
5. Run `raco test tests/` and the smoke test.

### Add a diagnostic code

1. Choose the stage prefix: `LEX-`, `PARSE-`, later `CHECK-` or `RUNTIME-`.
2. Raise it with the stage's `bail`/`fail` helper and a token or position span.
3. Test both the code and the location (`source-position-line`/`-column` of the diagnostic span), as `tests/parser-test.rkt` does.

### Add a pipeline stage

1. Create `src/<stage>.rkt` with one entry point and a `provide`.
2. Require the previous stage's data modules only; do not reach back into the CLI.
3. Wire it into `src/main.rkt` after the previous stage, behind a `diagnostic?` guard.
4. Add `tests/<stage>-test.rkt`. `raco test tests/` discovers it automatically; CI needs no change.

### Add tests

- Use `#lang racket`, `rackunit`, and `module+ test` with `test-case` blocks.
- Require sources with relative paths (`"../src/lexer.rkt"`); they resolve from the test file.
- Keep the small helpers pattern from `tests/parser-test.rkt`: `parse-ok` fails loudly when a valid input returns a diagnostic, and `parse-code` returns the code or fails when invalid input parses.
- Cover the happy path, the error path, and the specific behavior the change introduces.

## Racket gotchas

- `define` is not allowed in an expression context, and `(begin ...)` is an expression. `(begin (define x 1) ...)` fails with `define: not allowed in an expression context`. Use `(let () ...)` to open a body that allows internal defines. `cond`/`case` clause bodies, `let/ec` bodies, and lambda bodies already allow them.
- `define` binds like `letrec`. A local named the same as the accessor it calls, such as `(define param-type (param-type x))`, fails with `undefined; cannot use before initialization`. Name locals distinctly.
- `source` is opaque (no `#:transparent`), so printing a tree shows `#<source>` instead of repeating the file text; every other struct is `#:transparent`. Keep any struct that holds the whole source text opaque.
- The lexer and parser are single mutable-pass scanners driven by `set!`. The parser cursor is capped at the last token (`EOF`), so `advance!` never runs past the end and `current`/`peek-token` stay safe at EOF.
- Early exit uses `let/ec` with a `bail`/`return` helper that escapes with a `diagnostic`. This is how a stage stops at the first error.
- `provide (struct-out name)` exports the constructor, predicate, and accessors in one line.
- `#lang racket` provides `pretty-print`; `src/main.rkt` uses it for the tree.
- Positions count Racket string characters, line and column are 1-based, and span ends are exclusive. Keep that convention in new spans.

## Lexer gotcha: stray NL tokens

The lexer emits one `NL` per newline sequence outside `()` and `[]`, but a comment line splits a sequence, so a comment or blank line between statements can leave more than one `NL` token. The grammar's `program` and `block` rules do not model this. The parser therefore skips stray `NL` at the top level and between statements. Keep that skip when adding statement forms, or valid files with comments between statements will fail to parse.

## Error handling

- `raco test tests/` failure: read the failing `test-case` name and the message from the `parse-ok`/`parse-code` helper. A `parse-ok` failure prints the diagnostic the stage returned.
- Smoke test exits 1: `main.rkt` printed `file:line:column: [CODE] message` on stderr. That is a stage diagnostic, not a crash.
- A Racket traceback instead of a diagnostic means a stage raised or indexed out of range. Find the token or index and turn it into a `bail`/`fail`; the roadmap requires Agentica diagnostics, never host tracebacks.
- A stage unexpectedly returns a diagnostic: check the first-error rule and that `main.rkt` guards with `diagnostic?` before passing data to the next stage.

## Reference

Read `references/stages.md` for the full token-kind table, the diagnostic-code list, the AST node list, and each module's public API. Load it when adding or renaming tokens, AST nodes, or diagnostic codes.
