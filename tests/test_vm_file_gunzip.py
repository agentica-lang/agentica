"""File.gunzip against Python's stdlib gzip, on every system.

The peer decompresses the file at its argument with File.gunzip; the inputs
cover the chunk boundaries (empty, NUL bytes, invalid UTF-8, near and over
64 KiB, multi-MiB), gzip levels 1/6/9 and the optional headers (FNAME,
FCOMMENT, FHCRC, FEXTRA), and the refusals (bad magic, reserved flags,
truncation, corrupt payload, CRC and ISIZE, concatenated members, trailing
zeros and junk, a zlib wrapper and raw deflate). The caps (a zero, negative
or over-1 GiB max, the exact bound, a zero bomb cut at the cap) and the
filesystem taxonomy (missing, directory, FIFO, device, existing or
missing-parent destination, source and destination the same file, a symlink
at either end) run beside them, plus --deny-fs and the task fairness,
end and cancel cases. No timeout-latency case: a pool job that has started
runs to its end (like File.read_text), so only the argument check is
deterministic. The 256 MiB compressed-input bound is a slow test that
streams a stored-block member past it; the fast tier never builds it.
"""
import gzip
import hashlib
import json
import os
import struct
import sys
import zlib

import pytest

from tests.agentica_test import WINDOWS, cli, compile_agc, run, run_vm, vm_environment

PEER = (
    "def main() -> Void\n"
    '  puts(File.gunzip(System.args()[0], System.args()[1], 1073741824, 30000).unwrap!)\n'
    "end\n"
)

@pytest.fixture(scope="module")
def peer(tmp_path_factory):
    source = tmp_path_factory.mktemp("file-gunzip") / "peer.agc"
    source.write_text(PEER, encoding="utf-8")
    return compile_agc(source, source.with_suffix(".agcb"))


def gunzip_case(source, src, dst, limit):
    """Run File.gunzip on src/dst through argv: paths never enter the generated
    source, so a Windows path (D:\\a\\...) cannot break the lexer."""
    source.write_text(
        "def main() -> Void\n"
        '  puts(File.gunzip(System.args()[0], System.args()[1], %s, 30000))\n'
        "end\n" % (limit,),
        encoding="utf-8",
    )
    return run(cli() + [str(source), str(src), str(dst)], env=vm_environment())


def run_source(tmp_path, name, body, args):
    """Write body as name, run it with args through the product CLI."""
    source = tmp_path / name
    source.write_text(body, encoding="utf-8")
    return run(cli() + [str(source)] + [str(a) for a in args], env=vm_environment())


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def check_round_trip(peer, tmp_path, name, data, **kwargs):
    """Gzip data with the stdlib, gunzip it with the peer, compare bytes."""
    target = tmp_path / name
    target.write_bytes(gzip.compress(data, **kwargs))
    out = tmp_path / (name + ".out")
    result = run_vm(peer, args=[str(target), str(out)])
    assert result.code == 0, result.stderr
    assert json.loads(result.stdout) == len(data)
    assert read_bytes(out) == data
    return result


def test_gunzip_round_trip_chunks(peer, tmp_path):
    chunks = {
        "empty.bin": b"",
        "abc.bin": b"abc",
        "nul.bin": b"\x00\x00a\x00",
        "not-utf8.bin": b"\xff\xfe\x00bad\x80utf8",
        "near-64k.bin": bytes((k * 7) % 251 for k in range(65535)),
        "at-64k.bin": bytes((k * 7) % 251 for k in range(65536)),
        "over-64k.bin": bytes((k * 7) % 251 for k in range(65537)),
        "multi.bin": bytes((k * 7) % 251 for k in range(2 * 1048576 + 13)),
    }
    for name, data in chunks.items():
        check_round_trip(peer, tmp_path, name, data)


def test_gunzip_agrees_with_hashlib_on_multi_mib(peer, tmp_path):
    data = bytes((k * 13 + 5) % 251 for k in range(3 * 1048576 + 11))
    check_round_trip(peer, tmp_path, "hashy.bin", data)
    assert hashlib.sha256(read_bytes(tmp_path / "hashy.bin.out")).hexdigest() == hashlib.sha256(data).hexdigest()


@pytest.mark.parametrize("level", [1, 6, 9])
def test_gunzip_reads_every_compression_level(peer, tmp_path, level):
    check_round_trip(peer, tmp_path, "level-%d.bin" % level, bytes((k * 3) % 251 for k in range(300000)),
                      compresslevel=level, mtime=12345)


