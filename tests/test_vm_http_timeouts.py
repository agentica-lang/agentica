"""The connect, head and read timeouts of the std/http client (#1710), against a raw Python socket peer.

The peer (PeerServer) listens on 127.0.0.1 with port 0 and answers each path the way its name says: a head that never
comes, a chunked body with a pause in it, a body that stops after the head. It notes when a client left, so a test sees
that a cancelled stream closed its connection. A blackhole (a listener whose accept queue is full) makes a connect that
never ends; where the kernel does not drop the SYN, that test is skipped.
"""
import socket
import sys
import threading
import time

import pytest

from tests.agentica_test import WINDOWS, compile_text, output_lines, run_vm, scaled, vm_environment

# The pauses of the peer and the limits of the client, in milliseconds. A limit is well below the pause it must cut
# and well above the time a loaded machine needs to answer, and the windows that the programs print are wide.
PAUSE_MS = scaled(1500)
LIMIT_MS = scaled(400)
HEAD_PAUSE_MS = scaled(1000)


class PeerServer:
    """Serves one thread per connection on 127.0.0.1, port 0, until stop(). `closed` holds the paths whose client left."""

    def __init__(self):
        self.listener = socket.socket()
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(32)
        self.port = self.listener.getsockname()[1]
        self.closed = set()
        self.lock = threading.Lock()
        self.stopped = threading.Event()
        self.sockets = []
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while not self.stopped.is_set():
            try:
                client, _ = self.listener.accept()
            except OSError:
                return
            self.sockets.append(client)
            threading.Thread(target=self.serve, args=(client,), daemon=True).start()

    def stop(self):
        self.stopped.set()
        self.listener.close()
        for client in self.sockets:
            try:
                client.close()
            except OSError:
                pass

    def seen_closed(self, path):
        with self.lock:
            return path in self.closed

    def read_head(self, client):
        data = b""
        while b"\r\n\r\n" not in data:
            piece = client.recv(4096)
            if not piece:
                return None
            data += piece
        return data

    def wait_for_close(self, client, path):
        """Block until the client's end closes, then note the path."""
        try:
            while client.recv(4096):
                pass
        except OSError:
            pass
        with self.lock:
            self.closed.add(path)

    def serve(self, client):
        try:
            head = self.read_head(client)
            if head is None:
                return
            path = head.split(b" ")[1].decode()
            chunked = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Type: text/plain\r\n\r\n"
            if path.startswith("/seen/"):
                body = b"closed" if self.seen_closed("/" + path[len("/seen/"):]) else b"open"
                client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" % (len(body), body))
            elif path == "/never":
                self.wait_for_close(client, path)
            elif path == "/quiet-stream":
                client.sendall(chunked + b"3\r\none\r\n")
                time.sleep(PAUSE_MS / 1000)
                client.sendall(b"3\r\ntwo\r\n0\r\n\r\n")
            elif path == "/trickle":
                client.sendall(chunked)
                for _ in range(9):
                    time.sleep(LIMIT_MS / 3000)
                    client.sendall(b"1\r\nx\r\n")
                client.sendall(b"0\r\n\r\n")
            elif path == "/silent":
                client.sendall(chunked + b"3\r\none\r\n")
                self.wait_for_close(client, path)
            elif path == "/slow-head":
                time.sleep(HEAD_PAUSE_MS / 1000)
                client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 4\r\n\r\nlate")
            elif path == "/slow-body":
                client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nabc")
                time.sleep(PAUSE_MS / 1000)
                client.sendall(b"def")
            elif path == "/upload":
                self.wait_for_close(client, path)
            elif path == "/stall":
                # Takes the request head and never reads the body, so the client's writes back up.
                self.stopped.wait(60)
            elif path == "/flood":
                client.sendall(chunked)
                piece = b"10000\r\n" + b"x" * 65536 + b"\r\n"
                for _ in range(200):
                    client.sendall(piece)
            elif path == "/upload-ok":
                data = head.split(b"\r\n\r\n", 1)[1]
                while not data.endswith(b"0\r\n\r\n"):
                    more = client.recv(65536)
                    if not more:
                        return
                    data += more
                client.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\ngot")
        except OSError:
            pass
        finally:
            try:
                client.close()
            except OSError:
                pass


