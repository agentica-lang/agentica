"""Shared fixtures for CLI-backed language tests."""

import json
import os
from collections.abc import Callable, Mapping
from pathlib import Path

import pytest

from tests.agentica_test import cli, run


def pytest_collection_modifyitems(items):
    """Keep plain pytest functions in the same fast/slow tier as TestCase methods."""
    slow_run = os.environ.get("AGENTICA_TEST_SLOW", "") not in ("", "0")
    for item in items:
        if getattr(item, "cls", None) is not None:
            continue
        is_slow = item.get_closest_marker("slow") is not None
        if is_slow != slow_run:
            item.add_marker(pytest.mark.skip(reason="not selected in this test tier"))


@pytest.fixture
def agentica_check(tmp_path: Path) -> Callable[..., dict[str, object] | None]:
    """Write one or more programs under ``tmp_path`` and check the root file."""
    def check(
        source: str | Mapping[str, str], name: str = "main.agc"
    ) -> dict[str, object] | None:
        files = {name: source} if isinstance(source, str) else source
        for filename, text in files.items():
            path = tmp_path / filename
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        root = tmp_path / name
        result = run(cli() + ["--json", "check", str(root)])
        if result.code == 0:
            return None
        assert result.code == 1, result.stderr
        return json.loads(result.stderr)

    return check
