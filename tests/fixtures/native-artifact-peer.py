"""Peer for tests/test_spec_package_native_artifact.py: TAR archives over plain HTTP and TLS.

Serves small TAR and gzipped TAR archives built at startup (plus broken variants: a ZIP, plain
text, a gzip with trailing bytes, a late checksum corruption), fixed redirect routes (relative,
absolute, full URL, query, dot segments, loops, chains, downgrade, multi/no Location), status
codes, a slow endpoint and a truncated body. Prints {"plain": port, "tls": port, "log": path} as
JSON on stdout, serves until stdin closes. Everything is on 127.0.0.1 with port 0; only the
standard library is used. Request paths go to the log file, so the tests can prove a case used
no network at all.
"""
import gzip
import hashlib
import http.server
import io
import json
import os
import socketserver
import ssl
import sys
import tarfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
CERTS = os.path.join(HERE, "tls")
LOG = None
LOGGED = []
LOCK = threading.Lock()
ARCHIVES = {}


def log(path):
    with LOCK:
        LOGGED.append(path)
        with open(LOG, "a", encoding="utf-8") as handle:
            handle.write(path + "\n")


def blob(data):
    return data if isinstance(data, bytes) else data.encode("utf-8")


def tar_bytes(entries, gzip_it=False):
    """A TAR of (name, bytes-or-(kind, linkname)) entries; gzip_it compresses it."""
    out = io.BytesIO()
    with tarfile.open(fileobj=out, mode="w") as tar:
        for name, payload in entries:
            if isinstance(payload, tuple):
                info = tarfile.TarInfo(name)
                info.type = payload[0]
                info.linkname = payload[1]
                info.mtime = 0
                tar.addfile(info)
            else:
                data = blob(payload)
                info = tarfile.TarInfo(name)
                info.size = len(data)
                info.mode = 0o644
                info.mtime = 0
                tar.addfile(info, io.BytesIO(data))
    raw = out.getvalue()
    return gzip.compress(raw) if gzip_it else raw


