"""The cost of a WebSocket broadcast in std/http: N subscribers each get the same message M times, sent as
`Message.Text` (the writer frames it for every socket) or as the frame `HTTP.prepare` makes once. It prints the
garbage collector's time and the steps of the server from its profile report, and the time the clients took.

Run by hand on an idle machine: python3 benchmarks/websocket_broadcast.py [--subscribers 1000] [--messages 100].
The clients are plain sockets of this script (the standard library only); they read the frames and count them. Each
subscriber is a descriptor in both processes, so the script raises its soft limit of open files (the server inherits
it); where the hard limit is lower than the subscribers need, raise it first (ulimit -Hn).
"""

import argparse
import base64
import os
import re
import resource
import selectors
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
VM = ROOT / "dist" / "agentica"

# Every session waits for its peer's "go", then sends the same message COUNT times: PLAIN, a Message.Text, or
# PREPARED, the frame HTTP.prepare(PLAIN) gives, written out because a constant cannot call a function (main checks
# that it is that frame). The constants are shared by all sessions, as a broadcast shares its message.
SERVER = """import HTTP from "std/http"

TEXT = "x" * 1000
PLAIN = HTTP.Message.Text(TEXT)
FRAME = Bytes.concat([Bytes.from_list([129, 126, 3, 232]).unwrap!, TEXT.bytes])
PREPARED = HTTP.Message.Prepared(FRAME)
COUNT = MESSAGES

def send_all(ws: HTTP.WebSocket, message: HTTP.Message) -> Result[Void]
  for _ in 0...COUNT
    try ws.outgoing.send(message, 600000)
  end

  return ok()
end

def wait_go(ws: HTTP.WebSocket) -> Result[Void]
  _ = try ws.incoming.recv(600000)
  return ok()
end

def plain(ws: HTTP.WebSocket) -> Result[Void]
  try wait_go(ws)
  try send_all(ws, PLAIN)
  return wait_go(ws)
end

def prepared(ws: HTTP.WebSocket) -> Result[Void]
  try wait_go(ws)
  try send_all(ws, PREPARED)
  return wait_go(ws)
end

def app(request: HttpRequest, body: HTTP.RequestBody) -> Result[HTTP.Answer]
  options = HTTP.WebSocketOptions(outgoing_queue: 256, idle_ms: 600000)
  if request.path == "/prepared"
    return ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &prepared, options)))
  end

  return ok(HTTP.Answer.Upgrade(try HTTP.accept_websocket(request, &plain, options)))
end

def main() -> Void
  if HTTP.prepare(PLAIN) != PREPARED
    IO.warn("PREPARED is not the frame HTTP.prepare gives")
    System.exit(1)
  end

  subscribers = System.args()[0].to_i!
  options = HttpServerOptions(max_connections: subscribers + 16, idle_timeout_ms: 600000, request_timeout_ms: 600000)
  server = HTTP.serve("127.0.0.1", 0, &app, options).unwrap!
  puts(HTTP.local_port(server))
  IO.flush()
  _ = IO.gets()
  HTTP.close_server(server)
end
"""

# A masked text frame "go" (the mask is all zero bytes).
GO = bytes([0x81, 0x82, 0, 0, 0, 0]) + b"go"


def connect(port, mode):
    s = socket.create_connection(("127.0.0.1", port))
    key = base64.b64encode(os.urandom(16)).decode()
    s.sendall((f"GET /{mode} HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
               f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
    head = b""
    while b"\r\n\r\n" not in head:
        head += s.recv(1)
    assert b" 101 " in head, head
    return s


def frames_in(buffer):
    """How many whole frames start the buffer; they are taken out of it."""
    count = 0
    while len(buffer) >= 2:
        at, length = 2, buffer[1] & 127
        if length == 126:
            at = 4
            length = int.from_bytes(buffer[2:4], "big") if len(buffer) >= 4 else -1
        elif length == 127:
            at = 10
            length = int.from_bytes(buffer[2:10], "big") if len(buffer) >= 10 else -1
        if length < 0 or len(buffer) < at + length:
            break
        del buffer[:at + length]
        count += 1
    return count


def run(program, mode, subscribers, messages):
    env = dict(os.environ, AGENTICA_VM_TRACE="profile")
    vm = subprocess.Popen([str(VM), str(program), str(subscribers)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, env=env, text=True)
    port = int(vm.stdout.readline())
    sockets = [connect(port, mode) for _ in range(subscribers)]
    for s in sockets:
        s.sendall(GO)
        s.setblocking(False)
    selector = selectors.DefaultSelector()
    counts = {}
    for s in sockets:
        selector.register(s, selectors.EVENT_READ)
        counts[s] = [bytearray(), 0]
    start = time.monotonic()
    left = subscribers
    while left:
        for key, _ in selector.select():
            buffer, seen = counts[key.fileobj]
            buffer += key.fileobj.recv(1 << 20)
            seen += frames_in(buffer)
            counts[key.fileobj][1] = seen
            if seen == messages:
                selector.unregister(key.fileobj)
                left -= 1
    elapsed = time.monotonic() - start
    for s in sockets:
        s.setblocking(True)
        s.sendall(GO)
    vm.stdin.write("done\n")
    vm.stdin.close()
    vm.wait(timeout=120)
    for s in sockets:
        s.close()
    totals = [line for line in vm.stderr.read().splitlines() if " profile total " in line]
    # The last total is the program's (the first is the front end's).
    fields = dict(re.findall(r"(\w+)=(\d+)", totals[-1]))
    print(f"{mode:9} subscribers={subscribers} messages={messages} clients_s={elapsed:.2f} "
          f"gc_ms={fields['gc_ms']} collections={fields['collections']} steps={fields['steps']}")


def raise_open_files(wanted):
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft == resource.RLIM_INFINITY or soft >= wanted:
        return
    top = wanted if hard == resource.RLIM_INFINITY else min(wanted, hard)
    resource.setrlimit(resource.RLIMIT_NOFILE, (top, hard))
    if top < wanted:
        sys.exit(f"{wanted} open files are needed and the hard limit is {hard}: raise it (ulimit -Hn)")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--subscribers", type=int, default=1000)
    parser.add_argument("--messages", type=int, default=100)
    options = parser.parse_args()
    if not VM.exists():
        sys.exit("build dist/agentica first (make)")
    raise_open_files(options.subscribers * 2 + 64)
    with tempfile.TemporaryDirectory() as folder:
        program = Path(folder) / "broadcast.agc"
        program.write_text(SERVER.replace("MESSAGES", str(options.messages)), encoding="utf-8")
        for mode in ["plain", "prepared"]:
            run(program, mode, options.subscribers, options.messages)


if __name__ == "__main__":
    main()
