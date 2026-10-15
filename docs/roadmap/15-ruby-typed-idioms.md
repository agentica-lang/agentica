## Phase 15: Ruby typed idioms

Specified in [`docs/future/25-ruby-typed-idioms.md` section
25](../future/25-ruby-typed-idioms.md#25-ruby-typed-idioms), Part A, with its
principle of one way to do each thing. Every item comes after 7i deletes the
evaluator (order 7.2), changes the front end and `src/lower.rkt`, and runs on
the C VM only, never on the Racket evaluator. Item 15l is the exception: it
comes at order row 7.2.1g, before order step 7.5, and changes no lowering. Item
15c is another exception: the owner moved it before the bootstrap on 2026-10-15
(built; see its line). Three order steps: 15a (front end only) as order row
7.5a, deferred until after the bootstrap (row 7.2.7). `std/logger` (14c) does
not wait for it (§24.2): its `_meta` functions become one `fields` default when
it lands. 15b, 15d, 15e, 15i and 15j at order step 7.6, after phase 16 (strict
diagnostics); the prelude part, 15f and 15k, at order step 8.2, after faster
lists (8d), because on today's flat-array lists an Agentica loop that builds a
list is O(n²). One small PR per item, each with `grammar.md`, the programming
skill, the site page, the development skill's notes and tests (parser, lexer and
checker tests that assert codes and spans, golden VM fixtures, site examples).
The items are independent, except where noted. Library items follow the library
rule (after the order table): their code is Agentica in the compiler prelude,
and the only new builtins are `String.compare` (public, under its exception 5),
`File.eof?` (public, under its exception 1), and the internal `__fail_arg` and
`__float_fixed` (prelude-only, guarded by the loader). Part B (§25.12) and Part
C (§25.13) add no items. Ten items are planned; 15g and 15h are not planned.

- [ ] 15a Order row 7.5a (deferred until after the bootstrap, row 7.2.7). Not a
  dependency of 14c (§24.2). Default parameter values (§25.1):
  `CHECK-DEFAULT-ORDER`, `CHECK-DEFAULT-VALUE`, `CHECK-ARITY` with a range;
  `lower.rkt` fills the missing arguments at the call site; the linker resolves
  an enum default in the declaring module. Docs: `grammar.md`, the programming
  skill (with `references/diagnostics.md`), `site/content/tour/functions.md`.
- [ ] 15b Re-exports `export Alias.name` (§25.2), in the linker
  (`src/modules.rkt`) only. A re-export counts as a use of its alias for
  `CHECK-UNUSED-IMPORT` (16a, §26.1). Docs: `grammar.md`,
  `references/modules.md`, `site/content/tour/modules.md`.
- [x] 15c Struct update `value.with(field: x)` (§25.3), **built early** on the
  owner's decision of 2026-10-15, before the bootstrap (it relaxes the freeze of
  row 7.2.7), so that `compiler/` can be written as pure functions and
  `step(state)` loops. Both parsers (a `struct-update` node, `Update` in
  `compiler/ast.agc`), the checker (`CHECK-UNKNOWN-METHOD` for a receiver that
  is not a struct, `CHECK-UNKNOWN-FIELD`, `CHECK-DUPLICATE-FIELD`,
  `CHECK-TYPE-MISMATCH`, and `CHECK-IMPORT-NAME` for a struct that its module
  keeps private, through a `visible` predicate of the linker), and one new
  opcode, `STRUCT_WITH` (bytecode format version 4, an Updates section checked
  by the loader), which beat a constructor call by 15% to 34% on structs of 4 to
  16 fields (`docs/vm-benchmarks.md`). The ban on `Fn` fields named `with` comes
  here, in advance, so that 10a stays non-breaking; the ban on a type-parameter
  field named `with` is in 10c. Breaking change: an `Fn` field named `with`
  becomes `CHECK-REDEFINED-NAME`. Docs: `grammar.md`, the programming skill, the
  development skill, `site/content/tour/structs.md`. The checker and modules
  ports (§35.4 steps 3 and 4) carry it.
