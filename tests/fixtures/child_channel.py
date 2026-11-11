"""Starts a VM as the child of a Python peer with a child channel (docs/vm/10-io-processes.md, 10.4), on POSIX: the
common part of channel-run.py, test-protocol-peer.py and child-channel-peer.py (the Python twin of child_channel.js).

The channel is "3,4", as the VM gives it: the child reads descriptor 3 and writes descriptor 4, here one socket pair
each, as node gives them. With `inherited`, the child gets that one descriptor at 3 and the marker "3" instead, the
one-socket form of earlier versions, which a VM still takes from a parent that is no VM.
"""
import fcntl
import os
import socket
import subprocess

MARKER = "AGENTICA_CHANNEL"


class Channel:
    """The parent's ends of a "3,4" channel: it writes `to` (the child's descriptor 3) and reads `back` (its 4).

    A selector waits on it for reading."""

    def __init__(self, to, back):
        self.to = to
        self.back = back

    def fileno(self):
        return self.back.fileno()

    def sendall(self, data):
        self.to.sendall(data)

    def recv(self, size):
        return self.back.recv(size)

    def makefile(self, *args, **kwargs):
        return self.back.makefile(*args, **kwargs)

    def end_input(self):
        """The end of input: the close of the end the child reads, which every system delivers (a shutdown of one
        socket's write side did not always reach the child on macOS, #1392)."""
        self.to.close()

    def close(self):
        self.to.close()
        self.back.close()


def launch(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=None, marker=True, inherited=None):
    if inherited is None:
        to, to_child = socket.socketpair()
        back, back_child = socket.socketpair()
        parent, value = Channel(to, back), "3,4"
        given = [to_child.fileno(), back_child.fileno()]
    else:
        parent, value, given = None, "3", [inherited]
        to_child = back_child = None
    # Above 4, so that no redirection below overwrites a descriptor before it is read.
    spares = [fcntl.fcntl(fd, fcntl.F_DUPFD, 5) for fd in given]
    for end in (to_child, back_child):
        if end is not None:
            end.close()
    moves = " ".join("%d<&%d" % (3 + k, spare) for k, spare in enumerate(spares))
    closes = " ".join("%d<&-" % spare for spare in spares)
    shell = ["sh", "-c", 'exec "$@" %s %s' % (moves, closes), "sh"] + list(argv)
    merged = dict(os.environ) if env is None else dict(env)
    merged.pop(MARKER, None)
    if marker:
        merged[MARKER] = value
    try:
        process = subprocess.Popen(
            shell,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            pass_fds=tuple(spares),
            env=merged,
        )
    finally:
        for spare in spares:
            os.close(spare)
    return process, parent


def lines(channel):
    return channel.makefile("r", encoding="utf-8", newline="\n")


def read_ready(stream):
    os.set_blocking(stream.fileno(), False)
    try:
        data = stream.read()
    finally:
        os.set_blocking(stream.fileno(), True)
    return data or b""
