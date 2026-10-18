# Task: fix scope and return errors

`start.agc` (or `start.py` for Python) should classify numbers, but it is
broken. Fix it so it meets this spec, and save the result as `solution.agc` (or
`solution.py`).

Input: integers, one per line, until the end of input. There may be no lines at
all.

Output: one line per number, `negative`, `zero`, or `positive`. Then a last
line, `negatives: <how many numbers were negative>`.

Example input:

```text
-5
0
7
-1
```

Example output:

```text
negative
zero
positive
negative
negatives: 2
```

Test it with your own input before you finish, including empty input.
