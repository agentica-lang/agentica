"""Zlib compression against Python's stdlib zlib, gzip and hashlib, on every system.

Bytes and Lazy streams share one contract: deflate/inflate are the zlib
wrapper (RFC 1950, the Ruby and Python default), gzip/gunzip are the gzip
format (RFC 1952), and the Lazy steps add raw deflate (RFC 1951) through
`deflate(level, true)` and `inflate(true, max_bytes)`. One-shot input is at
most 1 MiB with max_bytes 1 to 1 MiB (default 1 MiB); a Lazy decoder's
max_bytes is at least 1 (default 1 GiB) and holds while streaming. Decoders
are strict: one stream or member, checksum verified, any trailing byte
refused. Chunks of any size are taken, empty ones too, and an output chunk is
at most 64 KiB. Only File.chunks and write_bytes touch the filesystem.

The peers are Python's stdlib zlib, gzip and hashlib only: both directions at
levels 0, 6 and 9 over empty, NUL bytes, invalid UTF-8 and binary payloads,
checked with wbits 15, -15 and 31. A run that stops early (first, find, a
failed try, a block error, a cancel) frees its zlib stream, proved with the io
trace.

Most error assertions check the shape of the failure (an error Result, the
zlib or filesystem family); the exact text is checked where it is the
contract of a cap, a bad argument or a refused file.
"""
import gzip
import hashlib
import os
import struct
import sys
import zlib

import pytest

from tests.agentica_test import WINDOWS, cli, compile_agc, run, run_vm, vm_environment

CAP_1MIB = 1048576

# One-shot bytes through files: argv is op, src, dst, max_out, level.
BYTES_PEER = (
    "def convert(op: String, data: List[Int], cap: Int, level: Int) -> Result[List[Int]]\n"
    '  if op == "deflate"\n'
    "    return Zlib.deflate(data, level, cap)\n"
    '  elsif op == "inflate"\n'
    "    return Zlib.inflate(data, cap)\n"
    '  elsif op == "gzip"\n'
    "    return Zlib.gzip(data, level, cap)\n"
    "  else\n"
    "    return Zlib.gunzip(data, cap)\n"
    "  end\n"
    "end\n"
    "\n"
    "def main() -> Void\n"
    "  op: String = System.args()[0]\n"
    "  src: String = System.args()[1]\n"
    "  dst: String = System.args()[2]\n"
    "  cap: Int = System.args()[3].to_i!\n"
    "  level: Int = System.args()[4].to_i!\n"
    '  fd = File.open(src, "read", 30000).unwrap!\n'
    "  data = File.read_bytes(fd, 1048576, 30000).unwrap!\n"
    "  File.close(fd, 30000)\n"
    "  out = convert(op, data, cap, level)\n"
    "  if out.ok?\n"
    '  w = File.open(dst, "write", 30000).unwrap!\n'
    "  File.write_bytes(w, out.unwrap!, 30000).unwrap!\n"
    "  File.close(w, 30000)\n"
    '  puts(\"ok\")\n'
    "  else\n"
    "    puts(out)\n"
    "  end\n"
    "end\n"
)

PAYLOADS = {
    "empty.bin": b"",
    "abc.bin": b"abc",
    "nul.bin": b"\x00\x00a\x00",
    "not-utf8.bin": b"\xff\xfe\x00bad\x80utf8",
    "binary.bin": bytes((k * 7) % 251 for k in range(100000)),
}


@pytest.fixture(scope="module")
def bytes_peer(tmp_path_factory):
    source = tmp_path_factory.mktemp("zlib-bytes") / "peer.agc"
    source.write_text(BYTES_PEER, encoding="utf-8")
    return compile_agc(source, source.with_suffix(".agcb"))


def run_source(tmp_path, name, body, args):
    """Write body as name, run it with args through the product CLI."""
    source = tmp_path / name
    source.write_text(body, encoding="utf-8")
    return run(cli() + [str(source)] + [str(a) for a in args], env=vm_environment())


def read_bytes(path):
    with open(path, "rb") as handle:
        return handle.read()


def bytes_case(peer, tmp_path, tag, op, data, cap=CAP_1MIB, level=6):
    """Run one bytes op through files, return (printed, output bytes)."""
    src = tmp_path / ("%s-in.bin" % tag)
    dst = tmp_path / ("%s-out.bin" % tag)
    src.write_bytes(data)
    result = run_vm(peer, args=[op, str(src), str(dst), str(cap), str(level)])
    out = read_bytes(dst) if dst.exists() else None
    return result, out


def check_bytes_round_trip(peer, tmp_path, tag, op, op_back, data, **kwargs):
    kwargs.setdefault("level", 6)
    result, packed = bytes_case(peer, tmp_path, tag + "-fwd", op, data, level=kwargs["level"])
    assert result.code == 0, result.stderr
    assert result.stdout == "ok\n", result.stdout
    result, back = bytes_case(peer, tmp_path, tag + "-back", op_back, packed, level=kwargs["level"])
    assert result.code == 0, result.stderr
    assert result.stdout == "ok\n", result.stdout
    assert back == data
    return packed


def test_zlib_bytes_round_trip_at_every_level(bytes_peer, tmp_path):
    for name, data in PAYLOADS.items():
        for level in (0, 6, 9):
            check_bytes_round_trip(bytes_peer, tmp_path, name, "deflate", "inflate", data, level=level)
            check_bytes_round_trip(bytes_peer, tmp_path, name, "gzip", "gunzip", data, level=level)


