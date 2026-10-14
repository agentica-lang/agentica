import fcntl
import os
import socket
import subprocess

MARKER = "AGENTICA_CHANNEL"


def launch(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=None, marker=True, inherited=None):
    parent = child = None
    if inherited is None:
        parent, child = socket.socketpair()
        inherited = child.fileno()
    spare = fcntl.fcntl(inherited, fcntl.F_DUPFD, 5)
    if child is not None:
        child.close()
    shell = ["sh", "-c", 'exec "$@" 3<&%d %d<&-' % (spare, spare), "sh"] + list(argv)
    merged = dict(os.environ) if env is None else dict(env)
    merged.pop(MARKER, None)
    if marker:
        merged[MARKER] = "3"
    try:
        process = subprocess.Popen(
            shell,
            stdin=stdin,
            stdout=stdout,
            stderr=stderr,
            pass_fds=(spare,),
            env=merged,
        )
    finally:
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
