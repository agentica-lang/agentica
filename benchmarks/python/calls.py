import sys


def fib(n: int) -> int:
    if n < 2:
        return n
    return fib(n - 1) + fib(n - 2)


def add(a: int, b: int) -> int:
    return a + b


def mix(total: int, value: int) -> int:
    return add(total * 31, value) % 1000000007


def main(scale: int) -> None:
    rounds = 2 * scale
    total = 0
    for round_ in range(rounds):
        total = mix(total, fib(20 + round_ % 2))
        for i in range(20000):
            total = mix(total, i)
    print(f"calls {rounds}: checksum {total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
