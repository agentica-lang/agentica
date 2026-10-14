import socket
import sys


def main():
    port = int(sys.argv[1])
    count = int(sys.argv[2])
    clients = []
    for i in range(count):
        client = socket.create_connection(("127.0.0.1", port), timeout=20)
        client.sendall(f"msg {i}\n".encode())
        clients.append(client)
    for i, client in enumerate(clients):
        data = b""
        while not data.endswith(b"\n"):
            chunk = client.recv(4096)
            if not chunk:
                break
            data += chunk
        client.close()
        print(f"{i} {data.decode().strip()}", flush=True)


main()
