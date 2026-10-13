import os
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
    vm = subprocess.Popen(command[:1] + ["--driver-pid", str(os.getpid())] + command[1:], stdout=subprocess.PIPE)
    vm.stdout.readline()
    print(vm.pid, flush=True)
    os._exit(0)


def inherit(command):
    read, write = os.pipe()
    os.write(write, b"inherited\n")
    os.close(write)
    vm = subprocess.run(command + ["/proc/self/fd/%d" % read], pass_fds=(read,), stdout=subprocess.PIPE)
    sys.stdout.write(vm.stdout.decode())
    sys.exit(vm.returncode)


if __name__ == "__main__":
    {"fill": lambda: fill(sys.argv[2]), "drive": lambda: drive(sys.argv[2:]), "inherit": lambda: inherit(sys.argv[2:])}[
        sys.argv[1]
    ]()
