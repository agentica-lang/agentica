"""HTTP.download, read_body and open: binary bodies streamed with bounded memory, against an independent peer.

The VM program downloads from tests/fixtures/http-download-peer.py (plain HTTP and a local
TLS server, both ThreadingHTTPServer from the standard library). Everything is on 127.0.0.1
with port 0; bodies stream file-ward in pieces of at most 1 MiB and never become a String.
"""
import hashlib
import json
import re
import urllib.parse

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
# Past the 256 MiB that every streamed body was capped at before #1865.
HUGE = 256 * 1024 * 1024 + 1024 * 1024 + 7


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
    error(e) -> puts("ERR #{flat(e.message)}")
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
  base = System.args()[0]
  dir = System.args()[1]
  options = HTTP.DownloadOptions()
  show(HTTP.download(base + "/bin/5", dir + "/five.bin", options))
  show(HTTP.download(base + "/chunked/70000", dir + "/chunk.bin", options))
  show(HTTP.download(base + "/close/70000", dir + "/close.bin", options))
  show(HTTP.download(base + "/status/404", dir + "/missing.bin", options))
  show(HTTP.download(base + "/status/301", dir + "/moved.bin", options))
end
""".replace("SHOW", SHOW)

ERRORS_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  base = System.args()[0]
  dir = System.args()[1]
  options = HTTP.DownloadOptions()
  ten = HTTP.DownloadOptions(max_total_bytes: some(10))
  show(HTTP.download("ftp://example.com/x", dir + "/u.bin", options))
  show(HTTP.download(base + "/bin/10", dir + "/zero.bin", HTTP.DownloadOptions(timeout_ms: some(0))))
  show(HTTP.download(base + "/bin/10", dir + "/neg.bin", HTTP.DownloadOptions(max_total_bytes: some(-1))))
  show(HTTP.download(base + "/bin/10", dir + "/hex.bin", HTTP.DownloadOptions(sha256: some("zz"))))
  show(HTTP.download(base + "/over-ceiling", dir + "/ceiling.bin", options))
  show(HTTP.download(base + "/bin/100", dir + "/over.bin", ten))
  show(HTTP.download(base + "/chunked/1000", dir + "/overc.bin", ten))
  show(HTTP.download(base + "/close/1000", dir + "/overu.bin", ten))
  show(HTTP.download(base + "/truncate/100/40", dir + "/trunc.bin", options))
  show(HTTP.download(base + "/cut-chunk", dir + "/cut.bin", options))
  show(HTTP.download(base + "/bad-chunk", dir + "/bad.bin", options))
  show(HTTP.download(base + "/slow-head", dir + "/slow.bin", HTTP.DownloadOptions(timeout_ms: some(500))))
  show(HTTP.download(base + "/bin/10", dir + "/absent/x.bin", options))
  show(HTTP.download(base + "/bin/10", dir + "/folder", options))
  show(HTTP.download(base + "/bin/7", dir + "/with space/seven.bin", options))
end
""".replace("SHOW", SHOW)

REPLACE_PROGRAM = """\
import HTTP from "std/http"

SHOW

def kind(result: Result[HTTP.Download]) -> Void
  case result
    ok(_) -> puts("ok")
    error(e) -> puts("ERR #{e.kind} #{e.message}")
  end
end

# A download that follows one redirect by hand: download has no redirect follow of its own.
def follow(base: String, url: String, path: String, options: HTTP.DownloadOptions) -> Result[HTTP.Download]
  first = try HTTP.download(url, path, HTTP.DownloadOptions())
  return ok(first) if first.status != 302
  HTTP.download(base + HTTP.header_values(first.headers, "location")[0], path, options)
end

def main() -> Void
  base = System.args()[0]
  dir = System.args()[1]
  right = HTTP.DownloadOptions(max_total_bytes: some(1000), sha256: some(System.args()[2]))
  show(follow(base, base + "/redirect/chunked/1000", dir + "/moved.bin", right))
  kind(HTTP.download(base + "/bin/1000", dir + "/wrong.bin", HTTP.DownloadOptions(sha256: some(System.args()[3]))))
  show(HTTP.download(base + "/bin/1000", dir + "/kept.bin", HTTP.DownloadOptions(sha256: some(System.args()[3]))))
  show(HTTP.download(base + "/truncate/100/40", dir + "/kept.bin", HTTP.DownloadOptions()))
  show(HTTP.download(base + "/bin/1000", dir + "/replaced.bin", right))
end
""".replace("SHOW", SHOW)

DENY_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  show(HTTP.download(System.args()[0] + "/bin/10", System.args()[1] + "/denied.bin"))
end
""".replace("SHOW", SHOW)

BIG_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  base = System.args()[0]
  dir = System.args()[1]
  options = HTTP.DownloadOptions(timeout_ms: some(60000))
  show(HTTP.download(base + "/bin/BIG", dir + "/big.bin", options))
  show(HTTP.download(base + "/chunked/CHUNKED", dir + "/big-chunked.bin", options))
end
""".replace("SHOW", SHOW).replace("BIG", str(BIG)).replace("CHUNKED", str(BIG_CHUNKED))

