import json
import os
import socket
import subprocess
import sys
import tempfile
import time

from child_channel import launch, lines


def finish(child, channel, started, extra=None):
    try:
        code = child.wait(timeout=30)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()
        raise
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


def pinned(vm, bytecode, kind, directory):
    mode = "pinned"
    if kind == "file":
        target = os.path.join(directory, "plain.txt")
        descriptor = os.open(target, os.O_RDWR | os.O_CREAT, 0o600)
    elif kind == "device":
        target = "/dev/null"
        descriptor = os.open(target, os.O_RDWR)
    elif kind == "writeonly":
        target = os.path.join(directory, "half")
        os.mkfifo(target)
        reader = os.open(target, os.O_RDONLY | os.O_NONBLOCK)
        descriptor = os.open(target, os.O_WRONLY)
    else:
        mode = "piped"
        target = os.path.join(directory, "fifo")
        os.mkfifo(target)
        descriptor = os.open(target, os.O_RDWR)
    child, _ = launch([vm, "--allow-run", "--", bytecode, mode], inherited=descriptor)
    os.close(descriptor)
    if kind == "fifo":
        writer = os.open(target, os.O_WRONLY)
        os.write(writer, b"hello\n")
        os.close(writer)
    head = b""
    while not head.endswith(b"ready\n"):
        more = child.stdout.readline()
        if not more:
            break
        head += more
    extra = {"head": head.decode(), "target": os.readlink("/proc/%d/fd/3" % child.pid)}
    if kind == "file":
        with open(target, "rb") as written:
            extra["content"] = written.read().decode()
    child.stdin.close()
    answer = finish(child, None, time.monotonic(), extra)
    if kind == "writeonly":
        os.close(reader)
    return answer


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
    elif mode == "split":
        sys.stdout.buffer.write(b"a\xc3")
        sys.stdout.buffer.flush()
        channel.write(b"one\n")
        data = b""
        while not data.endswith(b"\n"):
            data += channel.read(1)
        sys.stdout.buffer.write(b"\xa9b\n")
        sys.stdout.buffer.flush()
        channel.write(b"two\n")
        time.sleep(30)
    elif mode == "gone":
        return
    else:
        time.sleep(30)


def main():
    if sys.argv[1] == "child":
        as_child(sys.argv[2])
        return
    vm, bytecode = sys.argv[1], sys.argv[2]
    with tempfile.TemporaryDirectory() as directory:
        pinned_answers = {kind: pinned(vm, bytecode, kind, directory) for kind in ("file", "device", "writeonly", "fifo")}
    print(json.dumps({
        "pinned": pinned_answers,
        "serve": serve(vm, bytecode),
        "idle": held(vm, bytecode, "idle"),
        "bare": held(vm, bytecode, "bare", marker=False),
        "bare_marker_only": marker_only(vm, bytecode, "bare"),
        "spawning": held(vm, bytecode, "spawning"),
        "spawning_marker_only": marker_only(vm, bytecode, "spawning"),
    }))


if __name__ == "__main__":
    main()
