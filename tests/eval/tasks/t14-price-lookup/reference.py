import sys
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class State:
    prices: dict[str, int]
    unknown: int


def find_price(prices: dict[str, int], item: str) -> int | None:
    if item in prices:
        return prices[item]
    return None


def bad_command() -> None:
    print("error: bad command")


def miss(state: State) -> State:
    return replace(state, unknown=state.unknown + 1)


def parse_cents(text: str) -> int | None:
    try:
        n = int(text)
    except ValueError:
        return None
    return n if n >= 0 else None


def price_command(state: State, args: list[str]) -> State:
    if len(args) != 2:
        bad_command()
        return state
    cents = parse_cents(args[1])
    if cents is None:
        bad_command()
        return state
    item = args[0]
    old = find_price(state.prices, item)
    if old is not None:
        print(f"updated {item}: {old} -> {cents}")
    else:
        print(f"added {item}: {cents}")
    return replace(state, prices={**state.prices, item: cents})


def quote_command(state: State, args: list[str]) -> State:
    if len(args) != 1:
        bad_command()
        return state
    price = find_price(state.prices, args[0])
    if price is None:
        print(f"error: unknown item {args[0]}")
        return miss(state)
    print(f"{args[0]}: {price}")
    return state


def cost_command(state: State, args: list[str]) -> State:
    if len(args) < 3 or len(args) % 2 != 1:
        bad_command()
        return state
    quantities: list[int] = []
    for i in range(2, len(args), 2):
        qty = parse_cents(args[i])
        if qty is None or qty < 1:
            bad_command()
            return state
        quantities.append(qty)
    total = 0
    for n, qty in enumerate(quantities):
        item = args[1 + 2 * n]
        price = find_price(state.prices, item)
        if price is None:
            print(f"{args[0]}: unknown item {item}")
            return miss(state)
        total = total + price * qty
    print(f"{args[0]}: {total}")
    return state


def cheapest_command(state: State, args: list[str]) -> State:
    if len(args) < 1:
        bad_command()
        return state
    best = ""
    best_price = -1
    found = False
    misses = 0
    for item in args:
        price = find_price(state.prices, item)
        if price is None:
            misses += 1
        elif not found or price < best_price:
            best = item
            best_price = price
            found = True
    if found:
        print(f"cheapest: {best} ({best_price})")
    else:
        print("error: no known items")
    return replace(state, unknown=state.unknown + misses)


def report_command(state: State) -> None:
    for item in sorted(state.prices):
        print(f"{item} {state.prices[item]}")


def main() -> None:
    state = State(prices={}, unknown=0)
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        parts = [w for w in line.split(" ") if w != ""]
        args = parts[1:]
        match parts[0]:
            case "price":
                state = price_command(state, args)
            case "quote":
                state = quote_command(state, args)
            case "cost":
                state = cost_command(state, args)
            case "cheapest":
                state = cheapest_command(state, args)
            case "report":
                report_command(state)
            case _:
                bad_command()
    print(f"unknown: {state.unknown}")


if __name__ == "__main__":
    main()
