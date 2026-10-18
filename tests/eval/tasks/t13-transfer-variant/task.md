# Task: add a transaction kind

`start.agc` (or `start.py` for Python) is an account program that works. It
reads transactions from standard input until EOF (blank lines are ignored) and
keeps one balance that starts at 0. A transaction is one of three kinds today:
`deposit AMOUNT`, `withdraw AMOUNT` and `fee AMOUNT LABEL`. `AMOUNT` is a
positive integer. A line that is not one of these prints `invalid: <the line,
trimmed>`.

Add a fourth kind, `transfer AMOUNT TO` (`TO` is one word, the name of the
receiving account), and save the result as `solution.agc` (or `solution.py`).
Every place in the program that handles the kinds has to handle the new one.
Keep every other behavior as it is.

- A transfer takes `AMOUNT` from the balance, like a withdrawal, and is rejected
  with the same `insufficient funds` rule when `AMOUNT` is more than the
  balance.
- Its description is `transfer AMOUNT to TO` (for example `transfer 30 to bob`),
  and its category (the word that starts the line of an accepted transaction) is
  `transfer`. Rejected transfers print `rejected: transfer 500 to ann
  (insufficient funds)`, like the other kinds.
- The summary at the end gets a new line, `transferred: <sum of the accepted
  transfers>`, between `fees:` and `rejected:`. An accepted transfer does not
  count in `outflow:`.

Example input:

```text
deposit 100
transfer 30 bob
fee 5 wire
transfer 500 ann
transfer 5
```

Example output:

```text
inflow: deposit 100 -> 100
transfer: transfer 30 to bob -> 70
fee: fee 5 (wire) -> 65
rejected: transfer 500 to ann (insufficient funds)
invalid: transfer 5
balance: 65
inflow: 100
outflow: 0
fees: 5
transferred: 30
rejected: 1
```

Test it with your own input before you finish.
