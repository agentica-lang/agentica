## 49. Type aliases

**Status:** planned (owner, 2026-10-16). Two parts: simple aliases (49a), then
generic aliases (49b). Roadmap row 7.12 and phase 30
([`docs/roadmap/30-type-aliases.md`](../roadmap/30-type-aliases.md)) record it.
Nothing is implemented. The owner decided the three questions of 49.5 on
2026-10-16, with the recommendations of this section.

### 49.1 Goal and why

A type alias gives a long type a short name, written once:

```ruby
type Grid = List[List[Float]]
```

A `Grid` is a `List[List[Float]]`, and nothing else changes. The alias is
transparent: it adds no runtime cost and no conversion.

Long types repeat. `Map[String, List[Toml.Value]]` in a signature, a field and
a `JSON.decode` call is three copies that change together. An alias names the
type once. Agentica has no way to do this today: structs are not generic, and
only enums take type parameters.

A struct wrapper is the alternative when a distinct type is wanted, a newtype:
`struct Board` with one field is a different type with its own name, and its
value is unwrapped by hand. An alias is not a newtype. The two stay separate
tools, and this section does not add the second one.

### 49.2 Part 49a: simple aliases

The grammar gets one rule, next to `struct_decl` and `enum_decl` in
`docs/grammar/05-syntax.md`:

```ebnf
alias_decl       = [ "export" ], "type", TYPE_NAME, "=", type, NL ;
```

`type` is a contextual word. The parser reads it by its text at the start of a
top-level declaration, as it reads `from` and `as` in imports
(`compiler/parser.agc`, `expect_word` at lines 2011 and 2030, and the `as`
check at line 2099). The lexer's keyword table does not change
(`compiler/lexer.agc`, `WORD_ACTIONS` at line 21). The right side is any type,
as in section 5.

A doc block in front of an alias is allowed, as it is for `struct` and `enum`.

**Declaration order.** The fixed order of section 5 is: the module doc and the
imports, then the constants, then the `struct` and `enum` declarations in any
order among themselves, then `export def`, then private `def`. An alias is in
the `struct` and `enum` group. It may come before or after any struct or enum
of the file. A constant after an alias, or an import after one, is
`CHECK-DECL-ORDER`. The alias is one line, so the blank-line rule of the
declarations applies as it does to a struct: a blank line goes before the next
`struct`, `enum` or `def`.

**Semantics.**

- **Name.** `Grid` is a type name (a capital first letter). It may not be the
  name of a struct, an enum, a builtin type (the reserved names of
  `docs/grammar/04-lexical.md`), an import alias or another alias. That is
  `CHECK-REDEFINED-NAME`, at the name.
- **Transparent.** `Grid` and `List[List[Float]]` are one type everywhere: in
  assignments, arguments, returns, `==`, and as the type argument of
  `JSON.decode`. Diagnostics print the expanded type (49.5, decision 2).
- **Right side.** Any type: a builtin generic (`List[Int]`,
  `Map[String, Int]`), a struct, an enum with its arguments
  (`type Names = List[String]`, `type Res = Result[Int]`), another alias, or a
  function type `Fn[...]`. The linker resolves the right side in the declaring
  module, so an importer's aliases do not change it.
- **Not a constructor, not a pattern.** `Grid(...)` is an error, also when
  `Grid` names a struct. A variant built or matched through an alias
  (`Shape.Circle(1.0)`, or `Shape.Circle(r)` in a pattern) is an error too.
  The existing codes carry these: a constructor gets `CHECK-UNKNOWN-TYPE`
  (`compiler/check_call.agc`, "is not a declared struct", line 438), a variant
  of an unknown enum gets `CHECK-UNKNOWN-TYPE` (line 60), and a pattern gets
  `CHECK-PATTERN-TYPE` (`compiler/check_stmt.agc`, line 493). Each gets a help
  that names the type the alias stands for.
- **No methods.** An alias has no methods of its own. A value of the alias has
  the methods of the type it names: `grid.size` is the `List` method.
- **Cycles.** `type A = List[A]`, or `A` to `B` and back to `A`, is
  `CHECK-TYPE-ALIAS-CYCLE` (a proposed code), at the name that closes the cycle.
  The help is `the cycle is A -> B -> A`, as `CHECK-CONSTANT-CYCLE` gives for
  constants (`docs/grammar/06-semantics.md`).
- **Export and import.** `export type Grid = ...` exports the alias. An
  importer writes `Models.Grid` in annotations, as it writes `Models.User`, or
  imports it by name, `{Grid}`, or renames it, `{Grid as Board}`. A renamed
  alias gets a type name, by the case rule of `docs/grammar/05b-modules.md`.
  A private alias cannot be imported (`CHECK-IMPORT-NAME`).
- **Exported aliases that name private types.** Decided in 49.5, decision 3.

