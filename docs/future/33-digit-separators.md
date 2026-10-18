## 33. Digit separators

**Status:** implemented as roadmap
[phase 23](../roadmap/23-digit-separators.md). Decided on 2026-10-12: `_`
between digits makes long source literals readable, without changing their
values or the format of numbers read from data. The normative lexer rules are
in the [grammar's literal section](../grammar/04-lexical.md#literals); this
section retains the design rationale and rollout.

### 33.1 Before the change

The old lexer read `1_000` as the integer `1` followed by the name `_000`.
No valid program used `_` immediately after a number, so accepting it did not
change a valid program's meaning.

### 33.2 Syntax

`_` is allowed only between digits in the integer or fractional part. A
trailing `_`, `__`, or `_` beside the decimal point is
`LEX-INVALID-NUMBER`; its span covers the literal as written. A dot followed by
`_` belongs to the malformed number, while a dot followed by a letter or
another dot ends it. `_1` remains a name, ranges such as `1_000..2_000` remain
ranges, and the minus sign remains an operator. Patterns use the same integer
token, so `1_000 ->` and `-1_000 ->` work in `case` arms. The grammar link above
has the EBNF and examples; phase 23 lists the invalid forms and span tests.

### 33.3 What does not change

The lexer drops separators before reading the value. Printing remains
separator-free (`puts(1_000)` prints `1000`), and range checks still apply to
the resulting integer. `String.to_int`, `String.to_float` and JSON continue to
reject `_`: separators are for source readability, not a second format for
input data. Ruby's lenient `to_i` is deliberately not adopted; for example,
`"12abc".to_i` returns `12` in Ruby.

### 33.4 The §25 test

[§25](25-ruby-typed-idioms.md#25-ruby-typed-idioms) rejects forms that only
rename or re-spell a call or statement. A digit separator is not another way to
write an operation: it is a lexical aid inside one token, like the space between
operators. Ruby and Elixir users expect it, and agents can write long numbers
without triggering a confusing parse error at `_000`.

### 33.5 Order

Implemented as front-end-only phase 23a, after 7i and 22a at roadmap order
7.2a. The token remains the same `Int` or `Float`, so the AST, checker,
lowering, bytecode and VM do not change. The
[roadmap](../roadmap/23-digit-separators.md) records the completed lexer, test
and documentation work.
