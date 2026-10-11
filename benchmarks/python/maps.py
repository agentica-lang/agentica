import sys


def main(scale: int) -> None:
    rounds = 5 * scale
    checksum = 0
    for round_ in range(rounds):
        counts: dict[int, int] = {}
        for i in range(6000):
            key = (i * 7919 + round_) % 1009
            counts[key] = counts.get(key, 0) + 1
        for j in range(0, 1009, 3):
            counts.pop(j, None)
        for key, count in counts.items():
            checksum = (checksum + key * count) % 1000000007
        checksum = (checksum + len(counts)) % 1000000007
    print(f"maps {rounds}: checksum {checksum}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
