"""Console events and a console as standard output, on native Windows.

A VM started in its own process group takes Ctrl+Break the way a terminal gives
it (libuv reports it as SIGBREAK), and ends as a stop: children die, buffered
file data is written, the exit code is 128 + 21. Ctrl+C cannot be sent to a new
group (CREATE_NEW_PROCESS_GROUP turns it off), but libuv reports both through
one console handler, so Ctrl+Break covers that path. A pseudo console (ConPTY)
is the console of the test that writes standard output and standard error to a
console. The module needs a Windows console, so it does not run under Wine.
"""
import ctypes
import os
import re
import signal
import subprocess
import threading
import time

import pytest

from tests.agentica_test import PYTHON, compile_agc, scaled, start_vm, vm_command, vm_environment, wait_until

pytestmark = pytest.mark.skipif(os.name != "nt", reason="needs a Windows console")

WAIT_SECONDS = scaled(20)
SIGBREAK = 21
NEW_GROUP = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)

# A child that ignores Ctrl+Break and Ctrl+C, so only the VM can stop it.
CHILD = ("import os, signal, time; signal.signal(signal.SIGBREAK, signal.SIG_IGN); "
         "signal.signal(signal.SIGINT, signal.SIG_IGN); print(os.getpid(), flush=True); time.sleep(60)")

CHILD_PROGRAM = """\
def main() -> Void
  args = System.args()
  f = File.open(args[0], "write", 1000).unwrap!
  File.write(f, "buffered", 1000).unwrap!
  p = Process.spawn(args[1], ["-c", args[2]], 1000).unwrap!
  puts(Process.read_line(p, 5000).unwrap!)
  IO.flush()
  Task.sleep(30000)
end
"""

STUCK_STDOUT = """\
def main() -> Void
  line = "y"
  for i in 0..9
    line = line + line
  end
  n = 0
  while n < 100
    puts(line)
    n += 1
  end
  IO.warn("ready")
  Task.sleep(30000)
end
"""

CONSOLE_PROGRAM = """\
def main() -> Void
  puts("tty line é")
  IO.warn("tty error ü")
  puts("tty end")
end
"""

# The sequences a pseudo console adds around the text: CSI (colors, cursor), OSC (title) and the like.
ESCAPES = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][A-Z0-9]|\x1b[=>]")

if os.name == "nt":
    from ctypes import wintypes

    class Coord(ctypes.Structure):
        _fields_ = [("X", ctypes.c_short), ("Y", ctypes.c_short)]

    class StartupInfo(ctypes.Structure):
        _fields_ = [("cb", wintypes.DWORD), ("lpReserved", wintypes.LPWSTR), ("lpDesktop", wintypes.LPWSTR),
                    ("lpTitle", wintypes.LPWSTR), ("dwX", wintypes.DWORD), ("dwY", wintypes.DWORD),
                    ("dwXSize", wintypes.DWORD), ("dwYSize", wintypes.DWORD), ("dwXCountChars", wintypes.DWORD),
                    ("dwYCountChars", wintypes.DWORD), ("dwFillAttribute", wintypes.DWORD),
                    ("dwFlags", wintypes.DWORD), ("wShowWindow", wintypes.WORD), ("cbReserved2", wintypes.WORD),
                    ("lpReserved2", ctypes.c_void_p), ("hStdInput", wintypes.HANDLE),
                    ("hStdOutput", wintypes.HANDLE), ("hStdError", wintypes.HANDLE)]

    class StartupInfoEx(ctypes.Structure):
        _fields_ = [("StartupInfo", StartupInfo), ("lpAttributeList", ctypes.c_void_p)]

    class ProcessInformation(ctypes.Structure):
        _fields_ = [("hProcess", wintypes.HANDLE), ("hThread", wintypes.HANDLE),
                    ("dwProcessId", wintypes.DWORD), ("dwThreadId", wintypes.DWORD)]

    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    handle_pointer = ctypes.POINTER(wintypes.HANDLE)
    kernel32.CreatePipe.argtypes = [handle_pointer, handle_pointer, ctypes.c_void_p, wintypes.DWORD]
    kernel32.CreatePseudoConsole.argtypes = [Coord, wintypes.HANDLE, wintypes.HANDLE, wintypes.DWORD,
                                             ctypes.POINTER(ctypes.c_void_p)]
    kernel32.CreatePseudoConsole.restype = ctypes.c_long
    kernel32.ClosePseudoConsole.argtypes = [ctypes.c_void_p]
    kernel32.ClosePseudoConsole.restype = None
    kernel32.InitializeProcThreadAttributeList.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                                                           ctypes.POINTER(ctypes.c_size_t)]
    kernel32.UpdateProcThreadAttribute.argtypes = [ctypes.c_void_p, wintypes.DWORD, ctypes.c_size_t, ctypes.c_void_p,
                                                   ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p]
    kernel32.CreateProcessW.argtypes = [wintypes.LPCWSTR, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                        wintypes.BOOL, wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR,
                                        ctypes.POINTER(StartupInfoEx), ctypes.POINTER(ProcessInformation)]
    kernel32.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                                  ctypes.c_void_p]
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]


def bytecode(text, tmp_path, name="program"):
    source = tmp_path / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, tmp_path / (name + ".agcb"))


