"""SOCKS5 proxies (RFC 1928, with the user and password login of RFC 1929) and two origins, all on 127.0.0.1 with port
0, for the tests of std/socks and of the HTTP client through a SOCKS proxy.

It prints one line, `open locked A C`, the four ports, and serves until its stdin closes:

- `open` takes no login. It answers a CONNECT to port 1 to 8 with that reply code instead of connecting (1 general
  failure ... 8 address type not supported), to port 9 with a reply version that is not 5, to port 10 with half a reply
  and a close, to port 11 with nothing until the client closes, and connects any other target to 127.0.0.1 at its port, whatever address or name the request carried, so a test can use any name.
- `locked` asks for the user `us@er` and the password `p:ss/w`, and refuses any other login.
- `A` is a plain HTTP origin and `C` a TLS one (tests/fixtures/tls/server.pem). Both answer
  `hello from <A or C> <path>` with the Host header they got: `hello from A /x host=example.test:80`.

For each CONNECT it prints what it saw, so a test can assert the address type and the address:

    SAW <open or locked> <methods offered, comma-separated> <login or -> <atyp> <address> <port>

where `<address>` is the dotted IPv4 address, the IPv6 address in its short form, or the name. Standard library only.
"""
import http.server
import ipaddress
import os
import selectors
import socket
import socketserver
import ssl
import struct
import sys
import threading

sys.stdout.reconfigure(encoding="utf-8", newline="\n")

CERTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tls")
USER = b"us@er"
PASSWORD = b"p:ss/w"
PRINT = threading.Lock()


def say(text):
    with PRINT:
        print(text, flush=True)


def exact(sock, count):
    data = b""
    while len(data) < count:
        piece = sock.recv(count - len(data))
        if not piece:
            raise ConnectionError("closed")
        data += piece
    return data


def relay(client, upstream):
    """Moves bytes both ways with one selector until either side ends, then closes the target."""
    peers = {client: upstream, upstream: client}
    with selectors.DefaultSelector() as selector:
        for sock in peers:
            selector.register(sock, selectors.EVENT_READ)
        done = False
        while not done:
            for key, _ in selector.select():
                try:
                    data = key.fileobj.recv(65536)
                    if data:
                        peers[key.fileobj].sendall(data)
                except OSError:
                    data = b""
                done = done or not data
    upstream.close()


class Socks(socketserver.BaseRequestHandler):
    tag = "?"
    locked = False

    def reply(self, code, version=5):
        # The bound address: IPv4 0.0.0.0, port 0.
        self.request.sendall(bytes([version, code, 0, 1, 0, 0, 0, 0, 0, 0]))

    def handle(self):
        sock = self.request
        sock.settimeout(10)
        try:
            self.serve(sock)
        except (OSError, ConnectionError):
            pass

    def serve(self, sock):
        version, count = exact(sock, 2)
        methods = list(exact(sock, count))
        if version != 5:
            return
        login = "-"
        if self.locked:
            if 2 not in methods:
                sock.sendall(b"\x05\xff")
                say("SAW %s %s - refused" % (self.tag, ",".join(map(str, methods))))
                return
            sock.sendall(b"\x05\x02")
            _, size = exact(sock, 2)
            user = exact(sock, size)
            size = exact(sock, 1)[0]
            password = exact(sock, size)
            login = "%s:%s" % (user.decode(), password.decode())
            if (user, password) != (USER, PASSWORD):
                sock.sendall(b"\x01\x01")
                say("SAW %s %s %s refused" % (self.tag, ",".join(map(str, methods)), login))
                return
            sock.sendall(b"\x01\x00")
        else:
            sock.sendall(b"\x05\x00")
        _, command, _, atyp = exact(sock, 4)
        if atyp == 1:
            address = str(ipaddress.IPv4Address(exact(sock, 4)))
        elif atyp == 4:
            address = str(ipaddress.IPv6Address(exact(sock, 16)))
        elif atyp == 3:
            address = exact(sock, exact(sock, 1)[0]).decode()
        else:
            return self.reply(8)
        port = struct.unpack(">H", exact(sock, 2))[0]
        say("SAW %s %s %s %d %s %d" % (self.tag, ",".join(map(str, methods)), login, atyp, address, port))
        if command != 1:
            return self.reply(7)
        if 1 <= port <= 8:
            return self.reply(port)
        if port == 9:
            return self.reply(0, version=4)
        if port == 10:
            # Half a reply, then the close: a proxy that dies inside the handshake.
            return sock.sendall(bytes([5, 0]))
        if port == 11:
            # No reply at all, until the client gives up and closes.
            return sock.recv(1)
        try:
            upstream = socket.create_connection(("127.0.0.1", port), timeout=10)
        except OSError:
            return self.reply(5)
        sock.settimeout(None)
        self.reply(0)
        relay(sock, upstream)


class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    name = "?"

    def log_message(self, *args):
        pass

    def do_GET(self):
        body = ("hello from %s %s host=%s" % (self.name, self.path, self.headers.get("Host"))).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class Server(socketserver.ThreadingMixIn, socketserver.TCPServer):
    daemon_threads = True
    allow_reuse_address = True


class HttpServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def serve(server, tls=False):
    if tls:
        keys = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        keys.load_cert_chain(*(os.path.join(CERTS, name) for name in ("server.pem", "server-key.pem")))
        server.socket = keys.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    proxies = [type("Open", (Socks,), {"tag": "open"}), type("Locked", (Socks,), {"tag": "locked", "locked": True})]
    servers = [serve(Server(("127.0.0.1", 0), proxy)) for proxy in proxies]
    servers.append(serve(HttpServer(("127.0.0.1", 0), type("A", (Origin,), {"name": "A"}))))
    servers.append(serve(HttpServer(("127.0.0.1", 0), type("C", (Origin,), {"name": "C"})), tls=True))
    say(" ".join(str(server.server_address[1]) for server in servers))
    sys.stdin.read()
    for server in servers:
        server.shutdown()


main()
