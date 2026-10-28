"""File.sha256 against Python's hashlib, on every system.

The peer hashes the whole file at its argument with File.sha256; the inputs
cover the SHA-256 padding boundaries (55, 56 and 64 bytes), the 64 KiB chunk
boundary, several blocks and files over the 1 MiB whole-text limit (written by
Python in chunks, so no Agentica list ever holds the content). The other cases
check the filesystem taxonomy (missing, directory, FIFO, device), the argument
checks, --deny-fs, and that a cancelled or ended task behaves like any other
pool job. No timeout-latency case: a pool job that has started runs to its end
(like File.read_text), so only the argument check is deterministic.
"""
import hashlib
import json
import os
import random
import sys

import pytest

from tests.agentica_test import WINDOWS, cli, compile_agc, run, run_vm, vm_environment

SIZES = [0, 1, 3, 55, 56, 63, 64, 65, 119, 120, 128, 1000, 4096 + 7, 65535, 65536, 65537, 1024 * 1024,
         2 * 1024 * 1024 + 13]

PEER = (
    "def main() -> Void\n"
    "  puts(File.sha256(System.args()[0], 30000).unwrap!)\n"
    "end\n"
)

HEXER = (
    "def hex(digest: List[Int]) -> String\n"
    '  digits = "0123456789abcdef"\n'
    "  return digest.map do |b| digits.at(b / 16) + digits.at(b % 16) end.join(\"\")\n"
    "end\n"
)


def hex_of(data):
    return hashlib.sha256(data).hexdigest()


@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    source = tmp_path_factory.mktemp("file-sha256") / "peer.agc"
    source.write_text(PEER, encoding="utf-8")
    return compile_agc(source, source.with_suffix(".agcb"))


def write_data(directory, name, data):
    path = directory / name
    path.write_bytes(data)
    return path


def check_matches_hashlib(peer, tmp_path, name, data):
    """Hash data written to name with the peer and compare with hashlib."""
    target = write_data(tmp_path, name, data)
    result = run_vm(peer, args=[str(target)])
    assert result.code == 0, result.stderr
    assert json.loads(result.stdout) == list(hashlib.sha256(data).digest())
    return result


@pytest.mark.parametrize("size", SIZES)
def test_sha256_matches_hashlib(peer, tmp_path, size):
    # Every byte value appears in the larger inputs; the seed keeps a failure reproducible.
    check_matches_hashlib(peer, tmp_path, "input-%d.bin" % size, random.Random(size).randbytes(size))


def test_sha256_matches_digest_sha256_on_the_same_bytes(tmp_path):
    data = random.Random(1234).randbytes(999)
    target = write_data(tmp_path, "same.bin", data)
    source = tmp_path / "same.agc"
    source.write_text(
        HEXER + "\n"
        "def main() -> Void\n"
        "  from_fs = hex(File.sha256(System.args()[0], 30000).unwrap!)\n"
        '  handle = File.open(System.args()[0], "read", 30000).unwrap!\n'
        "  bytes = File.read_bytes(handle, 1048576, 30000).unwrap!\n"
        "  File.close(handle, 30000)\n"
        "  puts(from_fs == hex(Digest.sha256(bytes)))\n"
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(source), str(target)], env=vm_environment())
    assert (result.code, result.stdout) == (0, "true\n"), result.stderr


def test_sha256_accepts_spaces_and_symlinks(peer, tmp_path):
    name = "with spaces.bin"
    data = random.Random(77).randbytes(100000)
    result = check_matches_hashlib(peer, tmp_path, name, data)
    target = tmp_path / name
    if sys.platform == "win32":
        pytest.skip("host-only: a symbolic link needs a privilege on Windows")
    linked = tmp_path / "linked.bin"
    os.symlink(target, linked)
    again = run_vm(peer, args=[str(linked)])
    assert again.code == 0, again.stderr
    assert again.stdout == result.stdout


@pytest.mark.parametrize("name", ["missing.bin", "a-directory"])
def test_sha256_refuses_what_is_not_a_regular_file(peer, tmp_path, name):
    target = tmp_path / name
    if name == "a-directory":
        target.mkdir()
    result = run_vm(peer, args=[str(target)])
    assert result.code == 1, result.stdout
    assert 'filesystem: path does not refer to a regular file' in result.stderr, result.stderr


