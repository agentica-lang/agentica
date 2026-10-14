import sys
from dataclasses import dataclass


@dataclass
class Item:
    name: str
    price: int


def describe(item: Item) -> str:
    return item.name + ": " + str(item.price)


def main() -> None:
    total = 0
    for line in sys.stdin.read().split("\n"):
        if not line.strip():
            continue
        parts = line.strip().split(" ")
        item = Item(name=parts[0], price=int(parts[1]))
        print(describe(item))
        total = total + item.price
    print("total: " + str(total))


main()
