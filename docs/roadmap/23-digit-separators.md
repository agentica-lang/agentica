## Phase 23: Digit separators

Specified in [`docs/future/33-digit-separators.md` section 33](../future/33-digit-separators.md#33-digit-separators). Phase 23 is front end only: the lexer and the docs. The token value does not change, so the AST, the checker, lowering, the VM and the evaluator stay as they are, and it goes before 7i (§33.5): right after phase 22 (22a, 22b) and before HTTP 20b. It has one PR.

- [ ] **23a: `_` between digits in number literals (§33.2, §33.3).**
  - **Lexer** (`src/lexer.rkt`): read digits and `_` in both parts of a number, drop the `_`s for the value, and report `LEX-INVALID-NUMBER` at the literal's span for a trailing `_`, a `__` or a `_` next to the dot. A `.` followed by `_` counts as part of the number, so `1._5` is an error; a `.` followed by a letter or a `.` does not.
  - **Tests:**
    - `tests/lexer-test.rkt`:
      - valid forms and their values: `1_000`, `1_000_000`, `1_000.000_5`, `0.5_5`;
      - each invalid form with its code and span: `1_`, `1_a`, `1__0`, `1_.5`, `1._5`;
      - `1_000.times`, `1_000..2_000`, `1_000...2_000` and `-1_000` give the same token kinds as without `_`;
      - `_1` and `0.._n` keep `_1` and `_n` as names.
    - A golden fixture (`tests/fixtures/vm/digit-separators.agc` and its `.expected`) that prints a few separated literals, a range and `String.to_int("1_000")`, which stays an error.
  - **Docs:**
    - `docs/grammar.md`: the `INTEGER` and `FLOAT` EBNF (lines 103-104), the sentence that says there are no numeric separators (line 112), and the new code `LEX-INVALID-NUMBER`;
    - the programming skill: one line in the lexical part of `SKILL.md` and the code in `references/diagnostics.md`;
    - `site/content/tour/numbers.md`: a short section with a complete runnable example and its `output` block;
    - the development skill (`references/stages.md`, the lexer notes).
  - No CHANGELOG: the project adds none in the private alpha.

**Done when:** `1_000` and `1_000.000_5` lex to `1000` and `1000.0005`, the invalid forms give `LEX-INVALID-NUMBER` at their span, and the golden fixture and the site example pass.
