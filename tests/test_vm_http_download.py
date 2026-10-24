"""HTTP.download: binary downloads to a file with bounded memory, against an independent peer.

The VM program downloads from tests/fixtures/http-download-peer.py (plain HTTP and a local
TLS server, both ThreadingHTTPServer from the standard library). Everything is on 127.0.0.1
with port 0; bodies stream file-ward in pieces of at most 1 MiB and never become a String.
"""
import hashlib
import json

import pytest

from tests.agentica_test import (
    FIXTURES,
    PYTHON,
    Child,
    check_lines,
    compile_agc,
    output_lines,
    run_vm,
    vm_environment,
)

PEER = FIXTURES / "http-download-peer.py"
CERTS = FIXTURES / "tls"
PATTERN = bytes(range(256))
PIECE = 65536
BIG = 80 * 1024 * 1024
BIG_CHUNKED = 70 * 1024 * 1024


def expected_bytes(count):
    """The peer's deterministic binary pattern: bytes 0..255 repeating, with NUL and invalid UTF-8 in it."""
    full, rest = divmod(count, len(PATTERN))
    return PATTERN * full + PATTERN[:rest]


def expected_digest(count):
    """The SHA-256 of the pattern stream, hashed piece by piece so no side holds the body at once."""
    digest = hashlib.sha256()
    left = count
    while left > 0:
        take = min(PIECE, left)
        full, rest = divmod(take, len(PATTERN))
        digest.update(PATTERN * full + PATTERN[:rest])
        left -= take
    return digest.hexdigest()


SHOW = """\
def show(result: Result[HTTP.Download]) -> Void
  case result
    ok(download) -> puts("#{download.status} #{download.bytes_written}")
    error(message) -> puts("ERR #{flat(message)}")
  end
end

def flat(message: String) -> String
  return String.replace(message, "\\n", " | ")
end
"""

MAIN_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  pool = Result.unwrap!(HTTP.client(HTTP.client_options()))
  base = System.args()[0]
  dir = System.args()[1]
  options = HTTP.download_options()
  show(HTTP.download(pool, base + "/bin/5", dir + "/five.bin", options))
  show(HTTP.download(pool, base + "/chunked/70000", dir + "/chunk.bin", options))
  show(HTTP.download(pool, base + "/close/70000", dir + "/close.bin", options))
  show(HTTP.download(pool, base + "/status/404", dir + "/missing.bin", options))
  show(HTTP.download(pool, base + "/status/301", dir + "/moved.bin", options))
  HTTP.close_client(pool)
end
""".replace("SHOW", SHOW)

ERRORS_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  pool = Result.unwrap!(HTTP.client(HTTP.client_options()))
  base = System.args()[0]
  dir = System.args()[1]
  options = HTTP.download_options()
  show(HTTP.download(pool, "ftp://example.com/x", dir + "/u.bin", options))
  show(HTTP.download(pool, base + "/bin/10", dir + "/zero.bin", HTTP.DownloadOptions(timeout_ms: 0, max_total_bytes: 10)))
  show(HTTP.download(pool, base + "/bin/10", dir + "/huge-opt.bin", HTTP.DownloadOptions(timeout_ms: 5000, max_total_bytes: 268435457)))
  show(HTTP.download(pool, base + "/over-ceiling", dir + "/ceiling.bin", options))
  show(HTTP.download(pool, base + "/bin/100", dir + "/over.bin", HTTP.DownloadOptions(timeout_ms: 5000, max_total_bytes: 10)))
  show(HTTP.download(pool, base + "/chunked/1000", dir + "/overc.bin", HTTP.DownloadOptions(timeout_ms: 5000, max_total_bytes: 10)))
  show(HTTP.download(pool, base + "/close/1000", dir + "/overu.bin", HTTP.DownloadOptions(timeout_ms: 5000, max_total_bytes: 10)))
  show(HTTP.download(pool, base + "/truncate/100/40", dir + "/trunc.bin", options))
  show(HTTP.download(pool, base + "/cut-chunk", dir + "/cut.bin", options))
  show(HTTP.download(pool, base + "/bad-chunk", dir + "/bad.bin", options))
  show(HTTP.download(pool, base + "/slow-head", dir + "/slow.bin", HTTP.DownloadOptions(timeout_ms: 500, max_total_bytes: 1048576)))
  show(HTTP.download(pool, base + "/bin/10", dir + "/pre.bin", options))
  show(HTTP.download(pool, base + "/bin/10", dir + "/absent/x.bin", options))
  show(HTTP.download(pool, base + "/bin/7", dir + "/with space/seven.bin", options))
  HTTP.close_client(pool)
end
""".replace("SHOW", SHOW)

DENY_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  pool = Result.unwrap!(HTTP.client(HTTP.client_options()))
  show(HTTP.download(pool, System.args()[0] + "/bin/10", System.args()[1] + "/denied.bin", HTTP.download_options()))
  HTTP.close_client(pool)
end
""".replace("SHOW", SHOW)

BIG_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  pool = Result.unwrap!(HTTP.client(HTTP.client_options()))
  base = System.args()[0]
  dir = System.args()[1]
  options = HTTP.download_options()
  show(HTTP.download(pool, base + "/bin/BIG", dir + "/big.bin", options))
  show(HTTP.download(pool, base + "/chunked/CHUNKED", dir + "/big-chunked.bin", options))
  HTTP.close_client(pool)
end
""".replace("SHOW", SHOW).replace("BIG", str(BIG)).replace("CHUNKED", str(BIG_CHUNKED))

