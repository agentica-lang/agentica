import os
import sys

sys.path = [p for p in sys.path if os.path.abspath(p or ".") != os.path.dirname(os.path.abspath(__file__))]

import argparse
import asyncio
import email.utils
import http.server
import json
import shutil
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MAIN = ROOT / "src" / "main.rkt"
VM = Path(os.environ.get("AGENTICA_VM", ROOT / "dist" / "agentica-vm"))
SERVER = ROOT / "examples" / "http_server.agc"
NODE_FILE = ROOT / "benchmarks" / "http.js"
TICKS = os.sysconf("SC_CLK_TCK")

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

HELLO = b"hello\n"
MISSING = b"not found\n"
TYPE = "text/plain; charset=utf-8"


class Hello(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    disable_nagle_algorithm = True

    def log_message(self, *args):
        pass

    def do_GET(self):
        body = HELLO if self.path == "/" else MISSING
        self.send_response(200 if self.path == "/" else 404)
        self.send_header("Content-Type", TYPE)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def threading_server():
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Hello)
    server.daemon_threads = True
    print(server.server_address[1], flush=True)
    server.serve_forever()


async def answer(reader, writer):
    try:
        while True:
            head = await reader.readuntil(b"\r\n\r\n")
            lines = head.split(b"\r\n")
            method, target, _ = lines[0].split(b" ", 2)
            length = 0
            close = False
            for line in lines[1:]:
                name, _, value = line.partition(b":")
                name = name.strip().lower()
                if name == b"content-length":
                    length = int(value)
                elif name == b"connection" and value.strip().lower() == b"close":
                    close = True
            if length:
                await reader.readexactly(length)
            found = method == b"GET" and target == b"/"
            body = HELLO if found else MISSING
            status = b"200 OK" if found else b"404 Not Found"
            date = email.utils.formatdate(usegmt=True).encode()
            writer.write(b"HTTP/1.1 " + status + b"\r\nContent-Type: " + TYPE.encode() + b"\r\nDate: " + date
                         + b"\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
            await writer.drain()
            if close:
                break
    except (asyncio.IncompleteReadError, ConnectionError, ValueError):
        pass
    finally:
        writer.close()


async def asyncio_main():
    server = await asyncio.start_server(answer, "127.0.0.1", 0)
    print(server.sockets[0].getsockname()[1], flush=True)
    async with server:
        await server.serve_forever()


def pin(command: list[str], cpus: str | None) -> list[str]:
    return ["taskset", "-c", cpus, *command] if cpus else command


def compile_program(source: Path, output: Path):
    subprocess.run(["racket", str(MAIN), "compile", str(source), "-o", str(output)], check=True)


def start(command: list[str]) -> tuple[subprocess.Popen, int]:
    process = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
    line = process.stdout.readline()
    if not line.strip().isdigit():
        stop(process)
        raise SystemExit(f"{command} printed no port: {line!r}")
    return process, int(line)


def stop(process: subprocess.Popen):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def cpu_seconds(pid: int) -> float:
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
    return (int(fields[11]) + int(fields[12])) / TICKS


def load(node: str, port: int, connections: int, requests: int, processes: int, cpus: str | None) -> dict:
    share = connections // processes
    command = [node, str(NODE_FILE), "client", str(port), str(share), str(requests // processes)]
    clients = [subprocess.Popen(pin(command, cpus), stdout=subprocess.PIPE, text=True) for _ in range(processes)]
    results = []
    for client in clients:
        out, _ = client.communicate(timeout=600)
        if client.returncode != 0:
            raise SystemExit("a load client failed")
        results.append(json.loads(out))
    if any(r["failures"] for r in results):
        raise SystemExit("some requests failed")
    latencies = sorted(x for r in results for x in r["latencies"])
    seconds = max(r["seconds"] for r in results)
    return {
        "rps": sum(r["requests"] for r in results) / seconds,
        "seconds": seconds,
        "p50": latencies[len(latencies) // 2],
        "p99": latencies[min(len(latencies) - 1, int(len(latencies) * 0.99))],
        "client_cpu": max(r["cpu"] for r in results),
    }


def measure(node: str, command: list[str], args, connections: int, server_cpus, client_cpus) -> dict:
    process, port = start(pin(command, server_cpus))
    try:
        processes = min(args.client_processes, connections)
        load(node, port, connections, max(connections * 50, args.requests // 10), processes, client_cpus)
        before = cpu_seconds(process.pid)
        run = load(node, port, connections, args.requests, processes, client_cpus)
        run["server_cpu"] = (cpu_seconds(process.pid) - before) / run["seconds"]
    finally:
        stop(process)
    return run


def vm_client(node: str, bytecode: Path, args, server_cpus, client_cpus) -> float:
    process, port = start(pin([node, str(NODE_FILE), "server"], server_cpus))
    try:
        each = args.requests // 8
        started = time.perf_counter()
        command = [str(VM), "--", str(bytecode), f"http://127.0.0.1:{port}/", "8", str(each)]
        result = subprocess.run(pin(command, client_cpus), capture_output=True, text=True, check=True)
        seconds = time.perf_counter() - started
        if result.stdout.strip() != str(each * 8):
            raise SystemExit(f"the VM client got {result.stdout!r}")
    finally:
        stop(process)
    return each * 8 / seconds


def quiet_round(args, label: str, body):
    for attempt in range(args.retries + 1):
        load_average = os.getloadavg()[0]
        flagged = load_average > args.max_load
        print(f"{label}: load average {load_average:.2f}" + (" (busy)" if flagged else ""), file=sys.stderr, flush=True)
        if flagged and attempt < args.retries:
            time.sleep(args.wait)
            continue
        return load_average, flagged, body()
    raise AssertionError


def median_row(runs: list[dict]) -> dict:
    middle = sorted(runs, key=lambda r: r["rps"])[len(runs) // 2]
    return {**middle, "spread": (min(r["rps"] for r in runs), max(r["rps"] for r in runs))}


def main():
    parser = argparse.ArgumentParser(description="HTTP sanity check: keep-alive GET / against several servers")
    parser.add_argument("--requests", type=int, default=40000, help="requests per run")
    parser.add_argument("--connections", default="8,64", help="comma-separated connection counts")
    parser.add_argument("--rounds", type=int, default=3, help="rounds; each runs every server once, interleaved")
    parser.add_argument("--client-processes", type=int, default=4, help="Node load client processes")
    parser.add_argument("--server-cpus", default="0", help="taskset CPU list for the server")
    parser.add_argument("--client-cpus", default="2-7", help="taskset CPU list for the load clients")
    parser.add_argument("--no-pin", action="store_true", help="do not pin with taskset")
    parser.add_argument("--max-load", type=float, default=1.0, help="a round that starts above this 1-min load average is busy")
    parser.add_argument("--retries", type=int, default=3, help="repeats of a busy round before it is kept and flagged")
    parser.add_argument("--wait", type=float, default=30.0, help="seconds to wait before repeating a busy round")
    parser.add_argument("--serve", choices=["threading", "asyncio"], help=argparse.SUPPRESS)
    args = parser.parse_args()
    if args.serve == "threading":
        threading_server()
        return
    if args.serve == "asyncio":
        asyncio.run(asyncio_main())
        return
    node = shutil.which("node")
    if not node:
        raise SystemExit("node is required for the load client")
    if not VM.exists():
        raise SystemExit(f"{VM} is missing; run make vm")
    pinned = not args.no_pin
    if pinned and not shutil.which("taskset"):
        raise SystemExit("taskset is missing; install util-linux or pass --no-pin")
    server_cpus = args.server_cpus if pinned else None
    client_cpus = args.client_cpus if pinned else None
    levels = [int(c) for c in args.connections.split(",")]
    for level in levels:
        if level % min(args.client_processes, level):
            raise SystemExit(f"{level} connections do not split over {args.client_processes} client processes")
    with tempfile.TemporaryDirectory() as directory:
        work = Path(directory)
        bytecode = work / "http_server.agcb"
        compile_program(SERVER, bytecode)
        (work / "client.agc").write_text(CLIENT)
        compile_program(work / "client.agc", work / "client.agcb")
        servers = [
            ("VM (`examples/http_server.agc`)", [str(VM), "--", str(bytecode), "serve"]),
            ("Node `http`", [node, str(NODE_FILE), "server"]),
            ("Python asyncio", [sys.executable, str(Path(__file__)), "--serve", "asyncio"]),
            ("Python `ThreadingHTTPServer`", [sys.executable, str(Path(__file__)), "--serve", "threading"]),
        ]
        runs = {(level, name): [] for level in levels for name, _ in servers}
        client_runs = []
        rounds = []
        for number in range(1, args.rounds + 1):
            def one_round():
                for level in levels:
                    for name, command in servers:
                        runs[(level, name)].append(measure(node, command, args, level, server_cpus, client_cpus))
                client_runs.append(vm_client(node, work / "client.agcb", args, server_cpus, client_cpus))
            load_average, flagged, _ = quiet_round(args, f"round {number}", one_round)
            rounds.append((load_average, flagged))
    print(f"{args.requests} keep-alive GET / requests per run; {args.rounds} rounds, servers interleaved in each; "
          f"median per server; {os.cpu_count()} CPUs; "
          + (f"server on CPU {server_cpus}, {args.client_processes} Node client processes on CPUs {client_cpus} (taskset)"
             if pinned else f"not pinned, {args.client_processes} Node client processes"))
    print("1-min load average at the start of each round: "
          + ", ".join(f"{a:.2f}" + (" (busy)" if f else "") for a, f in rounds))
    print()
    print("| Connections | Server | Requests/s | Min to max | p50 ms | p99 ms | Server CPU | Max client CPU |")
    print("|---:|---|---:|---|---:|---:|---:|---:|")
    for (level, name), samples in runs.items():
        r = median_row(samples)
        low, high = r["spread"]
        print(f"| {level} | {name} | {r['rps']:,.0f} | {low:,.0f} to {high:,.0f} | {r['p50']:.2f} | {r['p99']:.2f} | "
              f"{r['server_cpu']:.0%} | {r['client_cpu']:.0%} |")
    print()
    print(f"VM client (8 tasks on one pool, start-up included) against the Node server: "
          f"{statistics.median(client_runs):,.0f} requests/s (median)")


main()
