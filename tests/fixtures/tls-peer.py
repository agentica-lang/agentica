import os
import socket
import ssl
import sys
import threading

# Windows would print CRLF; the tests compare LF lines.
sys.stdout.reconfigure(newline="\n")

CERTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tls")


def serve() -> None:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_2
    context.maximum_version = ssl.TLSVersion.TLSv1_2
    context.load_cert_chain(os.path.join(CERTS, "server.pem"), os.path.join(CERTS, "server-key.pem"))
    with socket.create_server(("127.0.0.1", 0)) as listener:
        print(listener.getsockname()[1], flush=True)
        conn, _ = listener.accept()
        with context.wrap_socket(conn, server_side=True) as tls:
            data = b""
            while not data.endswith(b"\n"):
                chunk = tls.recv(4096)
                if not chunk:
                    break
                data += chunk
            tls.sendall(b"python " + tls.version().encode() + b" " + data.upper())
            tls.unwrap()


def answer(context: ssl.SSLContext, conn: socket.socket, hang: threading.Event, done: list[str]) -> None:
    conn.settimeout(20)
    with context.wrap_socket(conn, server_side=True, suppress_ragged_eofs=False) as tls:
        path = ""
        data = b""
        while True:
            chunk = tls.recv(4096)
            if not chunk:
                break
            data += chunk
            while b"\r\n\r\n" in data:
                head, data = data.split(b"\r\n\r\n", 1)
                path = head.split(b" ")[1].decode()
                if path == "/hang":
                    hang.set()
                    continue
                if path == "/ping":
                    hang.wait(20)
                tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok")
        done.append("close_notify " + path)


def serve_http() -> None:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERTS, "server.pem"), os.path.join(CERTS, "server-key.pem"))
    hang = threading.Event()
    done: list[str] = []
    threads = []
    with socket.create_server(("127.0.0.1", 0)) as listener:
        print(listener.getsockname()[1], flush=True)
        for _ in range(2):
            conn, _ = listener.accept()
            thread = threading.Thread(target=answer, args=(context, conn, hang, done))
            thread.start()
            threads.append(thread)
    for thread in threads:
        thread.join()
    for line in sorted(done):
        print(line, flush=True)


def answer_once(context: ssl.SSLContext, conn: socket.socket) -> None:
    conn.settimeout(20)
    with context.wrap_socket(conn, server_side=True) as tls:
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = tls.recv(4096)
            if not chunk:
                return
            data += chunk
        tls.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok")


def serve_close() -> None:
    """HTTPS that answers one request per connection, until the test ends it: every call is a new handshake."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERTS, "server.pem"), os.path.join(CERTS, "server-key.pem"))
    with socket.create_server(("127.0.0.1", 0)) as listener:
        print(listener.getsockname()[1], flush=True)
        while True:
            conn, _ = listener.accept()
            threading.Thread(target=answer_once, args=(context, conn), daemon=True).start()


def connect(port: int) -> None:
    context = ssl.create_default_context(cafile=os.path.join(CERTS, "ca.pem"))
    with socket.create_connection(("127.0.0.1", port)) as raw:
        with context.wrap_socket(raw, server_hostname="localhost") as tls:
            tls.sendall(b"py")
            tls.sendall(b"thon\n")
            reply = b""
            while not reply.endswith(b"\n"):
                chunk = tls.recv(4096)
                if not chunk:
                    break
                reply += chunk
            print(reply.decode().strip(), tls.version(), flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "server":
        serve()
    elif sys.argv[1] == "http":
        serve_http()
    elif sys.argv[1] == "close":
        serve_close()
    else:
        connect(int(sys.argv[2]))