def test_gunzip_reads_optional_headers(peer, tmp_path):
    raw = bytes((k * 3) % 251 for k in range(100000))
    target = tmp_path / "named.bin"
    target.write_bytes(gzip.compress(raw, mtime=999))
    out = tmp_path / "named.bin.out"
    result = run_vm(peer, args=[str(target), str(out)])
    assert result.code == 0, result.stderr
    assert read_bytes(out) == raw
    fextra = b"AB" + struct.pack("<H", 2) + b"xy"
    head = b"\x1f\x8b\x08\x1e\x39\x30\x00\x00\x02\xff" + struct.pack("<H", len(fextra)) + fextra
    head += b"myname.txt\x00" + b"a comment here\x00"
    head += struct.pack("<H", zlib.crc32(head) & 0xFFFF)
    payload = b"optheaders!" * 1000
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = comp.compress(payload) + comp.flush()
    framed = head + body + struct.pack("<I", zlib.crc32(payload) & 0xFFFFFFFF) + struct.pack("<I", len(payload))
    manual = tmp_path / "manual.gz"
    manual.write_bytes(framed)
    manual_out = tmp_path / "manual.gz.out"
    again = run_vm(peer, args=[str(manual), str(manual_out)])
    assert again.code == 0, again.stderr
    assert json.loads(again.stdout) == len(payload)
    assert read_bytes(manual_out) == payload


def test_gunzip_refuses_a_second_member_and_trailing_bytes(peer, tmp_path):
    first = gzip.compress(b"hi")
    both = first + gzip.compress(b"yo")
    for name, blob in (("concat.gz", both), ("trail-zero.gz", first + b"\x00"),
                       ("trail-junk.gz", first + b"junk trailing")):
        target = tmp_path / name
        target.write_bytes(blob)
        out = tmp_path / (name + ".out")
        result = run_vm(peer, args=[str(target), str(out)])
        assert result.code == 1, result.stdout
        assert "gzip has trailing bytes" in result.stderr, result.stderr


