import queue
import sys
import threading


def main(scale: int) -> None:
    rounds = 100000 * scale
    ping: queue.Queue[int] = queue.Queue(1)
    pong: queue.Queue[int] = queue.Queue(1)
    echoed = [0]

    def echo() -> None:
        for _ in range(rounds):
            pong.put(ping.get(timeout=5.0) + 1, timeout=5.0)
            echoed[0] += 1

    worker = threading.Thread(target=echo)
    worker.start()
    total = 0
    for i in range(rounds):
        ping.put(i, timeout=5.0)
        total += pong.get(timeout=5.0)
    worker.join()
    print(f"channel-pingpong {rounds}: checksum {total} {echoed[0]}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
