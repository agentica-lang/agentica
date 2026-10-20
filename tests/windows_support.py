"""Shared low-level helpers for Windows filesystem tests."""

from __future__ import annotations

import csv
import ctypes
import os
import subprocess
import uuid
from collections.abc import Callable
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from tests.agentica_test import Result, TestCase, run_vm, start_vm, vm_environment


def kernel32_file_api() -> Any:
    """Return kernel32 with correctly typed CreateFileW and CloseHandle calls."""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.CreateFileW.argtypes = [
        ctypes.c_wchar_p,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
        ctypes.c_uint32,
        ctypes.c_uint32,
        ctypes.c_void_p,
    ]
    kernel32.CreateFileW.restype = ctypes.c_void_p
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int
    return kernel32


def assert_rename_race(
    test_case: TestCase,
    bytecode: str | Path,
    root: Path,
    source_name: Callable[[int], str],
) -> None:
    """Assert concurrent renames have one winner and preserve each losing source."""
    target = root / "target"
    sources = []
    for number in range(6):
        source = root / source_name(number)
        source.write_text(str(number))
        sources.append(source)
    racers = [test_case.adopt(start_vm(bytecode, str(source), str(target), cwd=root)) for source in sources]
    answers = [racer.next_line() for racer in racers]
    for racer in racers:
        test_case.assertEqual(racer.wait(), 0)
    test_case.assertEqual(sorted(answers), ["false"] * 5 + ["true"])
    winner = answers.index("true")
    test_case.assertEqual(target.read_text(), str(winner))
    test_case.assertFalse(sources[winner].exists())
    for number, source in enumerate(sources):
        test_case.assertEqual(source.exists(), number != winner)


def run_vm_with_stdout(
    test_case: TestCase,
    bytecode: str | Path,
    arguments: list[str],
    root: Path,
    expected_stdout: str,
) -> Result:
    """Run one VM program in `root` and assert its successful stdout."""
    result = run_vm(bytecode, args=arguments, env=vm_environment(), cwd=root)
    test_case.assertEqual((result.code, result.stdout), (0, expected_stdout))
    return result


PROCESS_QUERY_LIMITED_INFORMATION = 0x1000


def process_handle_count(pid: int) -> int:
    """The number of kernel handles that the process `pid` holds open (GetProcessHandleCount), the Windows counterpart
    of counting the entries of /proc/self/fd."""
    kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel32.OpenProcess.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_uint32]
    kernel32.OpenProcess.restype = ctypes.c_void_p
    kernel32.GetProcessHandleCount.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint32)]
    kernel32.GetProcessHandleCount.restype = ctypes.c_int
    kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel32.CloseHandle.restype = ctypes.c_int
    process = kernel32.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid)
    if not process:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        count = ctypes.c_uint32()
        if not kernel32.GetProcessHandleCount(process, ctypes.byref(count)):
            raise ctypes.WinError(ctypes.get_last_error())
        return count.value
    finally:
        kernel32.CloseHandle(process)


ERROR_NO_DATA = 232
ERROR_PIPE_CONNECTED = 535
ERROR_PIPE_LISTENING = 536
PIPE_ACCESS_DUPLEX = 3
PIPE_NOWAIT = 1
PIPE_ROOT = "\\\\.\\pipe\\"


class NamedPipeServer:
    r"""A named pipe that the test makes, with a few instances, for a program that tries to open it by a path.

    Windows has no FIFO file: a pipe is a server handle that a peer makes, and a client opens it by a name below
    \\.\pipe\. Each instance is in no-wait mode, so clients() can ask at any time, without blocking, which instances
    a client came to and whether it still holds them. A call that first stats the path takes one instance for the
    stat, so the pipe has more instances than one, and the open that follows can reach the instance of its own.
    Use it as a context manager; the name is unique to the test.
    """

    def __init__(self, instances: int = 4) -> None:
        self.name = "agentica-test-%d-%s" % (os.getpid(), uuid.uuid4().hex)
        self._kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        self._kernel32.CreateNamedPipeW.argtypes = [ctypes.c_wchar_p] + [ctypes.c_uint32] * 6 + [ctypes.c_void_p]
        self._kernel32.CreateNamedPipeW.restype = ctypes.c_void_p
        self._kernel32.ConnectNamedPipe.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        self._kernel32.ConnectNamedPipe.restype = ctypes.c_int
        self._kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        self._kernel32.CloseHandle.restype = ctypes.c_int
        self._handles: list[int] = []
        try:
            for _ in range(instances):
                handle = self._kernel32.CreateNamedPipeW(self.path(), PIPE_ACCESS_DUPLEX, PIPE_NOWAIT, instances,
                                                         65536, 65536, 0, None)
                if handle is None or handle == ctypes.c_void_p(-1).value:
                    raise ctypes.WinError(ctypes.get_last_error())
                self._handles.append(handle)
        except OSError:
            self.close()
            raise

    def path(self, root: str = PIPE_ROOT) -> str:
        r"""The name of the pipe below `root`, a spelling of the pipe folder (\\localhost\pipe\ is another)."""
        return root + self.name

    def clients(self) -> list[str]:
        """For each instance: "waiting" (no client came), "connected" (a client holds it) or "gone" (one came and left)."""
        states = {ERROR_PIPE_LISTENING: "waiting", ERROR_PIPE_CONNECTED: "connected", ERROR_NO_DATA: "gone"}
        found = []
        for handle in self._handles:
            if self._kernel32.ConnectNamedPipe(handle, None):
                found.append("connected")
                continue
            error = ctypes.get_last_error()
            if error not in states:
                raise ctypes.WinError(error)
            found.append(states[error])
        return found

    def close(self) -> None:
        while self._handles:
            self._kernel32.CloseHandle(self._handles.pop())

    def __enter__(self) -> "NamedPipeServer":
        return self

    def __exit__(self, *problem: object) -> None:
        self.close()


