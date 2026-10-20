import http.client
import os
import socket
import ssl
import subprocess
import sys
import time

PORT = int(sys.argv[1])
HOST = b"Host: x\r\n"


def head(start, *lines):
    return start + b"\r\n" + HOST + b"".join(line + b"\r\n" for line in lines) + b"\r\n"


def many(count):
    return [b"X-%d: v" % k for k in range(count)]


CLOSE = b"Connection: close"
CHUNKED = b"Transfer-Encoding: chunked"

HOSTILE = [
    ("length-and-chunked", head(b"POST / HTTP/1.1", b"Content-Length: 5", CHUNKED) + b"0\r\n\r\n"),
    ("two-lengths", head(b"POST / HTTP/1.1", b"Content-Length: 1", b"Content-Length: 2") + b"ab"),
    ("equal-lengths", head(b"POST / HTTP/1.1", CLOSE, b"Content-Length: 2", b"Content-Length: 2") + b"ab"),
    ("equal-length-list", head(b"POST / HTTP/1.1", CLOSE, b"Content-Length: 2, 2") + b"ab"),
    ("gzip", head(b"POST / HTTP/1.1", b"Transfer-Encoding: gzip")),
    ("gzip-chunked", head(b"POST / HTTP/1.1", b"Transfer-Encoding: gzip, chunked") + b"0\r\n\r\n"),
    ("two-encodings", head(b"POST / HTTP/1.1", CHUNKED, CHUNKED) + b"0\r\n\r\n"),
    ("huge-chunk", head(b"POST / HTTP/1.1", CHUNKED) + b"ffffffffffffffffffffffff\r\n"),
    ("bad-chunk", head(b"POST / HTTP/1.1", CHUNKED) + b"zz\r\nab\r\n0\r\n\r\n"),
    ("bare-lf", b"GET / HTTP/1.1\nHost: x\n\n"),
    ("long-line", head(b"GET /" + b"a" * 9000 + b" HTTP/1.1")),
    ("long-head", head(b"GET / HTTP/1.1", *[b"X-%d: " % k + b"v" * 1000 for k in range(70)])),
    ("headers-100", head(b"GET / HTTP/1.1", CLOSE, *many(98))),
    ("headers-101", head(b"GET / HTTP/1.1", CLOSE, *many(99))),
    ("headers-150", head(b"GET / HTTP/1.1", *many(149))),
    ("long-trailer", head(b"POST / HTTP/1.1", CHUNKED) + b"0\r\nX: " + b"a" * 9000 + b"\r\n\r\n"),
    ("many-trailers", head(b"POST / HTTP/1.1", CHUNKED) + b"0\r\n" + b"".join(b"T-%d: v\r\n" % k for k in range(101)) + b"\r\n"),
    ("bad-trailer", head(b"POST / HTTP/1.1", CHUNKED) + b"0\r\nContent-Length: 2\r\n\r\n"),
    ("http-1", head(b"GET / HTTP/1")),
    ("http-2", head(b"GET / HTTP/2")),
    ("http-1.10", head(b"GET / HTTP/1.10")),
    ("http-2.0", head(b"GET / HTTP/2.0")),
    ("http-1.0", head(b"GET / HTTP/1.0")),
    ("http-2.0-headers", head(b"GET / HTTP/2.0", *many(101))),
    ("bad-version", head(b"GET / HTTX/1.1")),
    ("leading-crlf", b"\r\n" + head(b"GET / HTTP/1.1", CLOSE, *many(98))),
    ("absolute-target", head(b"GET http://x/ HTTP/1.1")),
    ("non-ascii-target", head("GET /ñ HTTP/1.1".encode())),
    ("star-get", head(b"GET * HTTP/1.1")),
    ("star-options", head(b"OPTIONS * HTTP/1.1", CLOSE)),
    ("bad-method", head(b"G(T / HTTP/1.1")),
    ("connect", head(b"CONNECT x:443 HTTP/1.1")),
    ("upgrade", head(b"GET / HTTP/1.1", b"Upgrade: websocket", b"Connection: upgrade")),
    ("fold", head(b"GET / HTTP/1.1", b"X-A: one", b" two")),
    ("expect-other", head(b"POST / HTTP/1.1", b"Expect: 200-ok", b"Content-Length: 2") + b"ab"),
    ("over-limit", head(b"POST / HTTP/1.1", b"Content-Length: 1025")),
    ("chunked-over-limit", head(b"POST / HTTP/1.1", CHUNKED) + b"401\r\n" + b"a" * 1025 + b"\r\n0\r\n\r\n"),
    ("non-utf8", head(b"POST / HTTP/1.1", b"Content-Length: 2") + b"\xff\xfe"),
    ("no-host", b"GET / HTTP/1.1\r\n\r\n"),
    ("two-hosts", head(b"GET / HTTP/1.1", b"Host: y")),
    ("short-505", b"GET / HTTP/1\r\n"),
]


