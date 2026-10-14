import sys
from dataclasses import dataclass, replace
from typing import assert_never


@dataclass(frozen=True)
class Deposit:
    amount: int


@dataclass(frozen=True)
class Withdraw:
    amount: int


@dataclass(frozen=True)
class Fee:
    amount: int
    label: str


@dataclass(frozen=True)
class Transfer:
    amount: int
    to: str


Txn = Deposit | Withdraw | Fee | Transfer


@dataclass(frozen=True)
class Stats:
    inflow: int
    outflow: int
    fees: int
    transferred: int
    rejected: int


def parse_amount(text: str) -> int | None:
    try:
        n = int(text)
    except ValueError:
        return None
    if n <= 0:
        return None
    return n


def parse_txn(line: str) -> Txn | None:
    parts = [w for w in line.split(" ") if w != ""]
    if len(parts) == 2 and parts[0] == "deposit":
        amount = parse_amount(parts[1])
        return Deposit(amount) if amount is not None else None
    if len(parts) == 2 and parts[0] == "withdraw":
        amount = parse_amount(parts[1])
        return Withdraw(amount) if amount is not None else None
    if len(parts) == 3 and parts[0] == "fee":
        amount = parse_amount(parts[1])
        return Fee(amount, parts[2]) if amount is not None else None
    if len(parts) == 3 and parts[0] == "transfer":
        amount = parse_amount(parts[1])
        return Transfer(amount, parts[2]) if amount is not None else None
    return None


def describe(txn: Txn) -> str:
    match txn:
        case Deposit(amount):
            return f"deposit {amount}"
        case Withdraw(amount):
            return f"withdraw {amount}"
        case Fee(amount, label):
            return f"fee {amount} ({label})"
        case Transfer(amount, to):
            return f"transfer {amount} to {to}"
        case _:
            assert_never(txn)


def category(txn: Txn) -> str:
    match txn:
        case Deposit():
            return "inflow"
        case Withdraw():
            return "outflow"
        case Fee():
            return "fee"
        case Transfer():
            return "transfer"
        case _:
            assert_never(txn)


def apply_txn(balance: int, txn: Txn) -> int | None:
    match txn:
        case Deposit(amount):
            return balance + amount
        case Withdraw(amount):
            return balance - amount if amount <= balance else None
        case Fee(amount):
            return balance - amount if amount <= balance else None
        case Transfer(amount):
            return balance - amount if amount <= balance else None
        case _:
            assert_never(txn)


def tally(stats: Stats, txn: Txn) -> Stats:
    match txn:
        case Deposit(amount):
            return replace(stats, inflow=stats.inflow + amount)
        case Withdraw(amount):
            return replace(stats, outflow=stats.outflow + amount)
        case Fee(amount):
            return replace(stats, fees=stats.fees + amount)
        case Transfer(amount):
            return replace(stats, transferred=stats.transferred + amount)
        case _:
            assert_never(txn)


def main() -> None:
    balance = 0
    stats = Stats(inflow=0, outflow=0, fees=0, transferred=0, rejected=0)
    for raw in sys.stdin:
        line = raw.strip()
        if line == "":
            continue
        txn = parse_txn(line)
        if txn is None:
            print(f"invalid: {line}")
            continue
        applied = apply_txn(balance, txn)
        if applied is not None:
            balance = applied
            stats = tally(stats, txn)
            print(f"{category(txn)}: {describe(txn)} -> {balance}")
        else:
            stats = replace(stats, rejected=stats.rejected + 1)
            print(f"rejected: {describe(txn)} (insufficient funds)")
    print(f"balance: {balance}")
    print(f"inflow: {stats.inflow}")
    print(f"outflow: {stats.outflow}")
    print(f"fees: {stats.fees}")
    print(f"transferred: {stats.transferred}")
    print(f"rejected: {stats.rejected}")


if __name__ == "__main__":
    main()
