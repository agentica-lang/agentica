# Task: change a struct

`start.agc` (or `start.py` for Python) prints a price line for each item it
reads. Change it so every item also has a quantity, and update every place that
builds or uses the item. Save the result as `solution.agc` (or `solution.py`).

Input: one item per line, `name price quantity`, separated by single spaces.
`price` and `quantity` are integers. There is at least one line.

Output: for each item, `<name>: <price> x <quantity> = <price * quantity>`, then
a last line `total: <sum of all item totals>`.

Example input:

```text
pen 3 4
book 10 2
```

Example output:

```text
pen: 3 x 4 = 12
book: 10 x 2 = 20
total: 32
```

Test it with your own input before you finish.