@pytest.fixture
def peer():
    server = PeerServer()
    yield server
    server.stop()


PRELUDE = """\
import HTTP from "std/http"

struct Feed
  body: Channel[Bytes]
  pause: Int
  pieces: Int
  size: Int
end

def elapsed(since: Int) -> Int = Time.monotonic_ms() - since

# Whether `since` ago is between the two bounds, so a line does not print a time that changes from run to run.
def within(since: Int, low: Int, high: Int) -> Bool
  took = elapsed(since)
  return took >= low and took < high
end

def kind_of(r: Result[HTTP.Response]) -> String
  case r
    ok(response) -> return "#{response.status} #{String.from_bytes(response.body).unwrap!}"
    error(e) -> return e.kind
  end
end

def failed(r: Result[HTTP.Response]) -> String
  case r
    ok(_) -> return "answered"
    error(e) -> return "#{e.kind} #{e.details.get("phase").unwrap_or("-")}"
  end
end

# Whether the options pass their check: the unsupported URL is refused only after it.
def passes?(options: HTTP.ClientOptions) -> Bool
  case HTTP.get_response("ftp://x/", options)
    ok(_) -> return true
    error(e) -> return e.message.include?("URL")
  end
end

def producer(feed: Feed) -> Void
  Task.sleep(feed.pause)
  piece = ("x" * feed.size).bytes
  body = feed.body
  for _ in 0..feed.pieces
    case body.send(piece, 10000)
      ok(_) -> nil
      error(_) -> break
    end
  end

  body.close
end

def joined(stream: HTTP.Stream, wait: Int) -> String
  text = ""
  while true
    case stream.body.recv(wait)
      ok(piece) -> text = text + String.from_bytes(piece).unwrap!
      error(_) -> break
    end
  end

  outcome = "ended"
  case Task.await(stream.done)
    ok(_) -> outcome = "ok"
    error(e) -> outcome = e.kind
  end

  return "#{text} #{outcome}"
end

def drain(stream: HTTP.Stream, wait: Int) -> String
  seen: List[String] = []
  while true
    case stream.body.recv(wait)
      ok(piece) -> seen = seen.push(String.from_bytes(piece).unwrap!)
      error(_) -> break
    end
  end

  outcome = "ended"
  case Task.await(stream.done)
    ok(_) -> outcome = "ok"
    error(e) -> outcome = e.kind
  end

  return "#{seen.join(",")} #{outcome}"
end

"""

