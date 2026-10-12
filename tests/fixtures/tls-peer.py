import os
import socket
import ssl
import sys

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
    else:
        connect(int(sys.argv[2]))
