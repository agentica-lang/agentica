import os
import selectors
import socket
import sys

from child_channel import launch

PREFIX = b"channel> "


def drain(stream, out):
    os.set_blocking(stream.fileno(), False)
    try:
        data = stream.read()
    finally:
        os.set_blocking(stream.fileno(), True)
    if data:
        out.write(data)
        out.flush()


def feed(channel, pending):
    try:
        if pending:
            channel.sendall(pending.pop(0))
        if not pending:
            channel.shutdown(socket.SHUT_WR)
    except OSError:
        pending.clear()


def main():
    feed_file, command = sys.argv[1], sys.argv[2:]
    with open(feed_file, "rb") as source:
        pending = [line + b"\n" for line in source.read().split(b"\n") if line]
    out = sys.stdout.buffer
    child, channel = launch(command, stdin=None, stderr=None)
    selector = selectors.DefaultSelector()
    selector.register(channel, selectors.EVENT_READ, "channel")
    selector.register(child.stdout, selectors.EVENT_READ, "stdout")
    feed(channel, pending)
    buffer = b""
    open_streams = 2
    while open_streams:
        for key, _ in selector.select():
            if key.data == "stdout":
                data = os.read(child.stdout.fileno(), 65536)
                if not data:
                    selector.unregister(child.stdout)
                    open_streams -= 1
                else:
                    out.write(data)
                    out.flush()
                continue
            drain(child.stdout, out)
            try:
                data = channel.recv(65536)
            except ConnectionResetError:
                data = b""
            if not data:
                selector.unregister(channel)
                open_streams -= 1
                continue
            buffer += data
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                out.write(PREFIX + line + b"\n")
                out.flush()
                feed(channel, pending)
    if buffer:
        out.write(PREFIX + buffer + b"\n")
        out.flush()
    code = child.wait()
    sys.exit(code if code >= 0 else 128 - code)


if __name__ == "__main__":
    main()