def current_user_sid() -> str:
    """The security identifier of the user that runs the tests, as `S-1-5-21-...`."""
    identity = subprocess.run(["whoami.exe", "/user", "/fo", "csv", "/nh"], capture_output=True, text=True,
                              errors="replace", check=False, timeout=60)
    assert identity.returncode == 0, identity.stderr
    sid = next(csv.reader(identity.stdout.splitlines()))[1]
    assert sid.startswith("S-1-"), sid
    return sid


def icacls(path: str | Path, *arguments: str) -> None:
    """Change the access list of `path` with icacls.exe; the call must succeed."""
    changed = subprocess.run(["icacls.exe", str(path), *arguments], capture_output=True, text=True,
                             errors="replace", check=False, timeout=60)
    assert changed.returncode == 0, changed.stdout + changed.stderr


def processes_mentioning(text: str | Path) -> list[int]:
    """The ids of the processes whose command line contains `text` (without regard to case or the direction of the
    slashes), the Windows counterpart of reading /proc/<pid>/cmdline."""
    system = Path(os.environ["SystemRoot"]) / "System32"
    listing = subprocess.run(
        [str(system / "WindowsPowerShell" / "v1.0" / "powershell.exe"), "-NoProfile", "-NonInteractive", "-Command",
         "[Console]::OutputEncoding = [Text.Encoding]::UTF8; "
         "Get-CimInstance Win32_Process | ForEach-Object { '{0}|{1}' -f $_.ProcessId, $_.CommandLine }"],
        capture_output=True, check=False, timeout=60)
    assert listing.returncode == 0, listing.stderr.decode(errors="replace")

    def plain(value: str) -> str:
        return value.lower().replace("/", "\\")

    needle = plain(str(text))
    found = []
    for line in listing.stdout.decode("utf-8", errors="replace").splitlines():
        number, _, command = line.partition("|")
        if number.strip().isdigit() and needle in plain(command):
            found.append(int(number))
    return found


@contextmanager
def without_backup_restore_privileges():
    """Prevent the runner's restore privilege from bypassing ACLs in children."""
    from ctypes import wintypes

    class Luid(ctypes.Structure):
        _fields_ = [("low", wintypes.DWORD), ("high", wintypes.LONG)]

    class Privileges(ctypes.Structure):
        _fields_ = [("count", wintypes.DWORD), ("luid", Luid), ("attributes", wintypes.DWORD)]

    kernel32 = kernel32_file_api()
    kernel32.GetCurrentProcess.restype = wintypes.HANDLE
    advapi32 = ctypes.WinDLL("advapi32", use_last_error=True)
    advapi32.OpenProcessToken.argtypes = [wintypes.HANDLE, wintypes.DWORD, ctypes.POINTER(wintypes.HANDLE)]
    advapi32.LookupPrivilegeValueW.argtypes = [wintypes.LPCWSTR, wintypes.LPCWSTR, ctypes.POINTER(Luid)]
    advapi32.AdjustTokenPrivileges.argtypes = [
        wintypes.HANDLE, wintypes.BOOL, ctypes.POINTER(Privileges), wintypes.DWORD,
        ctypes.POINTER(Privileges), ctypes.POINTER(wintypes.DWORD),
    ]
    token = wintypes.HANDLE()
    assert advapi32.OpenProcessToken(kernel32.GetCurrentProcess(), 0x28, ctypes.byref(token))
    previous = []
    try:
        for name in ("SeBackupPrivilege", "SeRestorePrivilege"):
            requested = Privileges(count=1)
            assert advapi32.LookupPrivilegeValueW(None, name, ctypes.byref(requested.luid))
            old = Privileges()
            size = wintypes.DWORD()
            assert advapi32.AdjustTokenPrivileges(
                token, False, ctypes.byref(requested), ctypes.sizeof(old),
                ctypes.byref(old), ctypes.byref(size),
            )
            previous.append(old)
        yield
    finally:
        for old in reversed(previous):
            assert advapi32.AdjustTokenPrivileges(token, False, ctypes.byref(old), 0, None, None)
        kernel32.CloseHandle(token)