STREAM_PROGRAM = (
    PRELUDE
    + """\
def main() -> Void
  base = "http://127.0.0.1:#{System.args()[0]}"
  limit = System.args()[1].to_i!
  pause = System.args()[2].to_i!

  # A server that takes the connection and never answers: the connect is quick, the head is cut at timeout_ms.
  since = Time.monotonic_ms()
  never = HTTP.open("GET", base + "/never", "".bytes, [], HTTP.ClientOptions(timeout_ms: limit, connect_timeout_ms: 5000, read_timeout_ms: 0))
  case never
    ok(_) -> puts("never opened")
    error(e) -> puts("never #{e.kind} #{within(since, limit - 100, limit * 4)}")
  end

  # A stream silent for longer than timeout_ms and shorter than read_timeout_ms stays open.
  quiet = HTTP.open("GET", base + "/quiet-stream", "".bytes, [], HTTP.ClientOptions(timeout_ms: limit, read_timeout_ms: pause * 4)).unwrap!
  puts("quiet #{drain(quiet, pause * 4)}")

  # The default read_timeout_ms (300 s) allows a pause that timeout_ms would have cut.
  fallback = HTTP.open("GET", base + "/quiet-stream", "".bytes, [], HTTP.ClientOptions(timeout_ms: limit)).unwrap!
  puts("default #{drain(fallback, pause * 4)}")

  # The same stream with a read_timeout_ms below the pause is cut.
  cut = HTTP.open("GET", base + "/quiet-stream", "".bytes, [], HTTP.ClientOptions(timeout_ms: limit, read_timeout_ms: limit)).unwrap!
  puts("cut #{drain(cut, pause * 4)}")

  # read_timeout_ms 0 is no limit: the stream is still open after several times timeout_ms, and Task.cancel ends it.
  silent = HTTP.open("GET", base + "/silent", "".bytes, [], HTTP.ClientOptions(timeout_ms: limit, read_timeout_ms: 0)).unwrap!
  puts("first #{String.from_bytes(silent.body.recv(pause * 4).unwrap!).unwrap!}")
  case silent.body.recv(limit * 3)
    ok(_) -> puts("silent a piece")
    error(e) -> puts("silent waits #{e.kind}")
  end

  Task.cancel(silent.done)
  case Task.await(silent.done)
    ok(_) -> puts("cancelled ok")
    error(_) -> puts("cancelled error")
  end

  Task.sleep(300)
  puts("peer #{String.from_bytes(HTTP.get_response(base + "/seen/silent").unwrap!.body).unwrap!}")

  # A reader that does not take the pieces for longer than read_timeout_ms ends the stream.
  flood = HTTP.open("GET", base + "/flood", "".bytes, [], HTTP.ClientOptions(timeout_ms: limit * 5, read_timeout_ms: limit)).unwrap!
  Task.sleep(limit * 3)
  case Task.await(flood.done)
    ok(_) -> puts("flood ok")
    error(e) -> puts("flood #{e.kind}")
  end
end
"""
)

