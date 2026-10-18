## Phase 16: Strict diagnostics

Requirements and rationale: [future spec
§26](../future/26-strict-diagnostics.md#26-strict-diagnostics). Agentica has
errors, not warnings. Four front-end-only items; bytecode and VM do not change.
Each item is a breaking change: migrate affected programs and follow the spec's
tests, spans, docs and changelog requirements. No flag disables these checks.

Order: after evaluator removal (7i), before phase 15 items 15b–15e and 15i–15j.
Phase 17's `Task.map`, channels, HTTP streaming and `TlsContext` land first.
Implement in order 16a, 16c, 16b, 16d: 16b follows 16c so dead-code reads are
already rejected; 16d follows 16b because its discard form is `_ = f(...)`.

- [ ] 16a `CHECK-UNUSED-IMPORT` (§26.1), in the linker. An alias must resolve
  through a member of its module; the check covers `std/` and `pkg/`. A
  misspelled name that is neither a declared alias nor a builtin skips this
  check so the checker can report `CHECK-UNKNOWN-NAME`. A one-part alias used as
  a type or enum name gets `CHECK-IMPORT-NAME` with a suggested member.
  Package authors must remove unused imports.
- [ ] 16b `CHECK-UNUSED-VARIABLE` (§26.2), in the checker. Reject unread local,
  loop, block and pattern bindings; underscore-prefixed names are exempt. Bare
  `_` discards a value; reading it is `CHECK-UNKNOWN-NAME`. Function
  parameters are exempt. No flow analysis: reassignment before a read is not
  reported.
- [ ] 16c `CHECK-UNREACHABLE-CODE` (§26.3), in the checker. Reject statements
  after `return`, `break`, `next`, or a fully terminating `if`/`case`, with a
  secondary span on the terminator. `while true`, `try` and `System.exit` are
  not terminators.
- [ ] 16d `CHECK-UNUSED-RESULT` (§26.4), in the checker. Reject dropped `Result`
  values, except `IO.inspect`. Help offers `try`, a `case`, `.unwrap!`, or the
  explicit discard `_ = f(...)`; `CHECK-UNUSED-VALUE` remains for other unused
  values.

**Done when:** all four codes are documented in the grammar, programming skill
and site; repo programs are migrated; no code disables the checks.