@pytest.mark.skipif(sys.platform == "win32", reason="host-only: Windows has no FIFO files and no /dev/null")
def test_sha256_refuses_a_fifo_and_a_device_without_waiting(peer, tmp_path):
    fifo = tmp_path / "waiting"
    os.mkfifo(fifo)
    refused = run_vm(peer, args=[str(fifo)])
    assert refused.code == 1, refused.stdout
    assert 'filesystem: path does not refer to a regular file' in refused.stderr, refused.stderr
    device = run_vm(peer, args=["/dev/null"])
    assert device.code == 1, device.stdout
    assert 'filesystem: path does not refer to a regular file' in device.stderr, device.stderr


@pytest.mark.parametrize("timeout", ["0", "-5"])
def test_sha256_rejects_a_timeout_that_is_not_positive(tmp_path, timeout):
    source = tmp_path / "timeout.agc"
    source.write_text(
        "def main() -> Void\n"
        '  puts(File.sha256("x.bin", %s))\n'
        "end\n" % timeout,
        encoding="utf-8",
    )
    result = run(cli() + [str(source)], env=vm_environment())
    assert (result.code, result.stdout) == (
        0, 'error("filesystem: timeout must be positive milliseconds")\n'), result.stderr


def test_sha256_rejects_an_empty_path(tmp_path):
    source = tmp_path / "empty-path.agc"
    source.write_text(
        "def main() -> Void\n"
        '  puts(File.sha256("", 30000))\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(source)], env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error(\"path->complete-path: contract violation"), result.stdout


def test_sha256_reports_denied_fs(tmp_path):
    data = random.Random(9).randbytes(10)
    target = write_data(tmp_path, "denied.bin", data)
    source = tmp_path / "denied.agc"
    source.write_text(PEER, encoding="utf-8")
    result = run(cli() + ["--deny-fs", str(source), str(target)], env=vm_environment())
    assert result.code == 1, result.stdout
    assert "denied: --deny-fs turns off file access" in result.stderr, result.stderr


def test_sha256_runs_beside_other_tasks_and_each_hash_is_right(tmp_path):
    first = write_data(tmp_path, "first.bin", random.Random(1).randbytes(70000))
    second = write_data(tmp_path, "second.bin", random.Random(2).randbytes(140000))
    source = tmp_path / "fair.agc"
    source.write_text(
        HEXER + "\n"
        "def hash_it(path: String) -> String\n"
        "  return hex(File.sha256(path, 30000).unwrap!)\n"
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  a = Task.spawn(&hash_it, System.args()[0])\n"
        "  b = Task.spawn(&hash_it, System.args()[1])\n"
        "  puts(Task.await(a))\n"
        "  puts(Task.await(b))\n"
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(source), str(first), str(second)], env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [hex_of(first.read_bytes()), hex_of(second.read_bytes())]


def test_sha256_of_a_task_that_ends_is_dropped_like_any_pool_job(tmp_path):
    target = write_data(tmp_path, "ended.bin", random.Random(3).randbytes(1000))
    source = tmp_path / "ended.agc"
    source.write_text(
        "def hash_it(path: String) -> String\n"
        "  return File.sha256(path, 30000).unwrap!.size.to_s\n"
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  Task.spawn(&hash_it, System.args()[0])\n"
        '  puts("spawned")\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(source), str(target)], env=vm_environment())
    assert (result.code, result.stdout) == (0, "spawned\n"), result.stderr


def test_sha256_of_a_task_cancelled_before_it_runs_is_cancelled(tmp_path):
    target = write_data(tmp_path, "cancelled.bin", random.Random(4).randbytes(1000))
    source = tmp_path / "cancelled.agc"
    source.write_text(
        "def hash_it(path: String) -> Result[String]\n"
        "  return ok(File.sha256(path, 30000).unwrap!.size.to_s)\n"
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  t = Task.spawn(&hash_it, System.args()[0])\n"
        "  Task.cancel(t)\n"
        "  puts(Task.await(t))\n"
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(source), str(target)], env=vm_environment())
    assert (result.code, result.stdout) == (0, 'error("task: cancelled")\n'), result.stderr
