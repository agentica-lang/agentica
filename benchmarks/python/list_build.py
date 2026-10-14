import sys


def main(scale: int) -> None:
    n = 20000 * scale
    xs: list[int] = []
    for i in range(n):
        xs.append((i * 7919) % 10007)
    for j in range(n):
        xs[(j * 7919) % n] = j
    total = 0
    for x in xs:
        total = (total * 31 + x) % 1000000007
    print(f"list-build {n}: checksum {total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
