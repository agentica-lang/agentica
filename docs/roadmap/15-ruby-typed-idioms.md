## Phase 15: Ruby typed idioms

Specified in [`docs/future/25-ruby-typed-idioms.md` section 25](../future/25-ruby-typed-idioms.md#25-ruby-typed-idioms), Part A. Order step 11.2, after 7i: every item changes the front end and `src/lower.rkt` and runs on the C VM only, never on the Racket evaluator. One small PR per item, each with `grammar.md`, the programming skill, the site page, the development skill's notes and tests (parser, lexer and checker tests that assert codes and spans, golden VM fixtures, site examples). The items are independent, except where noted. Library items follow the library rule (after the order table): their code is Agentica in the compiler prelude, and only `Float.to_fixed` is a builtin, under its exception 5. Part B (§25.12) and Part C (§25.13) add no items.

- [ ] 15a Default parameter values (§25.1): `CHECK-DEFAULT-ORDER`, `CHECK-DEFAULT-VALUE`, `CHECK-ARITY` with a range; `lower.rkt` fills the missing arguments at the call site. Docs: `grammar.md`, the programming skill, `site/content/tour/functions.md`.
- [ ] 15b Re-exports `export Alias.name` (§25.2), in the linker (`src/modules.rkt`) only. Docs: `grammar.md`, `references/modules.md`, `site/content/tour/modules.md`.
- [ ] 15c Struct update `value.with(field: x)` (§25.3). Docs: `grammar.md`, the programming skill, `site/content/tour/structs.md`.
- [ ] 15d Value equality for structs, enums, lists, maps and Results (§25.4): the checker rule and the VM's `EQ`/`NE` opcodes with an explicit stack. Docs: `grammar.md`, the programming skill, `site/content/tour/structs.md`, `docs/vm/`.
- [ ] 15e Standalone lambdas `lambda do |x: Int| ... end` (§25.5). Docs: `grammar.md`, the programming skill, `site/content/tour/blocks.md`, section 11.4.
- [ ] 15f The compiler prelude and the Enumerable methods on `List`, `Range` and `Map` (§25.6), with `select` as an alias of `filter`. Docs: `grammar.md`, `references/builtins.md`, `site/content/library/list.md`, `range.md` and `map.md`, the development skill.
- [ ] 15g `unless ... else ... end` (§25.7). Docs: `grammar.md`, the programming skill, `site/content/tour/control-flow.md`.
- [ ] 15h Statement modifiers `S if c` and `S unless c` (§25.8), with `CHECK-MODIFIER-BINDING`. Gated: an evaluation round with a second model must show that agents use them well before this item ships (section 11's rule). Needs 15g for `unless`.
- [ ] 15i `File.open(path, mode, timeout_ms) do |f| ... end` closes the handle when the block ends (§25.9). Docs: `grammar.md`, `references/files.md`, `site/content/library/files.md`.
- [ ] 15j Heredocs `<<~NAME` (§25.10), lexer only: `LEX-UNTERMINATED-HEREDOC`, `LEX-HEREDOC-INDENT`. Docs: `grammar.md`, the programming skill, `site/content/tour/strings.md`.
- [ ] 15k `format("...", args)` with a literal format checked at compile time (§25.11): `CHECK-FORMAT-LITERAL`, `CHECK-FORMAT-SPEC`, the prelude `format.agc` and the `Float.to_fixed` builtin. Needs 15f (the prelude). Docs: `grammar.md`, `references/builtins.md`, `site/content/library/string.md` and `numbers.md`.

**Done when:** each item's site examples run on the VM, and an evaluation round shows the new forms checked and used by agents with the same diagnostic quality as the forms they replace.
