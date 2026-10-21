## 49. Type aliases

**Status:** 49a and 49b built (row 7.12). A
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

The rules are in the grammar (`type_parameters` and "generic alias" in
[`05-syntax.md`](../grammar/05-syntax.md)). Decisions kept here:

- **An unused parameter is allowed.** As for enums, and the language does not
  report unused names. This replaces the earlier plan of a
  `CHECK-TYPE-ALIAS-PARAM` code; no new code was added.
- **The count.** A wrong count uses an existing code: `CHECK-UNKNOWN-TYPE`, as
  an enum with the wrong number of arguments gets today (`resolve_generic` in
  `compiler/check/check_types.agc`). The checker has no separate code for the
  arity of a type, and this part adds none.
- **Not in 49b.** No higher-kinded parameters (a parameter applied to
  arguments, as `T[Int]`), no partial application (a use with fewer arguments,
  or the bare name), and no default type arguments.

### 49.4 What changes where

Only `compiler/` changes: the parser, the linker and the checker. Lowering,
the bytecode writer and the VM do not change, because a transparent alias
reaches them as the type it names.
