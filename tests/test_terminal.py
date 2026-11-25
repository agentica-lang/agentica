"""Terminal: tty?, raw mode, the size and System.Signal.Winch (issue #1862).

On Linux and macOS the peer is this test: it gives the VM a pty of its own (the VM's controlling terminal, in a new
session), reads the pty's modes with termios, types keys into it, resizes it (the kernel then sends SIGWINCH) and
checks that the VM gives the first mode back when it ends normally, on a crash and on a stop signal. On Windows a
pseudo console is the console of a Python child that prints the console modes before and after a VM that turns raw
mode on and then crashes. One case without a terminal runs everywhere.
"""
import os
import signal
import struct
import subprocess
import time

import pytest

from tests.agentica_test import PYTHON, WINDOWS, compile_text, host_only, scaled, vm_command, vm_environment
from tests.windows_console_support import ESCAPES, run_on_console

WAIT_SECONDS = scaled(10)
POSIX = "ptys and termios exist on POSIX only; test_console_modes_are_set_and_given_back checks Windows"
CONSOLE_ONLY = "a pseudo console exists on Windows only; the pty cases check Linux and macOS"

PROGRAM = """\
def show(label: String) -> Void
  puts(label)
  IO.flush()
end

def main() -> Void
  mode = System.args()[0]
  streams = [Terminal.Stream.Stdin, Terminal.Stream.Stdout, Terminal.Stream.Stderr]
  puts("tty #{streams.map { |s| Terminal.tty?(s) }}")
  case Terminal.size()
    ok(size) -> puts("size #{size.rows}x#{size.cols}")
    error(e) -> puts("size #{e.kind}")
  end

  case mode
    "none" ->
      case Terminal.raw()
        ok(_) -> puts("raw ok")
        error(e) -> puts("raw #{e.kind}")
      end

      puts("cooked #{Terminal.raw(on: false).ok?}")
    "keys" ->
      Terminal.raw().unwrap!
      show("raw")
      puts("got #{IO.read_bytes(1).unwrap!.to_a}")
      Terminal.raw(on: false).unwrap!
      show("cooked")
      puts("line #{IO.gets().unwrap!}")
    "crash" ->
      Terminal.raw().unwrap!
      show("raw")
      IO.read_bytes(1).unwrap!
      puts([1][streams.size])
    "heap" ->
      Terminal.raw().unwrap!
      show("raw")
      IO.read_bytes(1).unwrap!
      grown = ["x"]
      while grown.size > 0
        grown = grown + grown
      end

    "signal" ->
      Terminal.raw().unwrap!
      show("raw")
      Task.sleep(30000)
    "resize" ->
      resized = System.subscribe([System.Signal.Winch]).unwrap!
      show("ready")
      signal = resized.recv(10000).unwrap!
      size = Terminal.size().unwrap!
      puts("#{signal} #{size.rows}x#{size.cols}")
    _ -> nil
  end

end
"""


@pytest.fixture(scope="module")
def program(tmp_path_factory):
    return compile_text(PROGRAM, "terminal", tmp_path_factory.mktemp("terminal"))


def test_without_a_terminal_every_call_says_so(program):
    """Pipes and /dev/null: no stream is a terminal, size and raw are io.failed errors, and raw(on: false) is ok."""
    result = subprocess.run([*vm_command(), "--", str(program), "none"], stdin=subprocess.DEVNULL,
                            capture_output=True, env=vm_environment(), timeout=WAIT_SECONDS)
    assert result.returncode == 0, result.stderr
    lines = result.stdout.decode().splitlines()
    assert lines == ["tty [false, false, false]", "size io.failed", "raw io.failed", "cooked true"]


