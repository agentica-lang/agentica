import queue
import sys
import threading


def main(scale: int) -> None:
    clients = 50
    per = 1000 * scale
    inbox: queue.Queue[tuple[int, queue.Queue[int]]] = queue.Queue(64)
    stored = [0]

    def store() -> None:
        total = 0
        for _ in range(clients * per):
            value, reply = inbox.get(timeout=60.0)
            for k in range(60):
                total += k % 3
            total += value
            reply.put(total, timeout=60.0)
        stored[0] = total

    def client(index: int) -> None:
        reply: queue.Queue[int] = queue.Queue(1)
        answered = 0
        for i in range(per):
            inbox.put((i, reply), timeout=60.0)
            reply.get(timeout=60.0)
            answered += 1
        accs[index] = answered

    accs = [0] * clients
    server = threading.Thread(target=store)
    server.start()
    threads = [threading.Thread(target=client, args=(index,)) for index in range(clients)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    server.join()
    print(f"store-clients {clients * per}: {stored[0]} {sum(accs)}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
