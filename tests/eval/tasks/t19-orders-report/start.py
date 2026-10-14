import json
import sys
from dataclasses import asdict, dataclass


@dataclass(frozen=True)
class Customer:
    name: str
    orders: int
    total: int


@dataclass(frozen=True)
class Row:
    customer: str
    quantity: int
    cents: int


def parse_row(line: str) -> Row | None:
    fields = [f.strip() for f in line.split(";")]
    if len(fields) != 5:
        return None
    if fields[0] == "" or fields[1] == "" or fields[2] == "":
        return None
    try:
        quantity = int(fields[3])
        cents = int(fields[4])
    except ValueError:
        return None
    if quantity < 1 or cents < 0:
        return None
    return Row(customer=fields[1], quantity=quantity, cents=cents)


def main() -> None:
    source = sys.argv[1]
    with open(source, encoding="utf-8", newline="") as handle:
        lines = handle.read().split("\n")
    totals: dict[str, Customer] = {}
    rows = 0
    skipped = 0
    for line in lines:
        line = line.strip()
        if line == "":
            continue
        row = parse_row(line)
        if row is None:
            skipped += 1
            continue
        before = totals.get(row.customer, Customer(row.customer, 0, 0))
        totals[row.customer] = Customer(row.customer, before.orders + 1, before.total + row.cents)
        rows += 1
    report = {"customers": [asdict(c) for c in totals.values()], "skipped": skipped}
    with open(source, "w", encoding="utf-8", newline="") as handle:
        handle.write(json.dumps(report, separators=(",", ":")))
    print(f"rows: {rows}")
    print(f"skipped: {skipped}")


if __name__ == "__main__":
    main()