Proposed codes are names only until the PR lands. `CHECK-REDEFINED-NAME` and
`CHECK-UNKNOWN-TYPE` are the existing codes for collisions and unknown names.

### 49.3 Part 49b: generic aliases

```ruby
type Matrix[T] = List[List[T]]
export type Pairs[K, V] = List[Map[K, V]]
```

- **Parameters.** Type names in brackets, as the parameters of an enum
  (`type_parameters` in section 5). A parameter name follows the enum rule: a
  reserved name is `CHECK-REDEFINED-NAME`.
- **Every parameter is used.** A parameter that does not appear on the right
  side is `CHECK-TYPE-ALIAS-PARAM` (a proposed code), at the parameter.
- **The count.** A use gives exactly as many type arguments as the alias has.
  A wrong count uses an existing code: `CHECK-UNKNOWN-TYPE`, as an enum with
  the wrong number of arguments gets today (`resolve_generic` in
  `compiler/check_types.agc`). The checker has no separate code for the arity
  of a type, and this part adds none.
- **Expansion.** The arguments are substituted for the parameters:
  `Matrix[Int]` is `List[List[Int]]`. It is still transparent.
- **Not in 49b.** No higher-kinded parameters (a parameter applied to
  arguments, as `T[Int]`), no partial application (a use with fewer arguments,
  or the bare name), and no default type arguments.
- **The core rule changes.** AGENTS.md's core grammar says "user enums (the
  only user generics)". 49b widens it to "user enums and type aliases", and
  `docs/grammar/05-syntax.md` says "only enums take type parameters", which
  changes too. The 49b PR says so. This design does not edit AGENTS.md; that
  edit lands with 49b.

### 49.4 What changes where

Only `compiler/` changes: the parser, the linker and the checker. Lowering,
the bytecode writer and the VM do not change. A transparent alias reaches them
as the type it names, so the bytecode format does not change.

### 49.5 Decisions

The owner decided these on 2026-10-16, with the recommendations of this
section.

1. **The keyword.** `type Name = ...` is the form, with `type` a contextual
   word at the top level only. A bare `Name = Type` is rejected: it would parse
   like a constant (`NAME = value`), and a type name and a constant name differ
   only by case. `type` is common as a name in the source, so reserving it is
   not an option. The word `type` appears in 56 `.agc` files, as a parameter
   (`type: String` in `stdlib/binary.agc`, line 272), as a named argument or a
   field (`State.Out(st: ..., type: target.type)`, `compiler/check_call.agc`,
   line 142), as a field read (`node.type`, `compiler/rewrite.agc`, line 53)
   and as a local (`type = declared`, `compiler/check_stmt.agc`, line 181). A
   reserved word would break all of them. A contextual word breaks none: no
   top-level line starts with `type` today, and the parser already reads
   `from` and `as` by their text.
2. **Diagnostics.** In 49a, a diagnostic prints the expanded type, so the
   message reads `expected List[List[Float]]` for a `Grid`. The alias name may
   be printed in a later step.
3. **Exported aliases that name private types.** An exported alias may name a
   private type, as an exported signature may (`docs/grammar/05b-modules.md`).
   An importer can use its values, but cannot name or construct the private
   type.

### 49.6 Tests and docs

Tests:

- Spec tests through the CLI, `--json check`, asserting the code and the span
  and never the text, in `tests/test_spec_alias.py`: the rules of 49.2 and
  49.3.
- Front-end goldens (`make goldens`).
- A VM golden in `tests/fixtures/vm/`: a program that uses aliases runs
  unchanged, with the output of the same program written with the expanded
  types.
- An example in `examples/`, listed in `examples/README.md`.

Docs:

- `docs/grammar/05-syntax.md` (the `alias_decl` rule, the declaration order,
  and the "only enums take type parameters" sentence in 49b),
  `05b-modules.md` (export, import, rename), `06-semantics.md` (the types, and
  the transparency rule) and `07-diagnostics.md` (the codes, with their spans).
- The Hugo site: the pages on types and on modules (`make site` before the
  merge).
- The programming skill: the core rule in
  `.agents/skills/agentica-programming/SKILL.md` (about 2,000 tokens) and
  `references/language.md`.
- `CHANGELOG.md` under `## [Unreleased]`, for 49a and for 49b. Neither is
  breaking.

### 49.7 Implementation order

49a and then 49b, each one PR in `compiler/` only (parser, linker, checker).
Each PR holds its own tests and docs.

Neither PR needs a refresh of `bootstrap/stage0.agcb` while `compiler/` does
not use aliases. If `compiler/` starts to use them, the syntax takes the two
steps of [§35.3](35-self-hosting.md#353-bootstrap) for new syntax: one PR
teaches the compiler the syntax and refreshes stage0, and a later PR uses it.
