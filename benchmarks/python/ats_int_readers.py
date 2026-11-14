import sys


def main(scale: int) -> None:
    rounds = 150000 * scale
    table = {n: n for n in range(1000)}
    total = 0
    for task in range(8):
        part = 0
        for i in range(rounds):
            part = (part + table.get((i * 31 + task) % 1000, 0)) % 1000000007
        total += part
    print(f"ats-int-readers {rounds}: checksum {total % 1000000007}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