def alive(pid):
    """True while the process exists (SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, then a zero-wait)."""
    handle = kernel32.OpenProcess(0x00100000 | 0x1000, False, pid)
    if not handle:
        return False
    try:
        return kernel32.WaitForSingleObject(handle, 0) == 0x102
    finally:
        kernel32.CloseHandle(handle)


def run_on_console(command, env, limit):
    """Runs the command with a pseudo console as its console, standard input and standard output.

    Returns (exit code, the text the console showed). The pseudo console is closed after the exit, while a thread
    reads its output, because closing it waits for the output to be taken.
    """
    in_read, in_write, out_read, out_write = (wintypes.HANDLE() for _ in range(4))
    assert kernel32.CreatePipe(ctypes.byref(in_read), ctypes.byref(in_write), None, 0)
    assert kernel32.CreatePipe(ctypes.byref(out_read), ctypes.byref(out_write), None, 0)
    console = ctypes.c_void_p()
    result = kernel32.CreatePseudoConsole(Coord(100, 30), in_read, out_write, 0, ctypes.byref(console))
    assert result == 0, "CreatePseudoConsole: 0x%08x" % (result & 0xFFFFFFFF)
    kernel32.CloseHandle(in_read)
    kernel32.CloseHandle(out_write)
    size = ctypes.c_size_t()
    kernel32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
    attributes = ctypes.create_string_buffer(size.value)
    assert kernel32.InitializeProcThreadAttributeList(attributes, 1, 0, ctypes.byref(size))
    # PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE takes the handle itself as the value.
    assert kernel32.UpdateProcThreadAttribute(attributes, 0, 0x20016, console, ctypes.sizeof(ctypes.c_void_p),
                                              None, None)
    startup = StartupInfoEx()
    startup.StartupInfo.cb = ctypes.sizeof(StartupInfoEx)
    startup.lpAttributeList = ctypes.addressof(attributes)
    info = ProcessInformation()
    block = "".join("%s=%s\0" % item for item in env.items()) + "\0"
    environment = ctypes.create_string_buffer(block.encode("utf-16-le"))
    line = ctypes.create_unicode_buffer(subprocess.list2cmdline([str(word) for word in command]))
    extended_startup_info_present, unicode_environment = 0x00080000, 0x00000400
    created = kernel32.CreateProcessW(None, line, None, None, False,
                                      extended_startup_info_present | unicode_environment, environment, None,
                                      ctypes.byref(startup), ctypes.byref(info))
    assert created, ctypes.WinError(ctypes.get_last_error())
    chunks = []

    def drain():
        buffer = ctypes.create_string_buffer(65536)
        got = wintypes.DWORD()
        while kernel32.ReadFile(out_read, buffer, len(buffer), ctypes.byref(got), None) and got.value:
            chunks.append(buffer.raw[:got.value])

    reader = threading.Thread(target=drain, daemon=True)
    reader.start()
    if kernel32.WaitForSingleObject(info.hProcess, int(limit * 1000)) != 0:
        kernel32.TerminateProcess(info.hProcess, 1)
    code = wintypes.DWORD()
    kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(code))
    kernel32.ClosePseudoConsole(console)
    reader.join(WAIT_SECONDS)
    for handle in (info.hProcess, info.hThread, in_write, out_read):
        kernel32.CloseHandle(handle)
    return code.value, b"".join(chunks).decode("utf-8", errors="replace")


def test_ctrl_break_takes_the_exit_path_the_child_dies_buffered_file_data_is_written_and_the_exit_is_149(
    tmp_path, adopt
):
    path = tmp_path / "out.txt"
    vm = adopt(start_vm(bytecode(CHILD_PROGRAM, tmp_path), path, PYTHON, CHILD, flags=["--allow-run"],
                        creationflags=NEW_GROUP))
    pid = int(vm.next_line(WAIT_SECONDS))
    vm.process.send_signal(signal.CTRL_BREAK_EVENT)
    assert vm.wait(WAIT_SECONDS) == 128 + SIGBREAK
    assert path.read_text() == "buffered"
    assert wait_until(lambda: not alive(pid), WAIT_SECONDS, 0.1), "the child is gone"


def test_ctrl_break_with_standard_output_stuck_does_not_wait_for_the_flush_limit(tmp_path, adopt):
    vm = adopt(start_vm(bytecode(STUCK_STDOUT, tmp_path), read_stdout=False, creationflags=NEW_GROUP))
    assert vm.next_stderr_line(WAIT_SECONDS) == "ready"
    time.sleep(0.3)
    start = time.monotonic()
    vm.process.send_signal(signal.CTRL_BREAK_EVENT)
    assert vm.wait(WAIT_SECONDS) == 128 + SIGBREAK
    assert time.monotonic() - start < min(scaled(5), 25), "the run does not wait for the reader"


def test_standard_output_and_standard_error_on_a_console_arrive_in_order_as_text(tmp_path):
    code, shown = run_on_console([*vm_command(), "--", bytecode(CONSOLE_PROGRAM, tmp_path)], vm_environment(),
                                 WAIT_SECONDS)
    text = ESCAPES.sub("", shown)
    assert code == 0, text
    markers = ["tty line é", "tty error ü", "tty end"]
    positions = [text.find(marker) for marker in markers]
    assert -1 not in positions and positions == sorted(positions), text
