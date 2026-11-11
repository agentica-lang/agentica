import os
import selectors
import sys

from child_channel import launch

PREFIX = b"channel> "
# A test child (--agentica-test run) sends this before it reads its first index. The first line already went at the
# start, so this record brings no line: the next index goes only after the record of the test before, as the runner
# sends it, and a test's output stays before that record.
READY = b'{"event":"ready"}'


def pump(fd, out):
    """Copies what the child's stdout holds now to `out`; False once it has ended.

    The descriptor is non-blocking, so a read never waits: one select() can report the channel and stdout together,
    and the channel's turn pumps stdout first, so the stdout key that follows can find the pipe empty. A blocking read
    there waits for output the child never writes while it waits for the next index: the run hangs."""
    while True:
        try:
            data = os.read(fd, 65536)
        except BlockingIOError:
            return True
        if not data:
            return False
        out.write(data)
        out.flush()


def feed(channel, pending):
    try:
        if pending:
            channel.sendall(pending.pop(0))
        if not pending:
            channel.end_input()
    except OSError:
        pending.clear()


def main():
    feed_file, command = sys.argv[1], sys.argv[2:]
    with open(feed_file, "rb") as source:
        pending = [line + b"\n" for line in source.read().split(b"\n") if line]
    out = sys.stdout.buffer
    child, channel = launch(command, stdin=None, stderr=None)
    stdout = child.stdout.fileno()
    os.set_blocking(stdout, False)
    selector = selectors.DefaultSelector()
    selector.register(channel, selectors.EVENT_READ, "channel")
    selector.register(stdout, selectors.EVENT_READ, "stdout")
    feed(channel, pending)
    buffer = b""
    stdout_open = True
    open_streams = 2
    while open_streams:
        for key, _ in selector.select():
            # Every key pumps stdout first, so the output written before a record goes out before it.
            if stdout_open and not pump(stdout, out):
                selector.unregister(stdout)
                stdout_open = False
                open_streams -= 1
            if key.data == "stdout":
                continue
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
                if line != READY:
                    feed(channel, pending)
    if buffer:
        out.write(PREFIX + buffer + b"\n")
        out.flush()
    code = child.wait()
    sys.exit(code if code >= 0 else 128 - code)


if __name__ == "__main__":
    main()
