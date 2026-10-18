"""Shared helpers for tests that write Agentica modules to a workspace."""

from collections.abc import Mapping
from pathlib import Path
from typing import Protocol


class TemporaryWorkspace(Protocol):
    def make_temp_dir(self, prefix: str = "agentica-") -> Path: ...


def write_module_files(
    test_case: TemporaryWorkspace, files: Mapping[str, str]
) -> Path:
    """Write a mapping of relative module paths to a fresh temporary folder."""
    directory = test_case.make_temp_dir("agentica-modules-").resolve()
    for name, text in files.items():
        path = directory / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding="utf-8")
    return directory
