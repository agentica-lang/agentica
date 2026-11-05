## 48. Regular expressions

`std/regex` (a Pike VM in `stdlib/regex.agc`, with a C matcher in
`vm/regex.c`) and the regex literal are built; the grammar and the site's regex
page are the contract. This file keeps what is still planned and the decisions
that bound it.

### 48.9 Phase 48d: Unicode classes and case folding

Issue #990. `\p{L}`, `\pN` and scripts (`\p{Greek}`) are a compile error today,
and `(?i)` folds ASCII only. 48d adds the Unicode classes and `(?i)` with simple
Unicode folding. The tables are generated from the pinned Unicode Character
Database files by an Agentica program, byte for byte equal to what
`vm/unicode_data.c` holds (issue #1008; see the header of that file).

### 48.10 Decisions that stay

Decided by the owner on 2026-10-15:

- The engine is a Pike VM: linear time, no backtracking, leftmost-first. Not
  PCRE2 or Oniguruma (backtracking, a new submodule) or libc `regcomp`.
- Std first: `Regex` is a std module, not a builtin; C only where measured.
- Offsets are characters, as `index_of` and `slice` count. Case folding is
  ASCII today and simple Unicode in 48d, with no locale rules.
- Templates use `$` (`$N`, `${name}`, `$$`), not `\1`.
- Raw string literals are not planned.
- A match is the plain structs `Match` and `Group`, not an opaque `Match` with
  accessors or a builtin record.
- Module functions (`Regex.find_all(text, re)`), not methods on `String`.
- The file that uses a literal imports `std/regex` in any form or gets
  `CHECK-REGEX-IMPORT`; no implicit load.
- Ruby's anchors and `m`: text anchors and dot-all `m`, with the warning in the
  site page and the skill. Not line anchors in the literal only (one syntax with
  two meanings).
