"""An HTTP forward proxy and two origin servers, all on 127.0.0.1 with port 0, for the client's proxy tests.

It prints one line, `proxy A B proxy2 locked C D`, the seven ports (two proxies that share nothing, a third that asks for
credentials, and two origins that speak TLS, with the certificate of tests/fixtures/tls/server.pem), and serves until
its stdin closes. The proxy refuses anything but the
absolute-form request target (`GET http://host:port/path HTTP/1.1`, RFC 9112 3.2.2), forwards the request to the origin
named in it with http.client, and answers with a `Via` header. For each request it prints what it saw, so a test can
assert the request line and the `Host` header, and the number of the client connection it came on (`<proxy>:<n>`, `1:1` the first connection of the first proxy):

    SAW <connection> <request line> | <Host header>

The origins answer `/hello` (their name and the path with its query), `/big` (200000 bytes), `/seen` (the
`Proxy-Authorization` values they received), and echo a body on any other path (its size and its first 10 bytes).

A proxy also takes `CONNECT host:port` (RFC 9110 9.3.6): it answers 200, then relays the bytes both ways until one side
closes. It refuses port 9 with 403 and answers 502 for a target it cannot reach, and a SAW line names the CONNECT like
any request. The TLS origins C and D answer as A and B do (`/407` answers 407 as the origin's own answer).

The locked proxy answers 407 with `Proxy-Authenticate` unless `Proxy-Authorization` is `LOGIN`, the Basic credentials of
the user `us@er` and the password `p:ss/w`; a SAW line of it ends with ` | <the Proxy-Authorization header, or ->`. No
proxy passes that header on to the origin, as a forward proxy does not (it is hop-by-hop), and an origin records it if
one does. Standard library only.
"""
import base64
import http.client
import os
import http.server
import socket
import socketserver
import ssl
import sys
import threading
import urllib.parse

# Windows would print CRLF in the ANSI code page; the tests compare UTF-8 LF lines.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

CERTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tls")
HOP_BY_HOP = {"connection", "keep-alive", "proxy-connection", "proxy-authorization", "transfer-encoding", "upgrade",
              "te", "trailer"}
LOGIN = "Basic " + base64.b64encode(b"us@er:p:ss/w").decode()
PRINT = threading.Lock()


def say(text):
    with PRINT:
        print(text, flush=True)


def read_body(handler):
    """The request body, whole: a Content-Length one or a chunked one."""
    if handler.headers.get("Transfer-Encoding", "").lower() == "chunked":
        body = b""
        while True:
            size = int(handler.rfile.readline().split(b";")[0], 16)
            if size == 0:
                while handler.rfile.readline() not in (b"\r\n", b"\n", b""):
                    pass
                return body
            body += handler.rfile.read(size)
            handler.rfile.readline()
    return handler.rfile.read(int(handler.headers.get("Content-Length", 0)))


