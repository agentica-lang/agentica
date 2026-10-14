import sys
from dataclasses import dataclass, replace


@dataclass(frozen=True)
class Summary:
    balances: dict[str, int]
    total: int
    rejected: int


class LineError(Exception):
    pass


def valid_account(name: str) -> bool:
    if len(name) > 16:
        return False
    for i, c in enumerate(name):
        letter = "a" <= c <= "z"
        digit = "0" <= c <= "9"
        if i == 0 and not letter:
            return False
        if not letter and not digit and c != "_":
            return False
    return True


def apply_line(summary: Summary, line: str) -> Summary:
    parts = line.split(" ")
    if len(parts) != 2:
        raise LineError("expected 2 fields")
    account = parts[0]
    if not valid_account(account):
        raise LineError("bad account")
    try:
        amount = int(parts[1])
    except ValueError:
        raise LineError("bad amount") from None
    if amount > 1000000 or amount < -1000000:
        raise LineError("amount out of range")
    current = summary.balances.get(account, 0)
    return replace(
        summary,
        balances={**summary.balances, account: current + amount},
        total=summary.total + amount,
    )


def main() -> None:
    summary = Summary(balances={}, total=0, rejected=0)
    for number, raw in enumerate(sys.stdin, start=1):
        line = raw.strip()
        if line == "" or line.startswith("#"):
            continue
        try:
            summary = apply_line(summary, line)
        except LineError as exc:
            print(f"line {number}: {exc}")
            summary = replace(summary, rejected=summary.rejected + 1)
    for account in sorted(summary.balances):
        print(f"{account}: {summary.balances[account]}")
    print(f"total: {summary.total}")
    print(f"rejected: {summary.rejected}")


if __name__ == "__main__":
    main()
