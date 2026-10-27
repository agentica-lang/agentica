import http.server
import json
import os
import socket
import socketserver
import ssl
import sys
import threading
import time

# Windows would print CRLF in the ANSI code page; the tests compare UTF-8 LF lines.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

CERTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tls")
GATE = threading.Barrier(3, timeout=10)
HELD = []
# Set by every connection of the raw server; /early waits on it (see there).
ARRIVED = threading.Event()

RAW = {
    "/http10": b"HTTP/1.0 200 OK\r\nContent-Length: 2\r\n\r\nok",
    "/status99": b"HTTP/1.1 99 Odd\r\nContent-Length: 0\r\n\r\n",
    "/status600": b"HTTP/1.1 600 Odd\r\nContent-Length: 0\r\n\r\n",
    "/upgrade": b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: x\r\nConnection: upgrade\r\n\r\n",
    "/interim15": b"HTTP/1.1 100 Continue\r\n\r\n" * 15 + b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok",
    "/interim16": b"HTTP/1.1 100 Continue\r\n\r\n" * 16 + b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok",
    "/badchunk": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\nabc\r\n0\r\n\r\n",
    "/atlimit": b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1000\r\n\r\n" + b"x" * 1000,
    "/big": b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 1001\r\n\r\n" + b"x" * 1001,
    "/bigchunks": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n200\r\n" + b"y" * 512 + b"\r\n200\r\n" + b"y" * 512 + b"\r\n0\r\n\r\n",
    "/barelf": b"HTTP/1.1 200 OK\nContent-Length: 2\n\nok",
    "/fold": b"HTTP/1.1 200 OK\r\nX-A: one\r\n two\r\nContent-Length: 2\r\n\r\nok",
    "/twolengths": b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nContent-Length: 3\r\n\r\nok",
    "/smuggle": b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\n\r\n",
    "/gzip": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n0\r\n\r\n",
    "/badtrailer": b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\nContent-Length: 2\r\n\r\n",
    "/after": b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 2\r\n\r\nok",
    "/truncated": b"HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc",
    "/headerless": b"",
}


class Web(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body, headers=()):
        data = body.encode()
        self.send_response(status)
        for name, value in headers:
            self.send_header(name, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        port = str(self.client_address[1])
        if self.path == "/hello":
            self.reply(200, "hello " + self.headers["Host"].split(":")[0], [("X-Multi", "a"), ("X-Multi", "b")])
        elif self.path == "/port":
            self.reply(200, port)
        elif self.path == "/gate":
            GATE.wait()
            self.reply(200, port)
        elif self.path == "/chunked":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            for piece in [b"\xc3", b"\xb1and\xc3\xba", b" chunks"]:
                self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece))
            self.wfile.write(b"0\r\nX-Trailer: t\r\n\r\n")
        elif self.path == "/close":
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"until the end")
            self.close_connection = True
        elif self.path == "/notify":
            self.send_response(200)
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(b"closed cleanly")
            self.wfile.flush()
            self.connection.unwrap()
            self.close_connection = True
        elif self.path == "/hold":
            HELD.append(port)
            threading.Event().wait(3)
            self.close_connection = True
        elif self.path == "/held":
            self.reply(200, str(len(HELD)))
        elif self.path == "/slow":
            threading.Event().wait(3)
            self.close_connection = True
        else:
            self.reply(404, "missing")

    def do_POST(self):
        body = self.rfile.read(int(self.headers["Content-Length"]))
        self.reply(200, "%s %d %s" % (self.headers.get("X-Kind"), len(body), body[:8].decode()))


class Quiet(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def server_bind(self):
        # HTTPServer.server_bind sets server_name with socket.getfqdn(host),
        # and on the macOS CI runners that reverse lookup of 127.0.0.1 takes
        # about 35 s, longer than the test waits for the ports line (#407).
        # Nothing here reads server_name, so skip the lookup.
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]

    def handle_error(self, request, client_address):
        pass


class Raw(socketserver.BaseRequestHandler):
    def handle(self):
        began = time.monotonic()
        ARRIVED.set()
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.request.recv(65536)
            if not chunk:
                return
            data += chunk
        path = data.split(b" ")[1].decode()
        if path == "/early":
            # The 413 goes out while the upload is still coming. The rest of the upload is not read until the
            # client has the answer (its program's next connection shows it, or 10 s pass): with the upload stuck
            # on a full window, the client's send returns and it reads the 413 now. Reading at once let the whole
            # 4 MiB go out first, and on a loaded macOS runner one send call lasts as long as the upload, so the
            # 413 was read past the 5 s deadline (#692). The rest is then read to the end, so the close sends no
            # RST. The program of test_vm_http.py must open its next raw connection (/stale) after reading the 413.
            ARRIVED.clear()
            answered = time.monotonic()
            self.request.sendall(b"HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\nContent-Length: 4\r\n\r\nbig!")
            self.request.shutdown(socket.SHUT_WR)
            released = ARRIVED.wait(10)
            waited = time.monotonic()
            drained = 0
            try:
                while chunk := self.request.recv(65536):
                    drained += len(chunk)
            finally:
                # One line for the test, which prints it when the case fails: it tells a client that sent its head
                # late from one that did not read the answer (seconds since this connection was accepted).
                print("early: head at %.3f s, released by the next connection: %s at %.3f s, drained %d bytes"
                      % (answered - began, released, waited - began, drained), flush=True)
            return
        if path == "/stale":
            self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nstale")
            self.request.recv(65536)
            return
        if path == "/headlength":
            self.request.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n")
            if self.request.recv(65536):
                self.request.sendall(b"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 6\r\n\r\nreused")
            return
        if path == "/nocontent":
            self.request.sendall(b"HTTP/1.1 204 No Content\r\nContent-Length: 5\r\n\r\n")
            if self.request.recv(65536):
                self.request.sendall(b"helloHTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nreused")
            return
        self.request.sendall(RAW[path])
        if path in ("/truncated", "/headerless"):
            self.request.shutdown(socket.SHUT_WR)


class RawServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        pass


def start(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def serve_pair(handler):
    """Start a plain and a TLS server with handler; return {"plain": port, "tls": port}."""
    plain = Quiet(("127.0.0.1", 0), handler)
    secure = Quiet(("127.0.0.1", 0), handler)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERTS, "server.pem"), os.path.join(CERTS, "server-key.pem"))
    secure.socket = context.wrap_socket(secure.socket, server_side=True)
    return {"plain": start(plain), "tls": start(secure)}


def main():
    ports = serve_pair(Web)
    raw = RawServer(("127.0.0.1", 0), Raw)
    ports["raw"] = start(raw)
    print(json.dumps(ports), flush=True)
    sys.stdin.read()


if __name__ == "__main__":
    main()
