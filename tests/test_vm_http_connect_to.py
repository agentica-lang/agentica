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

    def __init__(self):
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(TLS_DIR / "wrong-host.pem", TLS_DIR / "wrong-host-key.pem")
        self.plain = self.listen()
        self.secure = self.listen()
        self.context = context
        self.stopped = threading.Event()
        threading.Thread(target=self.accept, args=(self.plain, False), daemon=True).start()
        threading.Thread(target=self.accept, args=(self.secure, True), daemon=True).start()

    @staticmethod
    def listen():
        listener = socket.socket()
        listener.bind(("127.0.0.1", 0))
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
  case HTTP.download(client, "http://name.test:#{plain}/", dir + "/saved.txt", HTTP.DownloadOptions())
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
  HTTP.close_client(tls_client)
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

  # Refused: a host name, and a proxy.
  puts("name #{HTTP.client(HTTP.ClientOptions(connect_to: "localhost")).ok?}")
  show("name call", HTTP.get_response("http://name.test:#{plain}/", HTTP.ClientOptions(connect_to: "localhost")))
  puts("v6 #{HTTP.client(HTTP.ClientOptions(connect_to: "::1")).ok?}")
  puts("proxy #{HTTP.client(HTTP.ClientOptions(connect_to: "127.0.0.1", proxy: "http://127.0.0.1:9")).ok?}")
end
"""


def test_connect_to_reaches_the_address_with_the_host_and_name_of_the_url(tmp_path, peer):
    bytecode = compile_text(PROGRAM, "connect-to", tmp_path)
    args = [peer.plain.getsockname()[1], peer.secure.getsockname()[1], TLS_DIR / "ca.pem", tmp_path]
    result = run_vm(bytecode, env=vm_environment(), args=[str(a) for a in args])
    assert result.code == 0, result.stderr
    plain = peer.plain.getsockname()[1]
    secure = peer.secure.getsockname()[1]
    lines = output_lines(result.stdout)
    assert lines[:8] == [
        "get_response 200 host=name.test:%d " % plain,
        "pooled 200 host=name.test:%d " % plain,
        "download host=name.test:%d " % plain,
        "open host=name.test:%d " % plain,
        "start host=name.test:%d " % plain,
        "upload 200 host=name.test:%d abc" % plain,
        "tls ok 200 host=wrong.example:%d " % secure,
        "tls pooled 200 host=wrong.example:%d " % secure,
    ]
    assert lines[8].startswith("tls other net.tls ") and "hostname mismatch" in lines[8], lines[8]
    assert lines[9:11] == ["tls start ok", "tls start other net.tls"]
    assert lines[11] == "name false"
    assert lines[12].startswith("name call argument "), lines[12]
    assert lines[13:] == ["v6 true", "proxy false"]