def test_zlib_deflate_matches_python_zlib(bytes_peer, tmp_path):
    for name, data in PAYLOADS.items():
        packed = check_bytes_round_trip(bytes_peer, tmp_path, name, "deflate", "inflate", data)
        assert zlib.decompress(packed) == data
        gz = check_bytes_round_trip(bytes_peer, tmp_path, name, "gzip", "gunzip", data)
        assert gzip.decompress(gz) == data


def test_zlib_inflate_reads_python_zlib(bytes_peer, tmp_path):
    for level in (0, 6, 9):
        for name, data in PAYLOADS.items():
            result, back = bytes_case(bytes_peer, tmp_path, "%s-%d-in" % (name, level), "inflate", zlib.compress(data, level))
            assert (result.code, result.stdout) == (0, "ok\n"), result.stderr
            assert back == data
            result, back = bytes_case(bytes_peer, tmp_path, "%s-%d-gz" % (name, level), "gunzip", gzip.compress(data, compresslevel=level))
            assert (result.code, result.stdout) == (0, "ok\n"), result.stderr
            assert back == data


def test_zlib_inflate_rejects_an_empty_stream(bytes_peer, tmp_path):
    for op in ("inflate", "gunzip"):
        result, _ = bytes_case(bytes_peer, tmp_path, "empty-" + op, op, b"")
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout


@pytest.mark.parametrize("mutate", ["magic", "method", "flags", "payload", "adler", "truncated"])
def test_zlib_inflate_rejects_a_broken_wrapper(bytes_peer, tmp_path, mutate):
    blob = bytearray(zlib.compress(b"hello world, hello world"))
    if mutate == "magic":
        blob[0] = 0x78 ^ 0x01
    elif mutate == "method":
        blob[1] = 0x9C ^ 0x01
    elif mutate == "flags":
        blob[0] = 0x00
    elif mutate == "payload":
        blob[len(blob) // 2] ^= 0x01
    elif mutate == "adler":
        blob[-1] ^= 0x01
    elif mutate == "truncated":
        del blob[len(blob) // 2:]
    result, _ = bytes_case(bytes_peer, tmp_path, "wrapper-" + mutate, "inflate", bytes(blob))
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout


def break_gzip_member(mutate):
    """One gzip member with one thing wrong, by kind."""
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
    return bytes(blob)


@pytest.mark.parametrize("mutate", ["magic", "method", "flags", "payload", "crc", "isize", "truncated"])
def test_zlib_gunzip_rejects_a_broken_member(bytes_peer, tmp_path, mutate):
    result, _ = bytes_case(bytes_peer, tmp_path, "member-" + mutate, "gunzip", break_gzip_member(mutate))
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout


def test_zlib_bytes_reject_a_second_member_and_trailing_bytes(bytes_peer, tmp_path):
    first = gzip.compress(b"hi")
    both = first + gzip.compress(b"yo")
    for blob in (both, first + b"\x00", first + b"junk trailing"):
        result, _ = bytes_case(bytes_peer, tmp_path, "trail", "gunzip", blob)
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout
    wrapped = zlib.compress(b"hi")
    for blob in (wrapped + wrapped, wrapped + b"\x00"):
        result, _ = bytes_case(bytes_peer, tmp_path, "trail-zz", "inflate", blob)
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout


def test_zlib_bytes_reject_the_wrong_wrapper(bytes_peer, tmp_path):
    result, _ = bytes_case(bytes_peer, tmp_path, "cross-gz", "inflate", gzip.compress(b"hi"))
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout
    result, _ = bytes_case(bytes_peer, tmp_path, "cross-zz", "gunzip", zlib.compress(b"hi"))
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    raw = comp.compress(b"hi") + comp.flush()
    for op in ("inflate", "gunzip"):
        result, _ = bytes_case(bytes_peer, tmp_path, "cross-raw-" + op, op, raw)
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout


def test_zlib_bytes_reject_a_bad_level(bytes_peer, tmp_path):
    body = (
        "def main() -> Void\n"
        "  puts(Zlib.deflate([1, 2], %s, 1048576))\n"
        "  puts(Zlib.gzip([1, 2], %s, 1048576))\n"
        "end\n"
    )
    for level in ("-1", "10"):
        result = run_source(tmp_path, "level-%s.agc" % level, body % (level, level), [])
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout


def test_zlib_bytes_reject_input_past_1_mib(tmp_path):
    body = (
        "def main() -> Void\n"
        "  big = List.concat(List.repeat(7, 600000), List.repeat(7, 600000))\n"
        "  puts(Zlib.deflate(big, 6, 1048576))\n"
        "  puts(Zlib.gzip(big, 6, 1048576))\n"
        "end\n"
    )
    result = run_source(tmp_path, "big.agc", body, [])
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout


def test_zlib_bytes_reject_a_max_outside_its_bounds(tmp_path):
    body = (
        "def main() -> Void\n"
        "  puts(Zlib.deflate([1, 2], 6, %s))\n"
        "  puts(Zlib.inflate([1, 2], %s))\n"
        "  puts(Zlib.gzip([1, 2], 6, %s))\n"
        "  puts(Zlib.gunzip([1, 2], %s))\n"
        "end\n"
    )
    for bound in ("0", "1048577"):
        result = run_source(tmp_path, "bound-%s.agc" % bound, body % ((bound,) * 4), [])
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout


def test_zlib_bytes_cut_output_past_its_cap(bytes_peer, tmp_path):
    data = bytes((k * 13 + 5) % 251 for k in range(100000))
    for op in ("deflate", "gzip"):
        result, _ = bytes_case(bytes_peer, tmp_path, "cut-" + op, op, data, cap=100)
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout


def test_zlib_bytes_reject_a_byte_outside_0_to_255(tmp_path):
    body = (
        "def main() -> Void\n"
        "  puts(Zlib.deflate([256], 6, 1048576))\n"
        "  puts(Zlib.gzip([1, -1], 6, 1048576))\n"
        "end\n"
    )
    result = run_source(tmp_path, "range.agc", body, [])
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout


# The Lazy steps through argv: op, src, dst, chunk size, then the level of an
# encoder or the max_bytes of a decoder. File.chunks reads src and write_bytes
# writes dst; the printed Result is the byte count or the error.
LAZY_PEER = (
    "def step(op: String, chunks: Lazy[List[Int]], arg: Int) -> Lazy[List[Int]]\n"
    '  if op == "deflate"\n'
    "    return chunks.deflate(arg)\n"
    '  elsif op == "raw_deflate"\n'
    "    return chunks.deflate(arg, true)\n"
    '  elsif op == "gzip"\n'
    "    return chunks.gzip(arg)\n"
    '  elsif op == "inflate"\n'
    "    return chunks.inflate(false, arg)\n"
    '  elsif op == "raw_inflate"\n'
    "    return chunks.inflate(true, arg)\n"
    "  else\n"
    "    return chunks.gunzip(arg)\n"
    "  end\n"
    "end\n"
    "\n"
    "def main() -> Void\n"
    "  args = System.args()\n"
    "  puts(step(args[0], File.chunks(args[1], args[3].to_i!), args[4].to_i!).write_bytes(args[2]))\n"
    "end\n"
)

# Python's peer of each op: the wbits of its stream.
WBITS = {"deflate": 15, "raw_deflate": -15, "gzip": 31}
DECODER = {"deflate": "inflate", "raw_deflate": "raw_inflate", "gzip": "gunzip"}


@pytest.fixture(scope="module")
def lazy_peer(tmp_path_factory):
    source = tmp_path_factory.mktemp("zlib-lazy") / "peer.agc"
    source.write_text(LAZY_PEER, encoding="utf-8")
    return compile_agc(source, source.with_suffix(".agcb"))


def python_compress(data, op, level=6):
    comp = zlib.compressobj(level, zlib.DEFLATED, WBITS[op])
    return comp.compress(data) + comp.flush()


def lazy_case(peer, tmp_path, tag, op, data, size=65536, arg=None, flags=()):
    """Run one Lazy op over data, return (result, output bytes or None)."""
    src = tmp_path / ("%s-in.bin" % tag)
    dst = tmp_path / ("%s-out.bin" % tag)
    src.write_bytes(data)
    if arg is None:
        arg = 6 if op in WBITS else CAP_1MIB * 1024
    result = run_vm(peer, *flags, args=[op, str(src), str(dst), str(size), str(arg)])
    return result, (read_bytes(dst) if dst.exists() else None)


def test_lazy_encoders_write_what_python_reads(lazy_peer, tmp_path):
    for index, (name, data) in enumerate(PAYLOADS.items()):
        size = (1, 7, 65536)[index % 3] if len(data) < 1000 else (7, 65536, 65537)[index % 3]
        for op in WBITS:
            for level in (0, 6, 9):
                result, out = lazy_case(lazy_peer, tmp_path, "%s-%s-%d" % (name, op, level), op, data, size, level)
                assert result.code == 0, result.stderr
                assert result.stdout == "ok(%d)\n" % len(out), result.stdout
                assert zlib.decompress(out, WBITS[op]) == data


def test_lazy_decoders_read_what_python_writes(lazy_peer, tmp_path):
    for index, (name, data) in enumerate(PAYLOADS.items()):
        for op in WBITS:
            for level in (0, 6, 9):
                packed = python_compress(data, op, level)
                size = 1 if len(packed) < 1000 else (7, 65536)[index % 2]
                tag = "%s-%s-%d" % (name, op, level)
                result, out = lazy_case(lazy_peer, tmp_path, tag, DECODER[op], packed, size)
                assert result.code == 0, result.stderr
                assert (result.stdout, out) == ("ok(%d)\n" % len(data), data)
    # A gzip member with every optional header field (FEXTRA, FNAME, FCOMMENT, FHCRC), framed by hand.
    fextra = b"AB" + struct.pack("<H", 2) + b"xy"
    head = b"\x1f\x8b\x08\x1e\x39\x30\x00\x00\x02\xff" + struct.pack("<H", len(fextra)) + fextra
    head += b"myname.txt\x00" + b"a comment here\x00"
    head += struct.pack("<H", zlib.crc32(head) & 0xFFFF)
    payload = b"optheaders!" * 1000
    framed = head + python_compress(payload, "raw_deflate", 9)
    framed += struct.pack("<I", zlib.crc32(payload) & 0xFFFFFFFF) + struct.pack("<I", len(payload))
    for size in (1, 65536):
        result, out = lazy_case(lazy_peer, tmp_path, "headers-%d" % size, "gunzip", framed, size)
        assert (result.code, result.stdout, out) == (0, "ok(%d)\n" % len(payload), payload), result.stderr


def test_lazy_gzip_round_trips_multi_mib_and_agrees_with_hashlib(lazy_peer, tmp_path):
    data = os.urandom(2 * CAP_1MIB) + bytes(3 * CAP_1MIB) + os.urandom(12345)
    result, packed = lazy_case(lazy_peer, tmp_path, "big", "gzip", data)
    assert result.code == 0, result.stderr
    assert hashlib.sha256(gzip.decompress(packed)).digest() == hashlib.sha256(data).digest()
    result, back = lazy_case(lazy_peer, tmp_path, "big-back", "gunzip", packed, 4096)
    assert (result.code, result.stdout) == (0, "ok(%d)\n" % len(data)), result.stderr
    assert hashlib.sha256(back).digest() == hashlib.sha256(data).digest()


def test_lazy_runs_the_same_in_every_jit_tier(lazy_peer, tmp_path):
    data = bytes((k * 7) % 251 for k in range(200000))
    packed = gzip.compress(data)
    for mode in ("off", "on", "always"):
        result, out = lazy_case(lazy_peer, tmp_path, "jit-" + mode, "gzip", data, 4096, flags=("--jit", mode))
        assert result.code == 0, result.stderr
        assert gzip.decompress(out) == data
        result, out = lazy_case(lazy_peer, tmp_path, "jit-back-" + mode, "gunzip", packed, 3,
                                flags=("--jit", mode))
        assert (result.code, out) == (0, data), result.stderr


def test_lazy_steps_take_empty_items_and_match_python_bytes(tmp_path):
    body = (
        "def main() -> Void\n"
        "  items: List[List[Int]] = [[], [104], [], [], [105], []]\n"
        "  packed = items.lazy.deflate.to_a.unwrap!\n"
        '  puts(packed.flat_map do |c| c end.map do |b| b.to_s end.join(","))\n'
        "  none: List[Int] = []\n"
        "  spaced = packed.flat_map do |c| [none, c, none] end\n"
        "  puts(spaced.lazy.inflate.to_a)\n"
        "  puts(items.lazy.gzip.gunzip.to_a)\n"
        "end\n"
    )
    result = run_source(tmp_path, "empty-items.agc", body, [])
    assert result.code == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0] == ",".join(str(b) for b in zlib.compress(b"hi")), lines[0]
    assert lines[1:] == ["ok([[104, 105]])", "ok([[104, 105]])"], lines


@pytest.mark.parametrize("op, blob", [
    ("gunzip", gzip.compress(b"hi") + gzip.compress(b"yo")),
    ("gunzip", gzip.compress(b"hi") + b"\x00"),
    ("gunzip", gzip.compress(b"hi")[:-3]),
    ("gunzip", break_gzip_member("crc")),
    ("gunzip", zlib.compress(b"hi")),
    ("inflate", zlib.compress(b"hi") + b"junk"),
    ("inflate", gzip.compress(b"hi")),
    ("inflate", b""),
    ("raw_inflate", python_compress(b"hi", "raw_deflate") + b"\x00"),
])
def test_lazy_decoders_are_strict(lazy_peer, tmp_path, op, blob):
    for size in (1, 65536):
        result, _ = lazy_case(lazy_peer, tmp_path, "strict-%d" % size, op, blob, size)
        assert result.code == 0, result.stderr
        assert result.stdout.startswith('error("zlib: '), result.stdout


def test_lazy_caps_hold_while_streaming(lazy_peer, tmp_path):
    bomb = gzip.compress(bytes(64 * CAP_1MIB), compresslevel=9)
    assert len(bomb) < 100000
    result, out = lazy_case(lazy_peer, tmp_path, "bomb", "gunzip", bomb, 4096, CAP_1MIB)
    assert result.code == 0, result.stderr
    assert result.stdout == 'error("zlib: output exceeds max_bytes")\n', result.stdout
    assert out is not None and len(out) <= CAP_1MIB
    result, out = lazy_case(lazy_peer, tmp_path, "exact", "gunzip", gzip.compress(b"abc"), 1, 3)
    assert (result.code, result.stdout, out) == (0, "ok(3)\n", b"abc"), result.stderr
    result, _ = lazy_case(lazy_peer, tmp_path, "short", "inflate", zlib.compress(b"abc"), 1, 2)
    assert result.stdout == 'error("zlib: output exceeds max_bytes")\n', result.stdout


def test_lazy_bad_arguments(tmp_path):
    body = (
        "def main() -> Void\n"
        "  puts([[1]].lazy.deflate(10).to_a)\n"
        "  puts([[1]].lazy.gzip(-1).to_a)\n"
        "  puts([[1]].lazy.inflate(false, 0).to_a)\n"
        "  puts([[1]].lazy.gunzip(0).to_a)\n"
        "  puts(File.chunks(System.args()[0], 0).to_a)\n"
        "end\n"
    )
    result = run_source(tmp_path, "bad-args.agc", body, [tmp_path / "bad-args.agc"])
    assert result.stdout.splitlines() == [
        'error("zlib: level must be between 0 and 9")',
        'error("zlib: level must be between 0 and 9")',
        'error("zlib: max_bytes must be at least 1")',
        'error("zlib: max_bytes must be at least 1")',
    ], result.stdout
    assert result.code == 1
    assert "RUNTIME-INVALID-COUNT" in result.stderr, result.stderr


def test_file_chunks_reads_a_file_and_refuses_what_is_not_regular(tmp_path):
    body = (
        "def main() -> Void\n"
        "  puts(File.chunks(System.args()[0], 2).to_a)\n"
        "  puts(File.chunks(System.args()[1]).to_a)\n"
        "  puts(File.chunks(System.args()[2]).to_a)\n"
        "  puts(File.chunks(System.args()[3]).to_a)\n"
        "end\n"
    )
    data = tmp_path / "data.bin"
    data.write_bytes(b"\x00\xffab\x80")
    empty = tmp_path / "empty.bin"
    empty.write_bytes(b"")
    result = run_source(tmp_path, "chunks.agc", body, [data, empty, tmp_path / "missing.bin", tmp_path])
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [
        "ok([[0, 255], [97, 98], [128]])",
        "ok([])",
        'error("filesystem: path does not refer to a regular file")',
        'error("filesystem: path does not refer to a regular file")',
    ], result.stdout


@pytest.mark.skipif(WINDOWS, reason="no FIFO on Windows")
def test_file_chunks_refuses_a_fifo_without_waiting(tmp_path):
    fifo = tmp_path / "fifo"
    os.mkfifo(fifo)
    body = "def main() -> Void\n  puts(File.chunks(System.args()[0]).to_a)\nend\n"
    result = run_source(tmp_path, "fifo.agc", body, [fifo])
    assert result.code == 0, result.stderr
    assert result.stdout == 'error("filesystem: path does not refer to a regular file")\n', result.stdout


def test_write_bytes_errors(tmp_path):
    body = (
        "def main() -> Void\n"
        "  args = System.args()\n"
        "  puts([[1, 2], [], [3]].lazy.write_bytes(args[0]))\n"
        "  puts([[1], [256]].lazy.write_bytes(args[1]))\n"
        "  puts([[1]].lazy.write_bytes(args[2]))\n"
        "  puts([[1]].lazy.write_bytes(args[3]))\n"
        "  puts(File.chunks(args[4]).gzip.write_bytes(args[5]))\n"
        "end\n"
    )
    out = tmp_path / "out.bin"
    out.write_bytes(b"old content that is longer")
    args = [out, tmp_path / "range.bin", tmp_path / "no" / "parent.bin", tmp_path, tmp_path / "missing.bin",
            tmp_path / "never.gz"]
    result = run_source(tmp_path, "write.agc", body, args)
    assert result.code == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[:2] == ["ok(3)", 'error("filesystem: bytes must be between 0 and 255")'], lines
    assert result.stdout.count('error("') == 4, result.stdout
    assert read_bytes(out) == b"\x01\x02\x03"


def test_deny_fs_refuses_file_chunks_and_write_bytes_but_not_the_steps(tmp_path):
    body = (
        "def main() -> Void\n"
        "  puts(File.chunks(System.args()[0]).to_a)\n"
        "  puts([[1]].lazy.write_bytes(System.args()[1]))\n"
        "  puts([[104, 105]].lazy.gzip.gunzip.to_a)\n"
        "end\n"
    )
    source = tmp_path / "deny.agc"
    source.write_text(body, encoding="utf-8")
    src = tmp_path / "src.bin"
    src.write_bytes(b"abc")
    dst = tmp_path / "dst.bin"
    result = run(cli() + ["--deny-fs", str(source), str(src), str(dst)], env=vm_environment())
    assert result.code == 0, result.stderr
    denied = 'error("denied: --deny-fs turns off file access")'
    assert result.stdout.splitlines() == [denied, denied, "ok([[104, 105]])"], result.stdout
    assert not dst.exists()


# A run that stops early frees its zlib stream: the trace shows each stream
# closed once, before the program ends. The run of "cancel" is parked in its
# block when the task is cancelled.
EARLY_STOP = (
    "def check(c: List[Int]) -> Result[Int]\n"
    "  if c.size > 1000\n"
    '    return error("big chunk")\n'
    "  end\n"
    "  return ok(c.size)\n"
    "end\n"
    "\n"
    "def total(path: String) -> Result[Int]\n"
    "  return File.chunks(path, 4096).gunzip.reduce(0) do |n, c|\n"
    "    try check(c)\n"
    "    n + c.size\n"
    "  end\n"
    "end\n"
    "\n"
    "def boom(path: String) -> Result[Int]\n"
    "  return ok(File.chunks(path, 4096).gunzip.reduce(0) do |n, c|\n"
    "    n + [1][c.size]\n"
    "  end.unwrap!)\n"
    "end\n"
    "\n"
    "def slow(path: String) -> Result[Int]\n"
    "  return File.chunks(path, 4096).gunzip.reduce(0) do |n, c|\n"
    "    Task.sleep(60000)\n"
    "    n + c.size\n"
    "  end\n"
    "end\n"
    "\n"
    "def main() -> Void\n"
    "  args = System.args()\n"
    "  path = args[1]\n"
    '  if args[0] == "first"\n'
    "    puts(File.chunks(path, 4096).gunzip.first(1).unwrap!.size)\n"
    '  elsif args[0] == "find"\n'
    "    puts(File.chunks(path, 4096).gunzip.find do |c| c.size > 0 end.unwrap!.size)\n"
    '  elsif args[0] == "try"\n'
    "    puts(total(path))\n"
    '  elsif args[0] == "block"\n'
    "    puts(Task.await(Task.spawn(&boom, path)).ok?)\n"
    "  else\n"
    "    t = Task.spawn(&slow, path)\n"
    "    Task.sleep(100)\n"
    "    Task.cancel(t)\n"
    "    puts(Task.await(t).ok?)\n"
    "  end\n"
    '  puts("after")\n'
    "end\n"
)


@pytest.fixture(scope="module")
def early_stop(tmp_path_factory):
    folder = tmp_path_factory.mktemp("zlib-early")
    source = folder / "early.agc"
    source.write_text(EARLY_STOP, encoding="utf-8")
    big = folder / "big.gz"
    big.write_bytes(gzip.compress(os.urandom(300000)))
    return compile_agc(source, source.with_suffix(".agcb")), big


@pytest.mark.parametrize("mode, printed", [
    ("first", "1"), ("find", "4081"), ("try", 'error("big chunk")'), ("block", "false"), ("cancel", "false"),
])
def test_lazy_frees_its_zlib_stream_when_it_stops_early(early_stop, tmp_path, mode, printed):
    bytecode, big = early_stop
    trace = tmp_path / "io.trace"
    result = run_vm(bytecode, args=[mode, str(big)],
                    env=vm_environment({"AGENTICA_VM_TRACE": "io", "AGENTICA_VM_TRACE_FILE": str(trace)}))
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [printed, "after"], result.stdout
    events = [line.split(" io ", 1)[1] for line in trace.read_text(encoding="utf-8").splitlines() if " io " in line]
    zlib_events = [e.split()[0] for e in events if e.startswith("zlib_")]
    assert zlib_events == ["zlib_open", "zlib_close"], events
    assert any(e.startswith("file_close") for e in events), events
    assert events.index(next(e for e in events if e.startswith("zlib_close"))) < events.index(
        next(e for e in events if e.startswith("output_start stream=stdout"))), events


# The streaming decoder of std/archive, kept until std/archive moves to the Lazy steps.
def test_zlib_stream_raw_and_gzip_match_python(tmp_path):
    data = bytes((k * 7) % 251 for k in range(70000))
    comp = zlib.compressobj(6, zlib.DEFLATED, -15)
    raw = comp.compress(data) + comp.flush()
    body = (
        "def main() -> Void\n"
        "  packed: List[Int] = []\n"
        "  for byte in [%s]\n"
        "    packed = packed.push(byte)\n"
        "  end\n"
        "  dec = Zlib.inflate_init(-15, 1073741824, 1073741824).unwrap!\n"
        "  out: List[Int] = []\n"
        "  rest: List[Int] = packed\n"
        "  while rest.size > 0\n"
        "    step = Zlib.inflate_next(dec, List.take(rest, 65536), 65536).unwrap!\n"
        "    out = List.concat(out, step.output)\n"
        "    rest = List.drop(rest, step.consumed)\n"
        "  end\n"
        "  Zlib.inflate_finish(dec).unwrap!\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "  puts(Test.eq(out, [%s]))\n"
        "end\n" % (", ".join(str(b) for b in raw), ", ".join(str(b) for b in data))
    )
    result = run_source(tmp_path, "raw-in.agc", body, [])
    assert result.code == 0, result.stderr
    assert "ok()" in result.stdout, result.stdout


def test_zlib_stream_pending_output_drains_from_empty_input(tmp_path):
    data = bytes((k * 3) % 251 for k in range(70000))
    packed = zlib.compress(data)
    body = (
        "def main() -> Void\n"
        "  packed: List[Int] = [%s]\n"
        "  dec = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!\n"
        "  fed = Zlib.inflate_next(dec, packed, 65536).unwrap!\n"
        "  out: List[Int] = fed.output\n"
        "  if fed.needs_input\n"
        '    puts("asked for more with pending output")\n'
        "  end\n"
        "  index = fed.consumed\n"
        "  empty = Zlib.inflate_next(dec, [], 65536).unwrap!\n"
        "  out = List.concat(out, empty.output)\n"
        "  if empty.output.size == 0\n"
        '    puts("empty drain stalled with output pending")\n'
        "  end\n"
        "  index = index + empty.consumed\n"
        "  again = not empty.finished\n"
        "  while again\n"
        "    step = Zlib.inflate_next(dec, List.take(List.drop(packed, index), 65536), 65536).unwrap!\n"
        "    out = List.concat(out, step.output)\n"
        "    index = index + step.consumed\n"
        "    again = not step.finished\n"
        "  end\n"
        "  Zlib.inflate_finish(dec).unwrap!\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "  puts(Test.eq(out, [%s]))\n"
        "end\n" % (", ".join(str(b) for b in packed), ", ".join(str(b) for b in data))
    )
    result = run_source(tmp_path, "drain.agc", body, [])
    assert result.code == 0, result.stderr
    assert "asked for more" not in result.stdout, result.stdout
    assert "stalled" not in result.stdout, result.stdout
    assert "ok()" in result.stdout, result.stdout


def test_zlib_stream_decoder_finish_needs_the_stream_end(tmp_path):
    data = bytes((k * 3) % 251 for k in range(1000))
    packed = zlib.compress(data)
    half = packed[:len(packed) // 2]
    body = (
        "def main() -> Void\n"
        "  fresh = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!\n"
        "  puts(Zlib.inflate_finish(fresh))\n"
        "  Zlib.decoder_close(fresh).unwrap!\n"
        "  half = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!\n"
        "  Zlib.inflate_next(half, [%s], 65536).unwrap!\n"
        "  puts(Zlib.inflate_finish(half))\n"
        "  Zlib.decoder_close(half).unwrap!\n"
        "end\n" % ", ".join(str(b) for b in half)
    )
    result = run_source(tmp_path, "trunc.agc", body, [])
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout


def test_zlib_stream_keeps_trailing_bytes_caller_owned(tmp_path):
    data = b"hi"
    both = gzip.compress(data) + b"leftover"
    body = (
        "def main() -> Void\n"
        "  packed: List[Int] = [%s]\n"
        "  dec = Zlib.inflate_init(31, 1073741824, 1073741824).unwrap!\n"
        "  step = Zlib.inflate_next(dec, packed, 65536).unwrap!\n"
        "  puts(Test.eq(step.output, [104, 105]))\n"
        "  puts(step.finished)\n"
        "  puts(step.consumed + 8 == packed.size)\n"
        "  puts(Zlib.inflate_finish(dec))\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "  puts(Zlib.gunzip(packed, 1048576))\n"
        "end\n" % ", ".join(str(b) for b in both)
    )
    result = run_source(tmp_path, "trailing.agc", body, [])
    assert result.code == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0] == "ok()", result.stdout
    assert lines[1] == "true", result.stdout
    assert lines[2] == "true", result.stdout
    assert lines[3] == "ok()", result.stdout
    assert lines[4].startswith("error("), result.stdout


def test_zlib_stream_feeding_after_finished_is_an_error(tmp_path):
    data = bytes((k * 3) % 251 for k in range(100))
    packed = zlib.compress(data)
    body = (
        "def main() -> Void\n"
        "  packed: List[Int] = [%s]\n"
        "  dec = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!\n"
        "  step = Zlib.inflate_next(dec, packed, 65536).unwrap!\n"
        "  puts(step.finished)\n"
        "  puts(Zlib.inflate_next(dec, [1], 65536))\n"
        "  puts(Zlib.inflate_next(dec, [], 65536))\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "end\n" % ", ".join(str(b) for b in packed)
    )
    result = run_source(tmp_path, "after-end.agc", body, [])
    assert result.code == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0] == "true", result.stdout
    assert lines[1].startswith("error("), result.stdout
    assert lines[2].startswith("ok("), result.stdout


