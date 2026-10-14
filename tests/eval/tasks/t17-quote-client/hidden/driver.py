import http.server
import json
import subprocess
import sys
import threading

PRICES = {"tea": 250, "coffee": 400, "milk": 120, "cocoa": 380}
LOG = []


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body, content_type="application/json"):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode("utf-8", "replace")
        media = self.headers.get("Content-Type", "").split(";")[0].strip().lower()
        try:
            shown = json.dumps(json.loads(raw), sort_keys=True, separators=(",", ":"))
        except ValueError:
            shown = raw
        LOG.append(f"{self.command} {self.path} [{media}] {shown}")
        if self.path != "/quote":
            self.reply(404, json.dumps({"error": "no such route"}))
            return
        try:
            body = json.loads(raw)
        except ValueError:
            self.reply(400, json.dumps({"error": "invalid json"}))
            return
        valid = (
            media == "application/json"
            and isinstance(body, dict)
            and set(body) == {"item", "quantity"}
            and isinstance(body["item"], str)
            and type(body["quantity"]) is int
        )
        if not valid:
            self.reply(400, json.dumps({"error": "bad request"}))
            return
        item, quantity = body["item"], body["quantity"]
        if quantity < 1:
            self.reply(400, json.dumps({"error": "quantity must be positive"}))
        elif item == "broken":
            self.reply(500, "oops", "text/plain")
        elif item == "badjson":
            self.reply(200, "not json")
        elif item == "partial":
            self.reply(200, json.dumps({"item": item, "unit_cents": 1}))
        elif item == "drop":
            self.close_connection = True
            self.connection.close()
        elif item in PRICES:
            unit = PRICES[item]
            self.reply(200, json.dumps({"item": item, "unit_cents": unit, "total_cents": unit * quantity, "currency": "EUR"}))
        else:
            self.reply(404, json.dumps({"error": "unknown item"}))


class Server(http.server.ThreadingHTTPServer):
    def handle_error(self, request, client_address):
        pass


def main():
    server = Server(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    url = f"http://127.0.0.1:{server.server_address[1]}"
    done = subprocess.run(sys.argv[1:] + [url], input=sys.stdin.read(), capture_output=True, text=True, timeout=30)
    server.shutdown()
    sys.stderr.write(done.stderr)
    sys.stdout.write(done.stdout)
    print("--- requests")
    for line in LOG:
        print(line)
    print(f"--- exit {done.returncode}")


main()
