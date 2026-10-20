import argparse
import json
import os
import socket
import subprocess
import sys
import threading
import time


def shrink_pipe(fd, size):
    """Makes the pipe hold at most `size` bytes where the system lets a program say so (Linux); a no-op elsewhere.

    Linux pipes hold 64 KiB and macOS and Windows pipes 16 KiB or less, so a test that needs a stuck pipe asks for the
    smallest one.
    """
    if not size:
        return
    try:
        import fcntl
        fcntl.fcntl(fd, fcntl.F_SETPIPE_SZ, size)
    except (ImportError, AttributeError, OSError):
        pass


def winsock_pair():
    """A connected pair of TCP sockets on 127.0.0.1 whose writer is not in overlapped mode.

    socket.socketpair() makes overlapped sockets, which a child cannot write with WriteFile (the call behind _write)
    and so cannot use as a standard handle. WSASocketW without WSA_FLAG_OVERLAPPED makes the kind that a console or
    an inetd-style parent hands over.
    """
    import ctypes

    wsa_socket = ctypes.WinDLL("ws2_32").WSASocketW
    wsa_socket.restype = ctypes.c_size_t
    wsa_socket.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
    handle = wsa_socket(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, None, 0, 0)
    if handle == (1 << (8 * ctypes.sizeof(ctypes.c_void_p))) - 1:
        raise OSError("WSASocketW failed: %d" % ctypes.get_last_error())
    writer = socket.socket(socket.AF_INET, socket.SOCK_STREAM, fileno=handle)
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        listener.listen(1)
        writer.connect(listener.getsockname())
        reader, _ = listener.accept()
    return reader, writer


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--stdout-file", required=True)
    parser.add_argument("--stderr-file", required=True)
    parser.add_argument("--delay", type=float, default=0)
    parser.add_argument("--error-delay", type=float, default=0)
    parser.add_argument("--chunk", type=int, default=65536)
    parser.add_argument("--pause", type=float, default=0)
    parser.add_argument("--read-after-exit", action="store_true")
    parser.add_argument("--merge", action="store_true")
    parser.add_argument("--socket", action="store_true")
    parser.add_argument("--pty", action="store_true")
    parser.add_argument("--close-after", type=int, default=0)
    parser.add_argument("--pipe-size", type=int, default=0)
    parser.add_argument("--limit", type=float, default=60)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    command = options.command[1:] if options.command[:1] == ["--"] else options.command

    read_socket = None
    if options.socket:
        reader, writer = winsock_pair() if os.name == "nt" else socket.socketpair()
        if os.name == "nt":
            # Winsock handles are not descriptors: the reader stays a socket object, and the writer becomes a CRT
            # descriptor over its handle, which is what Popen duplicates for the child.
            import msvcrt

            read_socket = reader
            if options.pipe_size:
                reader.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, options.pipe_size)
                writer.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, options.pipe_size)
            read_fd, write_fd = None, msvcrt.open_osfhandle(writer.detach(), 0)
        else:
            read_fd, write_fd = reader.detach(), writer.detach()
    elif options.pty:
        import pty

        read_fd, write_fd = pty.openpty()
    else:
        read_fd, write_fd = os.pipe()
        shrink_pipe(write_fd, options.pipe_size)
    if options.merge or options.pty:
        error_read, error_write = None, write_fd
    else:
        error_read, error_write = os.pipe()

    start = time.monotonic()
    vm = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=write_fd, stderr=error_write, close_fds=True)
    os.close(write_fd)
    if error_read is not None:
        os.close(error_write)

    state = {"exit": None, "read_start": None, "status": None, "ticks": 0, "first_error": None}
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
        time.sleep(options.error_delay)
        while True:
            data = os.read(error_read, 65536)
            if not data:
                break
            if state["first_error"] is None:
                state["first_error"] = time.monotonic() - start
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
        try:
            data = read_socket.recv(options.chunk) if read_socket else os.read(read_fd, options.chunk)
        except OSError:
            break
        if not data:
            break
        out_data.extend(data)
        if options.close_after and len(out_data) >= options.close_after:
            break
        if options.pause:
            time.sleep(options.pause)
    if read_socket:
        read_socket.close()
    else:
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
                "first_error_at": state["first_error"],
            }
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
