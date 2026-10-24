"""Peer for tests/test_vm_http_download.py: fixed binary bodies over plain HTTP and TLS.

The server bootstrap (quiet bind, TLS wrap, serve in a thread) is tests/fixtures/http-peer.py's;
only the handler is new here.

Usage: http-download-peer.py
Prints {"plain": port, "tls": port} as JSON on stdout, serves until stdin closes.
Every body streams the same deterministic binary pattern (bytes 0..255 repeating,
so NUL and invalid UTF-8 are in it); sizes come from the path, streamed in 64 KiB
pieces, so no side holds a large body at once.

Routes:
  /bin/<n>                 Content-Length body of n bytes
  /chunked/<n>             chunked body of n bytes
  /close/<n>               close-delimited body of n bytes
  /truncate/<declared>/<n> Content-Length <declared>, then only n bytes, then close
  /cut-chunk               a chunk header with half its data, then close
  /bad-chunk               invalid chunk framing
  /over-ceiling            Content-Length 256 MiB + 1, with no body
  /slow-head               sleeps 3 s, then a small 200 reply
  /status/<code>           a short ASCII body with that status
"""
import http.server
import importlib.util
import json
import os
import sys
import time

# Windows would print CRLF in the ANSI code page; the tests compare UTF-8 LF lines.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("http_peer", os.path.join(HERE, "http-peer.py"))
http_peer = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(http_peer)
PIECE = 65536
PATTERN = bytes(range(256)) * (PIECE // 256)
SLOW_SECONDS = 3
CEILING = 256 * 1024 * 1024


def pieces(count):
    """Yield count bytes of the binary pattern in PIECE chunks."""
    while count > 0:
        take = min(PIECE, count)
        yield PATTERN[:take]
        count -= take


class Web(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def send_body(self, status, count, framing):
        self.send_response(status)
        if framing == "length":
            self.send_header("Content-Length", str(count))
        elif framing == "chunked":
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        if framing == "chunked":
            for piece in pieces(count):
                self.wfile.write(b"%X\r\n" % len(piece))
                self.wfile.write(piece)
                self.wfile.write(b"\r\n")
            self.wfile.write(b"0\r\n\r\n")
        else:
            for piece in pieces(count):
                self.wfile.write(piece)

    def reply(self, status, text):
        data = text.encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        parts = self.path.split("/")
        if self.path == "/bad-chunk":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"zz\r\nabc\r\n0\r\n\r\n")
        elif self.path == "/cut-chunk":
            self.send_response(200)
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            self.wfile.write(b"1000\r\n")
            self.wfile.write(PATTERN[:100])
            self.close_connection = True
        elif self.path == "/over-ceiling":
            self.send_response(200)
            self.send_header("Content-Length", str(CEILING + 1))
            self.end_headers()
            self.close_connection = True
        elif self.path == "/slow-head":
            time.sleep(SLOW_SECONDS)
            self.reply(200, "late")
        elif len(parts) == 3 and parts[1] in ("bin", "chunked", "close") and parts[2].isdigit():
            framing = {"bin": "length", "chunked": "chunked", "close": "close"}[parts[1]]
            if framing == "close":
                self.close_connection = True
            self.send_body(200, int(parts[2]), framing)
        elif len(parts) == 4 and parts[1] == "truncate" and parts[2].isdigit() and parts[3].isdigit():
            self.send_response(200)
            self.send_header("Content-Length", parts[2])
            self.end_headers()
            for piece in pieces(int(parts[3])):
                self.wfile.write(piece)
            self.close_connection = True
        elif len(parts) == 3 and parts[1] == "status" and parts[2].isdigit():
            self.reply(int(parts[2]), "status %s" % parts[2])
        else:
            self.reply(404, "no such route")


def main():
    ports = http_peer.serve_pair(Web)
    print(json.dumps(ports), flush=True)
    sys.stdin.read()


if __name__ == "__main__":
    main()
