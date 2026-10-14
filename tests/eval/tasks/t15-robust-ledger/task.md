# Task: stop halting on bad input

`start.agc` (or `start.py` for Python) keeps account balances. Each input line is `ACCOUNT AMOUNT`, and the program adds `AMOUNT` to the account. At the end it prints one `ACCOUNT: BALANCE` line for every account sorted by name, then `total: <sum of all amounts>`. Blank lines and lines that start with `#` are ignored.

The program halts on the first bad line (a missing field, an amount that is not a number), after printing nothing, and the good lines before it are lost. Change it so that bad lines are reported and skipped, and save the result as `solution.agc` (or `solution.py`). Keep the behavior for good lines as it is.

A line is good when all of this holds, checked in this order:

1. It has exactly two fields separated by a single space (after trimming the line). Otherwise the problem is `expected 2 fields`.
2. The account name starts with a lowercase letter `a`-`z`, continues with lowercase letters, digits or `_`, and has at most 16 characters. Otherwise the problem is `bad account`.
3. The amount is an integer: digits with an optional leading `-` or `+`. Otherwise the problem is `bad amount`.
4. The amount is from -1000000 to 1000000. Otherwise the problem is `amount out of range`.

For a bad line the program prints `line N: <problem>` at once, where `N` is the line number in the input (the first line is 1; blank and `#` lines count), and the line changes no balance and does not count in the total. The program goes on with the next line. After the `total:` line it prints `rejected: K`, the number of bad lines. The program exits normally in every case, including when every line is bad or the input is empty.

Example input:

```text
cash 50
# a note
cash x
bank -20
Bad 5
cash 10 20
cash 2000000
```

Example output:

```text
line 3: bad amount
line 5: bad account
line 6: expected 2 fields
line 7: amount out of range
bank: -20
cash: 50
total: 30
rejected: 4
```

Test it with your own input before you finish, including empty input.