def connect():
    s = socket.create_connection(("127.0.0.1", PORT), timeout=10)
    s.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    return s


def drain(s):
    data = b""
    while True:
        try:
            part = s.recv(65536)
        except ConnectionResetError:
            return data, "reset"
        if not part:
            return data, "closed"
        data += part


def status(data):
    if not data.startswith(b"HTTP/1.1 "):
        return "none"
    return data[9:12].decode()


def send(s, data):
    try:
        s.sendall(data)
    except (BrokenPipeError, ConnectionResetError):
        pass


def hostile():
    for name, data in HOSTILE:
        s = connect()
        send(s, data)
        if name == "short-505":
            started = time.monotonic()
            got, end = drain(s)
            quick = time.monotonic() - started < 1.5
            print(name, status(got), end, "quick" if quick else "slow")
        else:
            got, end = drain(s)
            print(name, status(got), end)
        s.close()
    s = connect()
    send(s, b"BAD\r\n")
    started = time.monotonic()
    got, end = drain(s)
    print("bad-line-open", status(got), end, "quick" if time.monotonic() - started < 1.5 else "slow")
    s.close()
    s = connect()
    send(s, b"GET / HTTP/1.1\r\nHost: x\r\n")
    started = time.monotonic()
    got, end = drain(s)
    waited = time.monotonic() - started
    print("partial-head", status(got), end, "bounded" if 1.5 < waited < 10 else "unbounded %.1f" % waited)
    s.close()


def expect_over_limit():
    s = connect()
    send(s, head(b"POST / HTTP/1.1", b"Expect: 100-continue", b"Content-Length: 4096"))
    got, end = drain(s)
    print("expect-over-limit", got.split(b"\r\n", 1)[0].decode(), b"100 Continue" in got, end)
    s.close()


def expect_continue():
    s = connect()
    send(s, head(b"POST /expect HTTP/1.1", b"Expect: 100-continue", b"Content-Length: 5", CLOSE))
    first = s.recv(65536)
    send(s, b"hello")
    got, end = drain(s)
    print("expect-continue", first.split(b"\r\n", 1)[0].decode(), status(got), got.split(b"\r\n\r\n", 1)[1].decode(), end)
    s.close()


def pipelined():
    s = connect()
    # The chunked body's last framing read takes the next request's bytes too; they must reach the next head.
    send(s, head(b"GET /one HTTP/1.1") + head(b"POST /two HTTP/1.1", b"Content-Length: 3") + b"abc"
         + head(b"POST /four HTTP/1.1", CHUNKED) + b"3\r\nabc\r\n0\r\n\r\n" + head(b"GET /three HTTP/1.1", CLOSE))
    got, end = drain(s)
    bodies = []
    rest = got
    while rest:
        top, rest = rest.split(b"\r\n\r\n", 1)
        length = int([line for line in top.split(b"\r\n") if line.lower().startswith(b"content-length:")][0].split(b":")[1])
        bodies.append(rest[:length].decode())
        rest = rest[length:]
    print("pipelined", bodies, end)
    s.close()