TLS_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  secure = Result.unwrap!(HTTP.client(HttpClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 1048576, ca_file: System.args()[0] + "/ca.pem")))
  show(HTTP.download(secure, System.args()[1] + "/bin/100", System.args()[2] + "/tls.bin", HTTP.download_options()))
  HTTP.close_client(secure)
end
""".replace("SHOW", SHOW)


@pytest.fixture(scope="module")
def ports():
    """The peer's plain and TLS ports; the servers stop when the module ends."""
    peer = Child([PYTHON, PEER], stdin=True)
    try:
        found = json.loads(peer.next_line())
    except Exception:
        peer.stop()
        raise
    yield found
    peer.stop()


def run_program(tmp_path, name, text, args, flags=()):
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / (name + ".agcb"))
    result = run_vm(bytecode, *flags, args=args, env=vm_environment())
    assert result.code == 0, result.stderr
    return result.stdout


def test_small_bodies_in_every_framing_write_exact_bytes(tmp_path, ports):
    directory = tmp_path / "main"
    directory.mkdir()
    base = "http://127.0.0.1:%d" % ports["plain"]
    lines = output_lines(run_program(tmp_path, "main", MAIN_PROGRAM, [base, str(directory)]))
    assert lines == ["200 5", "200 70000", "200 70000", "404 10", "301 10"], lines
    assert (directory / "five.bin").read_bytes() == expected_bytes(5)
    assert (directory / "chunk.bin").read_bytes() == expected_bytes(70000)
    assert (directory / "close.bin").read_bytes() == expected_bytes(70000)
    assert (directory / "missing.bin").read_bytes() == b"status 404"
    # The 301 answer carries Location: /bin/5, whose body differs; a client that followed redirects would report
    # 200 with the 5-byte pattern instead of 301 with this body, so these checks catch a follow.
    assert (directory / "moved.bin").read_bytes() == b"status 301"


def test_failures_keep_bounds_and_leave_what_the_policy_says(tmp_path, ports):
    directory = tmp_path / "errors"
    (directory / "with space").mkdir(parents=True)
    (directory / "pre.bin").write_bytes(b"keep")
    base = "http://127.0.0.1:%d" % ports["plain"]
    lines = run_program(tmp_path, "errors", ERRORS_PROGRAM, [base, str(directory)])
    check_lines(lines, [
        "ERR http: the URL must be http:// or https:// with a host, and without user info",
        "ERR http: every download option must be positive",
        "ERR http: max_total_bytes must be at most 268435456",
        "ERR http: body exceeds max_body_bytes",
        "ERR http: body exceeds max_body_bytes",
        "ERR http: body exceeds max_body_bytes",
        "ERR http: body exceeds max_body_bytes",
        "ERR http: truncated HTTP body",
        "ERR http: truncated HTTP body",
        "ERR http: invalid chunk size",
        "ERR network: operation timed out",
        ("prefix", "ERR open-output-file: error opening file"),
        ("prefix", "ERR open-output-file: error opening file"),
        "200 7",
    ], "download errors")
    assert (directory / "pre.bin").read_bytes() == b"keep"
    assert not (directory / "u.bin").exists()
    assert not (directory / "zero.bin").exists()
    assert not (directory / "huge-opt.bin").exists()
    assert (directory / "ceiling.bin").read_bytes() == b""
    assert (directory / "over.bin").read_bytes() == b""
    assert (directory / "overc.bin").read_bytes() == b""
    assert len((directory / "overu.bin").read_bytes()) <= 10
    assert (directory / "trunc.bin").read_bytes() == expected_bytes(40)
    assert (directory / "cut.bin").read_bytes() == expected_bytes(100)
    assert (directory / "bad.bin").read_bytes() == b""
    assert (directory / "slow.bin").read_bytes() == b""
    assert not (directory / "absent").exists()
    assert (directory / "with space" / "seven.bin").read_bytes() == expected_bytes(7)


def test_big_bodies_stream_past_the_old_text_ceiling(tmp_path, ports):
    directory = tmp_path / "big"
    directory.mkdir()
    base = "http://127.0.0.1:%d" % ports["plain"]
    lines = output_lines(run_program(tmp_path, "big", BIG_PROGRAM, [base, str(directory)]))
    assert lines == ["200 %d" % BIG, "200 %d" % BIG_CHUNKED], lines
    for name, count in (("big.bin", BIG), ("big-chunked.bin", BIG_CHUNKED)):
        data = (directory / name).read_bytes()
        assert len(data) == count
        assert hashlib.sha256(data).hexdigest() == expected_digest(count)


def test_tls_download_keeps_certificate_verification(tmp_path, ports):
    directory = tmp_path / "tls"
    directory.mkdir()
    secure = "https://localhost:%d" % ports["tls"]
    lines = output_lines(run_program(tmp_path, "tls", TLS_PROGRAM, [str(CERTS), secure, str(directory)]))
    assert lines == ["200 100"], lines
    assert (directory / "tls.bin").read_bytes() == expected_bytes(100)


def test_deny_fs_fails_before_creating_anything(tmp_path, ports):
    directory = tmp_path / "deny"
    directory.mkdir()
    base = "http://127.0.0.1:%d" % ports["plain"]
    lines = output_lines(run_program(tmp_path, "deny", DENY_PROGRAM, [base, str(directory)], flags=("--deny-fs",)))
    assert lines == ["ERR denied: --deny-fs turns off file access"], lines
    assert list(directory.iterdir()) == []
