import json
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

INTEGER = re.compile(r"-?[0-9]+")


def stats_body(raw: bytes) -> tuple[int, object]:
    try:
        root = json.loads(raw.decode("utf-8"))
    except ValueError:
        return 400, {"error": "invalid json"}
    values = root.get("values") if isinstance(root, dict) else None
    if not isinstance(values, list) or len(values) == 0 or any(type(v) is not int for v in values):
        return 400, {"error": "values must be a non-empty array of integers"}
    return 200, {"count": len(values), "sum": sum(values), "min": min(values), "max": max(values)}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, format: str, *args: object) -> None:
        return

    def send_json(self, status: int, body: object, allow: str | None = None) -> None:
        data = json.dumps(body, separators=(",", ":")).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        if allow is not None:
            self.send_header("Allow", allow)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def handle_request(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b""
        parts = urlsplit(self.path)
        path = parts.path
        if path == "/health":
            allow = "GET"
        elif path == "/stats":
            allow = "POST"
        elif path == "/hello":
            allow = "GET"
        elif path.startswith("/double/"):
            allow = "GET"
        else:
            self.send_json(404, {"error": "not found"})
            return
        if self.command != allow:
            self.send_json(405, {"error": "method not allowed"}, allow)
        elif path == "/health":
            self.send_json(200, {"status": "ok"})
        elif path == "/stats":
            status, body = stats_body(raw)
            self.send_json(status, body)
        elif path == "/hello":
            names = parse_qs(parts.query).get("name", ["world"])
            self.send_json(200, {"greeting": f"hello, {names[0]}"})
        else:
            text = path[len("/double/"):]
            if INTEGER.fullmatch(text) is None:
                self.send_json(400, {"error": "not an integer"})
            else:
                self.send_json(200, {"n": int(text), "double": int(text) * 2})

    do_GET = handle_request
    do_POST = handle_request
    do_PUT = handle_request
    do_DELETE = handle_request
    do_PATCH = handle_request


def main() -> None:
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(f"listening {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
