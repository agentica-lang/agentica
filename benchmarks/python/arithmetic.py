import sys


def collatz_length(n: int) -> int:
    steps = 0
    while n != 1:
        n = n // 2 if n % 2 == 0 else 3 * n + 1
        steps += 1
    return steps


def main(scale: int) -> None:
    limit = 2500 * scale
    lengths = [collatz_length(n) for n in range(1, limit + 1)]
    print(f"collatz {limit}: total {sum(lengths)}, longest {max(lengths)}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
