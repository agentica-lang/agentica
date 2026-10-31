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


def stream_twice(label, conn, path, with_type):
    """Read a streamed answer piece by piece, then a whole one on the same connection to see it stays usable."""
    conn.request("GET", path)
    response = conn.getresponse()
    pieces = read_pieces(response)
    gaps = [later[0] - earlier[0] for earlier, later in zip(pieces, pieces[1:])]
    head = [response.status, response.getheader("Transfer-Encoding"), response.getheader("Content-Length")]
    if with_type:
        head.append(response.getheader("Content-Type"))
    print(label, *head, [text for _, text in pieces])
    print(label + "-timing", "apart" if gaps and min(gaps) >= APART else "held back %s" % gaps)
    sock = conn.sock
    conn.request("GET", "/whole")
    whole = conn.getresponse()
    print(label + "-keep-alive", whole.status, whole.getheader("Content-Length"), whole.read().decode(),
          conn.sock is sock)


def ticks(label, conn):
    stream_twice(label, conn, "/ticks", True)


def sized(label, conn):
    """A body with a length: Content-Length and no Transfer-Encoding, the pieces as they were sent, apart in time."""
    stream_twice(label, conn, "/sized", False)


def sized_head():
    conn = plain()
    conn.request("HEAD", "/sized")
    response = conn.getresponse()
    body = response.read()
    sock = conn.sock
    conn.request("GET", "/whole")
    whole = conn.getresponse()
    print("sized-head", response.status, response.getheader("Content-Length"), response.getheader("Transfer-Encoding"),
          body, whole.read().decode(), conn.sock is sock)


def sized_cut(label, path):
    """A body that ends short, or whose next piece would pass the length: the connection closes, the body is
    incomplete."""
    conn = plain()
    conn.request("GET", path)
    response = conn.getresponse()
    try:
        response.read()
        print(label, response.status, response.getheader("Content-Length"), "complete")
    except http.client.IncompleteRead as error:
        print(label, response.status, response.getheader("Content-Length"), "incomplete", error.partial)
    conn.close()


def sized_extra():
    """A producer that sends more after the length is full: the client has its whole body, and the connection closes
    instead of waiting for another request."""
    s = socket.create_connection(("127.0.0.1", PLAIN), timeout=20)
    s.sendall(b"GET /sized-extra HTTP/1.1\r\nHost: x\r\n\r\n")
    got = b""
    while not got.endswith(b"abcde"):
        got += s.recv(4096)
    try:
        end = "closed" if s.recv(4096) == b"" else "open"
    except OSError:
        end = "closed"
    print("sized-extra", got.split(b" ")[1].decode(), got.split(b"Content-Length: ")[1].split(b"\r\n")[0].decode(),
          got.split(b"\r\n\r\n")[1], end)
    s.close()


def sized_whole():
    """A closed body is sent whole whatever the route, but its size must be the length it was given."""
    conn = plain()
    conn.request("GET", "/sized-whole")
    response = conn.getresponse()
    print("sized-whole", response.status, response.getheader("Content-Length"), response.read())
    conn.request("GET", "/sized-wrong")
    wrong = conn.getresponse()
    wrong.read()
    print("sized-wrong", wrong.status)
    conn.close()


def head(conn):
    conn.request("HEAD", "/ticks")
    response = conn.getresponse()
    body = response.read()
    sock = conn.sock
    conn.request("GET", "/whole")
    whole = conn.getresponse()
    print("head", response.status, response.getheader("Transfer-Encoding"), body, whole.read().decode(),
          conn.sock is sock)


def binary(label, conn):
    """Bytes that are not UTF-8 arrive as they were sent, as a stream and as one body with a length.

    Whether /binary goes out in chunks or whole depends on timing: a producer that has already finished and closed the
    body when the server looks at it gives a whole body with a Content-Length (a slow machine, or TSan, does that). So
    the line checks the bytes and that the framing matches them, never the chunk boundaries."""
    conn.request("GET", "/binary")
    response = conn.getresponse()
    body = response.read()
    chunked = response.getheader("Transfer-Encoding") == "chunked"
    framed = chunked or response.getheader("Content-Length") == str(len(body))
    print(label, response.status, body, "framed" if framed else "mis-framed")
    conn.request("GET", "/binary-whole")
    whole = conn.getresponse()
    print(label + "-whole", whole.status, whole.getheader("Content-Length"), whole.read())


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


def half_close():
    """A client that closes only its sending side counts as gone: the body is cut, and the last chunk is not sent, so
    the client sees an incomplete body, not a finished one."""
    s = socket.create_connection(("127.0.0.1", PLAIN), timeout=20)
    s.sendall(b"GET /endless HTTP/1.1\r\nHost: x\r\n\r\n")
    s.shutdown(socket.SHUT_WR)
    got = b""
    while chunk := s.recv(65536):
        got += chunk
    s.close()
    print("half-close", got.startswith(b"HTTP/1.1 200"), b"0\r\n\r\n" in got[-7:])
    said("half-close")


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
    sized("plain-sized", plain())
    sized("tls-sized", secure())
    sized_head()
    sized_cut("sized-short", "/sized-short")
    sized_cut("sized-long", "/sized-long")
    sized_extra()
    sized_whole()
    binary("binary", plain())
    binary("tls-binary", secure())
    leave("plain-leave", plain())
    leave("tls-leave", secure())
    silent_leave()
    half_close()
    http10()


main()
