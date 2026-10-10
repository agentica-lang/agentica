# Diagnostics seen in agent evaluations

`tests/eval/diagnostics.py` reads the agent logs in `tests/eval/results/` and counts which diagnostics the agents saw when they ran `agentica` (or `racket src/main.rkt`). Commands that only mention Agentica, such as `cat`, `strings` or `find`, are not counted. For each code it reports how many times it appeared, in how many runs, how often the next Agentica call in the same run showed the same code again (the fix did not work; only the code is compared), the most common messages and the source lines that caused it.

```sh
python3 tests/eval/diagnostics.py                 # every valid round, skill/grammar/binary arms
python3 tests/eval/diagnostics.py --arms binary   # one arm
python3 tests/eval/diagnostics.py tests/eval/results/20261002-071645-pi
```

The logs are not versioned, so the numbers below are a snapshot.

## Snapshot (2026-10-10)

108 runs, 497 Agentica invocations, 129 with a diagnostic. Almost all of them come from the `binary` arm, where the agent has no documentation and learns the language from the diagnostics. The `skill` and `grammar` arms only hit the starter bugs of their tasks.

| code | hits | runs | repeated next call |
|---|---|---|---|
| `CHECK-TYPE-MISMATCH` | 36 | 24 | 7 |
| `CHECK-UNKNOWN-NAME` | 32 | 15 | 7 |
| `PARSE-UNEXPECTED-TOKEN` | 20 | 12 | 2 |
| `CHECK-MISSING-RETURN` | 17 | 12 | 1 |
| `CHECK-NOT-A-STRUCT` | 6 | 5 | 0 |
| `LEX-UNEXPECTED-CHAR` | 5 | 4 | 0 |
| `RUNTIME-INVALID-NUMBER` | 4 | 4 | 0 |
| others | 9 | — | 0 |

Caveats: the logs cover rounds from before Results, enums, sorting and the newer builtins, so some "unknown" names (`String.to_int`, `Float.from_int`) exist today. One model, few runs.

## What the agents tried

Most hits are not bugs in the agent's logic. They are habits from Python and Ruby that Agentica writes differently:

- **Task starter bugs (expected):** `return quantity * price` with Int and Float (19 of the type mismatches, `t2-fix-types`), and `classify` without a return on every path (16 of the missing returns, `t5-scope-return`). The tasks plant these on purpose.
- **Conversion functions guessed by name:** `Int.to_float`, `Float.from_int` (before it existed), `String.to_int` (before it existed), `read_line`, `String.to_nt`.
- **Method-call style:** `line.length`, `x.to_i`, `x.to_int`, `"42".to_int`, `x.to_f`, `s.length()`, `x.to_float() * y`. They give `CHECK-NOT-A-STRUCT` or `PARSE-UNEXPECTED-TOKEN`, and neither says which module function to use.
- **Operators from other languages:** `!a`, `while !IO.eof?()`, `a && b`. They give `LEX-UNEXPECTED-CHAR` or a parse error that does not name `not`/`and`.
- **Calls without parentheses:** `puts "hello"` (8 hits). This one already has a hint and was never repeated.
- **Annotating an existing variable:** `x: Int = x`.

A probe of the current checker with common Python habits shows the same gap. These produce a diagnostic with no suggestion, or a misleading one:

| Written | Current diagnostic | Agentica |
|---|---|---|
| `len(s)`, `len(xs)` | unknown function, no help | `String.length(s)`, `List.size(xs)` |
| `str(n)` | unknown function, no help | `String.from_int(n)` / `String.from_float(x)` |
| `print(x)` | unknown function, no help | `puts(x)` / `IO.print(x)` |
| `range(n)` | unknown function, no help | a `while` loop |
| `read_line()`, `input()` | unknown function, no help | `IO.gets()` |
| `Int.to_float(n)` | unknown function, no help | `Float.from_int(n)` |
| `s.length`, `xs.length`, `x.to_i` | field access needs a struct | `String.length(s)`, `List.size(xs)`, `String.to_int(x)` |
| `s.length()`, `xs.append(2)` | expected a newline, found "(" | module function; `xs = List.append(xs, 2)` |
| `!a`, `a && b`, `a \|\| b` | unexpected character | `not a`, `a and b`, `a or b` |
| `x += 1` | expected an expression, found "=" | `x = x + 1` |
| `None` | a type name is only valid as a JSON type argument | `nil` |
| `elif` | "calls need parentheses, as in elif(...)" (wrong) | `elsif` |

The Int/Float help said "there is no Int to Float conversion" after `Float.from_int` was added; it now names `Float.from_int` and `Float.to_int!`.

## Round 5 (2026-10-10)

