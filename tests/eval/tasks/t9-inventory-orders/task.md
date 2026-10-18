# Task: extend an inventory program

`start.agc` (or `start.py` for Python) is a small shop program that works. It
reads commands from standard input, one per line, until EOF, and keeps the stock
of a shop. Change it to add the three features below, and save the result as
`solution.agc` (or `solution.py`). Keep every other behavior as it is: the
commands, the messages and the error lines are part of the spec.

The commands the program already has (names, customers and amounts are separated
by single spaces; blank lines are ignored):

- `add NAME QTY PRICE`: add `QTY` units of `NAME` and set its price (in cents)
  to `PRICE`.
- `order CUSTOMER NAME QTY`: sell `QTY` units to a customer if the stock allows
  it.
- `price NAME PRICE`: change the price of an item.
- `stock NAME`: print the units in stock.
- `customers`: print what each customer has spent, sorted by customer name.
- `report`: print every item sorted by name, then the revenue.

## The changes

1. Bulk discounts. An order of 10 or more units gets 10% off the line total, and
   an order of 50 or more units gets 20% off. The discount is `line total *
   percent / 100`, with the fraction dropped (integer division). The sale line
   shows the total after the discount, and when the discount is more than zero
   it ends with ` (saved D)`, for example `sold ana tea 10 for 27 (saved 3)`.
   Revenue and the customer totals use the discounted amount. An order below 10
   units prints the same line as before.
2. A new command `remove NAME` removes an item from the shop. It prints `removed
   NAME`. For an item that is not in the shop it prints `error: unknown item
   NAME`. Revenue and customer totals do not change.
3. In `report`, an item with fewer than 5 units in stock (zero included) gets `
   low` at the end of its line, for example `coffee 0 x 5 low`. The `revenue:`
   line does not change.

Example input:

```text
add tea 100 3
order ana tea 10
order bob tea 4
remove tea
remove tea
report
```

Example output:

```text
added tea: 100 (now 100)
sold ana tea 10 for 27 (saved 3)
sold bob tea 4 for 12
removed tea
error: unknown item tea
revenue: 39
```

Test it with your own input before you finish.
