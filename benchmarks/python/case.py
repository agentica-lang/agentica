import sys
from dataclasses import dataclass


@dataclass(frozen=True, slots=True)
class Add:
    n: int


@dataclass(frozen=True, slots=True)
class Sub:
    n: int


@dataclass(frozen=True, slots=True)
class Mul:
    n: int


@dataclass(frozen=True, slots=True)
class Mod:
    n: int


@dataclass(frozen=True, slots=True)
class Neg:
    pass


@dataclass(frozen=True, slots=True)
class Twice:
    pass


type Op = Add | Sub | Mul | Mod | Neg | Twice


def apply(acc: int, op: Op) -> int:
    match op:
        case Add(n):
            return acc + n
        case Sub(n):
            return acc - n
        case Mul(n):
            return acc * n
        case Mod(n):
            return acc % n
        case Neg():
            return -acc
        case Twice():
            return acc * 2


def bucket(value: int) -> int:
    match value % 4:
        case 0:
            return 3
        case 1:
            return 5
        case 2:
            return 7
        case _:
            return 11


def main(scale: int) -> None:
    program = [Add(7), Mul(13), Twice(), Sub(5), Mod(1000003), Neg(), Add(1000003), Mul(3), Mod(999983)]
    rounds = 5000 * scale
    acc = 1
    checksum = 0
    for _ in range(rounds):
        for op in program:
            acc = apply(acc, op)
        checksum = (checksum + bucket(acc) * acc) % 1000000007
    print(f"case {rounds}: acc {acc}, checksum {checksum}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