class Origin(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    name = "?"
    # The Proxy-Authorization values that reached an origin after the proxy forwarded; `/seen` answers them.
    received = []

    def log_message(self, *args):
        pass

    def answer(self, body, status=200):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def handle_any(self):
        body = read_body(self)
        if self.headers.get("Proxy-Authorization") is not None:
            self.received.append(self.headers["Proxy-Authorization"])
        if self.path == "/seen":
            self.answer(("seen %s" % self.received).encode())
        elif self.path == "/407":
            self.answer(b"the origin wants credentials", 407)
        elif self.path.startswith("/hello"):
            self.answer(("hello from %s %s" % (self.name, self.path)).encode())
        elif self.path == "/big":
            self.answer(b"x" * 200000)
        else:
            self.answer(b"got %d bytes: %s" % (len(body), body[:10]))

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    tag = "?"
    locked = False

    def log_message(self, *args):
        pass

    def setup(self):
        super().setup()
        with self.lock:
            self.counter[0] += 1
            self.number = "%s:%d" % (self.tag, self.counter[0])

    def refuse(self, text, status=400):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def saw(self):
        """Prints the SAW line, and answers 407 (False) when this proxy is locked and the login is not the right one."""
        offered = self.headers.get("Proxy-Authorization")
        suffix = " | %s" % (offered or "-") if self.locked else ""
        say("SAW %s %s | %s%s" % (self.number, self.requestline, self.headers.get("Host"), suffix))
        if not self.locked or offered == LOGIN:
            return True
        body = b"credentials needed"
        self.send_response(407)
        self.send_header("Proxy-Authenticate", 'Basic realm="peer"')
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        return False

    def broken_tunnel(self, port):
        """Port 7: a proxy that never answers the CONNECT. Port 8: a 200 whose bytes carry junk after the head, in the
        one write, so the client has them before its TLS handshake. Both hold the socket until the client leaves."""
        if port == "8":
            self.wfile.write(b"HTTP/1.1 200 Connection Established\r\n\r\njunk")
            self.wfile.flush()
        self.connection.settimeout(10)
        try:
            self.connection.recv(1)
        except OSError:
            pass
        self.close_connection = True

    def do_CONNECT(self):
        if not self.saw():
            return
        host, _, port = self.path.rpartition(":")
        if port == "9":
            return self.refuse("this proxy does not tunnel to port 9", 403)
        if port in ("7", "8"):
            return self.broken_tunnel(port)
        try:
            upstream = socket.create_connection((host.strip("[]"), int(port)), timeout=10)
        except (OSError, ValueError):
            return self.refuse("bad gateway", 502)
        self.send_response(200, "Connection Established")
        self.end_headers()
        self.close_connection = True
        relay(self.connection, upstream)

    def forward(self):
        body = read_body(self)
        if not self.saw():
            return
        if not self.path.startswith("http://"):
            return self.refuse("the request target must be in absolute form")
        url = urllib.parse.urlsplit(self.path)
        path = url.path.lstrip("/") + ("?" + url.query if url.query else "")
        origin = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=10)
        headers = {name: value for name, value in self.headers.items()
                   if name.lower() not in HOP_BY_HOP and name.lower() != "content-length"}
        try:
            origin.request(self.command, "/" + path, body=body or None, headers=headers)
            answer = origin.getresponse()
            data = answer.read()
        except OSError:
            # An origin that is not there (an IPv6 literal the test only wants to see in the request line).
            body = b"bad gateway"
            self.send_response(502)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        self.send_response(answer.status)
        for name, value in answer.getheaders():
            if name.lower() not in HOP_BY_HOP and name.lower() != "content-length":
                self.send_header(name, value)
        self.send_header("Via", "1.1 proxy-peer")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)
        origin.close()

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = forward


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


def relay(client, upstream):
    """Copies bytes between the two sockets until one side ends, then closes both (a CONNECT tunnel)."""
    def pump(source, sink):
        try:
            while True:
                data = source.recv(65536)
                if not data:
                    break
                sink.sendall(data)
        except OSError:
            pass
        for sock in (source, sink):
            try:
                sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass

    back = threading.Thread(target=pump, args=(upstream, client), daemon=True)
    back.start()
    pump(client, upstream)
    back.join()
    upstream.close()


def serve(handler, tls=False):
    server = Server(("127.0.0.1", 0), handler)
    if tls:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(os.path.join(CERTS, "server.pem"), os.path.join(CERTS, "server-key.pem"))
        # The handshake runs in the handler's thread, on its first read, so a client that stalls blocks no one else.
        server.socket = context.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    first = type("A", (Origin,), {"name": "A"})
    second = type("B", (Origin,), {"name": "B"})
    proxies = [type("P%d" % n, (Proxy,), {"tag": str(n), "counter": [0], "lock": threading.Lock(), "locked": n == 3})
               for n in (1, 2, 3)]
    third = type("C", (Origin,), {"name": "C"})
    fourth = type("D", (Origin,), {"name": "D"})
    servers = [serve(proxies[0]), serve(first), serve(second), serve(proxies[1]), serve(proxies[2]),
               serve(third, tls=True), serve(fourth, tls=True)]
    say(" ".join(str(server.server_address[1]) for server in servers))
    sys.stdin.read()
    for server in servers:
        server.shutdown()


main()
