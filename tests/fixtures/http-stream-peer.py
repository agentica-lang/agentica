"""An independent peer for the streaming HTTP server of std/http: Python http.client reads each chunk as it arrives.

Usage: http-stream-peer.py PLAIN_PORT TLS_PORT CERTS_DIR. It prints one line per fact; the test compares the lines.
The server (tests/test_vm_http.py, STREAM_SERVER_PROGRAM) sends four pieces of /ticks with a pause between them.
"""
import http.client
import os
import socket
import ssl
import sys
import time

# Windows would print CRLF in the ANSI code page; the tests compare UTF-8 LF lines.
sys.stdout.reconfigure(encoding="utf-8", newline="\n")

PLAIN = int(sys.argv[1])
TLS = int(sys.argv[2])
CERTS = sys.argv[3]
# The server pauses PAUSE seconds between pieces; a piece that is held back until the next one is sent would arrive
# less than that after the one before. The bound leaves room for a slow machine.
PAUSE = 0.5
APART = 0.3


def plain():
    return http.client.HTTPConnection("127.0.0.1", PLAIN, timeout=20)


def secure():
    context = ssl.create_default_context(cafile=os.path.join(CERTS, "ca.pem"))
    return http.client.HTTPSConnection("localhost", TLS, timeout=20, context=context)


def read_pieces(response):
    """Every piece with the time it arrived: read1 returns what one chunk holds, as soon as that chunk is in."""
    pieces = []
    while True:
        data = response.read1(65536)
        if not data:
            return pieces
        pieces.append((time.monotonic(), data.decode()))


def ticks(label, conn):
    conn.request("GET", "/ticks")
    response = conn.getresponse()
    pieces = read_pieces(response)
    gaps = [later[0] - earlier[0] for earlier, later in zip(pieces, pieces[1:])]
    print(label, response.status, response.getheader("Transfer-Encoding"), response.getheader("Content-Length"),
          response.getheader("Content-Type"), [text for _, text in pieces])
    print(label + "-timing", "apart" if gaps and min(gaps) >= APART else "held back %s" % gaps)
    sock = conn.sock
    conn.request("GET", "/whole")
    whole = conn.getresponse()
    print(label + "-keep-alive", whole.status, whole.getheader("Content-Length"), whole.read().decode(),
          conn.sock is sock)


def head(conn):
    conn.request("HEAD", "/ticks")
    response = conn.getresponse()
    body = response.read()
    sock = conn.sock
    conn.request("GET", "/whole")
    whole = conn.getresponse()
    print("head", response.status, response.getheader("Transfer-Encoding"), body, whole.read().decode(),
          conn.sock is sock)


def said(label):
    """What the server says about the producer of /endless: it learns that the client left, and stops."""
    conn = plain()
    conn.request("GET", "/said")
    print(label, conn.getresponse().read().decode())
    conn.close()


def leave(label, conn):
    conn.request("GET", "/endless")
    response = conn.getresponse()
    first = response.read1(65536)
    # Close without reading the rest: the producer is mid-stream and ready to send more.
    conn.close()
    print(label + "-first", response.status, [first.decode()])
    said(label)


def silent_leave():
    """A client that sends the request and closes at once, before any piece is read."""
    s = socket.create_connection(("127.0.0.1", PLAIN), timeout=20)
    s.sendall(b"GET /endless HTTP/1.1\r\nHost: x\r\n\r\n")
    s.close()
    said("silent-leave")


def http10():
    s = socket.create_connection(("127.0.0.1", PLAIN), timeout=20)
    s.sendall(b"GET /ticks HTTP/1.0\r\n\r\n")
    got = b""
    while chunk := s.recv(4096):
        got += chunk
    s.close()
    print("http-1.0", got.split(b" ")[1].decode(), got.count(b"Transfer-Encoding"))


def main():
    ticks("plain", plain())
    ticks("tls", secure())
    head(plain())
    leave("plain-leave", plain())
    leave("tls-leave", secure())
    silent_leave()
    http10()


main()
