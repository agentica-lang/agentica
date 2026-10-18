"""The logger on the VM."""
import json
import re

import pytest

from tests.agentica_test import FIXTURES, PYTHON, compile_agc, run, run_vm, vm_environment


@pytest.fixture
def bytecode_of(tmp_path):
    def compile_fixture(name):
        return compile_agc(FIXTURES / (name + ".agc"), tmp_path / (name + ".agcb"))

    return compile_fixture


def test_default_run_prints_one_info_line_on_stderr(bytecode_of):
    result = run_vm(bytecode_of("logger-default"), env=vm_environment())
    assert result.code == 0
    assert result.stdout == ""
    assert re.fullmatch(
        r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z INFO hello\n", result.stderr
    )


def test_async_handler_leaves_every_event_in_the_file_in_order(bytecode_of, tmp_path):
    result = run_vm(bytecode_of("logger-async"), cwd=tmp_path, env=vm_environment())
    assert result.code == 0
    assert result.stdout == ""
    lines = (tmp_path / "app.log").read_text().splitlines()
    assert len(lines) == 3
    events = [json.loads(line) for line in lines]
    assert [event["msg"] for event in events] == [
        "server started", "request done", "cannot open the cache"
    ]
    assert [event["level"] for event in events] == ["info", "info", "error"]
    assert events[1]["fields"] == {"path": "/items", "status": "200"}


def test_python_peer_decodes_json_lines_and_checks_time_text(bytecode_of, tmp_path):
    """The peer checks time_text against datetime."""
    peer = FIXTURES / "logger-peer.py"
    made = run([PYTHON, peer, "vectors", tmp_path])
    assert made.code == 0, made.stderr
    result = run_vm(
        bytecode_of("logger-peer"), stdin=(tmp_path / "ms.txt").read_bytes(), env=vm_environment()
    )
    assert result.code == 0, result.stderr
    (tmp_path / "stdout.txt").write_text(result.stdout, encoding="utf-8")
    (tmp_path / "stderr.txt").write_text(result.stderr, encoding="utf-8")
    checked = run([PYTHON, peer, "check", tmp_path])
    assert (checked.code, checked.stdout.strip()) == (0, "ok"), checked.stderr
