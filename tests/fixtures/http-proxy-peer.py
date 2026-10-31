"""An HTTP forward proxy and two origin servers, all on 127.0.0.1 with port 0, for the client's proxy tests.

It prints one line, `proxy A B`, the three ports, and serves until its stdin closes. The proxy refuses anything but the
absolute-form request target (`GET http://host:port/path HTTP/1.1`, RFC 9112 3.2.2), forwards the request to the origin
named in it with http.client, and answers with a `Via` header. For each request it prints what it saw, so a test can
assert the request line and the `Host` header, and the number of the client connection it came on:

    SAW <connection> <request line> | <Host header>

The origins answer `/hello` (their name and the path with its query), `/big` (200000 bytes), and echo a body on any
other path (its size and its first 10 bytes). Standard library only.
"""
import http.client
import http.server
import socketserver
import sys
import threading

# Windows would print CRLF in the ANSI code page; the tests compare UTF-8 LF lines.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

HOP_BY_HOP = {"connection", "keep-alive", "proxy-connection", "transfer-encoding", "upgrade", "te", "trailer"}
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
        if self.path.startswith("/hello"):
            self.answer(("hello from %s %s" % (self.name, self.path)).encode())
        elif self.path == "/big":
            self.answer(b"x" * 200000)
        else:
            self.answer(b"got %d bytes: %s" % (len(body), body[:10]))

    do_GET = do_HEAD = do_POST = do_PUT = do_PATCH = do_DELETE = handle_any


class Proxy(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    connections = 0
    lock = threading.Lock()

    def log_message(self, *args):
        pass

    def setup(self):
        super().setup()
        with Proxy.lock:
            Proxy.connections += 1
            self.number = Proxy.connections

    def refuse(self, text):
        body = text.encode()
        self.send_response(400)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.close_connection = True

    def forward(self):
        body = read_body(self)
        say("SAW %d %s | %s" % (self.number, self.requestline, self.headers.get("Host")))
        if not self.path.startswith("http://"):
            return self.refuse("the request target must be in absolute form")
        rest = self.path[len("http://"):]
        authority, slash, path = rest.partition("/")
        host, _, port = authority.partition(":")
        origin = http.client.HTTPConnection(host, int(port or 80), timeout=10)
        headers = {name: value for name, value in self.headers.items()
                   if name.lower() not in HOP_BY_HOP and name.lower() != "content-length"}
        origin.request(self.command, "/" + path, body=body or None, headers=headers)
        answer = origin.getresponse()
        data = answer.read()
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


def serve(handler):
    server = Server(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    first = type("A", (Origin,), {"name": "A"})
    second = type("B", (Origin,), {"name": "B"})
    servers = [serve(Proxy), serve(first), serve(second)]
    say(" ".join(str(server.server_address[1]) for server in servers))
    sys.stdin.read()
    for server in servers:
        server.shutdown()


main()