@pytest.mark.parametrize("mutate", ["magic", "method", "flags", "payload", "crc", "isize", "truncated"])
def test_gunzip_refuses_a_broken_member(peer, tmp_path, mutate):
    blob = bytearray(gzip.compress(b"hello world, hello world"))
    if mutate == "magic":
        blob[0] = 0x1E
    elif mutate == "method":
        blob[2] = 0x00
    elif mutate == "flags":
        blob[3] = 0xE0
    elif mutate == "payload":
        blob[len(blob) // 2] ^= 0x01
    elif mutate == "crc":
        blob[-8] ^= 0x01
    elif mutate == "isize":
        blob[-1] ^= 0x01
    elif mutate == "truncated":
        del blob[len(blob) // 2:]
    target = tmp_path / ("%s.gz" % mutate)
    target.write_bytes(bytes(blob))
    out = tmp_path / ("%s.gz.out" % mutate)
    result = run_vm(peer, args=[str(target), str(out)])
    assert result.code == 1, result.stdout
    if mutate in ("crc", "isize", "payload"):
        # A flip inside the deflate payload either breaks framing or decodes
        # to other bytes that the trailer CRC catches; both are errors.
        assert ("gzip checksum mismatch" in result.stderr or "invalid gzip data" in result.stderr), result.stderr
    else:
        assert "invalid gzip data" in result.stderr, result.stderr


def test_gunzip_refuses_a_zlib_wrapper_and_raw_deflate(peer, tmp_path):
    wrapper = tmp_path / "wrapper.gz"
    wrapper.write_bytes(zlib.compress(b"hi"))
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    raw = tmp_path / "raw.deflate"
    raw.write_bytes(comp.compress(b"hi") + comp.flush())
    for target in (wrapper, raw):
        result = run_vm(peer, args=[str(target), str(tmp_path / (target.name + ".out"))])
        assert result.code == 1, result.stdout
        assert "invalid gzip data" in result.stderr, result.stderr


def test_gunzip_refuses_what_is_not_a_regular_file(peer, tmp_path):
    missing = run_vm(peer, args=[str(tmp_path / "missing.gz"), str(tmp_path / "missing.out")])
    assert missing.code == 1, missing.stdout
    assert "path does not refer to a regular file" in missing.stderr, missing.stderr
    is_dir = run_vm(peer, args=[str(tmp_path), str(tmp_path / "dir.out")])
    assert is_dir.code == 1, is_dir.stdout
    assert "path does not refer to a regular file" in is_dir.stderr, is_dir.stderr


@pytest.mark.skipif(sys.platform == "win32", reason="host-only: Windows has no FIFO files and no /dev/null")
def test_gunzip_refuses_a_fifo_and_a_device_without_waiting(peer, tmp_path):
    fifo = tmp_path / "waiting"
    os.mkfifo(fifo)
    refused = run_vm(peer, args=[str(fifo), str(tmp_path / "fifo.out")])
    assert refused.code == 1, refused.stdout
    assert "path does not refer to a regular file" in refused.stderr, refused.stderr
    device = run_vm(peer, args=["/dev/null", str(tmp_path / "null.out")])
    assert device.code == 1, device.stdout
    assert "path does not refer to a regular file" in device.stderr, device.stderr


def test_gunzip_keeps_an_existing_destination_intact(tmp_path):
    src = tmp_path / "src.gz"
    src.write_bytes(gzip.compress(b"fresh"))
    dst = tmp_path / "dst.out"
    dst.write_bytes(b"keepme")
    source = tmp_path / "exists.agc"
    result = gunzip_case(source, src, dst, 100)
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout
    assert "error opening file" in result.stdout, result.stdout
    assert read_bytes(dst) == b"keepme"


def test_gunzip_rejects_itself_missing_parents_and_symlink_targets(tmp_path):
    src = tmp_path / "self.gz"
    src.write_bytes(gzip.compress(b"abc"))
    source = tmp_path / "self.agc"
    assert "error opening file" in gunzip_case(source, src, src, 100).stdout
    assert read_bytes(src) == gzip.compress(b"abc")
    assert "error opening file" in gunzip_case(source, src, tmp_path / "no-dir" / "out", 100).stdout
    assert not (tmp_path / "no-dir").exists()
    if sys.platform == "win32":
        pytest.skip("host-only: a symbolic link needs a privilege on Windows")
    linked = tmp_path / "linked.gz"
    os.symlink(src, linked)
    out = tmp_path / "linked.out"
    source = tmp_path / "link.agc"
    source.write_text(
        "def main() -> Void\n"
        '  puts(File.gunzip(System.args()[0], System.args()[1], 100, 30000))\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(source), str(linked), str(out)], env=vm_environment())
    assert (result.code, result.stdout) == (0, "ok(3)\n"), result.stderr
    assert read_bytes(out) == b"abc"
    dangling = tmp_path / "dangling.out"
    os.symlink(tmp_path / "never.gz", dangling)
    assert "error opening file" in gunzip_case(source, src, dangling, 100).stdout


@pytest.mark.parametrize("limit", ["0", "-5", "1073741825"])
def test_gunzip_rejects_a_max_outside_its_bounds(tmp_path, limit):
    source = tmp_path / "limit.agc"
    source.write_text(
        "def main() -> Void\n"
        '  puts(File.gunzip("x.gz", "x.out", %s, 30000))\n'
        "end\n" % limit,
        encoding="utf-8",
    )
    result = run(cli() + [str(source)], env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout
    assert "max_out_bytes must be between 1 and 1073741824" in result.stdout, result.stdout


def test_gunzip_rejects_a_timeout_that_is_not_positive(tmp_path):
    source = tmp_path / "timeout.agc"
    source.write_text(
        "def main() -> Void\n"
        '  puts(File.gunzip("x.gz", "x.out", 100, 0))\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + [str(source)], env=vm_environment())
    assert (result.code, result.stdout) == (0, 'error("filesystem: timeout must be positive milliseconds")\n')


def test_gunzip_stops_at_an_exact_bound_and_above_it(tmp_path):
    src = tmp_path / "exact.gz"
    src.write_bytes(gzip.compress(b"abc"))
    source = tmp_path / "exact.agc"
    assert gunzip_case(source, src, tmp_path / "exact-3.out", 3).stdout == "ok(3)\n"
    assert read_bytes(tmp_path / "exact-3.out") == b"abc"
    assert "exceeds max_out_bytes" in gunzip_case(source, src, tmp_path / "exact-2.out", 2).stdout
    assert (tmp_path / "exact-2.out").stat().st_size == 0


def test_gunzip_cuts_a_bomb_at_its_cap_and_keeps_the_partial(tmp_path):
    src = tmp_path / "bomb.gz"
    src.write_bytes(gzip.compress(bytes(8 * 1048576)))
    dst = tmp_path / "bomb.out"
    source = tmp_path / "bomb.agc"
    result = gunzip_case(source, src, dst, 1048576)
    assert result.code == 0, result.stderr
    assert "exceeds max_out_bytes" in result.stdout, result.stdout
    size = dst.stat().st_size
    assert 1048576 - 65536 < size <= 1048576, size


@pytest.mark.slow
def test_gunzip_refuses_more_than_256_mib_of_compressed_input(tmp_path):
    """A stored-block member past the fixed input cap, written in 1 MiB
    chunks so the fast tier never builds it."""
    src = tmp_path / "huge.gz"
    total = 268435456 + 1048576
    crc = 0
    with open(src, "wb") as handle:
        handle.write(bytes([0x1F, 0x8B, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0xFF]))
        chunk = os.urandom(32768)
        at = 0
        while at < total:
            take = min(32768, total - at)
            piece = chunk[:take]
            crc = zlib.crc32(piece, crc)
            last = at + take == total
            handle.write(bytes([0x01 if last else 0x00, take & 0xFF, take >> 8,
                                (~take) & 0xFF, (~take >> 8) & 0xFF]))
            handle.write(piece)
            at += take
        handle.write(struct.pack("<I", crc & 0xFFFFFFFF) + struct.pack("<I", total & 0xFFFFFFFF))
    dst = tmp_path / "huge.out"
    source = tmp_path / "huge.agc"
    result = gunzip_case(source, src, dst, 1073741824)
    assert result.code == 0, result.stderr
    assert "compressed input exceeds 268435456 bytes" in result.stdout, result.stdout


def test_gunzip_reports_denied_fs(tmp_path):
    src = tmp_path / "denied.gz"
    src.write_bytes(gzip.compress(b"abc"))
    source = tmp_path / "denied.agc"
    source.write_text(
        "def main() -> Void\n"
        '  puts(File.gunzip(System.args()[0], System.args()[1], 100, 30000))\n'
        "end\n",
        encoding="utf-8",
    )
    result = run(cli() + ["--deny-fs", str(source), str(src), str(tmp_path / "denied.out")],
                   env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stdout == 'error("denied: --deny-fs turns off file access")\n', result.stdout


@pytest.mark.skipif(sys.platform == "win32",
                     reason="host-only: Windows reserves the backslash as a separator, "
                     "so no file name holds one")
def test_gunzip_accepts_a_backslash_in_a_path_through_argv(tmp_path):
    """A backslash is a valid Linux file name, which proves the Windows shape
    (D:\\a\\...) on this system: argv carries the path, so the generated
    source holds no backslash for the lexer to reject."""
    src = tmp_path / "back\\slash.gz"
    src.write_bytes(gzip.compress(b"abc"))
    dst = tmp_path / "back\\slash.out"
    source = tmp_path / "backslash.agc"
    result = gunzip_case(source, src, dst, 100)
    assert "\\" not in source.read_text(encoding="utf-8")
    assert result.code == 0, result.stderr
    assert result.stdout == "ok(3)\n", result.stdout
    assert read_bytes(dst) == b"abc"


def test_gunzip_runs_beside_other_tasks_and_each_result_is_right(tmp_path):
    first = tmp_path / "first.gz"
    first.write_bytes(gzip.compress(bytes((k * 3) % 251 for k in range(70000))))
    second = tmp_path / "second.gz"
    second.write_bytes(gzip.compress(bytes((k * 5) % 251 for k in range(140000))))
    body = (
        "def unzipped(src: String) -> Int\n"
        '  return File.gunzip(src, src + ".out", 1073741824, 30000).unwrap!\n'
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  a = Task.spawn(&unzipped, System.args()[0])\n"
        "  b = Task.spawn(&unzipped, System.args()[1])\n"
        '  puts("#{Task.await(a)} #{Task.await(b)}")\n'
        "end\n"
    )
    result = run_source(tmp_path, "fair.agc", body, [first, second])
    assert result.code == 0, result.stderr
    assert result.stdout == "70000 140000\n", result.stdout


def test_gunzip_of_a_task_that_ends_is_dropped_like_any_pool_job(tmp_path):
    target = tmp_path / "ended.gz"
    target.write_bytes(gzip.compress(bytes(1000)))
    body = (
        "def unzipped(path: String) -> Int\n"
        '  return File.gunzip(path, path + ".out", 1073741824, 30000).unwrap!\n'
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  Task.spawn(&unzipped, System.args()[0])\n"
        '  puts("spawned")\n'
        "end\n"
    )
    result = run_source(tmp_path, "ended.agc", body, [target])
    assert (result.code, result.stdout) == (0, "spawned\n"), result.stderr


def test_gunzip_of_a_task_cancelled_before_it_runs_is_cancelled(tmp_path):
    target = tmp_path / "cancelled.gz"
    target.write_bytes(gzip.compress(bytes(1000)))
    body = (
        "def unzipped(path: String) -> Result[Int]\n"
        '  return ok(File.gunzip(path, path + ".out", 1073741824, 30000).unwrap!)\n'
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  t = Task.spawn(&unzipped, System.args()[0])\n"
        "  Task.cancel(t)\n"
        "  puts(Task.await(t))\n"
        "end\n"
    )
    result = run_source(tmp_path, "cancelled.agc", body, [target])
    assert (result.code, result.stdout) == (0, 'error("task: cancelled")\n'), result.stderr
