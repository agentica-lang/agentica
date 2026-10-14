import sys


def find_price(prices: dict[str, int], item: str) -> int:
    if item in prices:
        return prices[item]
    return -1


def bad_command() -> None:
    print("error: bad command")


def parse_cents(text: str) -> int | None:
    try:
        n = int(text)
    except ValueError:
        return None
    return n if n >= 0 else None


def price_command(prices: dict[str, int], args: list[str]) -> dict[str, int]:
    if len(args) != 2:
        bad_command()
        return prices
    cents = parse_cents(args[1])
    if cents is None:
        bad_command()
        return prices
    item = args[0]
    old = find_price(prices, item)
    if old == -1:
        print(f"added {item}: {cents}")
    else:
        print(f"updated {item}: {old} -> {cents}")
    return {**prices, item: cents}


def quote_command(prices: dict[str, int], args: list[str]) -> None:
    if len(args) != 1:
        bad_command()
        return
    print(f"{args[0]}: {find_price(prices, args[0])}")


def cost_command(prices: dict[str, int], args: list[str]) -> None:
    if len(args) < 3 or len(args) % 2 != 1:
        bad_command()
        return
    total = 0
    for i in range(1, len(args), 2):
        qty = parse_cents(args[i + 1])
        if qty is None or qty < 1:
            bad_command()
            return
        total = total + find_price(prices, args[i]) * qty
    print(f"{args[0]}: {total}")


def cheapest_command(prices: dict[str, int], args: list[str]) -> None:
    if len(args) < 1:
        bad_command()
        return
    best = args[0]
    best_price = find_price(prices, best)
    for item in args[1:]:
        price = find_price(prices, item)
        if price < best_price:
            best = item
            best_price = price
    print(f"cheapest: {best} ({best_price})")


def report_command(prices: dict[str, int]) -> None:
    for item in sorted(prices):
        print(f"{item} {prices[item]}")


def main() -> None:
    prices: dict[str, int] = {}
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        parts = [w for w in line.split(" ") if w != ""]
        args = parts[1:]
        match parts[0]:
            case "price":
                prices = price_command(prices, args)
            case "quote":
                quote_command(prices, args)
            case "cost":
                cost_command(prices, args)
            case "cheapest":
                cheapest_command(prices, args)
            case "report":
                report_command(prices)
            case _:
                bad_command()


if __name__ == "__main__":
    main()