def test_zlib_stream_empty_feed_before_input_asks_for_more(tmp_path):
    body = (
        "def main() -> Void\n"
        "  dec = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!\n"
        "  step = Zlib.inflate_next(dec, [], 65536).unwrap!\n"
        "  puts(step.output.size)\n"
        "  puts(step.consumed)\n"
        "  puts(step.finished)\n"
        "  puts(step.needs_input)\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "end\n"
    )
    result = run_source(tmp_path, "empty-feed.agc", body, [])
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == ["0", "0", "false", "true"], result.stdout


def test_zlib_stream_decoder_finishes_at_an_exact_output_budget(tmp_path):
    for window, split in ((31, 15), (15, 7)):
        packed = gzip.compress(b"abc") if window == 31 else zlib.compress(b"abc")
        text = ", ".join(str(b) for b in packed)
        body = (
            "def main() -> Void\n"
            "  packed: List[Int] = [%s]\n"
            "  head = List.take(packed, %d)\n"
            "  tail = List.drop(packed, %d)\n"
            "  dec = Zlib.inflate_init(%d, 1073741824, 3).unwrap!\n"
            "  first = Zlib.inflate_next(dec, head, 3).unwrap!\n"
            "  puts(Test.eq(first.output, [97, 98, 99]))\n"
            "  puts(first.consumed)\n"
            "  puts(first.finished)\n"
            "  step = Zlib.inflate_next(dec, tail, 1).unwrap!\n"
            "  puts(Test.eq(step.output, []))\n"
            "  puts(step.consumed)\n"
            "  puts(step.finished)\n"
            "  puts(Zlib.inflate_finish(dec))\n"
            "  Zlib.decoder_close(dec).unwrap!\n"
            "  wide = Zlib.inflate_init(%d, 1073741824, 3).unwrap!\n"
            "  Zlib.inflate_next(wide, head, 3).unwrap!\n"
            "  big = Zlib.inflate_next(wide, tail, 65536).unwrap!\n"
            "  puts(Test.eq(big.output, []))\n"
            "  puts(big.finished)\n"
            "  puts(Zlib.inflate_finish(wide))\n"
            "  Zlib.decoder_close(wide).unwrap!\n"
            "end\n" % (text, split, split, window, window)
        )
        result = run_source(tmp_path, "exact-budget-%d.agc" % window, body, [])
        assert result.code == 0, result.stderr
        assert result.stdout.splitlines() == [
            "ok()", str(split), "false", "ok()", str(len(packed) - split), "true", "ok()",
            "ok()", "true", "ok()",
        ], result.stdout


