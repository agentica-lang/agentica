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

## Next steps

Tracked in the roadmap under Phase 5d3 ("Diagnostics from evaluation data"):

1. A table of foreign habits (Python, Ruby, JavaScript) mapped to the Agentica form, used by `CHECK-UNKNOWN-NAME`, `CHECK-NOT-A-STRUCT` and the lexer/parser errors above to fill `help`.
2. Method-call style on builtin types (`x.length`, `x.to_i()`) suggests the module function for that type.
3. Fix the misleading `elif` and `None` messages.
4. Re-run the `binary` arm and this script to measure the change.