Only the round-5 `binary` run (`tests/eval/results/20261010-102333-pi`), on the Ruby-style language: 24 runs, 473 invocations, 183 with a diagnostic. The earlier `binary` rounds had 58 runs, 393 invocations and 120 with a diagnostic.

```sh
python3 tests/eval/diagnostics.py tests/eval/results/20261010-102333-pi --arms binary
```

| code | hits | runs | repeated next call |
|---|---|---|---|
| `PARSE-UNEXPECTED-TOKEN` | 98 | 14 | 48 |
| `CHECK-UNKNOWN-NAME` | 23 | 11 | 4 |
| `CHECK-TYPE-MISMATCH` | 14 | 8 | 1 |
| `CHECK-MISSING-RETURN` | 11 | 9 | 2 |
| `CHECK-UNKNOWN-TYPE` | 7 | 3 | 1 |
| `CHECK-IMPORT-NAME` | 5 | 4 | 1 |
| others | 25 | — | 1 |

Compared with the snapshot above:

- **Gone:** `CHECK-NOT-A-STRUCT` (methods on builtins) and `LEX-UNEXPECTED-CHAR` (`!`, `&&`, `||`). No run was stuck on `Float.from_int` or `s.length` any more.
- **Parse errors grew** (98 hits, 48 repeated). By task: t6 36, t8 26, t7 15, t1 14, t4 7. The forms: `when` in a case arm (12×), `case x` without `do` (8×), a case arm body on the arrow line (8×), `IO.gets!` without parentheses (7×), `var x = ...` (7×), `while cond do`, `puts "hello"`. They are Ruby, and the language now looks like Ruby, so agents expect more of it.
- **Unknown names:** `break` (5×), `println`, `Float.to_string`, `gets`, `range`. Except `break`, these already had a hint, and they were rarely repeated.
- **Enums:** `Result.Ok(5)` as a value (`CHECK-UNKNOWN-TYPE`, 5×) and `Command.Show` without parentheses (`CHECK-IMPORT-NAME`, 5×).
- **New codes** were seen and fixed on the next call: `CHECK-CAPTURED-ASSIGNMENT` (2×, a `total = total + x` inside a block) and `PARSE-MISSING-BLANK-LINE` (2×).

Changes made from this round: `case`, `while` and `for` accept an optional `do`; a case arm can hold one statement on the arrow line; `Module.fn` without arguments may drop its parentheses. Hints were added for `when`, `then`, `let`/`var`/`val`/`const`, `match`, `fn`/`lambda`/`proc`, a `do` with no call, `Hash.new`/`Array.new`, `break`/`continue`/`next`, `Result.Ok(x)` as a value and a variant without parentheses. A new `binary` round should show whether the parse errors drop.

## Round 6 (2026-10-10)

The `binary` run after the round-5 changes (`tests/eval/results/20261010-113647-pi`): 24 runs, 377 invocations, 117 with a diagnostic (round 5: 473 and 183).

| code | hits (5 → 6) | repeated next call (5 → 6) |
|---|---|---|
| `PARSE-UNEXPECTED-TOKEN` | 98 → 47 | 48 → 13 |
| `CHECK-UNKNOWN-NAME` | 23 → 22 | 4 → 4 |
| `CHECK-TYPE-MISMATCH` | 14 → 16 | 1 → 3 |
| `CHECK-MISSING-RETURN` | 11 → 9 | 2 → 0 |
| `CHECK-IMPORT-NAME` | 5 → 4 | 1 → 1 |
| `CHECK-UNKNOWN-TYPE` | 7 → 4 | 1 → 1 |

- The accepted forms (`while ... do`, `case x`, one-line arms, `IO.gets!`) no longer show up as errors.
- The parse errors left are hinted forms that agents try once and then fix: `puts "hello"` (6×), `let`/`var` (9×), `fn(...)` lambdas (4×), `when` (4×).
- Still repeated: `Result.Ok(x)` / `Result.Err(m)` as values (3×), `Command.Show` without parentheses (4×), `break` (3×), `gets()`, `Float.to_string`, `println`. A new confusion goes the other way: `ok(v) ->` used as a case pattern, where the pattern is `Result.Ok(v)`.

## Next steps (2026-10-10 snapshot)

Tracked in the roadmap under Phase 5d3 ("Diagnostics from evaluation data"):

1. A table of foreign habits (Python, Ruby, JavaScript) mapped to the Agentica form, used by `CHECK-UNKNOWN-NAME`, `CHECK-NOT-A-STRUCT` and the lexer/parser errors above to fill `help`.
2. Method-call style on builtin types (`x.length`, `x.to_i()`) suggests the module function for that type.
3. Fix the misleading `elif` and `None` messages.
4. Re-run the `binary` arm and this script to measure the change.
