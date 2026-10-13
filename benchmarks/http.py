import os
import sys

sys.path = [p for p in sys.path if os.path.abspath(p or ".") != os.path.dirname(os.path.abspath(__file__))]

import argparse
import http.client
import http.server
import statistics
import subprocess
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "src" / "main.rkt"
VM = Path(os.environ.get("AGENTICA_VM", ROOT / "dist" / "agentica-vm"))
SERVER = ROOT / "examples" / "http_server.agc"

CLIENT = """import "std/http" as HTTP

struct Job
  pool: HttpClient
  url: String
  count: Int
end

def fetch(job: Job) -> Int
  ok_count = 0
  for k in 0...job.count
    if HTTP.get(job.pool, job.url).unwrap!.status == 200
      ok_count = ok_count + 1
    end
  end
  return ok_count
end

def main() -> Void
  args = System.args()
  connections = args[1].to_i!
  each = args[2].to_i!
  options = HttpClientOptions(timeout_ms: 30000, idle_timeout_ms: 30000, max_connections: connections, max_body_bytes: 1048576, ca_file: "")
  pool = HTTP.client(options).unwrap!
  tasks: List[Task[Int]] = []
  for k in 0...connections
    tasks = tasks.push(Task.spawn(&fetch, Job(pool: pool, url: args[0], count: each)))
  end
  total = 0
  for t in tasks
    total = total + Task.await(t)
  end
  puts(total)
end
"""


class Hello(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True

    def log_message(self, *args):
        pass

    def do_GET(self):
        body = b"hello\n" if self.path == "/" else b"not found\n"
        self.send_response(200 if self.path == "/" else 404)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def python_server():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hello)
    server.daemon_threads = True
    print(server.server_address[1], flush=True)
    server.serve_forever()


def compile_program(source: Path, output: Path):
    subprocess.run(["racket", str(MAIN), "compile", str(source), "-o", str(output)], check=True)


def start(command: list[str]) -> tuple[subprocess.Popen, int]:
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    line = process.stdout.readline()
    if not line.strip().isdigit():
        process.kill()
        process.wait()
        raise SystemExit(f"the server printed no port: {line!r}")
    return process, int(line)


def stop(process: subprocess.Popen):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def load(port: int, connections: int, each: int) -> float:
    failures = []

    def work():
        conn = http.client.HTTPConnection("127.0.0.1", port, timeout=30)
        try:
            for _ in range(each):
                conn.request("GET", "/")
                response = conn.getresponse()
                if response.read() != b"hello\n" or response.status != 200:
                    failures.append(response.status)
        finally:
            conn.close()

    threads = [threading.Thread(target=work) for _ in range(connections)]
    started = time.perf_counter()
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    seconds = time.perf_counter() - started
    if failures:
        raise SystemExit(f"{len(failures)} requests failed")
    return seconds


def server_rows(bytecode: Path, args) -> list[tuple[str, float]]:
    rows = []
    for name, command in (("vm server (examples/http_server.agc)", [str(VM), "--", str(bytecode), "serve"]),
                          ("python ThreadingHTTPServer", [sys.executable, str(Path(__file__)), "--python-server"])):
        process, port = start(command)
        try:
            load(port, args.connections, max(1, args.requests // args.connections // 10))
            times = [load(port, args.connections, args.requests // args.connections) for _ in range(args.runs)]
        finally:
            stop(process)
        rows.append((name, statistics.median(times)))
    return rows


def client_row(work: Path, args) -> tuple[str, float]:
    source = work / "client.agc"
    bytecode = work / "client.agcb"
    source.write_text(CLIENT)
    compile_program(source, bytecode)
    process, port = start([sys.executable, str(Path(__file__)), "--python-server"])
    try:
        each = args.requests // args.connections
        times = []
        for _ in range(args.runs):
            started = time.perf_counter()
            result = subprocess.run([str(VM), "--", str(bytecode), f"http://127.0.0.1:{port}/", str(args.connections), str(each)],
                                    capture_output=True, text=True, check=True)
            times.append(time.perf_counter() - started)
            if result.stdout.strip() != str(each * args.connections):
                raise SystemExit(f"the VM client got {result.stdout!r}")
    finally:
        stop(process)
    return ("vm client against python ThreadingHTTPServer", statistics.median(times))


def main():
    parser = argparse.ArgumentParser(description="HTTP sanity check: keep-alive GET requests over several connections")
    parser.add_argument("--requests", type=int, default=20000)
    parser.add_argument("--connections", type=int, default=8)
    parser.add_argument("--runs", type=int, default=3)
    parser.add_argument("--python-server", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.python_server:
        python_server()
        return
    if not VM.exists():
        raise SystemExit(f"{VM} is missing; run make vm")
    total = args.requests // args.connections * args.connections
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        bytecode = work / "http_server.agcb"
        compile_program(SERVER, bytecode)
        rows = server_rows(bytecode, args) + [client_row(work, args)]
    print(f"{total} keep-alive GET requests over {args.connections} connections, median of {args.runs} runs")
    print("| Setup | Median s | Requests/s |")
    print("|---|---:|---:|")
    for name, seconds in rows:
        print(f"| {name} | {seconds:.3f} | {total / seconds:,.0f} |")


main()
