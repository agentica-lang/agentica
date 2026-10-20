"""A Windows pseudo console (ConPTY) as the console of a command, for tests that need a console.

A console is where Ctrl+C and Ctrl+Break go: a command started with run_on_console has a console of its own, so a
test can type into it (Ctrl+C is the character 3) without signalling the console that runs pytest. The module imports
on every system and works on native Windows only.
"""
import ctypes
import os
import re
import subprocess
import threading

from tests.agentica_test import scaled

WAIT_SECONDS = scaled(20)

# A child that ignores Ctrl+Break and Ctrl+C, so only the VM can stop it. It prints its pid, and writes it to the file
# that its first argument names, when it has one.
CHILD = ("import os, signal, sys, time; signal.signal(signal.SIGBREAK, signal.SIG_IGN); "
         "signal.signal(signal.SIGINT, signal.SIG_IGN); "
         "len(sys.argv) > 1 and open(sys.argv[1], 'w').write(str(os.getpid())); "
         "print(os.getpid(), flush=True); time.sleep(60)")

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
    kernel32.DeleteProcThreadAttributeList.argtypes = [ctypes.c_void_p]
    kernel32.DeleteProcThreadAttributeList.restype = None
    kernel32.InitializeProcThreadAttributeList.argtypes = [ctypes.c_void_p, wintypes.DWORD, wintypes.DWORD,
                                                           ctypes.POINTER(ctypes.c_size_t)]
    kernel32.UpdateProcThreadAttribute.argtypes = [ctypes.c_void_p, wintypes.DWORD, ctypes.c_size_t, ctypes.c_void_p,
                                                   ctypes.c_size_t, ctypes.c_void_p, ctypes.c_void_p]
    kernel32.CreateProcessW.argtypes = [wintypes.LPCWSTR, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p,
                                        wintypes.BOOL, wintypes.DWORD, ctypes.c_void_p, wintypes.LPCWSTR,
                                        ctypes.POINTER(StartupInfoEx), ctypes.POINTER(ProcessInformation)]
    kernel32.ReadFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                                  ctypes.c_void_p]
    kernel32.WriteFile.argtypes = [wintypes.HANDLE, ctypes.c_void_p, wintypes.DWORD, ctypes.POINTER(wintypes.DWORD),
                                   ctypes.c_void_p]
    kernel32.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel32.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
    kernel32.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    kernel32.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel32.OpenProcess.restype = wintypes.HANDLE
    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.SetConsoleCtrlHandler.argtypes = [ctypes.c_void_p, wintypes.BOOL]
else:
    kernel32 = None  # imported by name on every system; only the Windows tests use it


def close_handle(handle):
    """Closes a handle that is set and marks it closed, so a second call does nothing."""
    if handle.value:
        kernel32.CloseHandle(handle)
        handle.value = None


