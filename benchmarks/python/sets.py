import sys


def main(scale: int) -> None:
    rounds = 5 * scale
    checksum = 0
    for round_ in range(rounds):
        # A dict keeps the first-insertion order that Set promises.
        seen: dict[int, None] = {}
        for i in range(6000):
            seen.setdefault((i * 7919 + round_) % 1009)
        hits = 0
        for j in range(6000):
            if (j * 31 + round_) % 2003 in seen:
                hits += 1
        for k in range(0, 1009, 3):
            seen.pop(k, None)
        low = dict.fromkeys(range(round_, round_ + 500))
        both = [key for key in seen if key in low]
        either = dict(seen)
        either.update(low)
        rest = [key for key in seen if key not in low]
        for position, key in enumerate(seen, 1):
            checksum = (checksum + key * position) % 1000000007
        checksum = (checksum + hits + len(seen) + len(both) + len(either) + len(rest)) % 1000000007
    print(f"sets {rounds}: checksum {checksum}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