def client():
    conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
    conn.request("POST", "/chunked", body=iter([b"ab", "ñ".encode(), b"cd"]), encode_chunked=True)
    response = conn.getresponse()
    print("client-chunked", response.status, response.read().decode())
    first = conn.sock
    conn.request("HEAD", "/head")
    response = conn.getresponse()
    print("client-head", response.status, response.getheader("Content-Length"), repr(response.read()))
    conn.request("GET", "/again")
    response = conn.getresponse()
    print("client-again", response.status, response.read().decode(), conn.sock is first)
    conn.close()


def slots(limit):
    held = []
    for k in range(limit):
        conn = http.client.HTTPConnection("127.0.0.1", PORT, timeout=10)
        conn.request("GET", "/slot%d" % k)
        response = conn.getresponse()
        response.read()
        held.append(conn)
    extra = connect()
    send(extra, head(b"GET /waiting HTTP/1.1", CLOSE))
    extra.settimeout(0.5)
    try:
        early = extra.recv(65536)
    except socket.timeout:
        early = b""
    print("slots", limit, "waiting" if early == b"" else "served early")
    held[0].close()
    extra.settimeout(10)
    got, end = drain(extra)
    print("slot-freed", status(got), got.split(b"\r\n\r\n", 1)[1].decode(), end)
    extra.close()
    for conn in held[1:]:
        conn.close()


def secure(port, certs):
    context = ssl.create_default_context(cafile=os.path.join(certs, "ca.pem"))
    conn = http.client.HTTPSConnection("localhost", port, timeout=10, context=context)
    conn.request("GET", "/one")
    one = conn.getresponse()
    first = (one.status, one.read().decode())
    sock = conn.sock
    conn.request("POST", "/two", body="over tls")
    two = conn.getresponse()
    print("tls-keep-alive", *first, two.status, two.read().decode(), conn.sock is sock)
    conn.close()
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    started = time.monotonic()
    got, end = drain(s)
    waited = time.monotonic() - started
    print("tls-silent", end, "bounded" if 1.5 < waited < 10 and got == b"" else "unbounded %.1f %r" % (waited, got))
    s.close()
    s = socket.create_connection(("127.0.0.1", port), timeout=10)
    send(s, head(b"GET / HTTP/1.1", CLOSE))
    got, end = drain(s)
    print("tls-plain", end if not got.startswith(b"HTTP/") else "answered in plain text")
    s.close()


def rss_kb(pid):
    return int(subprocess.run(["ps", "-o", "rss=", "-p", pid], capture_output=True, text=True, check=True).stdout)


def flood(vm_pid):
    # The property is that the server does not buffer pipelined requests it
    # has not read, so this checks the VM's memory, not the bytes sent: the
    # kernel or the server's lingering close may accept and drop many bytes
    # (on macOS more than 256 MB at times, #408).
    s = connect()
    send(s, head(b"GET /big HTTP/1.1"))
    s.recv(4096)
    before = rss_kb(vm_pid)
    junk = head(b"GET / HTTP/1.1") * 2048
    s.settimeout(0.5)
    total = 0
    try:
        while total < 256 * 1024 * 1024:
            total += s.send(junk)
    except (socket.timeout, BrokenPipeError, ConnectionResetError):
        pass
    grown = rss_kb(vm_pid) - before
    print("flood", "bounded" if grown < 64 * 1024 else "unbounded %d KB after %d bytes" % (grown, total))
    s.close()


def main():
    hostile()
    expect_over_limit()
    expect_continue()
    pipelined()
    client()
    slots(int(sys.argv[2]))
    secure(int(sys.argv[3]), sys.argv[4])
    flood(sys.argv[5])


main()
