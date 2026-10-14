import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout-file", required=True)
    parser.add_argument("--stderr-file", required=True)
    parser.add_argument("--delay", type=float, default=0)
    parser.add_argument("--chunk", type=int, default=65536)
    parser.add_argument("--pause", type=float, default=0)
    parser.add_argument("--read-after-exit", action="store_true")
    parser.add_argument("--merge", action="store_true")
    parser.add_argument("--socket", action="store_true")
    parser.add_argument("--close-after", type=int, default=0)
    parser.add_argument("--limit", type=float, default=60)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    command = options.command[1:] if options.command[:1] == ["--"] else options.command

    if options.socket:
        reader, writer = socket.socketpair()
        read_fd, write_fd = reader.detach(), writer.detach()
    else:
        read_fd, write_fd = os.pipe()
    if options.merge:
        error_read, error_write = None, write_fd
    else:
        error_read, error_write = os.pipe()

    start = time.monotonic()
    vm = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=write_fd, stderr=error_write, close_fds=True)
    os.close(write_fd)
    if error_read is not None:
        os.close(error_write)

    state = {"exit": None, "read_start": None, "status": None, "ticks": 0}
    error_data = bytearray()

    def watch_exit():
        try:
            state["status"] = vm.wait(timeout=options.limit)
        except subprocess.TimeoutExpired:
            vm.kill()
            state["status"] = vm.wait()
            state["status"] = "timeout"
        state["exit"] = time.monotonic() - start

    def read_errors():
        while True:
            data = os.read(error_read, 65536)
            if not data:
                break
            if state["read_start"] is None:
                state["ticks"] += data.count(b"tick")
            error_data.extend(data)

    threads = [threading.Thread(target=watch_exit)]
    if error_read is not None:
        threads.append(threading.Thread(target=read_errors))
    for thread in threads:
        thread.start()

    out_data = bytearray()
    if options.read_after_exit:
        threads[0].join()
    else:
        time.sleep(options.delay)
    state["read_start"] = time.monotonic() - start
    while True:
        data = os.read(read_fd, options.chunk)
        if not data:
            break
        out_data.extend(data)
        if options.close_after and len(out_data) >= options.close_after:
            break
        if options.pause:
            time.sleep(options.pause)
    os.close(read_fd)
    for thread in threads:
        thread.join()

    with open(options.stdout_file, "wb") as handle:
        handle.write(out_data)
    with open(options.stderr_file, "wb") as handle:
        handle.write(error_data)
    print(
        json.dumps(
            {
                "status": state["status"],
                "exit": state["exit"],
                "read_start": state["read_start"],
                "ticks_before_read": state["ticks"],
                "stdout_bytes": len(out_data),
                "stderr_bytes": len(error_data),
            }
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
