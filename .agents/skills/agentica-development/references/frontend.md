# Front-end recipes and Racket gotchas

Step lists for common front-end changes (keyword, AST node, syntax, diagnostic, stage, tests), the Racket and lexer gotchas of this repo, and how to read a failure. Read before editing `src/*.rkt` or `compiler/`.

## The freeze and the Agentica front end

Roadmap row 7.2.7 froze the Racket front end. By default, from then on `src/` takes no new syntax and no new checker rules. Its only changes are bug fixes and the data that row 7.2.7 lists: builtin table rows in `src/builtins.rkt` with their `vm-builtins` names in `src/lower.rkt`, builtin record and enum entries, registry lines, std-only and reserved names, and message texts. Every later language change goes into `compiler/` (`docs/future/35-self-hosting.md`), and the recipes below that add a keyword, a node or a syntax form describe the change to make there once its stage is ported. A bug fix in a ported stage changes `src/` and `compiler/` in the same PR, with a golden case for it. They may be relaxed when following them costs more than it saves; the PR says which rule it relaxes and why.

`compiler/` holds the Agentica front end, one stage per PR in the order of 35.4. So far it has the lexer and the parser: `source.agc`, `token.agc` and `diagnostic.agc` (the data of `src/source.rkt`, `token.rkt`, `diagnostic.rkt`), `lexer.agc` (`src/lexer.rkt`), `unicode.agc` with the generated `unicode_table.agc` (Racket's `char-graphic?` for the text of `LEX-UNEXPECTED-CHAR`), and the entry `lex.agc` with `lex_text.agc`. The parser is `ast.agc` (`src/ast.rkt`), `parse_base.agc` and `parser.agc` (`src/parser.rkt`), with the entry `parse.agc` and `parse_text.agc`; `text.agc` holds the quoting and span printing both text forms share. Code follows 35.5: build lists with `push` and strings with `join`, and use loops, not recursion over the input. Positions and offsets count characters, as in Racket.

The lexer's output has a text form, one line per token (`kind start-end "lexeme" value`, spans as `offset:line:column`, `=` when the value is the lexeme) or one `ERROR` line. The Racket printer is `tests/frontend-lexer-common.rkt`; `compiler/lex.agc` prints the same for each file in `System.args()`, after a `== path` line. Token kinds are Strings in `compiler/`; they must match the symbols of the kind list in `src/token.rkt` and `references/stages.md`, because the parser compares them. Goldens are in `tests/fixtures/frontend/lexer/` (`NAME.input` and `NAME.tokens`); `.input` files keep their bytes (`-text` in `.gitattributes`). They hold the message and help text on purpose: 35.2 keeps the texts equal, an exception to "tests assert codes, not messages". They are not tied to live files, so they still work after Racket is deleted. While Racket exists, `tests/frontend-lexer-test.rkt` also compares the two lexers live on `examples/`, `stdlib/`, `tests/fixtures/vm/` and 300 generated inputs (the cases named "while Racket exists"; delete them with `src/`).

The parser has a text form too: one node per line, two spaces of indent per level, `role: kind #id start-offset:line:column-stop-offset:line:column attrs`, the root as `program #id span`. Spans print as `offset:line:column-offset:line:column`. Attributes are `name="x"`, ` op=plus op-span=SPAN`, ` value=int:N`, `float:bits:N` (signed IEEE bits), `string:"..."`, `bool:true` or `nil`, ` piped=true|false`, ` type-parameters=["T"]`, ` bindings=["a",-]`, ` doc="..."` and ` module-doc="..."`. The else part of an `if` is a line `else:`, and text parts of a string interpolation are `part: text "..."`. A failure prints the lexer's `ERROR CODE SPAN "message" "help"|-` line (a `LEX-` error passes through). The Racket printer is `tests/frontend-parser-common.rkt` (not `src/`, so `--dump` is unchanged); `compiler/parse.agc` prints the same for each file argument.

Node ids are dense, start at 0 and follow post-order: a child has a smaller id than its parent, siblings count in source order, and the `program` node has the last id. The Agentica parser builds trees bottom-up, so it gives ids as it goes; the Racket printer numbers by a post-order walk. Docs are a `doc` field on the declaration, field, variant and export nodes and `module_doc` on `Program`, where Racket keeps a span table. Ids restart per call: `Parser.parse(tokens, first_id)` numbers from `first_id`, and `Ast.next_free_id(program)` is the first id for the next file, so the modules of step 3 can share one numbering (`compiler/parse.agc --first-id=N` and `parser-text #:first-id` test it).

Parser goldens are in `tests/fixtures/frontend/parser/` (`NAME.input` and `NAME.ast`): valid files for every node kind, one `err-*` file per `PARSE-` diagnostic site of `tests/parser-test.rkt`, and `deep-*` files for the nesting limit. Both parsers stop with `PARSE-TOO-DEEP` when the nesting passes 1,000 levels (counted in `parse-statement`, `parse-expression`, each prefix operator, `parse-type`, and each link of a chain, where what follows the k-th link starts k levels deeper); this is a new parser rule in `src/`, allowed because the Agentica parser needs a bound well inside the VM's call depth (10,000 frames, up to about 6 frames per level; the tightest shapes overflow at 1.7 times the limit). It bounds the parser's calls, not the depth of the tree (see `references/stages.md`). The Agentica parser takes `(env, pos, ids)` and returns a `Result` with the new position and the next id; a failure is a packed diagnostic in the `Result` error, so `try` stops at the first error.

Two tiers: the golden checks run in `(module+ test ...)`. The comparisons "while Racket exists" over live files, the 300 generated inputs, the boundary and large-file guards run in `(module+ slow ...)`, which CI runs with `make test-slow`.

```sh
racket src/main.rkt compiler/lex.agc file.agc              # the Agentica lexer's text form of a file
raco test tests/frontend-lexer-test.rkt                    # Racket printer and Agentica lexer against every golden
make goldens                                               # also rewrites the front-end goldens from the Racket stages (make goldens FIXTURES=... skips them)
racket tests/frontend-lexer-common.rkt                     # rewrites only the lexer goldens
racket src/main.rkt compiler/parse.agc file.agc            # the Agentica parser's text form of a file
raco test tests/frontend-parser-test.rkt                   # fast tier: Racket printer and Agentica parser against every golden
racket tests/frontend-parser-common.rkt                    # rewrites only the parser goldens
racket tools/gen-lexer-unicode.rkt                         # rewrites compiler/unicode_table.agc (a test checks it)
```

To add a case, put `NAME.input` in the folder and run `racket tests/frontend-lexer-common.rkt` (or `frontend-parser-common.rkt`). A change to a ported stage reruns the test for that stage; review the golden diff.

## Common tasks

By default, under the freeze, these recipes name `src/` files. New syntax and new checker rules go into `compiler/` instead, and cannot start until the stage they change is ported (the parser for a syntax form, the checker for a rule): they wait (the same default). Only the lexer and the parser are ported so far, so a new syntax form now goes into `compiler/parser.agc` and `compiler/ast.agc` with a parser golden.

### Add a keyword or operator

1. Add it to the `keywords` hash (reserved words) or the operator hash in `src/lexer.rkt`.
2. If the parser must act on it, add the kind to the relevant `case`/`memq` in `src/parser.rkt`.
3. Add a test in `tests/lexer-test.rkt` (kinds) and, when it affects syntax, `tests/parser-test.rkt`.
4. Run `make test TESTS="tests/<stage>-test.rkt"`.

### Add an AST node

1. Add a `#:transparent` struct in `src/ast.rkt` with `span` as the last field, and add `(struct-out <node>)` to `provide`.
2. Construct it in `src/parser.rkt` and set the span from the first token to the last consumed token (the existing `span-from` helper).
3. Test the node's fields and its span line/column.

### Add syntax

1. Add tokens first if the syntax needs them.
2. Add the AST node if no existing node fits.
3. Write a parse function and call it from the right place: `parse-statement` for statements, `parse-primary` for expressions, `parse-program` for declarations.
4. Add one valid test and one rejection test asserting the diagnostic code.
5. Run `make test TESTS="tests/<stage>-test.rkt"` and the affected example.

### Add a diagnostic code

1. Choose the stage prefix: `LEX-`, `PARSE-`, later `CHECK-` or `RUNTIME-`.
2. Raise it with the stage's `bail`/`fail` helper and a token or position span.
3. Test both the code and the location (`source-position-line`/`-column` of the diagnostic span), as `tests/parser-test.rkt` does.

### Add a pipeline stage

1. Create `src/<stage>.rkt` with one entry point and a `provide`.
2. Require the previous stage's data modules only; do not reach back into the CLI.
3. Wire it into `src/main.rkt` after the previous stage, behind a `diagnostic?` guard.
4. Add `tests/<stage>-test.rkt`. `make test` discovers it automatically; CI needs no change.

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
- `#lang racket` provides `pretty-print`; `src/main.rkt` uses it for `--dump`.
- `unary` and `binary` carry `op-span` (the operator token) beside `span`. Operator diagnostics use `op-span`; `node-span` in `ast.rkt` returns any node's span.
- Racket `equal?` treats `+nan.0` as equal to itself and `0.0` unequal to `-0.0`; compare numbers with `=` so `==` follows IEEE 754.
- Positions count Racket string characters, line and column are 1-based, and span ends are exclusive. Keep that convention in new spans.

## Lexer gotcha: stray NL tokens

The lexer emits one `NL` per LF/CRLF outside `()`, `[]`, and `{}`, including every blank/comment line, so extra lines between statements can leave more than one `NL` token. The grammar's `program` and `block` rules do not model this. The parser therefore skips stray `NL` at the top level and between statements. Keep that skip when adding statement forms, or valid files with comments between statements will fail to parse.

Top-level declarations need a blank line after their `end` (`PARSE-MISSING-BLANK-LINE`, checked in `parse-program` from the NL tokens). A `##` doc block is one `DOC` token followed by the `NL` of its last line, and it does not count as a blank line: the check also fires when the next token is a `DOC`. A blank line and a `#` comment line both give one `NL`, so a `DOC` token carries what follows it (`doc-block-next`) for the module-doc rule. The rule only fires when the next token starts a declaration or import, so stray text after `end` stays `PARSE-TOP-LEVEL-STATEMENT`. Inline test programs end each top-level `end` with `end\n\n`, so fragments can be joined safely.

## Error handling

- `make test TESTS="tests/<stage>-test.rkt"` failure: read the failing `test-case` name and the message from the `parse-ok`/`parse-code` helper. A `parse-ok` failure prints the diagnostic the stage returned.
- Smoke test exits 1: `main.rkt` printed `file:line:column error[CODE]`, the message, and a source excerpt with a caret on stderr. That is a stage diagnostic, not a crash.
- A Racket traceback instead of a diagnostic means a stage raised or indexed out of range. Find the token or index and turn it into a `bail`/`fail`; the roadmap requires Agentica diagnostics, never host tracebacks.
- A stage unexpectedly returns a diagnostic: check the first-error rule and that `main.rkt` guards with `diagnostic?` before passing data to the next stage.

## Comments

- `compiler/*.agc`: a `#` comment where the code is complex or copies a Racket behavior on purpose (name the behavior, such as the span or NL rule). Each exported `def`, `struct` and `enum` you add or touch gets a `##` doc block, as in `stdlib/queue.agc` (`compiler/` has none yet; do not add docs to code you do not touch); the file's first doc block, followed by a blank line, is its module doc (`docs/grammar/05-syntax.md`). A `#` comment goes inside the body or above the `##` block, never between the block and its `def` (that is `PARSE-DETACHED-DOC`).
- `src/*.rkt` and `tests/*.rkt`: a `;` comment for the non-obvious why, such as a Racket quirk, a freeze exception or a golden that must not change. Never narrate the code.
