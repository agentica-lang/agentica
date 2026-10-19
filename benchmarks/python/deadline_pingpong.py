import queue
import sys
import threading


def main(scale: int) -> None:
    rounds = 50000 * scale
    a: queue.Queue[int] = queue.Queue(1)
    b: queue.Queue[int] = queue.Queue(1)
    echoed = [0]

    def echo() -> None:
        total = 0
        for _ in range(rounds):
            v = a.get(timeout=1.0)
            b.put(v + 1, timeout=1.0)
            total += v
        echoed[0] = total

    worker = threading.Thread(target=echo)
    worker.start()
    total = 0
    for i in range(rounds):
        a.put(i, timeout=1.0)
        total += b.get(timeout=1.0)
    worker.join()
    print(f"deadline-pingpong {rounds}: checksum {total} {echoed[0]}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
