import json
import os
import socket
import subprocess
import sys
import time

from child_channel import launch, lines


def finish(child, channel, started, extra=None):
    code = child.wait(timeout=30)
    seconds = time.monotonic() - started
    if channel is not None:
        channel.close()
    answer = {"exit": code, "stdout": child.stdout.read().decode(), "waited": seconds >= 0.25}
    answer.update(extra or {})
    return answer


def serve(vm, bytecode):
    child, channel = launch([vm, "--allow-run", "--", bytecode, "serve"])
    reader = lines(channel)
    started = time.monotonic()
    replies = []
    channel.sendall(b"one\n")
    replies.append(reader.readline())
    channel.sendall(b"tw")
    time.sleep(0.2)
    channel.sendall(b"o\n\n")
    replies.append(reader.readline())
    replies.append(reader.readline())
    channel.sendall(b"y" * 300000 + b"\n")
    replies.append(len(reader.readline()))
    channel.sendall("café\n".encode())
    replies.append(reader.readline())
    channel.shutdown(socket.SHUT_WR)
    replies.append(reader.readline())
    replies.append(reader.readline())
    return finish(child, channel, started, {"replies": replies})


def held(vm, bytecode, mode, marker=True):
    child, channel = launch([vm, "--allow-run", "--", bytecode, mode], marker=marker)
    return finish(child, channel, time.monotonic())


def marker_only(vm, bytecode, mode):
    env = dict(os.environ, AGENTICA_CHANNEL="3")
    child = subprocess.Popen([vm, "--allow-run", "--", bytecode, mode], stdin=subprocess.DEVNULL,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    return finish(child, None, time.monotonic())


def as_child(mode):
    if mode == "plain":
        print("marker=%s fd3=%s" % (os.environ.get("AGENTICA_CHANNEL"), os.path.exists("/proc/self/fd/3")), flush=True)
        return
    channel = os.fdopen(3, "r+b", buffering=0)
    if mode == "echo":
        data = b""
        while not data.endswith(b"\n"):
            data += channel.read(1)
        print("out:" + data.decode().strip(), flush=True)
        channel.write(data.upper())
        while channel.read(1):
            pass
    elif mode == "long":
        channel.write(b"x" * 1048700)
        time.sleep(30)
    elif mode == "loud":
        print("noise", flush=True)
        channel.write(b"done\n")
        time.sleep(30)
    else:
        time.sleep(30)


def main():
    if sys.argv[1] == "child":
        as_child(sys.argv[2])
        return
    vm, bytecode = sys.argv[1], sys.argv[2]
    print(json.dumps({
        "serve": serve(vm, bytecode),
        "idle": held(vm, bytecode, "idle"),
        "bare": held(vm, bytecode, "bare", marker=False),
        "bare_marker_only": marker_only(vm, bytecode, "bare"),
        "spawning": held(vm, bytecode, "spawning"),
        "spawning_marker_only": marker_only(vm, bytecode, "spawning"),
    }))


if __name__ == "__main__":
    main()
