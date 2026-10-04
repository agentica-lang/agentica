# Task: process a command ledger

Read commands from standard input, one per line, until EOF. Start with a balance of 0.

Commands (surrounding whitespace is allowed; tokens within a command are separated by one space):
- `credit N`: add N to the balance.
- `debit N`: subtract N if the balance is at least N.
- `show`: leave the balance unchanged.
- `reset`: set the balance to 0.

N must be an integer from 0 through 1,000,000. For every valid command, print `balance: <balance>`. For an unknown command, malformed amount, out-of-range amount, or debit larger than the balance, print `error` and leave the balance unchanged. After all input, print `final: <balance>`.

Use an enum `Command[T]` for parsed commands and exhaustive `case` matching to handle both parse results and commands. Keep processing after an invalid command.

Example input:

```text
credit 20
debit 5
show
```

Example output:

```text
balance: 20
balance: 15
balance: 15
final: 15
```

Write `solution.agc` or `solution.py`, as instructed. Test it with your own input, including empty input.