LATE_DIRECTORY_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  case HTTP.download(System.args()[0], System.args()[1])
    ok(saved) -> puts("200 #{saved.bytes_written}")
    error(e) -> puts("#{e.kind} #{e.message.split("\\n")[0]}")
  end
end
""".replace("SHOW", SHOW)

CANCEL_PROGRAM = """\
import HTTP from "std/http"

struct Job
  url: String
  path: String
end

def fetch(job: Job) -> Result[HTTP.Download]
  HTTP.download(job.url, job.path)
end

def growing?(folder: String) -> Bool
  empty: List[String] = []
  names = Dir.list(folder).unwrap_or(empty)
  names.any? do |name: String| name.end_with?(".agc-part") end
end

def main() -> Void
  job = Job(url: System.args()[0], path: System.args()[1])
  task = Task.spawn(&fetch, job)
  # The peer stalls after the first bytes: cancel once the hidden file is there, waiting at most 30 s.
  folder = System.args()[2]
  waited = 0
  while waited < 30000 and not growing?(folder)
    Task.sleep(50)
    waited = waited + 50
  end
  Task.cancel(task)
  puts("cancelled")
end
"""

MAP_PROGRAM = """\
import HTTP from "std/http"

def growing?(folder: String) -> Bool
  empty: List[String] = []
  names = Dir.list(folder).unwrap_or(empty)
  names.any? do |name: String| name.end_with?(".agc-part") end
end

def fetch(url: String, path: String) -> Result[Int]
  if HTTP.download(url, path).ok?
    return ok(1)
  end
  error("download failed")
end

# Done once the hidden file is there, so the timeout of Task.map comes while the body is being saved.
def watch(folder: String) -> Result[Int]
  waited = 0
  while waited < 30000 and not growing?(folder)
    Task.sleep(50)
    waited = waited + 50
  end
  return error("the file never appeared") if waited >= 30000
  ok(2)
end

def main() -> Void
  args = System.args()
  results = Task.map([0, 1], 2, 3000) do |n: Int|
    return fetch(args[0], args[1]) if n == 0
    watch(args[2])
  end
  puts(results.map do |item: Result[Int]| item.ok? end)
end
"""

HUGE_PROGRAM = """\
import HTTP from "std/http"

SHOW

def location(headers: List[HTTP.Header]) -> String = HTTP.header_values(headers, "location")[0]

# The body of the last response on `conn` counted to its end.
def drained(conn: HTTP.Connection) -> Int
  total = 0
  while true
    piece = HTTP.read_body(conn, 1048576).unwrap!
    return total if piece.empty?
    total = total + piece.size
  end
  total
end

# The body of `open` counted to its end through the channel.
def streamed(stream: HTTP.Stream) -> String
  total = 0
  while true
    case stream.body.recv(30000)
      ok(piece) -> total = total + piece.size
      error(_) -> break
    end
  end
  case Task.await(stream.done)
    ok(_) -> return "open #{total}"
    error(e) -> return "open ERR #{e.message}"
  end
end

def main() -> Void
  base = System.args()[0]
  dir = System.args()[1]
  moved = HTTP.download(base + "/redirect/bin/HUGE", dir + "/huge.bin").unwrap!
  checked = HTTP.DownloadOptions(sha256: some(System.args()[2]))
  show(HTTP.download(base + location(moved.headers), dir + "/huge.bin", checked))

  conn = HTTP.start(base).unwrap!
  head = HTTP.send_request(conn, "GET", "/redirect/chunked/HUGE", "".bytes).unwrap!
  _ = drained(conn)
  _ = HTTP.send_request(conn, "GET", location(head.headers), "".bytes).unwrap!
  puts("read_body #{drained(conn)}")
  HTTP.finish(conn)

  first = HTTP.open("GET", base + "/redirect/close/HUGE", "".bytes).unwrap!
  _ = streamed(first)
  puts(streamed(HTTP.open("GET", base + location(first.headers), "".bytes).unwrap!))
end
""".replace("SHOW", SHOW).replace("HUGE", str(HUGE))

TLS_PROGRAM = """\
import HTTP from "std/http"

SHOW

def main() -> Void
  secure = HTTP.ClientOptions(timeout_ms: 5000, idle_timeout_ms: 5000, max_connections: 1, max_body_bytes: 1048576, tls: some(TLS.client_context(TLS.ClientOptions(ca_file: System.args()[0] + "/ca.pem")).unwrap!))
  show(HTTP.download(System.args()[1] + "/bin/100", System.args()[2] + "/tls.bin", HTTP.DownloadOptions(), secure))
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