CALLS_PROGRAM = (
    PRELUDE
    + """\
def main() -> Void
  base = "http://127.0.0.1:#{System.args()[0]}"
  limit = System.args()[1].to_i!
  pause = System.args()[2].to_i!
  head_pause = System.args()[3].to_i!

  # A head that takes longer than read_timeout_ms is still waited for: the head is under timeout_ms.
  slow = HTTP.get_response(base + "/slow-head", HTTP.ClientOptions(timeout_ms: head_pause * 5, read_timeout_ms: limit))
  puts("slow head #{kind_of(slow)}")

  # A body that goes quiet is cut at read_timeout_ms, long before timeout_ms.
  since = Time.monotonic_ms()
  quiet = HTTP.get_response(base + "/slow-body", HTTP.ClientOptions(timeout_ms: pause * 5, read_timeout_ms: limit))
  puts("quiet body #{kind_of(quiet)} #{within(since, limit - 100, pause)}")

  # With read_timeout_ms 0 only the whole-call timeout_ms limits it.
  whole = HTTP.get_response(base + "/slow-body", HTTP.ClientOptions(timeout_ms: pause * 5, read_timeout_ms: 0))
  puts("no read limit #{kind_of(whole)}")
  total = HTTP.get_response(base + "/slow-body", HTTP.ClientOptions(timeout_ms: limit, read_timeout_ms: 0))
  puts("total #{kind_of(total)}")

  # A download reads its body with the same limit.
  dir = System.args()[4]
  options = HTTP.ClientOptions(read_timeout_ms: limit)
  case HTTP.download(base + "/slow-body", dir + "/cut.bin", HTTP.DownloadOptions(timeout_ms: some(pause * 5)), options)
    ok(_) -> puts("download finished")
    error(e) -> puts("download #{e.kind}")
  end

  # A Connection reads each piece of the body within read_timeout_ms.
  conn = HTTP.start(base, HTTP.ClientOptions(read_timeout_ms: limit)).unwrap!
  head = HTTP.send_request(conn, "GET", "/slow-body", "".bytes).unwrap!
  first = String.from_bytes(HTTP.read_body(conn).unwrap!).unwrap!
  puts("start #{head.status} #{first}")
  case HTTP.read_body(conn)
    ok(_) -> puts("second piece")
    error(e) -> puts("second #{e.kind}")
  end

  HTTP.finish(conn)

  # An upload whose producer is silent for longer than read_timeout_ms ends with a timeout.
  since = Time.monotonic_ms()
  body: Channel[Bytes] = Channel.new(1)
  uploaded = HTTP.upload("POST", base + "/upload", body, -1, [], HTTP.ClientOptions(timeout_ms: pause * 5, read_timeout_ms: limit))
  puts("upload #{kind_of(uploaded)} #{within(since, limit - 100, pause)}")

  # A server that never reads the upload: the write stops at read_timeout_ms.
  since = Time.monotonic_ms()
  stalled: Channel[Bytes] = Channel.new(1)
  Task.spawn(&producer, Feed(body: stalled, pause: 0, pieces: 64, size: 1048576))
  refused = HTTP.upload("POST", base + "/stall", stalled, -1, [], HTTP.ClientOptions(timeout_ms: pause * 20, read_timeout_ms: limit))
  puts("stalled upload #{kind_of(refused)} #{within(since, limit - 100, pause * 10)}")

  # The default read_timeout_ms (300 s) allows a producer that is silent for longer than timeout_ms.
  delayed: Channel[Bytes] = Channel.new(1)
  Task.spawn(&producer, Feed(body: delayed, pause: pause, pieces: 1, size: 5))
  late = HTTP.upload("POST", base + "/upload-ok", delayed, -1, [], HTTP.ClientOptions(timeout_ms: limit))
  puts("slow producer #{kind_of(late)}")

  # The options are checked: 0 is no limit for a read and not for the others.
  puts("read -1 #{passes?(HTTP.ClientOptions(read_timeout_ms: -1))}")
  puts("read 0 #{passes?(HTTP.ClientOptions(read_timeout_ms: 0))}")
  puts("connect 0 #{passes?(HTTP.ClientOptions(connect_timeout_ms: 0))}")
end
"""
)

TRICKLE_PROGRAM = (
    PRELUDE
    + """\
def main() -> Void
  url = "http://127.0.0.1:#{System.args()[0]}/trickle"
  limit = System.args()[1].to_i!
  options = HTTP.ClientOptions(timeout_ms: limit * 20, read_timeout_ms: limit)

  # A piece every third of read_timeout_ms for three times as long: each wait is short, the sum is not.
  since = Time.monotonic_ms()
  puts("get_response #{kind_of(HTTP.get_response(url, options))} #{within(since, limit * 2, limit * 8)}")
  stream = HTTP.open("GET", url, "".bytes, [], options).unwrap!
  puts("open #{joined(stream, limit * 2)}")
end
"""
)

CONNECT_PROGRAM = (
    PRELUDE
    + """\
def main() -> Void
  url = System.args()[0]
  limit = System.args()[1].to_i!
  options = HTTP.ClientOptions(timeout_ms: limit * 20, connect_timeout_ms: limit)

  since = Time.monotonic_ms()
  puts("get_response #{failed(HTTP.get_response(url + "/", options))} #{within(since, limit - 100, limit * 6)}")
  since = Time.monotonic_ms()
  case HTTP.open("GET", url + "/", "".bytes, [], options)
    ok(_) -> puts("open connected")
    error(e) -> puts("open #{e.kind} #{e.details.get("phase").unwrap_or("-")} #{within(since, limit - 100, limit * 6)}")
  end

  since = Time.monotonic_ms()
  case HTTP.start(url, options)
    ok(_) -> puts("start connected")
    error(e) -> puts("start #{e.kind} #{e.details.get("phase").unwrap_or("-")} #{within(since, limit - 100, limit * 6)}")
  end

  # timeout_ms of the whole call also bounds a connect that has a longer connect_timeout_ms.
  since = Time.monotonic_ms()
  short = HTTP.ClientOptions(timeout_ms: limit, connect_timeout_ms: limit * 20)
  puts("total #{kind_of(HTTP.get_response(url + "/", short))} #{within(since, limit - 100, limit * 6)}")
end
"""
)


