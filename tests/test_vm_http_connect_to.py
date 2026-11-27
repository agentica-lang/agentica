"""`connect_to` of the std/http client (#1556): the connection goes to a chosen IP address while `Host`, the TLS server
name and the certificate check keep the host of the URL. The peer is a raw Python socket server on 127.0.0.1 with port 0
(plain, and TLS with a test certificate for `wrong.example`), so no name resolves and no external service is used.
"""
import socket
import ssl
import threading

import pytest

from tests.agentica_test import FIXTURES, compile_text, output_lines, run_vm, vm_environment

TLS_DIR = FIXTURES / "tls"


class Peer:
    """Answers every request with `host=<Host header> <body>`, on a plain port and on a TLS port."""

    def __init__(self, v6=False):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(TLS_DIR / "wrong-host.pem", TLS_DIR / "wrong-host-key.pem")
        self.plain = self.listen("::1" if v6 else "127.0.0.1")
        self.secure = self.listen()
        self.context = context
        self.stopped = threading.Event()
        threading.Thread(target=self.accept, args=(self.plain, False), daemon=True).start()
        threading.Thread(target=self.accept, args=(self.secure, True), daemon=True).start()

    @staticmethod
    def listen(host="127.0.0.1"):
        listener = socket.socket(socket.AF_INET6 if ":" in host else socket.AF_INET)
        listener.bind((host, 0))
        listener.listen(16)
        return listener

    def accept(self, listener, secure):
        while not self.stopped.is_set():
            try:
                client, _ = listener.accept()
            except OSError:
                return
            threading.Thread(target=self.serve, args=(client, secure), daemon=True).start()

    def serve(self, client, secure):
        try:
            client.settimeout(10)
            if secure:
                client = self.context.wrap_socket(client, server_side=True)
            data = b""
            while b"\r\n\r\n" not in data:
                more = client.recv(4096)
                if not more:
                    return
                data += more
            head, body = data.split(b"\r\n\r\n", 1)
            lines = head.decode().split("\r\n")
            headers = {k.lower(): v for k, v in (line.split(": ", 1) for line in lines[1:] if ": " in line)}
            wanted = int(headers.get("content-length", "0"))
            while len(body) < wanted:
                more = client.recv(4096)
                if not more:
                    break
                body += more
            answer = ("host=%s %s" % (headers.get("host", "-"), body.decode())).encode()
            client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(answer), answer))
        except (OSError, ssl.SSLError):
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass

    def stop(self):
        self.stopped.set()
        for listener in (self.plain, self.secure):
            listener.close()


@pytest.fixture
def peer():
    server = Peer()
    yield server
    server.stop()


PROGRAM = """\
import HTTP from "std/http"

def show(label: String, r: Result[HTTP.Response]) -> Void
  case r
    ok(response) -> puts("#{label} #{response.status} #{String.from_bytes(response.body).unwrap!}")
    error(e) -> puts("#{label} #{e.kind} #{e.message}")
  end
end

def main() -> Void
  plain = System.args()[0]
  secure = System.args()[1]
  ca = System.args()[2]
  dir = System.args()[3]
  trust = some(TLS.client_context(TLS.ClientOptions(ca_file: ca)).unwrap!)
  pinned = HTTP.ClientOptions(connect_to: "127.0.0.1")
  safe = HTTP.ClientOptions(connect_to: "127.0.0.1", tls: trust)

  show("get_response", HTTP.get_response("http://name.test:#{plain}/", pinned))
  client = HTTP.client(pinned).unwrap!
  show("pooled", HTTP.get(client, "http://name.test:#{plain}/"))
  show("other host", HTTP.get(client, "http://other-host.test:#{plain}/"))
  case HTTP.download("http://name.test:#{plain}/", dir + "/saved.txt", HTTP.DownloadOptions(), pinned)
    ok(_) -> puts("download #{File.read_text(dir + "/saved.txt").unwrap!}")
    error(e) -> puts("download #{e.kind}")
  end
  HTTP.close_client(client)

  stream = HTTP.open("GET", "http://name.test:#{plain}/", "".bytes, [], pinned).unwrap!
  puts("open #{String.from_bytes(stream.body.recv(5000).unwrap!).unwrap!}")
  conn = HTTP.start("http://name.test:#{plain}", pinned).unwrap!
  HTTP.send_request(conn, "GET", "/", "".bytes).unwrap!
  puts("start #{String.from_bytes(HTTP.read_body(conn).unwrap!).unwrap!}")
  HTTP.finish(conn)
  pieces: Channel[Bytes] = Channel.new(2)
  _ = pieces.send("abc".bytes, 1000)
  pieces.close
  show("upload", HTTP.upload("POST", "http://name.test:#{plain}/", pieces, 3, [], pinned))

  # The certificate is for wrong.example: that name passes, another one fails, in the pool and in start.
  show("tls ok", HTTP.get_response("https://wrong.example:#{secure}/", safe))
  tls_client = HTTP.client(safe).unwrap!
  show("tls pooled", HTTP.get(tls_client, "https://wrong.example:#{secure}/"))
  show("tls other", HTTP.get(tls_client, "https://other.example:#{secure}/"))
  case HTTP.download("https://wrong.example:#{secure}/", dir + "/secure.txt", HTTP.DownloadOptions(), safe)
    ok(_) -> puts("tls download #{File.read_text(dir + "/secure.txt").unwrap!}")
    error(e) -> puts("tls download #{e.kind}")
  end
  HTTP.close_client(tls_client)
  secure_pieces: Channel[Bytes] = Channel.new(2)
  _ = secure_pieces.send("xyz".bytes, 1000)
  secure_pieces.close
  show("tls upload", HTTP.upload("POST", "https://wrong.example:#{secure}/", secure_pieces, 3, [], safe))
  case HTTP.start("https://wrong.example:#{secure}", safe)
    ok(c) ->
      puts("tls start ok")
      HTTP.finish(c)
    error(e) -> puts("tls start #{e.kind}")
  end

  case HTTP.start("https://other.example:#{secure}", safe)
    ok(_) -> puts("tls start other ok")
    error(e) -> puts("tls start other #{e.kind}")
  end

  # Refused: a host name, a loose or ambiguous spelling of an address, and a proxy.
  for address in ["localhost", "127.0.0.010", "012.0.0.1", "127.0.0.1:80", "1.2.3", "256.0.0.1", "abc:def", ":", ":::",
                  "1::2::3", "::ffff:127.0.0.1", "::ffff:7f00:1", "[::1]", "1:2:3:4:5:6:7:8:9", "::1%lo", "0.0.0.0",
                  "::", "0:0:0:0:0:0:0:0", "0::0"]
    puts("refused #{address} #{HTTP.client(HTTP.ClientOptions(connect_to: address)).ok?}")
  end
  show("name call", HTTP.get_response("http://name.test:#{plain}/", HTTP.ClientOptions(connect_to: "localhost")))
  for address in ["127.0.0.1", "::1", "2001:db8::1", "1:2:3:4:5:6:7:8"]
    puts("accepted #{address} #{HTTP.client(HTTP.ClientOptions(connect_to: address)).ok?}")
  end
  puts("proxy #{HTTP.client(HTTP.ClientOptions(connect_to: "127.0.0.1", proxy: "http://127.0.0.1:9")).ok?}")
end
"""


