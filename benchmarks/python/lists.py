import sys


def main(scale: int) -> None:
    rounds = 30 * scale
    total = 0
    for round_ in range(rounds):
        xs = [(i * 7919 + round_ * 104729) % 10007 for i in range(1000)]
        evens = [x for x in xs if x % 2 == 0]
        total_squares = sum(x * x for x in evens)
        ordered = sorted(xs)
        big = any(x > 10000 for x in xs)
        count = 0
        for x in ordered:
            if x > ordered[500]:
                break
            count += 1
        total = (total + total_squares + ordered[0] + ordered[-1] + len(evens) + count) % 1000000007
        if big:
            total += 1
    print(f"lists {rounds}: checksum {total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
