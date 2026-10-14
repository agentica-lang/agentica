import sys
from dataclasses import dataclass


@dataclass(frozen=True)
class Summary:
    balances: dict[str, int]
    total: int


def apply_line(summary: Summary, line: str) -> Summary:
    parts = line.split(" ")
    account = parts[0]
    amount = int(parts[1])
    current = summary.balances.get(account, 0)
    return Summary(
        balances={**summary.balances, account: current + amount},
        total=summary.total + amount,
    )


def main() -> None:
    summary = Summary(balances={}, total=0)
    for raw in sys.stdin:
        line = raw.strip()
        if line == "" or line.startswith("#"):
            continue
        summary = apply_line(summary, line)
    for account in sorted(summary.balances):
        print(f"{account}: {summary.balances[account]}")
    print(f"total: {summary.total}")


if __name__ == "__main__":
    main()
