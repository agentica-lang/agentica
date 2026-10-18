# Task: repair a CSV report pipeline

`start.agc` (or `start.py` for Python) turns an orders CSV file into a JSON
report, and it produces the wrong files. Fix it and save the result as
`solution.agc` (or `solution.py`). Keep the files and the output exactly as
specified below.

## Usage

The program gets two command-line arguments, the input path and the output path
(`System.args()` in Agentica, `sys.argv[1:]` in Python). Paths are relative to
the current directory. It reads the input file, writes the output file, and
writes nothing else to disk. It never changes the input file.

## The input

A CSV file in UTF-8. The first line is a header and is always skipped. Every
other line is an order, `order_id,customer,sku,quantity,unit_cents`. There is no
quoting: a comma always separates fields. Spaces around a field are ignored. A
blank line is ignored (it is neither a row nor skipped). Lines end with `\n`; a
line may end with `\r\n`, and the last line may have no end of line.

An order line is valid when it has exactly 5 fields, `order_id`, `customer` and
`sku` are not empty, `quantity` is an integer of 1 or more and `unit_cents` is
an integer of 0 or more. Any other order line is skipped.

## The output file

One line of compact JSON (no spaces) followed by `\n`:

```json
{"customers":[{"customer":"ana","rows":2,"items":5,"total_cents":860}],"skipped":3}
```

- `customers` has one object per customer that has at least one valid order,
  sorted by customer name (plain character order), with the fields in this
  order: `customer`; `rows`, the number of valid orders; `items`, the sum of
  their `quantity`; `total_cents`, the sum of `quantity * unit_cents`.
- `skipped` is the number of skipped order lines.
- With no valid order, `customers` is `[]`.

## Standard output

Two lines: `rows: R`, the number of valid orders, and `skipped: S`.

Example input file:

```text
order_id,customer,sku,quantity,unit_cents
1,ana,tea,2,250
2,bob,coffee,1,400
3,ana,milk,3,120
4,bob,tea,x,250
```

Output file:

```text
{"customers":[{"customer":"ana","rows":2,"items":5,"total_cents":860},{"customer":"bob","rows":1,"items":1,"total_cents":400}],"skipped":1}
```

Standard output:

```text
rows: 3
skipped: 1
```

Test it with your own files before you finish.
