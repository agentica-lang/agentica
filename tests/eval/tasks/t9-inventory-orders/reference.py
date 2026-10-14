import sys
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Item:
    name: str
    qty: int
    price: int


@dataclass(frozen=True)
class Shop:
    items: dict[str, Item]
    spent: dict[str, int]
    revenue: int


def new_shop() -> Shop:
    return Shop(items={}, spent={}, revenue=0)


def words(line: str) -> list[str]:
    return [w for w in line.strip().split(" ") if w != ""]


def parse_count(text: str) -> int | None:
    try:
        n = int(text)
    except ValueError:
        return None
    if n < 0:
        return None
    return n


def bad_command() -> None:
    print("error: bad command")


def unknown_item(name: str) -> None:
    print(f"error: unknown item {name}")


def with_item(shop: Shop, item: Item) -> Shop:
    return replace(shop, items={**shop.items, item.name: item})


def add_command(shop: Shop, args: list[str]) -> Shop:
    if len(args) != 3:
        bad_command()
        return shop
    qty = parse_count(args[1])
    price = parse_count(args[2])
    if qty is None or price is None:
        bad_command()
        return shop
    name = args[0]
    have = shop.items[name].qty if name in shop.items else 0
    total = have + qty
    print(f"added {name}: {qty} (now {total})")
    return with_item(shop, Item(name=name, qty=total, price=price))


def line_total(item: Item, qty: int) -> int:
    return item.price * qty


def discount_percent(qty: int) -> int:
    if qty >= 50:
        return 20
    elif qty >= 10:
        return 10
    return 0


def order_command(shop: Shop, args: list[str]) -> Shop:
    if len(args) != 3:
        bad_command()
        return shop
    qty = parse_count(args[2])
    if qty is None or qty == 0:
        bad_command()
        return shop
    customer = args[0]
    name = args[1]
    if name not in shop.items:
        print(f"rejected {customer} {name}: unknown item")
        return shop
    item = shop.items[name]
    if item.qty < qty:
        print(f"rejected {customer} {name}: only {item.qty} in stock")
        return shop
    gross = line_total(item, qty)
    saved = gross * discount_percent(qty) // 100
    total = gross - saved
    if saved > 0:
        print(f"sold {customer} {name} {qty} for {total} (saved {saved})")
    else:
        print(f"sold {customer} {name} {qty} for {total}")
    left = replace(item, qty=item.qty - qty)
    before = shop.spent.get(customer, 0)
    return replace(
        shop,
        items={**shop.items, name: left},
        spent={**shop.spent, customer: before + total},
        revenue=shop.revenue + total,
    )


def price_command(shop: Shop, args: list[str]) -> Shop:
    if len(args) != 2:
        bad_command()
        return shop
    price = parse_count(args[1])
    if price is None:
        bad_command()
        return shop
    name = args[0]
    if name not in shop.items:
        unknown_item(name)
        return shop
    print(f"price {name}: {price}")
    return with_item(shop, replace(shop.items[name], price=price))


def stock_command(shop: Shop, args: list[str]) -> None:
    if len(args) != 1:
        bad_command()
        return
    name = args[0]
    if name not in shop.items:
        unknown_item(name)
        return
    print(f"{name}: {shop.items[name].qty}")


def remove_command(shop: Shop, args: list[str]) -> Shop:
    if len(args) != 1:
        bad_command()
        return shop
    name = args[0]
    if name not in shop.items:
        unknown_item(name)
        return shop
    print(f"removed {name}")
    return replace(shop, items={k: v for k, v in shop.items.items() if k != name})


def customers_command(shop: Shop) -> None:
    if len(shop.spent) == 0:
        print("no customers")
        return
    for customer in sorted(shop.spent):
        print(f"{customer}: {shop.spent[customer]}")


def report_command(shop: Shop) -> None:
    for name in sorted(shop.items):
        item = shop.items[name]
        if item.qty < 5:
            print(f"{item.name} {item.qty} x {item.price} low")
        else:
            print(f"{item.name} {item.qty} x {item.price}")
    print(f"revenue: {shop.revenue}")


def run_command(shop: Shop, line: str) -> Shop:
    parts = words(line)
    command = parts[0]
    args = parts[1:]
    if command == "add":
        return add_command(shop, args)
    elif command == "order":
        return order_command(shop, args)
    elif command == "price":
        return price_command(shop, args)
    elif command == "remove":
        return remove_command(shop, args)
    elif command == "stock":
        stock_command(shop, args)
    elif command == "customers":
        customers_command(shop)
    elif command == "report":
        report_command(shop)
    else:
        bad_command()
    return shop


def main() -> None:
    shop = new_shop()
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        shop = run_command(shop, line)


if __name__ == "__main__":
    main()