class Pty:
    """The VM on a new pty. With `controlling` the pty is its controlling terminal, so a resize sends it SIGWINCH; the
    other cases leave it not controlling, because macOS revokes a controlling terminal when its session leader ends,
    and the test reads the pty's mode after the VM ended. The test reads what the VM writes while it waits for the
    end: macOS holds a process's exit until its output to a tty is read."""

    def __init__(self, program, mode, rows=33, cols=77, flags=(), controlling=False):
        import fcntl
        import pty
        import termios
        self.termios = termios
        self.master, self.slave = pty.openpty()
        self.resize(rows, cols)
        self.before = self.mode()
        self.text = b""

        def take_terminal():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)

        self.process = subprocess.Popen([*vm_command(), *flags, "--", str(program), mode], stdin=self.slave,
                                        stdout=self.slave, stderr=self.slave, env=vm_environment(),
                                        preexec_fn=take_terminal if controlling else None)

    def resize(self, rows, cols):
        import fcntl
        fcntl.ioctl(self.master, self.termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def mode(self):
        """The pty's modes, without PENDIN: macOS sets that kernel flag when ICANON comes back on and clears it at the
        next read, so it says nothing about the mode the VM set."""
        mode = self.termios.tcgetattr(self.slave)
        mode[3] &= ~getattr(self.termios, "PENDIN", 0)
        return mode

    def take(self, seconds):
        """What the VM wrote within SECONDS, added to the text; empty when nothing came."""
        import select
        if not select.select([self.master], [], [], seconds)[0]:
            return b""
        try:
            chunk = os.read(self.master, 4096)
        except OSError:  # Linux: EIO once nothing holds the slave side open
            chunk = b""
        self.text += chunk
        return chunk

    def read_until(self, marker):
        """The text the VM wrote up to and with MARKER; fails after WAIT_SECONDS."""
        deadline = time.monotonic() + WAIT_SECONDS
        while marker not in self.text:
            left = deadline - time.monotonic()
            assert left > 0 and self.take(left), self.text
        return self.text

    def type(self, keys):
        os.write(self.master, keys)

    def wait(self):
        """The exit status, reading the output meanwhile."""
        deadline = time.monotonic() + WAIT_SECONDS
        while self.process.poll() is None:
            assert time.monotonic() < deadline, self.text
            self.take(0.05)
        return self.process.returncode

    def close(self):
        try:
            if self.process.poll() is None:
                self.process.kill()
                self.wait()
        finally:
            os.close(self.master)
            os.close(self.slave)


@pytest.fixture
def ptys():
    opened = []
    yield lambda *args, **options: opened.append(Pty(*args, **options)) or opened[-1]
    for one in opened:
        one.close()


def assert_raw(pty):
    """No echo, no line editing, no signals from keys, bytes in (no CR to LF); output processing stays on."""
    termios = pty.termios
    iflag, oflag, _cflag, lflag = pty.mode()[:4]
    assert not lflag & (termios.ECHO | termios.ICANON | termios.ISIG | termios.IEXTEN)
    assert not iflag & (termios.ICRNL | termios.IXON)
    assert oflag & termios.OPOST


@host_only(WINDOWS, POSIX)
def test_raw_mode_takes_keys_as_bytes_without_echo_and_off_gives_the_line_mode_back(program, ptys):
    pty = ptys(program, "keys")
    assert b"tty [true, true, true]\r\nsize 33x77\r\n" in pty.read_until(b"raw\r\n")
    assert_raw(pty)
    pty.type(b"\x03")  # Ctrl+C is a byte, not SIGINT, and it is not echoed (as ^C)
    assert pty.read_until(b"cooked\r\n").endswith(b"raw\r\ngot [3]\r\ncooked\r\n")
    assert pty.mode() == pty.before
    pty.type(b"ab\n")
    assert pty.read_until(b"line ab\r\n").endswith(b"ab\r\nline ab\r\n")  # the line is echoed again
    assert pty.wait() == 0


@host_only(WINDOWS, POSIX)
def test_a_crash_gives_the_mode_back(program, ptys):
    pty = ptys(program, "crash")
    pty.read_until(b"raw\r\n")
    assert_raw(pty)
    pty.type(b"x")
    assert pty.wait() == 1
    assert b"RUNTIME-INDEX-OUT-OF-RANGE" in pty.read_until(b"RUNTIME-INDEX-OUT-OF-RANGE")
    assert pty.mode() == pty.before


@host_only(WINDOWS, POSIX)
def test_the_heap_limit_gives_the_mode_back(program, ptys):
    pty = ptys(program, "heap", flags=("--max-heap", "16M"))
    pty.read_until(b"raw\r\n")
    assert_raw(pty)
    pty.type(b"x")
    assert pty.wait() == 70
    assert pty.mode() == pty.before


@host_only(WINDOWS, POSIX)
def test_a_stop_signal_gives_the_mode_back(program, ptys):
    pty = ptys(program, "signal")
    pty.read_until(b"raw\r\n")
    assert_raw(pty)
    pty.type(b"x")
    pty.process.send_signal(signal.SIGTERM)
    assert pty.wait() == -signal.SIGTERM
    assert pty.mode() == pty.before


@host_only(WINDOWS, POSIX)
def test_a_resize_is_a_winch_value_and_the_new_size(program, ptys):
    pty = ptys(program, "resize", controlling=True)
    pty.read_until(b"ready\r\n")
    pty.resize(40, 100)
    assert pty.read_until(b"100\r\n").endswith(b"System.Signal.Winch 40x100\r\n")
    assert pty.wait() == 0


# Prints the modes of the console's input buffer and screen buffer (CONIN$ and CONOUT$, opened for reading and writing,
# which GetConsoleMode needs), as two numbers, whatever the standard handles of this process are.
MODES = ("import ctypes, sys; k = ctypes.WinDLL('kernel32'); k.CreateFileW.restype = ctypes.c_void_p; "
         "m = ctypes.c_ulong(); h = lambda n: ctypes.c_void_p(k.CreateFileW(n, 0xC0000000, 3, None, 3, 0, None)); "
         "f = lambda n: k.GetConsoleMode(h(n), ctypes.byref(m)) and m.value; "
         "print('modes', f('CONIN$'), f('CONOUT$'), flush=True)")

# Prints the modes, runs the VM (which shares the console), and prints them again.
CONSOLE = MODES + "; import subprocess; c = subprocess.call(sys.argv[1:]); print('exit', c, flush=True); " + \
          "print('modes', f('CONIN$'), f('CONOUT$'), flush=True)"

RAW_THEN_CRASH = """\
def modes(python: String) -> String
  child = Process.spawn_captured(python, ["-c", System.args()[1]]).unwrap!
  Process.output(child, 10000).unwrap!.stdout.strip
end

def main() -> Void
  python = System.args()[0]
  size = Terminal.size().unwrap!
  puts("size #{size.rows}x#{size.cols} #{Terminal.tty?(Terminal.Stream.Stdin)}")
  Terminal.raw().unwrap!
  puts(modes(python))
  Terminal.raw(on: false).unwrap!
  puts(modes(python))
  Terminal.raw().unwrap!
  puts([1][3])
end
"""

ENABLE_PROCESSED_INPUT, ENABLE_LINE_INPUT, ENABLE_ECHO_INPUT = 0x1, 0x2, 0x4
ENABLE_VIRTUAL_TERMINAL_INPUT, ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x200, 0x4


@host_only(not WINDOWS, CONSOLE_ONLY)
def test_console_modes_are_set_and_given_back(tmp_path):
    bytecode = compile_text(RAW_THEN_CRASH, "console", tmp_path)
    command = [PYTHON, "-c", CONSOLE, *vm_command(), "--", str(bytecode), PYTHON, MODES]
    code, shown = run_on_console(command, vm_environment(), WAIT_SECONDS)
    assert code == 0, shown
    lines = [line.strip() for line in ESCAPES.sub("", shown).splitlines()]
    lines = [line for line in lines if line.startswith(("modes", "size", "exit"))]
    first, size, raw, cooked, ended, last = (line.split() for line in lines[:6])
    assert size == ["size", "30x100", "true"], shown
    in_mode, out_mode = int(first[1]), int(first[2])
    raw_in, raw_out = int(raw[1]), int(raw[2])
    assert not raw_in & (ENABLE_PROCESSED_INPUT | ENABLE_LINE_INPUT | ENABLE_ECHO_INPUT)
    assert raw_in & ENABLE_VIRTUAL_TERMINAL_INPUT and raw_out & ENABLE_VIRTUAL_TERMINAL_PROCESSING
    assert cooked[1:] == first[1:] and last[1:] == first[1:], shown
    assert ended == ["exit", "1"], shown
    assert in_mode & ENABLE_LINE_INPUT and out_mode


RESIZED = """\
def main() -> Void
  resized = System.subscribe([System.Signal.Winch]).unwrap!
  File.write_text(System.args()[0], "ready").unwrap!
  signal = resized.recv(10000).unwrap!
  size = Terminal.size().unwrap!
  puts("#{signal} #{size.rows}x#{size.cols}")
end
"""


@host_only(not WINDOWS, CONSOLE_ONLY)
def test_a_console_resize_is_a_winch_value(tmp_path):
    bytecode = compile_text(RESIZED, "resized", tmp_path)
    ready = tmp_path / "ready"

    def resize_when_ready(type_text):
        deadline = time.monotonic() + WAIT_SECONDS
        while not ready.exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        type_text.resize(90, 25)

    command = [*vm_command(), "--", str(bytecode), str(ready)]
    code, shown = run_on_console(command, vm_environment(), WAIT_SECONDS, during=resize_when_ready)
    assert code == 0, shown
    assert "System.Signal.Winch 25x90" in ESCAPES.sub("", shown), shown