def run_on_console(command, env, limit, typed=None, during=None):
    """Runs the command with a pseudo console as its console, standard input and standard output.

    `typed` is text typed into the console after the start (a line ends with a carriage return, the Enter key).
    `during(type_text)` runs after the start, while the command runs: it waits for what the test needs (a file the
    command writes) and types, with type_text, what the test wants the console to receive. The character 3 is
    Ctrl+C: the console turns it into a CTRL_C_EVENT for every process attached to it, as the keys do on a terminal.
    Returns (exit code, the text the console showed). The pseudo console is closed after the exit, while a thread
    reads its output, because closing it waits for the output to be taken. Whatever step fails, the handles, the
    pseudo console, the attribute list and the process are released.
    """
    in_read, in_write, out_read, out_write = (wintypes.HANDLE() for _ in range(4))
    console = ctypes.c_void_p()
    info = ProcessInformation()
    attributes = None
    reader = None
    chunks = []

    def drain():
        buffer = ctypes.create_string_buffer(65536)
        got = wintypes.DWORD()
        while kernel32.ReadFile(out_read, buffer, len(buffer), ctypes.byref(got), None) and got.value:
            chunks.append(buffer.raw[:got.value])

    try:
        assert kernel32.CreatePipe(ctypes.byref(in_read), ctypes.byref(in_write), None, 0)
        assert kernel32.CreatePipe(ctypes.byref(out_read), ctypes.byref(out_write), None, 0)
        result = kernel32.CreatePseudoConsole(Coord(100, 30), in_read, out_write, 0, ctypes.byref(console))
        assert result == 0, "CreatePseudoConsole: 0x%08x" % (result & 0xFFFFFFFF)
        close_handle(in_read)
        close_handle(out_write)
        # The reader starts before anything can fail, since closing the pseudo console waits for its output to be read.
        reader = threading.Thread(target=drain, daemon=True)
        reader.start()
        size = ctypes.c_size_t()
        kernel32.InitializeProcThreadAttributeList(None, 1, 0, ctypes.byref(size))
        attributes = ctypes.create_string_buffer(size.value)
        assert kernel32.InitializeProcThreadAttributeList(attributes, 1, 0, ctypes.byref(size))
        # PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE takes the handle itself as the value.
        assert kernel32.UpdateProcThreadAttribute(attributes, 0, 0x20016, console, ctypes.sizeof(ctypes.c_void_p),
                                                  None, None)
        startup = StartupInfoEx()
        startup.StartupInfo.cb = ctypes.sizeof(StartupInfoEx)
        # With no standard handles named, a child of a parent whose own are redirected (a test run) gets those; asking
        # for STARTF_USESTDHANDLES with null handles leaves it the console.
        startup.StartupInfo.dwFlags = 0x00000100
        startup.lpAttributeList = ctypes.addressof(attributes)
        block = "".join("%s=%s\0" % item for item in env.items()) + "\0"
        environment = ctypes.create_string_buffer(block.encode("utf-16-le"))
        line = ctypes.create_unicode_buffer(subprocess.list2cmdline([str(word) for word in command]))
        extended_startup_info_present, unicode_environment = 0x00080000, 0x00000400
        # A process inherits the "ignore Ctrl+C" state of its parent, which a test run started from a new process group
        # (a service, a job runner) has set. The command is to take Ctrl+C like a program in a terminal does.
        assert kernel32.SetConsoleCtrlHandler(None, False)
        created = kernel32.CreateProcessW(None, line, None, None, False,
                                          extended_startup_info_present | unicode_environment, environment, None,
                                          ctypes.byref(startup), ctypes.byref(info))
        assert created, ctypes.WinError(ctypes.get_last_error())

        def type_text(text):
            data = text.encode("utf-8")
            written = wintypes.DWORD()
            assert kernel32.WriteFile(in_write, data, len(data), ctypes.byref(written), None)

        if typed:
            type_text(typed)
        if during:
            during(type_text)
        if kernel32.WaitForSingleObject(info.hProcess, int(limit * 1000)) != 0:
            kernel32.TerminateProcess(info.hProcess, 1)
        code = wintypes.DWORD()
        kernel32.GetExitCodeProcess(info.hProcess, ctypes.byref(code))
        kernel32.ClosePseudoConsole(console)
        console = ctypes.c_void_p()
        reader.join(WAIT_SECONDS)
        assert not reader.is_alive(), "the output of the pseudo console was read to its end"
        return code.value, b"".join(chunks).decode("utf-8", errors="replace")
    finally:
        if info.hProcess and kernel32.WaitForSingleObject(info.hProcess, 0) == 0x102:
            kernel32.TerminateProcess(info.hProcess, 1)
        if console.value:
            kernel32.ClosePseudoConsole(console)
        if reader is not None:
            reader.join(WAIT_SECONDS)
        if attributes is not None:
            kernel32.DeleteProcThreadAttributeList(attributes)
        for handle in (wintypes.HANDLE(info.hProcess), wintypes.HANDLE(info.hThread), in_read, out_write, in_write):
            close_handle(handle)
        # The reader may still be inside ReadFile if it did not end: its handle stays open then, as the test fails.
        if reader is None or not reader.is_alive():
            close_handle(out_read)
