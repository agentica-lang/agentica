## 33. Digit separators

**Status:** planned (roadmap [phase 23](../roadmap/23-digit-separators.md)). Decided on 2026-10-12: number literals may use `_` between digits, as in Ruby and Elixir: `3_000`, `1_000_000`. It is front end only. It comes after 7i, right after doc comments (§33.5).

### 33.1 Today

Checked at `5622598`:

- `INTEGER = DIGIT, { DIGIT }` and `FLOAT = DIGIT, { DIGIT }, ".", DIGIT, { DIGIT }` (`docs/grammar/04-lexical.md`, "Literals"). The text says the core has no numeric separators (`docs/grammar/04-lexical.md`).
- The lexer reads a run of digits, then a `.` and more digits only when a digit follows the `.` (`src/lexer.rkt:195-207`). That is why `1..5` lexes as two integers around `..`, never as a Float (`docs/grammar/05-syntax.md`). The value is `string->number` of the lexeme (`src/lexer.rkt:206`).
- A name may start with `_` (`docs/grammar/04-lexical.md`, `src/lexer.rkt:169`). So `1_000` lexes today as the integer `1` and the name `_000`, and the parser stops with `PARSE-UNEXPECTED-TOKEN` at `_000`. No valid program today has a `_` right after the digits of a number.
- The lexer has five codes: `LEX-UNEXPECTED-CHAR`, `LEX-UNTERMINATED-STRING`, `LEX-INVALID-ESCAPE`, `LEX-UNCLOSED-DELIMITER`, `LEX-UNMATCHED-DELIMITER`.
- An `Int` literal above the 64-bit range is `CHECK-INT-RANGE` in the checker (`src/checker.rkt:468-472`).

### 33.2 Syntax

- `_` is allowed only between two digits, in `INTEGER` and in both parts of `FLOAT`: `1_000`, `1_000.000_5`. It is only visual: `1_000` is the same `Int` as `1000`.
- These forms are rejected with a new lexer code, `LEX-INVALID-NUMBER`:
  - a trailing `_`: `1_`, `1_000_`, also `1_a`;
  - a double `__`: `1__0`;
  - `_` next to the dot: `1_.5`, `1._5`.
- A `.` followed by `_` belongs to the number, so `1._5` is an error. Today it lexes as `1`, `.` and the name `_5`, a method call that no builtin has, so no valid program changes. A `.` followed by a letter or by another `.` still ends the number.
- The span covers the literal as written: the run of digits and `_`, plus a `.` followed by a digit or `_` and the run after it. So the span of `1__0` is all four characters, and that of `1_.times` is `1_`.
- `_1` stays a NAME, as today, because a number starts with a digit. `0.._n` is still a range up to the variable `_n`.
- New EBNF:

```ebnf
INTEGER    = DIGIT, { [ "_" ], DIGIT } ;
FLOAT      = DIGIT, { [ "_" ], DIGIT }, ".", DIGIT, { [ "_" ], DIGIT } ;
```

- The lexer drops the `_`s before it reads the value, so the token is the same `integer` or `float` token with the same value. A `case` pattern takes the same token: `1_000 ->` and `-1_000 ->` work.

```agentica
def main() -> Void
  budget = 1_000_000
  rate = 0.000_5
  puts(budget)
  puts(rate)
end
```

### 33.3 What does not change

- **Text form.** `IO.inspect`, `to_s` and interpolation print without separators: `puts(1_000)` prints `1000`, as in Ruby.
- **Conversions stay strict.** `String.to_int`, `String.to_float` (and their `!` forms) and JSON keep rejecting `_`. Ruby's `"1_000".to_i` gives `1000`, but Ruby's `to_i` is lenient in general (`"12abc".to_i` is `12`). Agentica's conversions read outside data (input, files, HTTP), which has one strict number format, and JSON forbids `_`. A separator is for people who write code, not for data.
- **Range checks.** `9_223_372_036_854_775_808` is still `CHECK-INT-RANGE` at the literal.
- **Lexing next to dots and signs.** These lex as expected and are test cases in 23a:
  - `1_000.times do |i| ... end`: the integer `1000`, then `.times`;
  - `1_000..2_000` and `1_000...2_000`: two integers around the range operator;
  - `x = -1_000`: the minus operator, then the integer `1000`.

### 33.4 The §25 test

[§25](25-ruby-typed-idioms.md#25-ruby-typed-idioms) rejects a form when it only renames or re-spells a call or a statement, so there is one way to write each thing. A digit separator is not a second way to call or write a statement. It is a lexical aid inside one token, like the space between operators, that makes long numbers readable. Every Ruby or Elixir user expects it, and agents write it. Without it they get a parse error at `_000` that helps nobody.

### 33.5 Order

- **Front end only:** the lexer and the docs. The token value is the same `Int` or `Float`, so the AST, the checker, lowering, the bytecode, and the VM do not change.
- **When:** decided by the user on 2026-10-13, 23a comes after 7i, right after phase 22 (22a, 22b), at roadmap order step 7.2a, before `Task.map` and channels (order step 7.3). It is no longer an exception to "new features are VM-only and come after 7i".
