## Phase 13: Binary data

Specified in [`docs/future/23-binary-data.md` section
23](../future/23-binary-data.md#23-binary-data). Order row 7.2.4 (taken out of
row 7.5 by the owner on 2026-10-14): a new feature after 7i, VM-only, before the
freeze of the Racket front end (row 7.2.7), so the bytecode writer of the
self-hosted front end can use it
([§35.5](../future/35-self-hosting.md#355-language-and-vm-prerequisites)). UDP
(row 7.5) comes after this phase, since UDP programs pack their headers with
`std/binary`. This phase has no technical need for TCP or TLS: `std/` imports
already run on the VM, so it can move earlier if a real program needs it. It
follows the library rule (after the order table): the packing is a `std/` module
in Agentica, and the bit operations are builtins under its exception 5.

- [ ] 13a Builtins on the VM, in one PR (`docs/future/23-binary-data.md` §23.2
  to §23.4): `Int.bit_and`, `bit_or`, `bit_xor`, `bit_not`, `shift_left`
  (wraps), `shift_right` (arithmetic), `shift_right_unsigned` (logical), with
  `RUNTIME-INVALID-COUNT` for a negative count; `Float.to_bits`, `from_bits`,
  `to_bits32`, `from_bits32`, with the canonical NaNs and
  `RUNTIME-INVALID-NUMBER` for `from_bits32` outside `0 .. 4294967295`. With
  `grammar.md`, the programming skill,
  `site/content/library/text-and-data/numbers.md`, and the tests of §23.7
  (vm-diff fixtures, evaluator tests, Python vectors).
- [ ] 13b `std/binary` (`stdlib/binary.agc`, registered in `src/stdlib.rkt`),
  its own PR after 13a (`docs/future/23-binary-data.md` §23.5): readers and
  writers for `u8` to `i64`, `f32` and `f64` in both byte orders, `concat`, and
  the 4-byte length framing, written in Agentica on the 13a builtins. Docs: a
  "Binary data" part in `grammar.md` next to "String queue"; a
  `references/binary.md` file in the programming skill and its row in the "When
  to read a reference" table; a `site/content/library/text-and-data/binary.md`
  page (front matter `title` and `weight`, runnable examples that
  `tests/site-examples-test.rkt` checks). Tests (§23.7): the Python `struct`
  vectors checked in with their generator, round trips, error cases, both
  backends through the vm-diff fixtures, and the fixed-output check in
  `tests/std-binary-test.rkt`.
- Not in this phase: `Bytes` (`docs/future/12-data-structures.md` §12.5), which
  this work does not replace; when `Bytes` lands, the `std/binary` API moves to
  it together with the `*_bytes` builtins. No mutable buffers or references.

**Done when:** the Python vectors of 13a and 13b pass on the VM, what each
reader returns writes back to the same bytes (a NaN pattern other than the
canonical one aside), and the site page's examples run.

