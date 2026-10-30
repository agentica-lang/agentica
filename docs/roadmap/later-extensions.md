## Later extensions

- [x] Faster maps (done before JSON, 5f): hash-backed maps with
  insertion-order keys.
- [ ] SIMD in the VM ([`docs/future/19-simd.md` section
  19](../future/19-simd.md#19-simd-in-the-vm)), on demand (order row 19). Using
  libc `memcpy`/`memcmp`/`memchr` in place of hand loops needs no profiling and
  can land at any time.
- [ ] `Crypto` module ([`docs/future/20-crypto.md` section
  20](../future/20-crypto.md#20-crypto-module)), on demand: after TLS on the VM
  (7h). `Bytes` is done (#805). Started: the `Digest` hashes on `Bytes` (#455,
  #757), SHA-256 for the package hash, and `SecureRandom` (#757).

### Enums and pattern matching: implemented

- [x] Generic enums, enum-qualified variants, qualified imported names
  (`Domain.Option.Some`) and `case expression do ... -> ... end` with
  exhaustiveness checks; the rules are in the grammar.
- [ ] Define normative designs for generics, methods, FFI, async, or actors
  before implementing them.
- [x] Complete lightweight I/O concurrency before networking in phase 5j2.
  Channels are built
  ([§27.2](../future/27-iteration-and-concurrency.md#272-channels)); the
  remaining decisions are in
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
