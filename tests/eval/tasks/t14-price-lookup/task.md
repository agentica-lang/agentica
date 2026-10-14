# Task: make a missing value part of the type

`start.agc` (or `start.py` for Python) is a price-list program that works. It reads commands from standard input until EOF (blank lines are ignored). `find_price` looks an item up and returns `-1` when the item is not in the list. Some callers check for `-1` and some do not, so an unknown item gives wrong answers (`salt: -1`, a recipe cost that subtracts an unknown item, an unknown item as the cheapest).

Change it so a missing price is part of the type and cannot be forgotten: `find_price` returns a `Result[Int]` in Agentica (an `error` for an unknown item) and an `int | None` in Python (`None` for an unknown item). Then follow the change through every use. Save the result as `solution.agc` (or `solution.py`). Keep every behavior that does not involve an unknown item as it is.

The commands (words are separated by single spaces, prices are integers of 0 or more):

- `price ITEM CENTS`: set the price. Prints `added ITEM: CENTS` for a new item and `updated ITEM: OLD -> CENTS` for a known one.
- `quote ITEM`: prints `ITEM: CENTS`.
- `cost LABEL ITEM QTY ITEM QTY ...`: the cost of a recipe. At least one `ITEM QTY` pair; `QTY` is an integer of 1 or more. Prints `LABEL: TOTAL`.
- `cheapest ITEM ITEM ...`: prints `cheapest: ITEM (CENTS)` for the item with the lowest price, the first one when prices are equal.
- `report`: prints `ITEM CENTS` for every item, sorted by name.
- anything else, or a command with the wrong arguments, prints `error: bad command`. The arguments are checked first (their number, then every `QTY` and `CENTS`), and only then are items looked up.

## What an unknown item does now

- `quote ITEM` prints `error: unknown item ITEM`.
- `cost` prints `LABEL: unknown item ITEM` for the first unknown item, in the order given, and no total.
- `cheapest` ignores unknown items. When none of the items is known it prints `error: no known items`.
- The program counts the unknown items it met: one for each `quote` that failed, one for each `cost` that failed (the first unknown item only), and one for every unknown item named in a `cheapest` line (counting repeats). At the end of the input it prints `unknown: N`, also when `N` is 0.

Example input:

```text
price flour 120
price eggs 30
quote salt
cost cake flour 2 eggs 3
cost bad flour 1 salt 4
cheapest salt flour eggs salt
```

Example output:

```text
added flour: 120
added eggs: 30
error: unknown item salt
cake: 330
bad: unknown item salt
cheapest: eggs (30)
unknown: 4
```

Test it with your own input before you finish.