def build():
    binary = bytes(range(256)) + "héllo-☃-invalid-\xff\xfe".encode("utf-8", "ignore") + b"\x00\xff"
    lib = [
        ("lib.bin", binary),
        ("sub/deep.bin", b"deep-bytes"),
        ("./dot.bin", b"dot-spelling"),
    ]
    ARCHIVES["lib.tar"] = tar_bytes(lib)
    ARCHIVES["lib.tar.gz"] = tar_bytes(lib, gzip_it=True)
    ARCHIVES["other.tar"] = tar_bytes([("other.bin", b"other-bytes")])
    ARCHIVES["evil.tar"] = tar_bytes([("../evil", b"escape"), ("good.bin", b"good-bytes")])
    ARCHIVES["link.tar"] = tar_bytes([("link", (tarfile.SYMTYPE, "lib.bin")), ("lib.bin", b"real")])
    ARCHIVES["dup.tar"] = tar_bytes([("dup.bin", b"first"), ("dup.bin", b"second")])
    good = tar_bytes([("late.bin", b"late-bytes"), ("second.bin", b"second-bytes")])
    bad = bytearray(good)
    # Corrupt the checksum field (offset 148, 8 bytes) of the second entry header.
    first_size = 512 + ((len(b"late-bytes") + 511) // 512) * 512
    bad[first_size + 148:first_size + 156] = b"00000000"
    ARCHIVES["late.tar"] = bytes(bad)
    ARCHIVES["empty.tar"] = b""
    ARCHIVES["text"] = b"this is not an archive at all"
    import zipfile
    zipped = io.BytesIO()
    with zipfile.ZipFile(zipped, "w") as zf:
        zf.writestr("zipped.bin", b"zip-bytes")
    ARCHIVES["sneaky.tar.gz"] = zipped.getvalue()
    ARCHIVES["trailing.tar.gz"] = gzip.compress(tar_bytes([("t.bin", b"t")])) + b"TRAIL"


class Web(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ArtifactPeer/1"

    def log_message(self, *args):
        pass

    def send_tar(self, name):
        data = ARCHIVES[name]
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def redirect(self, *locations):
        body = b"moved\n"
        self.send_response(302)
        for location in locations:
            self.send_header("Location", location)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        log(self.path)
        plain = "http://127.0.0.1:%d" % PLAIN_PORT
        secure = "https://127.0.0.1:%d" % TLS_PORT
        bare = self.path.split("?", 1)[0]
        if bare.startswith("/t/") or bare.startswith("/g/"):
            self.send_tar(bare[3:])
        elif bare == "/r-rel":
            self.redirect("t/lib.tar")
        elif bare == "/r-abs":
            self.redirect("/t/lib.tar")
        elif bare == "/r-full":
            self.redirect(plain + "/t/lib.tar")
        elif bare == "/r-query":
            self.redirect("/t/lib.tar?token=s3cr3t-signed-query")
        elif bare == "/r-dot":
            self.redirect("./sub/../t/lib.tar")
        elif bare == "/r-loop":
            self.redirect("/r-loop")
        elif bare == "/r-pair-a":
            self.redirect("/r-pair-b")
        elif bare == "/r-pair-b":
            self.redirect("/r-pair-a")
        elif bare.startswith("/r-chain/"):
            left = int(bare.rsplit("/", 1)[1])
            if left > 0:
                self.redirect("/r-chain/%d" % (left - 1))
            else:
                self.send_tar("lib.tar")
        elif bare == "/r-down":
            self.redirect(plain + "/t/lib.tar")
        elif bare == "/r-up":
            self.redirect(secure + "/t/lib.tar")
        elif bare == "/r-scheme":
            self.redirect("//127.0.0.1:%d/t/lib.tar" % PLAIN_PORT)
        elif bare == "/r-schemeq":
            self.redirect("//127.0.0.1:%d/t/lib.tar?token=qq-signed" % PLAIN_PORT)
        elif bare == "/r-ext":
            self.redirect("//example.com/t/lib.tar")
        elif bare == "/r-multi":
            self.redirect("/t/lib.tar", "/t/other.tar")
        elif bare == "/r-noloc":
            body = b"moved\n"
            self.send_response(302)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        elif bare == "/gone":
            self.send_response(404)
            self.send_header("Content-Length", "9")
            self.end_headers()
            self.wfile.write(b"no entry\n")
        elif bare == "/slow":
            time.sleep(5)
            self.send_tar("lib.tar")
        elif bare == "/trunc":
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.send_header("Content-Length", "100")
            self.end_headers()
            self.wfile.write(b"0123456789")
            # The server then shuts the socket down and closes it (a FIN after the bytes, no reset): the
            # request was read in full. A bare socket close here would not end the connection while the
            # handler's files still hold it.
            self.close_connection = True
        else:
            self.send_response(404)
            self.send_header("Content-Length", "9")
            self.end_headers()
            self.wfile.write(b"no route\n")


class QuietServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    # The default queue holds 5 connections and a test opens 8 at once; Windows refuses a connection past it.
    request_queue_size = 32


def serve(server):
    threading.Thread(target=server.serve_forever, daemon=True).start()


if __name__ == "__main__":
    build()
    LOG = sys.argv[1]
    open(LOG, "w").close()
    plain_server = QuietServer(("127.0.0.1", 0), Web)
    PLAIN_PORT = plain_server.server_address[1]
    tls_server = QuietServer(("127.0.0.1", 0), Web)
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(os.path.join(CERTS, "server.pem"), os.path.join(CERTS, "server-key.pem"))
    tls_server.socket = context.wrap_socket(tls_server.socket, server_side=True)
    TLS_PORT = tls_server.server_address[1]
    self_server = QuietServer(("127.0.0.1", 0), Web)
    self_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    self_context.load_cert_chain(os.path.join(CERTS, "self-signed.pem"),
                                 os.path.join(CERTS, "self-signed-key.pem"))
    self_server.socket = self_context.wrap_socket(self_server.socket, server_side=True)
    SELF_PORT = self_server.server_address[1]
    serve(plain_server)
    serve(tls_server)
    serve(self_server)
    print(json.dumps({"plain": PLAIN_PORT, "tls": TLS_PORT, "self": SELF_PORT}), flush=True)
    sys.stdin.read()
