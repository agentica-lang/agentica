"""The server that the hooks of tests/test_bdd_feature_hooks.py start: a counter over HTTP on a free port.

GET /hit adds one, GET /reset sets zero, and every answer is the count. It logs "start PORT PID" to the file named by
the argument, and stops when it is killed.
"""
import http.server
import os
import sys

count = 0


class Counter(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        global count
        if self.path == "/hit":
            count += 1
        elif self.path == "/reset":
            count = 0
        body = str(count).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


server = http.server.HTTPServer(("127.0.0.1", 0), Counter)
with open(sys.argv[1], "a") as log:
    log.write("start %d %d\n" % (server.server_address[1], os.getpid()))
print(server.server_address[1], flush=True)
server.serve_forever()
