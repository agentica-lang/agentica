import sys


def main(scale: int) -> None:
    rounds = 20000 * scale
    table: dict[int, int] = {}
    done = 0
    for task in range(8):
        for i in range(rounds):
            table[i % 16] = table.get(i % 16, 0) + 1
            own = 1000 * (task + 1) + i % 500
            table[own] = i
            if i % 2 == 0:
                table.pop(own, None)
        done += rounds
    shared = sum(table.get(key, 0) for key in range(16))
    print(f"ats-writers {rounds}: checksum {done} {shared} {len(table)}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