def test_zlib_stream_decoder_reads_an_exact_budget_one_byte_at_a_time(tmp_path):
    packed = gzip.compress(b"abc")
    text = ", ".join(str(b) for b in packed)
    body = (
        "def main() -> Void\n"
        "  packed: List[Int] = [%s]\n"
        "  dec = Zlib.inflate_init(31, 1073741824, 3).unwrap!\n"
        "  out: List[Int] = []\n"
        "  rest = packed\n"
        "  rounds = 0\n"
        "  ended = false\n"
        "  while rest.size > 0\n"
        "    step = Zlib.inflate_next(dec, List.take(rest, 1), 1).unwrap!\n"
        "    out = List.concat(out, step.output)\n"
        "    rest = List.drop(rest, step.consumed)\n"
        "    ended = step.finished\n"
        "    if step.finished\n"
        "      puts(rest.size)\n"
        "      rest = []\n"
        "    end\n"
        "    rounds = rounds + 1\n"
        "    if rounds > 100\n"
        '      puts("stuck")\n'
        "      rest = []\n"
        "    end\n"
        "  end\n"
        "  puts(Test.eq(out, [97, 98, 99]))\n"
        "  puts(ended)\n"
        "  puts(Zlib.inflate_finish(dec))\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "end\n" % text
    )
    result = run_source(tmp_path, "exact-bytes.agc", body, [])
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == ["0", "ok()", "true", "ok()"], result.stdout


