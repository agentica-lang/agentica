## Phase 15: Ruby typed idioms

Requirements and full rationale: [future spec
§25](../future/25-ruby-typed-idioms.md#25-ruby-typed-idioms), Part A. One PR per
item; migration, docs, tests and acceptance details live in that spec. Part B
(§25.12) is deferred; Part C (§25.13) records decisions against `unless` and
statement modifiers. Ten items are planned; 15g and 15h are not.

Order: 15a follows the bootstrap (7.5a); 15b, 15d, 15e, 15i and 15j follow phase
16 (7.6); 15f and 15k follow faster lists (8.2). Exceptions: 15c landed before
bootstrap because the compiler uses immutable struct updates; 15l landed after
channels (7.2.1g). Library additions are `String.compare`, `File.eof?`, and
prelude-only `__fail_arg` and `__float_fixed`.

- [x] 15a Default parameters, built after the bootstrap. Missing args
  are filled at the call site; enum defaults resolve in the declaring module.
  `std/logger` migrated from `_meta` functions to a `fields` default (breaking).
  Compiler code still needs the two-step stage0 refresh before using defaults.
- [ ] 15b Re-exports (§25.2), linker only. Re-exporting an alias counts as using
  it for phase 16's unused-import check.
- [x] 15c Struct update `value.with(field: x)`, built early because the
  compiler uses immutable struct updates. Adds `STRUCT_WITH` and bytecode format
  v4; forbids `Fn` fields named `with` early so phase 10a stays non-breaking
  (`CHECK-REDEFINED-NAME`).
- [ ] 15d Value equality for structs, enums, lists, maps and Results (§25.4).
  Requires checker and VM equality changes, an explicit stack, and a bytecode
  version bump.
- [ ] 15e Standalone lambdas (§25.5). Follows phase 16; reserves `lambda`. Full
  block-target and diagnostic rules are in §25.5.
- [x] 15f Enumerable methods for List and Map, built after faster lists
  (8d). Adds `String.compare` for ordering String keys. Follow-up: precompile
  the prelude to avoid lexing and parsing it on every check (about 7–10 ms).
- 15g `unless` and 15h statement modifiers are not planned; see §25.13.
- [ ] 15i `File.open` block form and `File.eof?` (§25.9). Reuses phase 17a's
  `try`-in-block rule; body rules follow phase 16.
- [x] 15j Heredocs, built in the compiler after the bootstrap. Includes
  `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT` and `LEX-HEREDOC-ONE-LINE`; a
  heredoc is canonical for multiline text. The parser identifies heredocs from
  the token lexeme; a dedicated flag waits for 15k.
- [ ] 15k Compile-time checked `format` (§25.11), after 15f. Adds
  `CHECK-FORMAT-LITERAL` and `CHECK-FORMAT-SPEC`, plus prelude-only
  `__float_fixed`; reserves user-defined `format` (breaking).
- [x] 15l Pipe operator `|>`, ordered before phase 15. Builds an
  ordinary call with the left side as argument 0; `PARSE-PIPE-TARGET` and
  `CHECK-PIPE-METHOD`. No lowering or VM change.

**Done when:** site examples run on the VM and evaluation confirms agents use
the forms with the same diagnostic quality as the forms they replace.
