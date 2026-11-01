import os
import socket
import ssl
import sys
import threading
from collections.abc import Iterator

# Windows would print CRLF; the tests compare LF lines.
sys.stdout.reconfigure(newline="\n")

CERTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tls")


def server_context() -> ssl.SSLContext:
    """A server context with the test server's certificate and key."""
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERTS, "server.pem"), os.path.join(CERTS, "server-key.pem"))
    return context


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
    context = server_context()
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
    context = server_context()
    with socket.create_server(("127.0.0.1", 0)) as listener:
        print(listener.getsockname()[1], flush=True)
        while True:
            conn, _ = listener.accept()
            threading.Thread(target=answer_once, args=(context, conn), daemon=True).start()


def accepted(count: int) -> Iterator[socket.socket]:
    """Listens on 127.0.0.1, port 0, prints the port, and yields COUNT connections, each with a 20 s timeout."""
    with socket.create_server(("127.0.0.1", 0)) as listener:
        print(listener.getsockname()[1], flush=True)
        for _ in range(count):
            conn, _ = listener.accept()
            conn.settimeout(20)
            yield conn


def serve_mtls() -> None:
    """A TLS server that requires a client certificate from client-ca.pem: two connections, one line each.

    For each it prints the client certificate's common name, or "refused" when the client sent none.
    """
    context = server_context()
    context.verify_mode = ssl.CERT_REQUIRED
    context.load_verify_locations(os.path.join(CERTS, "client-ca.pem"))
    for conn in accepted(2):
        try:
            with context.wrap_socket(conn, server_side=True) as tls:
                subject = dict(item for field in tls.getpeercert()["subject"] for item in field)
                data = b""
                while not data.endswith(b"\n"):
                    chunk = tls.recv(4096)
                    if not chunk:
                        break
                    data += chunk
                tls.sendall(b"hello " + subject["commonName"].encode() + b"\n")
                print("client " + subject["commonName"], flush=True)
        except (ssl.SSLError, OSError):
            conn.close()
            print("refused", flush=True)


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


def read_line(conn: socket.socket, size: int = 4096) -> bytes:
    """Up to the first LF, or what came before the end. Plain text reads one byte at a time (size 1), so nothing past
    the line leaves the socket before a TLS handshake on it."""
    data = b""
    while not data.endswith(b"\n"):
        chunk = conn.recv(size)
        if not chunk:
            break
        data += chunk
    return data


def drain(conn: socket.socket) -> None:
    """Reads until the client closes; a reset is a close too."""
    try:
        while conn.recv(4096):
            pass
    except ConnectionResetError:
        pass


def serve_starttls() -> None:
    """STARTTLS, three connections: each reads "STARTTLS" and answers "220 ready" in plain text. The first then starts
    TLS and answers one line; the second sends a line before the handshake, which STARTTLS forbids; the third never
    starts its handshake. The last two wait for the client to close."""
    context = server_context()
    with socket.create_server(("127.0.0.1", 0)) as listener:
        print(listener.getsockname()[1], flush=True)
        for answer, handshake in ((b"220 ready\n", True), (b"220 ready\nearly\n", False), (b"220 ready\n", False)):
            conn, _ = listener.accept()
            with conn:
                conn.settimeout(20)
                read_line(conn, 1)
                conn.sendall(answer)
                if not handshake:
                    drain(conn)
                    continue
                with context.wrap_socket(conn, server_side=True) as tls:
                    tls.sendall(b"python " + tls.version().encode() + b" " + read_line(tls).upper())


def connect_starttls(port: int) -> None:
    """STARTTLS as a client: "STARTTLS" and its answer in plain text, then TLS on the same connection."""
    context = ssl.create_default_context(cafile=os.path.join(CERTS, "ca.pem"))
    with socket.create_connection(("127.0.0.1", port)) as raw:
        raw.settimeout(20)
        raw.sendall(b"STARTTLS\n")
        ready = read_line(raw, 1).decode().strip()
        with context.wrap_socket(raw, server_hostname="localhost") as tls:
            tls.sendall(b"python\n")
            print(ready, read_line(tls).decode().strip(), tls.version(), flush=True)


def serve_alpn() -> None:
    """ALPN on a server that offers h2 and http/1.1: two connections, each answered with the protocol it selected ("" for
    none, which is also Python's answer when nothing is in common)."""
    context = server_context()
    context.set_alpn_protocols(["h2", "http/1.1"])
    for conn in accepted(2):
        with context.wrap_socket(conn, server_side=True) as tls:
            tls.sendall((tls.selected_alpn_protocol() or "").encode() + b"\n")


def connect_alpn(port: int, protocols: list[str]) -> None:
    """ALPN on a client: prints the protocol the server selected, "" for none, or "refused" when the server ended the
    handshake."""
    context = ssl.create_default_context(cafile=os.path.join(CERTS, "ca.pem"))
    context.set_alpn_protocols(protocols)
    try:
        with socket.create_connection(("127.0.0.1", port)) as raw:
            raw.settimeout(20)
            with context.wrap_socket(raw, server_hostname="localhost") as tls:
                print(tls.selected_alpn_protocol() or "", flush=True)
    except ssl.SSLError:
        print("refused", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "server":
        serve()
    elif sys.argv[1] == "http":
        serve_http()
    elif sys.argv[1] == "close":
        serve_close()
    elif sys.argv[1] == "mtls":
        serve_mtls()
    elif sys.argv[1] == "starttls":
        serve_starttls()
    elif sys.argv[1] == "starttls-client":
        connect_starttls(int(sys.argv[2]))
    elif sys.argv[1] == "alpn":
        serve_alpn()
    elif sys.argv[1] == "alpn-client":
        connect_alpn(int(sys.argv[2]), sys.argv[3].split(","))
    else:
        connect(int(sys.argv[2]))
