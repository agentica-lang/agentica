## Later extensions

- [ ] SIMD in the VM ([`docs/future/19-simd.md` section
  19](../future/19-simd.md#19-simd-in-the-vm)), on demand (order row 19). Using
  libc `memcpy`/`memcmp`/`memchr` in place of hand loops needs no profiling and
  can land at any time.
- [ ] Define normative designs for generics, methods, FFI, async, or actors
  before implementing them.

### Open decisions

- [ ] No structural unions (`Int | String`): they need flow-sensitive narrowing
  and duplicate the exhaustiveness work of enums. Sum types come from enums.
- [x] A builtin `Optional[T]` (special-cased like `Result[T]`) for nullable
  values: decided by the owner on 2026-10-30 (#831).
- [x] Front-end implementation language: decided by the owner on 2026-10-13:
  self-hosting, for one binary and a fast start, as an item in the roadmap order
  from row 7.2.7 on ([§18](../future/18-front-end-language.md)).
  Section 18 keeps the history of the question.

The open items in this section are outside the current implementation order.
