# Task: extend a calculator

`start.agc` (or `start.py` for Python) is a line calculator that works. It reads
one line at a time from standard input until EOF and ignores blank lines. A line
is either an expression, which prints its value, or an assignment `name =
expression`, which stores the value and prints `name = value`. Names are made of
the letters `a` to `z` and `_`. The values are integers, `/` drops the fraction
(it truncates toward zero), and the supported forms are `+ - * /`, parentheses
and names. A bad line prints `error: <message>` and the program goes on with the
next line; variables set by earlier lines stay.

Change the program to add three things, and save the result as `solution.agc`
(or `solution.py`). Everything the program does today must stay the same,
including every message.

1. `%`, the remainder. It has the same precedence as `*` and `/` and groups to
   the left. `a % b` is `a - b * (a / b)` with the truncating `/`, so `-7 % 3`
   is `-1` and `7 % -3` is `1`. A zero divisor gives `error: division by zero`.
2. `^`, the power. `a ^ b` multiplies `a` by itself `b` times, and `a ^ 0` is
   `1` (also for `a` equal to `0`). It binds tighter than `*` and groups to the
   right, so `2 ^ 3 ^ 2` is `2 ^ 9`. An exponent below zero gives `error:
   negative exponent`. The tests keep every result inside a signed 64-bit
   integer.
3. A unary minus: `-x`, `--x`, `2 * -3`, `-(1 + 2)`. It binds looser than `^`
   and tighter than `*`, so `-2 ^ 2` is `-4`, and the right side of `^` may
   start with a minus (`2 ^ -1` is a negative exponent).

A missing or misplaced operand for the new operators is reported like it is for
the old ones (`error: unexpected end of input` at the end of the line, `error:
unexpected token` elsewhere). A character the calculator does not know is
`error: bad character 'c'`.

Example input:

```text
-7 % 3
2 ^ 3 ^ 2
-2 ^ 2
n = 3
n ^ n % 5
2 ^ -1
```

Example output:

```text
-1
512
-4
n = 3
2
error: negative exponent
```

Test it with your own input before you finish.