REFUSED = ["localhost", "127.0.0.010", "012.0.0.1", "127.0.0.1:80", "1.2.3", "256.0.0.1", "abc:def", ":", ":::",
           "1::2::3", "::ffff:127.0.0.1", "::ffff:7f00:1", "[::1]", "1:2:3:4:5:6:7:8:9", "::1%lo", "0.0.0.0",
           "::", "0:0:0:0:0:0:0:0", "0::0"]


def test_connect_to_reaches_the_address_with_the_host_and_name_of_the_url(tmp_path, peer):
    bytecode = compile_text(PROGRAM, "connect-to", tmp_path)
    plain = peer.plain.getsockname()[1]
    secure = peer.secure.getsockname()[1]
    args = [plain, secure, TLS_DIR / "ca.pem", tmp_path]
    result = run_vm(bytecode, env=vm_environment(), args=[str(a) for a in args])
    assert result.code == 0, result.stderr
    lines = output_lines(result.stdout)
    assert lines[:9] == [
        "get_response 200 host=name.test:%d " % plain,
        "pooled 200 host=name.test:%d " % plain,
        "other host 200 host=other-host.test:%d " % plain,
        "download host=name.test:%d " % plain,
        "open host=name.test:%d " % plain,
        "start host=name.test:%d " % plain,
        "upload 200 host=name.test:%d abc" % plain,
        "tls ok 200 host=wrong.example:%d " % secure,
        "tls pooled 200 host=wrong.example:%d " % secure,
    ]
    assert lines[9].startswith("tls other net.tls ") and "hostname mismatch" in lines[9], lines[9]
    assert lines[10:14] == [
        "tls download host=wrong.example:%d " % secure,
        "tls upload 200 host=wrong.example:%d xyz" % secure,
        "tls start ok",
        "tls start other net.tls",
    ]
    assert lines[14:14 + len(REFUSED)] == ["refused %s false" % address for address in REFUSED]
    rest = lines[14 + len(REFUSED):]
    assert rest[0].startswith("name call argument "), rest[0]
    assert rest[1:] == ["accepted %s true" % a for a in ["127.0.0.1", "::1", "2001:db8::1", "1:2:3:4:5:6:7:8"]] \
        + ["proxy false"]


V6_PROGRAM = """\
import HTTP from "std/http"

def main() -> Void
  case HTTP.get_response("http://name.test:#{System.args()[0]}/", HTTP.ClientOptions(connect_to: "::1"))
    ok(response) -> puts("#{response.status} #{String.from_bytes(response.body).unwrap!}")
    error(e) -> puts("#{e.kind} #{e.message}")
  end
end
"""


def test_connect_to_reaches_an_ipv6_address(tmp_path):
    try:
        Peer.listen("::1").close()
    except OSError:
        pytest.skip("host-only: this system has no IPv6 loopback")
    server = Peer(v6=True)
    try:
        port = server.plain.getsockname()[1]
        result = run_vm(compile_text(V6_PROGRAM, "connect-to-v6", tmp_path), env=vm_environment(), args=[str(port)])
        assert result.code == 0, result.stderr
        assert output_lines(result.stdout) == ["200 host=name.test:%d " % port]
    finally:
        server.stop()
