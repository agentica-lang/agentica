"""The POSIX side of the child channel: descriptors pinned to files, FIFOs and devices, and a shell child.

They need fcntl, mkfifo and sh, so they run on Linux and macOS; the cases of every system are in
child-channel-peer.js. Where /proc exists (Linux) the answer also names the target of descriptor 3. Drives the child side of fixtures/child-channel.agc and prints JSON.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

from child_channel import launch


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


def held(vm, bytecode, mode, marker=True):
    child, channel = launch([vm, "run", "--", bytecode, mode], marker=marker)
    return finish(child, channel, time.monotonic())


def marker_only(vm, bytecode, mode):
    env = dict(os.environ, AGENTICA_CHANNEL="3")
    child = subprocess.Popen([vm, "run", "--", bytecode, mode], stdin=subprocess.DEVNULL,
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
    child, _ = launch([vm, "run", "--", bytecode, mode], inherited=descriptor)
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
    extra = {"head": head.decode()}
    if os.path.isdir("/proc/self/fd"):
        extra["target"] = os.readlink("/proc/%d/fd/3" % child.pid)
    if kind == "file":
        with open(target, "rb") as written:
            extra["content"] = written.read().decode()
    child.stdin.close()
    answer = finish(child, None, time.monotonic(), extra)
    if kind == "writeonly":
        os.close(reader)
    return answer


def main():
    vm, bytecode = sys.argv[1], sys.argv[2]
    with tempfile.TemporaryDirectory() as directory:
        pinned_answers = {kind: pinned(vm, bytecode, kind, directory) for kind in ("file", "device", "writeonly", "fifo")}
    print(json.dumps({
        "pinned": pinned_answers,
        "spawning": held(vm, bytecode, "spawning"),
        "spawning_marker_only": marker_only(vm, bytecode, "spawning"),
    }))


if __name__ == "__main__":
    main()
