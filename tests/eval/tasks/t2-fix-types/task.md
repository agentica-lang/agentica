# Task: fix the types

`start.agc` (or `start.py` for Python) is a price calculator that does not work. Fix it so it meets this spec, and save the result as `solution.agc` (or `solution.py`). Do not change what the program is supposed to print.

Input: one item per line, `name quantity price`, separated by single spaces. `quantity` is an integer and `price` is a decimal number written like `2.5`. There is at least one line.

Output: one line per item, `<name>: <quantity * price>`, then a last line `total: <sum of all lines>`. Numbers are printed the default way for a decimal number (`5.0`, `0.25`).

Example input:

```text
tea 2 2.5
salt 1 0.25
```

Example output:

```text
tea: 5.0
salt: 0.25
total: 5.25
```

Test it with your own input before you finish.
