## Later extensions

- [x] Faster maps (done before JSON, 5f): hash-backed maps with
  insertion-order keys; numbers stay in git.

  | Entries | Build before / after (ms) | Build+read before / after (ms) |
  |---|---|---|
  | 1,000 | 9.94 / 1.23 | 25.11 / 2.85 |
  | 10,000 | 869.56 / 12.59 | 2,200.83 / 29.21 |
  | 50,000 | 23,240.65 / 61.62 | 54,904.19 / 146.60 |

- [ ] SIMD in the VM ([`docs/future/19-simd.md` section
  19](../future/19-simd.md#19-simd-in-the-vm)), on demand: starts only if
  profiling (7j or phase 12) shows time in string, JSON or copy routines. Using
  libc `memcpy`/`memcmp`/`memchr` in place of hand loops needs no profiling and
  can land at any time.
- [ ] `Crypto` module ([`docs/future/20-crypto.md` section
  20](../future/20-crypto.md#20-crypto-module)), on demand: after TLS on the VM
  (7h) and `Bytes`; VM only if it lands after 7i. Started: `Crypto.sha256` on
  `List[Int]` (#455), for the package hash.

### Enums and pattern matching: implemented

- [x] Specify generic enums, enum-qualified variants, and qualified imported
  names (`Domain.Option.Some`).
- [x] Implement Elixir-inspired `case expression do ... -> ... end` as a
  statement, with literal and variant patterns, direct bindings, `_` payload
  discards, and arm-local scopes.
- [x] Check generic constructor inference, enum and builtin Result
  exhaustiveness, wildcard requirements for non-enums, and unreachable arms.
- [x] Add parser, checker, evaluator, and module-linker regression tests; move
  normative syntax to `grammar.md` and mirror it in the programming reference
  and development skill.
- [ ] Define normative designs for interpolation, generics, methods, FFI, async,
  or actors before implementing them. Modules/imports have an explicit place in
  the current implementation order; error propagation is already implemented in
  5e.
- [x] Complete lightweight I/O concurrency before networking in phase 5j2.
  Channels are built
  ([§27.2](../future/27-iteration-and-concurrency.md#272-channels)); CPU
  parallelism remains unscheduled, and its remaining decisions are in
  [§27.6](../future/27-iteration-and-concurrency.md#276-open-questions).

### Open decisions

- [ ] No structural unions (`Int | String`): they need flow-sensitive narrowing
  and duplicate the exhaustiveness work of enums. Sum types come from enums.
  After Phase 6, decide whether agents need a builtin `Option[T]` (special-cased
  like `Result[T]`) for nullable values.
- [x] Front-end implementation language: decided by the owner on 2026-10-13:
  self-hosting, for one binary and a fast start, as an item in the roadmap order
  from row 7.2.7 on ([§18](../future/18-front-end-language.md)).
  Section 18 keeps the history of the question.

The open items in this section are outside the current implementation order.
