import os
import signal
import subprocess
import sys


def fill(path):
    os.mkfifo(path, 0o600)
    fd = os.open(path, os.O_RDWR | os.O_NONBLOCK)
    try:
        while True:
            os.write(fd, b"f" * 65536)
    except BlockingIOError:
        pass
    print("ready", flush=True)
    sys.stdin.read()
    os.close(fd)


def drive(command):
    # command is [binary, "run", "--", file, ...]: the flag goes after `run`.
    vm = subprocess.Popen(command[:2] + ["--driver-pid", str(os.getpid())] + command[2:], stdout=subprocess.PIPE)
    vm.stdout.readline()
    print(vm.pid, flush=True)
    os._exit(0)


def relay(command, **options):
    vm = subprocess.run(command, stdout=subprocess.PIPE, close_fds=True, **options)
    sys.stdout.write(vm.stdout.decode())
    sys.exit(vm.returncode)


def launch(disposition, command):
    handler = {"default": signal.SIG_DFL, "ignore": signal.SIG_IGN}[disposition]
    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, handler)
    os.execv(command[0], command)


def inherit(command):
    read, write = os.pipe()
    os.write(write, b"inherited\n")
    os.close(write)
    directory = "/dev/fd" if sys.platform == "darwin" else "/proc/self/fd"
    relay(command + [f"{directory}/{read}"], pass_fds=(read,))


if __name__ == "__main__":
    {
        "fill": lambda: fill(sys.argv[2]),
        "drive": lambda: drive(sys.argv[2:]),
        "inherit": lambda: inherit(sys.argv[2:]),
        "clean": lambda: relay(sys.argv[2:]),
        "launch": lambda: launch(sys.argv[2], sys.argv[3:]),
    }[sys.argv[1]]()
