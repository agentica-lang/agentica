import sys
import time
from concurrent.futures import ThreadPoolExecutor


def nap(index: int) -> int:
    total = 0
    for k in range(10):
        time.sleep(0.001)
        total += index + k
    return total


def quick(index: int) -> int:
    return index * 3 + 1


def main(scale: int) -> None:
    rounds = 2 * scale
    total = 0
    with ThreadPoolExecutor(max_workers=100) as pool:
        for _ in range(rounds):
            futures = [pool.submit(nap, i) for i in range(100)]
            for f in futures:
                total += f.result()
            for j in range(3000):
                total += pool.submit(quick, j).result(timeout=60)
    print(f"sleepers {rounds}: checksum {total}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
