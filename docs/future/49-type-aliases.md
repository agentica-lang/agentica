## 49. Type aliases

**Status:** 49a built; 49b planned (roadmap phase 30,
[`docs/roadmap/30-type-aliases.md`](../roadmap/30-type-aliases.md), row 7.12). A
type alias gives a long type a short name, written once
(`type Grid = List[List[Float]]`). The 49a rules are in the grammar: the
`alias_decl` production and the declaration order in
[`05-syntax.md`](../grammar/05-syntax.md), transparency, cycles and the
constructor and pattern errors in
[`06-semantics.md`](../grammar/06-semantics.md#enums-and-pattern-matching),
export, import and rename in [`05b-modules.md`](../grammar/05b-modules.md), and
the codes with their spans in
[`07-diagnostics.md`](../grammar/07-diagnostics.md).
The owner decided the three questions of §49.5 on 2026-10-16: the keyword is
`type` (contextual at the top level only), a diagnostic prints the expanded
type, and an exported alias may name a private type. All three are grammar
rules now.

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
the bytecode writer and the VM do not change, because a transparent alias
reaches them as the type it names.

### 49.7 Implementation order

49b is one PR in `compiler/` only, with its own tests and docs. It needs no
refresh of `bootstrap/stage0.agcb` while `compiler/` does not use aliases. If
`compiler/` starts to use them, the syntax takes the two steps of
[§18.2](18-front-end-language.md#182-bootstrap) for new syntax: one PR teaches
the compiler the syntax and refreshes stage0, and a later PR uses it.
