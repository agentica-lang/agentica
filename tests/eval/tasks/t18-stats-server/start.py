import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        return

    def send_text(self, status: int, body: str) -> None:
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def stats(self, raw: bytes) -> str:
        values = json.loads(raw.decode("utf-8"))["values"]
        ordered = sorted(values)
        return json.dumps({"count": len(values), "total": sum(values), "min": ordered[-1], "max": ordered[0]})

    def do_GET(self) -> None:
        if self.path == "/health":
            self.send_text(200, json.dumps({"status": "ok"}))
        elif self.path == "/hello":
            self.send_text(200, json.dumps({"greeting": "hello, world"}))
        elif self.path.startswith("/double/"):
            n = int(self.path[len("/double/"):])
            self.send_text(200, json.dumps({"n": n, "double": n * 2}))
        else:
            self.send_text(200, json.dumps({"error": "not found"}))

    def do_POST(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        if self.path == "/stats":
            self.send_text(200, self.stats(raw))
        else:
            self.send_text(200, json.dumps({"error": "not found"}))


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print("listening 0", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