- [ ] 15d Value equality for structs, enums, lists, maps and Results (§25.4):
  the checker rule and the VM's `EQ`/`NE` opcodes with an explicit stack; a
  bytecode format version bump (an opcode's meaning changes). Docs:
  `grammar.md`, the programming skill, `site/content/tour/structs.md`,
  `lists.md` and `maps.md`, `results-and-try.md`, `enums-and-case.md`,
  `site/content/library/errors/result.md`, `docs/vm/03-ir-and-bytecode.md` §4.2
  (`EQ` and `NE`), `docs/vm/10-io-scheduler.md` §10.2.1 ("`==` only on scalars,
  strings and ranges").
- [ ] 15e Standalone lambdas `lambda do |x: Int| ... end` (§25.5). In the lexer,
  parser, checker and lowering. A `lambda` literal as the last argument where a
  trailing block is accepted (named, builtin, method and import-alias calls; not
  `.call(...)`) is `CHECK-BLOCK-TARGET` with the trailing-block help (tests for
  it, for `g.call(1, lambda do |x: Int| x end)` and for the valid places).
  Lambda bodies and parameters follow phase 16 (`CHECK-UNUSED-VARIABLE`,
  `CHECK-UNREACHABLE-CODE`, `CHECK-UNUSED-RESULT`), with tests. Breaking change:
  `lambda` becomes a reserved word (say so in the changelog). Docs: `grammar.md`
  (and its §7 hint row), the programming skill (and its adapter examples),
  `site/content/tour/blocks.md` and the site's adapter examples, section 11.4,
  and `docs/future/15-adapters-and-json-inspection.md` (once lambdas land, the
  `getter`/`putter` helpers there are replaced by `lambda`).
- [ ] 15f Order step 8.2, after 8d. The compiler prelude and the Enumerable
  methods on `List` and `Map` (§25.6), with no new aliases: `select`, `collect`,
  `detect`, `inject` and `reject` get `CHECK-UNKNOWN-METHOD` with the canonical
  form. Adds the public builtin `String.compare(a, b) -> Int` (-1, 0 or 1, by
  code point, as `sort`) for String keys of `min_by`/`max_by`; a NaN key never
  wins unless every key is NaN, and ties go to the first element (tests for
  both). The prelude modules are always linked, checked once at build time with
  the result cached next to the embedded source, and `lower.rkt` emits only the
  prelude functions the checked program reaches. Runtime errors in prelude code
  are reported at the user's call or argument (the outermost frame of the
  innermost run of prelude frames; `__fail_arg`, a prelude-only intrinsic), and
  prelude frames are skipped in stack traces. User calls into the prelude, and
  prelude calls of the user's `Fn`, never lower to `tail-call`. Every prelude
  function is O(n) plus callbacks on the 8d lists (`push`, `set` and indexing
  O(log32 n)): bodies build with `push` or on `map`/`filter`/`reduce`, never
  call `concat`, `take`, `drop`, `reverse`, `sort`, `sort_by`, `Map.keys`,
  `Map.values` or `Map.delete` in a loop (a lint test checks this), list each
  cost in the `grammar.md` table, and have a 100,000-element golden with its
  step count. A bytecode format version bump: `src/bytecode.rkt` writes a
  prelude flag on each function, the argument spans on prelude calls, and one
  name-only source entry per prelude file whose single span every prelude
  instruction uses; the VM replaces that span at run time in every reader of
  spans (step limit, runtime diagnostics, tracing, stack traces); `__fail_arg`
  is a builtin that the loader (`vm/loader.c`) rejects outside prelude
  functions. Docs: `grammar.md`, `references/builtins.md`,
  `site/content/library/data-structures/list.md`, `map.md` and `string.md`, the
  development skill, `docs/vm/03-ir-and-bytecode.md` (with the §4.5 sentence
  "There are no internal helper builtins") and `docs/vm/08-loader-and-cli.md`.
- 15g `unless` and 15h statement modifiers: not planned, see §25.13 (second ways
  to write `if`; `unless c` gets a help that shows `if !c ... end`, and section
  11's help for modifiers stays).
- [ ] 15i `File.open(path, mode, timeout_ms) do |f| ... end` closes the handle
  when the block ends (§25.9), and the builtin
  `File.eof?(handle, timeout_ms) -> Result[Bool]`, so the canonical example does
  not match error text. `try` in the block uses the checker rule for builtins
  whose block result is `Result[T]`, when `T` is inferred, which the first of
  17a (§27.1) and this item adds, the other reusing it; 17d added only the
  completion-value check and its help. The block form becomes the canonical way
  to use a file handle in the skill and the site. The block follows phase 16
  (`CHECK-UNUSED-VARIABLE`, `CHECK-UNREACHABLE-CODE`, `CHECK-UNUSED-RESULT`; the
  lowered close is never reported), with tests. Docs: `grammar.md`,
  `references/files.md`, `site/content/library/io-and-system/files.md`.
- [ ] 15j Heredocs `<<~NAME` (§25.10): the lexer, with today's token kinds and a
  `heredoc?` field on the token, carried to the parser's string node as a flag
  (added here); `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT`,
  `LEX-HEREDOC-ONE-LINE` (a heredoc is the canonical form for two or more
  lines); a heredoc in a `case` pattern or an import path is
  `PARSE-UNEXPECTED-TOKEN`. Docs: `grammar.md`, the programming skill (with
  `references/diagnostics.md`), `site/content/tour/strings.md`.
- [ ] 15k Order step 8.2, after 15f. `format("...", args)` with a literal format
  checked at compile time (§25.11): `CHECK-FORMAT-LITERAL` (also for a heredoc),
  `CHECK-FORMAT-SPEC`, a catalog entry for `format` with a "checker-handled,
  variadic" marker (so the linker keeps the name in imported modules), the
  prelude `format.agc` and the prelude-only `__float_fixed` builtin (a catalog
  entry with the prelude-only flag, like `__fail_arg`); bare `%s`/`%d` formats
  get a help that shows interpolation (`CHECK-FORMAT-SPEC`). Breaking change: a
  user `def format` becomes `CHECK-REDEFINED-NAME` (say so in the changelog).
  Docs: `grammar.md`, `references/builtins.md` and `references/diagnostics.md`,
  `site/content/library/text-and-data/string.md` and `numbers.md`,
  `docs/vm/03-ir-and-bytecode.md` §4.5 ("There are no internal helper
  builtins").
- [x] 15l Pipe operator `|>` (§25.14). Order row 7.2.1g, after channels (row
  7.2.1e), decided by the owner on 2026-10-14. The lexer gets a `|>` token. The
  parser gets a binary level between `+ -` and the comparisons; it builds the
  ordinary call with the left value as argument 0 and a `piped` marker.
  `PARSE-PIPE-TARGET` comes from the parser, and `CHECK-PIPE-METHOD` from the
  checker, for a builtin that has a method form for the left value's type. No
  lowering or VM change. Tests: lexer, parser and checker tests that assert
  codes and spans, one golden fixture, a site example. Docs: `grammar.md` (04,
  05 and 07), the programming skill (with `references/diagnostics.md`),
  `site/content/tour/functions.md`. Done: the `pipe-forward` token in
  `src/lexer.rkt`; `parse-pipe` in `src/parser.rkt` (a level between `+ -` and
  the comparisons) builds the ordinary `call` with the left value as argument 0
  and sets the new `piped` field of `call` (`src/ast.rkt`, kept by
  `src/modules.rkt`); `PARSE-PIPE-TARGET` also covers a call without parentheses
  (`x |> gets`) and a call that is already piped; `check-pipe-method!` in
  `src/checker.rkt` raises `CHECK-PIPE-METHOD` at the call span after the call
  checks, so an ordinary type or arity error comes first. Tests:
  `tests/lexer-test.rkt`, `tests/parser-test.rkt`, `tests/checker-test.rkt`, the
  golden `pipe-chain`, and the example in `site/content/tour/functions.md`.

**Done when:** each item's site examples run on the VM, and an evaluation round
shows the new forms checked and used by agents with the same diagnostic quality
as the forms they replace.
