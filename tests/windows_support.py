"""Shared low-level helpers for Windows filesystem tests."""

from __future__ import annotations

import ctypes
from collections.abc import Callable
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