def run_program(tmp_path, name, text, *args):
    result = run_vm(compile_text(text, name, tmp_path), env=vm_environment(), args=[str(a) for a in args])
    assert result.code == 0, result.stderr
    return output_lines(result.stdout)


def test_a_stream_has_a_short_head_timeout_and_a_long_or_no_read_timeout(tmp_path, peer):
    lines = run_program(tmp_path, "stream", STREAM_PROGRAM, peer.port, LIMIT_MS, PAUSE_MS)
    assert lines == [
        "never net.timeout true",
        "quiet one,two ok",
        "default one,two ok",
        "cut one net.timeout",
        "first one",
        "silent waits channel.timeout",
        "cancelled error",
        "peer closed",
        "flood channel.timeout",
    ]


def test_whole_calls_cut_a_quiet_body_at_read_timeout_ms_and_wait_for_a_slow_head(tmp_path, peer):
    lines = run_program(tmp_path, "calls", CALLS_PROGRAM, peer.port, LIMIT_MS, PAUSE_MS, HEAD_PAUSE_MS, tmp_path)
    assert lines == [
        "slow head 200 late",
        "quiet body net.timeout true",
        "no read limit 200 abcdef",
        "total net.timeout",
        "download net.timeout",
        "start 200 abc",
        "second net.timeout",
        "upload channel.timeout true",
        "stalled upload net.timeout true",
        "slow producer 200 got",
        "read -1 false",
        "read 0 true",
        "connect 0 false",
    ]


def test_read_timeout_ms_is_the_wait_for_each_piece_and_not_a_total(tmp_path, peer):
    lines = run_program(tmp_path, "trickle", TRICKLE_PROGRAM, peer.port, LIMIT_MS)
    assert lines == ["get_response 200 xxxxxxxxx true", "open xxxxxxxxx ok"]


CONNECT_LINES = [
    "get_response net.timeout connect true",
    "open net.timeout connect true",
    "start net.timeout connect true",
    "total net.timeout true",
]


def test_a_tls_handshake_that_is_not_answered_ends_at_connect_timeout_ms_in_each_call(tmp_path, peer):
    """The peer takes the connection and never speaks, so an https:// connect stalls in the handshake on every system."""
    lines = run_program(tmp_path, "tls-connect", CONNECT_PROGRAM, "https://127.0.0.1:%d" % peer.port, scaled(500))
    assert lines == CONNECT_LINES


@pytest.fixture
def blackhole():
    """A listener whose accept queue is full, so the next connect is not answered. Windows and macOS answer or refuse
    instead of dropping the SYN; the portable case is the https one above."""
    if WINDOWS or sys.platform == "darwin":
        pytest.skip("host-only: a full accept queue does not stall a connect here, it is refused or answered")
    listener = socket.socket()
    listener.bind(("127.0.0.1", 0))
    listener.listen(0)
    address = listener.getsockname()
    fillers = []
    stalled = False
    try:
        for _ in range(16):
            filler = socket.socket()
            filler.settimeout(0.3)
            fillers.append(filler)
            try:
                filler.connect(address)
            except OSError:
                stalled = True
                break
        if not stalled:
            pytest.skip("host-only: this kernel does not stall a connect to a full accept queue")
        yield address[1]
    finally:
        for filler in fillers:
            filler.close()
        listener.close()


def test_a_connect_that_is_not_answered_ends_at_connect_timeout_ms_in_each_call(tmp_path, blackhole):
    assert run_program(tmp_path, "connect", CONNECT_PROGRAM, "http://127.0.0.1:%d" % blackhole, scaled(500)) == \
        CONNECT_LINES
