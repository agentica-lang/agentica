## Phase 30: Type aliases

Specified in [`docs/future/49-type-aliases.md` section
49](../future/49-type-aliases.md#49-type-aliases). Planned by the owner on
2026-10-16: simple aliases first (30a, §49.2), then generic aliases (30b,
§49.3), both before the path to the JIT. It is row 7.12 of the
[roadmap](README.md) order, after the other post-bootstrap language rows, and
it waits for nothing: the bootstrap is done. The three questions of §49.5 are
decided. Item 30b waits for 30a, because its parameters use the same parser and
checker paths.

- [x] **30a: simple aliases (§49.2).** `type Name = Type` and
  `export type Name = Type` at the top level, with `type` a contextual word.
  - **Syntax:** the `alias_decl` rule of `docs/grammar/05-syntax.md`, in the
    struct and enum group of the declaration order.
  - **Checks:** `CHECK-REDEFINED-NAME` for a collision, `CHECK-UNKNOWN-TYPE`
    for an unknown name or type arguments, `CHECK-TYPE-ALIAS-CYCLE` for a
    cycle, and `CHECK-TOO-DEEP` for expansions over 1,000 type references.
    Constructors and patterns written through an alias use the existing codes,
    with help that names the aliased type.
  - **Where:** `compiler/` only: the parser, the linker and the checker.
    Lowering, the bytecode writer and the VM do not change.
  - **Tests:** spec tests in `tests/test_spec_alias.py` (`--json check`, the
    code and the span), front-end goldens, a VM golden of a program that uses
    aliases and runs unchanged, and an example in `examples/`.
  - **Docs:** the grammar (`05-syntax.md`, `05b-modules.md`, `06-semantics.md`,
    `07-diagnostics.md`), the site pages on types and modules, the programming
    skill (`SKILL.md` and `references/language.md`), and a `CHANGELOG.md` entry
    under `[Unreleased]`.
- [ ] **30b: generic aliases (§49.3).** `type Name[T, ...] = Type`, with
  every parameter used on the right.
  - **Checks:** `CHECK-TYPE-ALIAS-PARAM` (proposed) for a parameter that is not
    used; a wrong number of type arguments is `CHECK-UNKNOWN-TYPE`, as an enum
    gets today. Expansion substitutes the arguments; no higher-kinded
    parameters, no partial application, no default type arguments.
  - **Core rule:** this item widens AGENTS.md's core grammar from "user enums
    (the only user generics)" to "user enums and type aliases", and changes
    the "only enums take type parameters" sentence of
    `docs/grammar/05-syntax.md`. Its PR says so and makes the AGENTS.md edit
    itself.
  - **Tests and docs:** the same kinds as 30a, for the generic cases.

Each item has its own PR, with its own tests and docs.

**Done when:** a program names a type once with an alias and uses it wherever
the type can stand, with the same results as the expanded type; and the tests
of §49.2 and §49.3 pass.