def test_zlib_stream_decoder_overflow_past_a_full_budget_fails_sticky(tmp_path):
    packed = gzip.compress(b"abc")
    text = ", ".join(str(b) for b in packed)
    body = (
        "def main() -> Void\n"
        "  packed: List[Int] = [%s]\n"
        "  dec = Zlib.inflate_init(31, 1073741824, 2).unwrap!\n"
        "  out: List[Int] = []\n"
        "  rest = packed\n"
        "  rounds = 0\n"
        "  failed = false\n"
        "  while rest.size > 0\n"
        "    step = Zlib.inflate_next(dec, List.take(rest, 1), 1)\n"
        "    if step.ok?\n"
        "      good = step.unwrap!\n"
        "      out = List.concat(out, good.output)\n"
        "      rest = List.drop(rest, good.consumed)\n"
        "    else\n"
        "      failed = true\n"
        "      rest = []\n"
        "    end\n"
        "    rounds = rounds + 1\n"
        "    if rounds > 100\n"
        "      rest = []\n"
        "    end\n"
        "  end\n"
        "  puts(Test.eq(out, [97, 98]))\n"
        "  puts(failed)\n"
        "  puts(Zlib.inflate_next(dec, List.take(packed, 1), 1))\n"
        "  puts(Zlib.inflate_finish(dec))\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "end\n" % text
    )
    result = run_source(tmp_path, "exact-overflow.agc", body, [])
    assert result.code == 0, result.stderr
    out_lines = result.stdout.splitlines()
    assert out_lines[:2] == ["ok()", "true"], result.stdout
    # Exact wording here pins the sticky failure: a retryable cap refusal
    # would repeat the cap error and report truncation on finish instead.
    assert out_lines[2:] == ['error("zlib: handle failed")'] * 2, result.stdout


