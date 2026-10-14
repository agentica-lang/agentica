## Phase 23: Digit separators

Specified in [`docs/future/33-digit-separators.md` section
33](../future/33-digit-separators.md#33-digit-separators). Phase 23 is front end
only: the lexer and the docs. The token value does not change, so the AST, the
checker, lowering and the VM stay as they are. It comes after 7i (§33.5), right
after phase 22 (22a, 22b), at order step 7.2a. It has one PR.

- [x] **23a: `_` between digits in number literals (§33.2, §33.3).**
  - **Lexer** (`src/lexer.rkt`): read digits and `_` in both parts of a number,
    drop the `_`s for the value, and report `LEX-INVALID-NUMBER` at the
    literal's span for a trailing `_`, a `__` or a `_` next to the dot. A `.`
    followed by `_` counts as part of the number, so `1._5` is an error; a `.`
    followed by a letter or a `.` does not.
  - **Tests:**
    - `tests/lexer-test.rkt`:
      - valid forms and their values: `1_000`, `1_000_000`, `1_000.000_5`,
        `0.5_5`;
      - each invalid form with its code and span: `1_`, `1_a`, `1__0`, `1_.5`,
        `1._5`, and in a Float's fractional part `1.5_` (trailing) and `1.5__5`
        (double);
      - `1_000.times`, `1_000..2_000`, `1_000...2_000` and `-1_000` give the
        same token kinds as without `_`;
      - `_1` and `0.._n` keep `_1` and `_n` as names.
    - A golden fixture (`tests/fixtures/vm/digit-separators.agc` and its
      `.expected`) that prints a few separated literals, a range and
      `String.to_int("1_000")`, which stays an error, and has one `case` with a
      `1_000 ->` arm and one with a `-1_000 ->` arm.
  - **Docs:**
    - `docs/grammar/04-lexical.md`: the `INTEGER` and `FLOAT` EBNF, the sentence
      that says there are no numeric separators, and the lexical rules;
    - the programming skill: one line in the lexical part of `SKILL.md`, and
      `LEX-INVALID-NUMBER` in the lexer-code table of
      `references/diagnostics.md` (around line 19);
    - `site/content/tour/numbers.md`: a short section with a complete runnable
      example and its `output` block;
    - the development skill: `references/stages.md`, the lexer notes and
      `LEX-INVALID-NUMBER` in its lexer-code table (around line 53).
  - CHANGELOG: an entry under `[Unreleased]` for any user-visible change.

**Done when:** `1_000` and `1_000.000_5` lex to `1000` and `1000.0005`, the
invalid forms give `LEX-INVALID-NUMBER` at their span, and the golden fixture
and the site example pass.
