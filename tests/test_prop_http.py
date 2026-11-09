"""Property tests (Hypothesis) of the VM HTTP server and client against Python's http.client and raw sockets.

The profiles and the seed of each tier are in tests/conftest.py. One VM serves every example of a run.
"""
import http.client
from importlib.util import find_spec

import pytest

from tests.agentica_test import compile_agc, require, scaled, start_vm, timeout
from tests.test_vm_http import read_after_close

# make test falls back to the system pytest when Poetry is missing, and that one may lack Hypothesis: the module then
# skips at import locally and fails in CI.
require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import example, given, strategies as st  # noqa: E402

HEADER_ECHO_PROGRAM = """\
import HTTP from "std/http"

# The request body, read as UTF-8, goes back as the value of X-Out.
def handle(request: HttpRequest) -> Result[HttpResponse]
  value = try String.from_bytes(request.body)
  return ok(HttpResponse(status: 200, headers: [Header(name: "X-Out", value: value)], body: "".bytes))
end

def main() -> Void
  options = HttpServerOptions(request_timeout_ms: 10000, idle_timeout_ms: 10000, max_connections: 4, max_body_bytes: 65536)
  server = HTTP.serve("127.0.0.1", 0, HTTP.app(&handle), options).unwrap!
  port = HTTP.local_port(server)
  puts(port)
  IO.flush()
  client = HTTP.client(HttpClientOptions(timeout_ms: 10000, idle_timeout_ms: 10000, max_connections: 1, max_body_bytes: 65536, tls: none)).unwrap!
  # Each line is a case number and the hex of one value. The answer repeats the number, then the status and the hex of
  # the X-Out the client read (or "-"), or "error" and why the request failed.
  while !IO.eof?
    words = gets!.split(" ")
    case HTTP.post(client, "http://127.0.0.1:#{port}/", OpenSSL.Digest.hexdecode(words[1]).unwrap!)
      ok(reply) ->
        out = reply.headers.detect do |h| h.name == "x-out" end
        shown = "-"
        if out.ok?
          shown = OpenSSL.Digest.hexencode(out.unwrap!.value.bytes)
        end
        puts("#{words[0]} #{reply.status} #{shown}")
      error(message) -> puts("#{words[0]} error #{message}")
    end
    IO.flush()
  end
  HTTP.close_server(server)
  IO.inspect(HTTP.wait(server))
end
"""

# The longest value the server sends: the line "X-Out: <value>" is at most AGC_HTTP_MAX_LINE (8192) bytes on the wire.
MAX_HEADER_VALUE = 8192 - len("X-Out: ")
HEADER_CHARS = st.one_of(
    st.characters(min_codepoint=0x20, max_codepoint=0x7E),
    st.characters(min_codepoint=0x80, max_codepoint=0xFF),  # obs-text: one byte each on the wire
    st.characters(max_codepoint=0x1F) | st.just("\x7f"),  # control characters; only tab is allowed
    st.characters(min_codepoint=0x100, exclude_categories=("Cs",)),  # no surrogates: the body that carries it is UTF-8
)
HEADER_VALUES = st.one_of(
    st.text(HEADER_CHARS, max_size=20),
    # Around the line limit: one character (ASCII or Latin-1) repeated up to it, then a short tail.
    st.builds(lambda fill, count, tail: fill * count + tail, st.sampled_from("aé"),
              st.integers(MAX_HEADER_VALUE - 3, MAX_HEADER_VALUE), st.text(HEADER_CHARS, max_size=3)),
)


def sendable_header_value(value):
    """RFC 9110 5.5 field-value within the line limit: Latin-1 with no control character but tab."""
    return len(value) <= MAX_HEADER_VALUE and all(c == "\t" or " " <= c <= "\xff" and c != "\x7f" for c in value)


class EchoVm:
    """HEADER_ECHO_PROGRAM and its port. Each case carries a number, so an answer that came after its case timed out is
    skipped instead of being read as the answer of the next case."""

    def __init__(self, vm):
        self.vm = vm
        self.port = int(vm.next_line())
        self.cases = 0

    def client_read(self, body):
        """The VM client's POST of `body`: its status and the X-Out it read (None when absent), or "error" and why."""
        assert self.vm.process.poll() is None, "the VM ended (exit %r)" % self.vm.process.poll()
        self.cases += 1
        self.vm.process.stdin.write(b"%d %s\n" % (self.cases, body.hex().encode("ascii")))
        self.vm.process.stdin.flush()
        while True:
            line = self.vm.next_line(timeout=scaled(30))
            parts = line.split(" ", 2)
            assert len(parts) == 3, "unexpected line from the VM: %r" % line
            number, status, shown = parts
            if number == str(self.cases):
                break
        if status == "error":
            return status, shown
        return status, None if shown == "-" else bytes.fromhex(shown).decode("utf-8")


@pytest.fixture(scope="module")
def header_echo(tmp_path_factory):
    """One EchoVm for every example of the property."""
    directory = tmp_path_factory.mktemp("header-echo")
    source = directory / "header-echo.agc"
    source.write_text(HEADER_ECHO_PROGRAM, encoding="utf-8")
    vm = start_vm(compile_agc(source, directory / "header-echo.agcb"), stdin=True)
    try:
        yield EchoVm(vm)
        vm.close_stdin()
        assert vm.wait() == 0, "the VM server finishes"
        assert vm.next_line() == "ok()"
    finally:
        vm.stop()


# 1000 examples of the slow tier took about 4 s on a laptop; the limit leaves room for a busy runner and the shrinking
# of a failure, so the Hypothesis report and its seed are printed rather than cut by the per-test limit.
@timeout(300)
@given(HEADER_VALUES)
@example("a" * MAX_HEADER_VALUE)
@example("a" * (MAX_HEADER_VALUE + 1))
@example("é" * MAX_HEADER_VALUE)
@example("é" * (MAX_HEADER_VALUE + 1))
def test_server_sends_a_header_value_only_when_it_is_valid_and_both_clients_read_it_back(header_echo, value):
    """Property (#1184): the server sends a value if and only if it is a valid field value, else it answers 500. A
    value it sends is its Latin-1 bytes on the wire, and http.client and the VM client read back the same text, without
    the spaces and tabs around it (RFC 9110 5.5; http.client keeps those at the end)."""
    body = value.encode("utf-8")
    sent = sendable_header_value(value)
    got = read_after_close(header_echo.port, b"POST / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n"
                           b"Content-Length: %d\r\n\r\n%s" % (len(body), body))
    head = got.partition(b"\r\n\r\n")[0] + b"\r\n"
    if sent:
        assert head.startswith(b"HTTP/1.1 200 ") and b"\r\nX-Out: " + value.encode("latin-1") + b"\r\n" in head, head
    else:
        assert head.startswith(b"HTTP/1.1 500 ") and b"X-Out" not in head, head
    conn = http.client.HTTPConnection("127.0.0.1", header_echo.port, timeout=scaled(10))
    try:
        conn.request("POST", "/", body=body)
        reply = conn.getresponse()
        reply.read()
        assert reply.status == (200 if sent else 500)
        if sent:
            assert reply.getheader("X-Out").rstrip(" \t") == value.strip(" \t")
    finally:
        conn.close()
    assert header_echo.client_read(body) == (("200", value.strip(" \t")) if sent else ("500", None))