def test_zlib_stream_decoder_full_budget_keeps_trailer_and_input_errors(tmp_path):
    packed = gzip.compress(b"abc")
    bad = bytearray(packed)
    bad[-1] ^= 0x01
    good_text = ", ".join(str(b) for b in packed)
    bad_text = ", ".join(str(b) for b in bad)
    body = (
        "def main() -> Void\n"
        "  bad: List[Int] = [%s]\n"
        "  dec = Zlib.inflate_init(31, 1073741824, 3).unwrap!\n"
        "  Zlib.inflate_next(dec, List.take(bad, 15), 3).unwrap!\n"
        "  puts(Zlib.inflate_next(dec, List.drop(bad, 15), 1))\n"
        "  puts(Zlib.inflate_finish(dec))\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "  good: List[Int] = [%s]\n"
        "  short = Zlib.inflate_init(31, 1073741824, 3).unwrap!\n"
        "  Zlib.inflate_next(short, List.take(good, 15), 3).unwrap!\n"
        "  part = Zlib.inflate_next(short, List.take(List.drop(good, 15), 4), 1).unwrap!\n"
        "  puts(part.output.size)\n"
        "  puts(part.finished)\n"
        "  puts(part.needs_input)\n"
        "  puts(Zlib.inflate_finish(short))\n"
        "  Zlib.decoder_close(short).unwrap!\n"
        "  capped = Zlib.inflate_init(15, 5, 100).unwrap!\n"
        "  puts(Zlib.inflate_next(capped, [120, 156, 75, 76, 74, 6], 100))\n"
        "  Zlib.decoder_close(capped).unwrap!\n"
        "end\n" % (bad_text, good_text)
    )
    result = run_source(tmp_path, "exact-errors.agc", body, [])
    assert result.code == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0].startswith("error("), result.stdout
    assert lines[1].startswith("error("), result.stdout
    assert lines[2] == "0", result.stdout
    assert lines[3] == "false", result.stdout
    assert lines[4] == "true", result.stdout
    assert lines[5].startswith("error("), result.stdout
    assert lines[6].startswith("error("), result.stdout
