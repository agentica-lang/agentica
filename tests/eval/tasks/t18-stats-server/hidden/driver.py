import http.client
import json
import os
import re
import select
import signal
import subprocess
import sys
import time


def read_port(proc):
    deadline = time.time() + 15
    buffer = b""
    while time.time() < deadline:
        ready, _, _ = select.select([proc.stdout], [], [], 0.2)
        if ready:
            chunk = os.read(proc.stdout.fileno(), 4096)
            if not chunk:
                return None
            buffer += chunk
            found = re.search(rb"^listening (\d+)\r?$", buffer, re.MULTILINE)
            if found:
                return int(found.group(1))
        if proc.poll() is not None:
            return None
    return None


def shown_body(media, raw):
    text = raw.decode("utf-8", "replace")
    if media == "application/json":
        try:
            return json.dumps(json.loads(text), sort_keys=True, separators=(",", ":"))
        except ValueError:
            pass
    return "<not json: " + repr(text[:60]) + ">"


def request(port, line):
    method, _, rest = line.partition(" ")
    path, _, body = rest.partition(" ")
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        headers = {"Content-Type": "application/json"} if body else {}
        connection.request(method, path, body=body.encode() if body else None, headers=headers)
        response = connection.getresponse()
        raw = response.read()
        media = (response.getheader("Content-Type") or "-").split(";")[0].strip().lower()
        allow = response.getheader("Allow")
        suffix = f" allow={allow}" if allow else ""
        return f"{method} {path} -> {response.status} {media} {shown_body(media, raw)}{suffix}"
    except (OSError, http.client.HTTPException):
        return f"{method} {path} -> no response"
    finally:
        connection.close()


def main():
    script = [line for line in sys.stdin.read().splitlines() if line.strip()]
    proc = subprocess.Popen(sys.argv[1:], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, start_new_session=True)
    port = read_port(proc)
    if port is None:
        print("error: the server did not announce a port")
    else:
        for line in script:
            print(request(port, line))
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()
    sys.stderr.write(proc.stderr.read().decode("utf-8", "replace"))


main()
