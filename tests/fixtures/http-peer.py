import http.server
import json
import os
import socket
import socketserver
import ssl
import sys
import threading

CERTS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "tls")
GATE = threading.Barrier(3, timeout=10)

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

    def handle_error(self, request, client_address):
        pass


class Raw(socketserver.BaseRequestHandler):
    def handle(self):
        data = b""
        while b"\r\n\r\n" not in data:
            chunk = self.request.recv(65536)
            if not chunk:
                return
            data += chunk
        path = data.split(b" ")[1].decode()
        if path == "/early":
            self.request.sendall(b"HTTP/1.1 413 Payload Too Large\r\nConnection: close\r\nContent-Length: 4\r\n\r\nbig!")
            self.request.shutdown(socket.SHUT_WR)
            while self.request.recv(65536):
                pass
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


def main():
    plain = Quiet(("127.0.0.1", 0), Web)
    secure = Quiet(("127.0.0.1", 0), Web)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERTS, "server.pem"), os.path.join(CERTS, "server-key.pem"))
    secure.socket = context.wrap_socket(secure.socket, server_side=True)
    raw = RawServer(("127.0.0.1", 0), Raw)
    ports = {"plain": start(plain), "tls": start(secure), "raw": start(raw)}
    print(json.dumps(ports), flush=True)
    sys.stdin.read()


if __name__ == "__main__":
    main()
