import sys


def parse_command(line: str) -> tuple[str, int | None] | None:
    words = line.strip().split(" ")
    if words == ["show"]:
        return "show", None
    if words == ["reset"]:
        return "reset", None
    if len(words) != 2 or words[0] not in {"credit", "debit"}:
        return None
    try:
        amount = int(words[1])
    except ValueError:
        return None
    if not 0 <= amount <= 1_000_000:
        return None
    return words[0], amount


def main() -> None:
    balance = 0
    for line in sys.stdin:
        command = parse_command(line)
        match command:
            case ("credit", amount):
                balance += amount
                print(f"balance: {balance}")
            case ("debit", amount):
                if amount > balance:
                    print("error")
                else:
                    balance -= amount
                    print(f"balance: {balance}")
            case ("show", _):
                print(f"balance: {balance}")
            case ("reset", _):
                balance = 0
                print("balance: 0")
            case _:
                print("error")
    print(f"final: {balance}")


if __name__ == "__main__":
    main()