def test_failures_leave_no_file_and_check_options_first(tmp_path, ports):
    directory = tmp_path / "errors"
    (directory / "with space").mkdir(parents=True)
    (directory / "folder").mkdir()
    base = "http://127.0.0.1:%d" % ports["plain"]
    lines = run_program(tmp_path, "errors", ERRORS_PROGRAM, [base, str(directory)])
    check_lines(lines, [
        "ERR http: the URL must be http:// or https:// with a host, and without user info",
        "ERR http: every download option must be positive",
        "ERR http: every download option must be positive",
        "ERR http: sha256 must be 64 hex digits",
        # A Content-Length past the old 256 MiB ceiling is read, and the peer closes before the body.
        "ERR http: truncated HTTP body",
        "ERR http: body exceeds max_body_bytes",
        "ERR http: body exceeds max_body_bytes",
        "ERR http: body exceeds max_body_bytes",
        "ERR http: truncated HTTP body",
        "ERR http: truncated HTTP body",
        "ERR http: invalid chunk size",
        "ERR network: operation timed out",
        ("prefix", "ERR filesystem: cannot open file for writing"),
        "ERR http: the download path is a directory, not a file",
        "200 7",
    ], "download errors")
    assert sorted(path.name for path in directory.iterdir()) == ["folder", "with space"]
    assert list((directory / "folder").iterdir()) == []
    assert [path.name for path in (directory / "with space").iterdir()] == ["seven.bin"]
    assert (directory / "with space" / "seven.bin").read_bytes() == expected_bytes(7)


def test_a_file_is_replaced_only_by_a_clean_body_with_its_digest(tmp_path, ports):
    directory = tmp_path / "replace"
    directory.mkdir()
    (directory / "kept.bin").write_bytes(b"keep")
    (directory / "replaced.bin").write_bytes(b"old")
    base = "http://127.0.0.1:%d" % ports["plain"]
    args = [base, str(directory), expected_digest(1000), "0" * 64]
    lines = output_lines(run_program(tmp_path, "replace", REPLACE_PROGRAM, args))
    assert lines == [
        "200 1000",
        "ERR http.digest http: the body does not match the sha256 digest",
        "ERR http: the body does not match the sha256 digest",
        "ERR http: truncated HTTP body",
        "200 1000",
    ], lines
    assert sorted(path.name for path in directory.iterdir()) == ["kept.bin", "moved.bin", "replaced.bin"]
    assert (directory / "moved.bin").read_bytes() == expected_bytes(1000)
    assert (directory / "kept.bin").read_bytes() == b"keep"
    assert (directory / "replaced.bin").read_bytes() == expected_bytes(1000)


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


def test_a_directory_made_during_the_download_is_left_alone(tmp_path, ports):
    directory = tmp_path / "late"
    directory.mkdir()
    target = directory / "saved.bin"
    url = "http://127.0.0.1:%d/dir-at/1000?path=%s" % (ports["plain"], urllib.parse.quote(str(target)))
    lines = output_lines(run_program(tmp_path, "late", LATE_DIRECTORY_PROGRAM, [url, str(target)]))
    assert lines == ["io.is_directory filesystem: cannot rename path"], lines
    assert [path.name for path in directory.iterdir()] == ["saved.bin"]
    assert target.is_dir() and list(target.iterdir()) == []


def test_a_cancelled_download_leaves_no_hidden_part_file(tmp_path, ports):
    directory = tmp_path / "cancel"
    directory.mkdir()
    (directory / "kept.bin").write_bytes(b"keep")
    url = "http://127.0.0.1:%d/stall/1000" % ports["plain"]
    lines = output_lines(run_program(tmp_path, "cancel", CANCEL_PROGRAM, [url, str(directory / "kept.bin"), str(directory)]))
    assert lines == ["cancelled"], lines
    assert [path.name for path in directory.iterdir()] == ["kept.bin"]
    assert (directory / "kept.bin").read_bytes() == b"keep"


def test_a_download_stopped_by_a_task_map_timeout_leaves_no_hidden_part_file(tmp_path, ports):
    directory = tmp_path / "map"
    directory.mkdir()
    (directory / "kept.bin").write_bytes(b"keep")
    url = "http://127.0.0.1:%d/stall/1000" % ports["plain"]
    lines = output_lines(run_program(tmp_path, "map", MAP_PROGRAM, [url, str(directory / "kept.bin"), str(directory)]))
    assert lines == ["[false, true]"], lines
    assert [path.name for path in directory.iterdir()] == ["kept.bin"]
    assert (directory / "kept.bin").read_bytes() == b"keep"


def test_bodies_past_256_mib_stream_whole_through_a_redirect(tmp_path, ports):
    directory = tmp_path / "huge"
    directory.mkdir()
    base = "http://127.0.0.1:%d" % ports["plain"]
    lines = output_lines(run_program(tmp_path, "huge", HUGE_PROGRAM, [base, str(directory), expected_digest(HUGE)]))
    assert lines == ["200 %d" % HUGE, "read_body %d" % HUGE, "open %d" % HUGE], lines
    assert [path.name for path in directory.iterdir()] == ["huge.bin"]
    assert (directory / "huge.bin").stat().st_size == HUGE


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
