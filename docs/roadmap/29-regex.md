## Phase 29: Regular expressions

Specified in [`docs/future/48-regex.md` section
48](../future/48-regex.md#48-regular-expressions). Decided by the owner on
2026-10-15: a regular expression library, `std/regex`, with a linear-time
matcher and no backtracking, and then a regex literal, `/pattern/flags`. Its
items keep the numbers of §48.9 (48a to 48d). It is row 7.10 of the
[roadmap](README.md) order and waits until after the bootstrap of the
self-hosted front end ([§18](../future/18-front-end-language.md), step 8).
The open questions of §48.10 (1, 2, 3 and 4) need the owner's answers before
the items that depend on them.

- [ ] **48a: `std/regex` in Agentica (§48.3 to §48.5, §48.7, §48.8).**
  - **Std module:** `stdlib/regex.agc`, embedded as `std/regex` and registered
    like `std/toml`. Pure Agentica: no builtin and no VM change.
  - **Tests:** goldens in `tests/fixtures/vm/`, the Python peer in
    `tests/test_regex.py`, the ReDoS budget test, and the benchmark pair in
    `benchmarks/`.
  - **Docs:** the site page `site/content/library/text-and-data/regex.md`, the
    programming skill (the "no regex" line in `SKILL.md`, `references/regex.md`
    and its row), and a `CHANGELOG.md` entry under `[Unreleased]`.
- [ ] **48b: the regex literal (§48.6; questions 3 and 4 of §48.10).**
  - **Syntax:** `/pattern/flags` with the flags `i` and `m`; the lexer rule and
    the cases of §48.6; `#{` is an error. The value has the type `Regex.Regex`,
    and a file that uses a literal imports `std/regex` in any form.
  - **Checks:** `CHECK-INVALID-REGEX` at the literal's span,
    `CHECK-REGEX-IMPORT` without the import, and the lexer errors
    `LEX-UNTERMINATED-REGEX`, `LEX-REGEX-FLAG` and `LEX-REGEX-INTERPOLATION`.
    The diagnostic code names are proposals until this item lands. Each literal
    is a constant, built before `main`.
  - **Where:** `compiler/` only, after the bootstrap. The Racket front end gets
    no change, as §18 and row 7.2.7 require.
  - **Tests:** lexer goldens for each case of §48.6, a golden for each new code
    with its span, and a check that a literal equals `Regex.compile` of the same
    body with its flags mapped.
  - **Docs:** `docs/grammar/04-lexical.md`, `06-semantics.md`,
    `07-diagnostics.md`, the site page section and the programming skill. The
    site page and the skill state the Ruby differences of §48.6 next to the
    literal.
- [ ] **48c: C matcher, only if the 48a numbers ask for it (§48.3).** A stepper
  behind the same API, with one STEP per resume. The PR records the numbers and
  the threshold.
- [ ] **48d: Unicode classes and case folding (§48.4, §48.10 decision 5).** The
  tables are generated like `vm/unicode_data.c`. Whether the generator, which is
  Racket, stays after the bootstrap is open (§18).

Each item has its own PR, with its own tests and docs. 48b waits for 48a,
because the literal's checker runs the parser of `std/regex`.

**Done when:** a program searches, extracts, replaces and splits text with a
pattern, given as a literal or as a string; a pattern cannot stall the VM beyond
its step budget; and the tests of §48.6 and §48.8 pass.
