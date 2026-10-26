"""Zlib compression against Python's stdlib zlib, gzip and hashlib, on every system.

Bytes, files and incremental streaming share one contract: deflate/inflate are
the zlib wrapper (RFC 1950, the Ruby and Python default), gzip/gunzip are the
gzip format (RFC 1952), and streaming adds raw deflate (RFC 1951) through
window_bits -15. One-shot input is at most 1 MiB with max_out_bytes 1 to
1 MiB; a streaming call takes at most 64 KiB with max_out 1 to 64 KiB; each
stream total cap is 1 to 1 GiB; file output caps at 1 GiB, file decompression
reads at most 256 MiB of compressed input and file compression at most 1 GiB
of raw input. Decoders are strict: one stream or member, checksum verified,
any unused or trailing bytes rejected; the streaming caller owns the
remainder through consumed. Empty input is valid for encoding and for drains;
needs_input asks for more input (or a finish), never for a spin. Closing is
idempotent; feeding or finishing a closed, failed or finished handle is an
error; handles move across tasks with Task.spawn_owning.

The peers are Python's stdlib zlib, gzip and hashlib only. Both interop
directions run at levels 0, 6 and 9 over empty, NUL bytes, invalid UTF-8 and
binary payloads: the default deflate entries are checked with wbits 15, the
raw streaming entries with -15 and the gzip entries with 31. The refusals
cover truncation, CRC/Adler and ISIZE corruption, trailing bytes and
concatenated members, a zlib wrapper or raw deflate where gzip is wanted and
the reverse, plus the caps, the filesystem taxonomy (missing, directory,
FIFO, device, existing or missing-parent destination, the source and the
destination the same file, a symlink at either end) with --deny-fs, and the
task fairness, end and cancel cases beside them. No timeout-latency case: a
pool job that has started runs to its end (like File.read_text), so only the
argument check is deterministic.

The error assertions below check the shape of the failure (an error Result,
the filesystem family, the halting code), not the exact wording of the new
data errors: the native review owns the final strings.
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
CAP_1GIB = 1073741824

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

# The four file functions through argv: op, src, dst, max_out, level, timeout.
FILES_PEER = (
    "def main() -> Void\n"
    "  op: String = System.args()[0]\n"
    "  src: String = System.args()[1]\n"
    "  dst: String = System.args()[2]\n"
    "  cap: Int = System.args()[3].to_i!\n"
    "  level: Int = System.args()[4].to_i!\n"
    "  timeout: Int = System.args()[5].to_i!\n"
    '  if op == "deflate_file"\n'
    "    puts(Zlib.deflate_file(src, dst, level, cap, timeout))\n"
    '  elsif op == "inflate_file"\n'
    "    puts(Zlib.inflate_file(src, dst, cap, timeout))\n"
    '  elsif op == "gzip_file"\n'
    "    puts(Zlib.gzip_file(src, dst, level, cap, timeout))\n"
    "  else\n"
    "    puts(Zlib.gunzip_file(src, dst, cap, timeout))\n"
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


@pytest.fixture(scope="module")
def files_peer(tmp_path_factory):
    source = tmp_path_factory.mktemp("zlib-files") / "peer.agc"
    source.write_text(FILES_PEER, encoding="utf-8")
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


def files_case(peer, op, src, dst, cap=CAP_1GIB, level=6, timeout=30000):
    """Run one file op through argv: paths never enter the generated source,
    so a Windows path (D:\\a\\...) cannot break the lexer."""
    return run_vm(peer, args=[op, str(src), str(dst), str(cap), str(level), str(timeout)])


def check_files_round_trip(peer, op, op_back, tmp_path, name, data, **kwargs):
    """Compress with op, decompress with op_back, compare bytes both ways."""
    level = kwargs.get("level", 6)
    target = tmp_path / name
    target.write_bytes(data)
    mid = tmp_path / (name + ".mid")
    out = tmp_path / (name + ".out")
    # File outputs never overwrite: drop the previous pair's products first.
    for stale in (mid, out):
        if stale.exists():
            stale.unlink()
    result = files_case(peer, op, target, mid, level=level)
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("ok("), result.stdout
    again = files_case(peer, op_back, mid, out, level=level)
    assert again.code == 0, again.stderr
    assert again.stdout.startswith("ok("), again.stdout
    assert read_bytes(out) == data
    return result


def test_zlib_files_round_trip_chunks(files_peer, tmp_path):
    chunks = {
        "empty.bin": b"",
        "abc.bin": b"abc",
        "nul.bin": b"\x00\x00a\x00",
        "not-utf8.bin": b"\xff\xfe\x00bad\x80utf8",
        "near-64k.bin": bytes((k * 7) % 251 for k in range(65535)),
        "at-64k.bin": bytes((k * 7) % 251 for k in range(65536)),
        "over-64k.bin": bytes((k * 7) % 251 for k in range(65537)),
        "multi.bin": bytes((k * 7) % 251 for k in range(2 * CAP_1MIB + 13)),
    }
    for name, data in chunks.items():
        check_files_round_trip(files_peer, "gzip_file", "gunzip_file", tmp_path, name, data)
        check_files_round_trip(files_peer, "deflate_file", "inflate_file", tmp_path, name, data)


def test_zlib_files_agree_with_hashlib_on_multi_mib(files_peer, tmp_path):
    data = bytes((k * 13 + 5) % 251 for k in range(3 * CAP_1MIB + 11))
    check_files_round_trip(files_peer, "gzip_file", "gunzip_file", tmp_path, "hashy.bin", data)
    assert hashlib.sha256(read_bytes(tmp_path / "hashy.bin.out")).hexdigest() == hashlib.sha256(data).hexdigest()


@pytest.mark.parametrize("level", [0, 6, 9])
def test_zlib_files_read_every_compression_level(files_peer, tmp_path, level):
    data = bytes((k * 3) % 251 for k in range(300000))
    check_files_round_trip(files_peer, "gzip_file", "gunzip_file", tmp_path,
                            "level-%d.bin" % level, data, level=level)
    check_files_round_trip(files_peer, "deflate_file", "inflate_file", tmp_path,
                            "level-%d.bin" % level, data, level=level)


def test_zlib_gunzip_file_reads_python_gzip(files_peer, tmp_path):
    data = bytes((k * 3) % 251 for k in range(100000))
    target = tmp_path / "py.bin"
    target.write_bytes(gzip.compress(data, mtime=999))
    out = tmp_path / "py.bin.out"
    result = files_case(files_peer, "gunzip_file", target, out)
    assert result.code == 0, result.stderr
    assert read_bytes(out) == data
    raw = tmp_path / "raw.bin"
    raw.write_bytes(zlib.compress(data))
    raw_out = tmp_path / "raw.bin.out"
    again = files_case(files_peer, "inflate_file", raw, raw_out)
    assert again.code == 0, again.stderr
    assert read_bytes(raw_out) == data


def test_zlib_compress_files_match_python(files_peer, tmp_path):
    data = bytes((k * 3) % 251 for k in range(100000))
    for level in (0, 6, 9):
        target = tmp_path / ("mine-%d.bin" % level)
        target.write_bytes(data)
        gz = tmp_path / ("mine-%d.bin.gz" % level)
        result = files_case(files_peer, "gzip_file", target, gz, level=level)
        assert result.code == 0, result.stderr
        assert gzip.decompress(read_bytes(gz)) == data
        wrapped = tmp_path / ("mine-%d.bin.zz" % level)
        again = files_case(files_peer, "deflate_file", target, wrapped, level=level)
        assert again.code == 0, again.stderr
        assert zlib.decompress(read_bytes(wrapped)) == data


def test_zlib_gunzip_file_reads_optional_headers(files_peer, tmp_path):
    raw = bytes((k * 3) % 251 for k in range(100000))
    target = tmp_path / "named.bin"
    target.write_bytes(gzip.compress(raw, mtime=999))
    out = tmp_path / "named.bin.out"
    result = files_case(files_peer, "gunzip_file", target, out)
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
    again = files_case(files_peer, "gunzip_file", manual, manual_out)
    assert again.code == 0, again.stderr
    assert again.stdout == ("ok(%d)\n" % len(payload)), again.stdout
    assert read_bytes(manual_out) == payload


def test_zlib_gunzip_file_refuses_a_second_member_and_trailing_bytes(files_peer, tmp_path):
    first = gzip.compress(b"hi")
    both = first + gzip.compress(b"yo")
    for name, blob in (("concat.gz", both), ("trail-zero.gz", first + b"\x00"),
                       ("trail-junk.gz", first + b"junk trailing")):
        target = tmp_path / name
        target.write_bytes(blob)
        out = tmp_path / (name + ".out")
        result = files_case(files_peer, "gunzip_file", target, out)
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout
        assert "trailing bytes" in result.stdout, result.stdout


@pytest.mark.parametrize("mutate", ["magic", "method", "flags", "payload", "crc", "isize", "truncated"])
def test_zlib_gunzip_file_refuses_a_broken_member(files_peer, tmp_path, mutate):
    blob = break_gzip_member(mutate)
    target = tmp_path / ("%s.gz" % mutate)
    target.write_bytes(blob)
    out = tmp_path / ("%s.gz.out" % mutate)
    result = files_case(files_peer, "gunzip_file", target, out)
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout


def test_zlib_inflate_file_refuses_a_broken_wrapper(files_peer, tmp_path):
    blob = bytearray(zlib.compress(b"hello world, hello world"))
    blob[len(blob) // 2] ^= 0x01
    target = tmp_path / "broken.zz"
    target.write_bytes(bytes(blob))
    result = files_case(files_peer, "inflate_file", target, tmp_path / "broken.out")
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout
    truncated = tmp_path / "trunc.zz"
    truncated.write_bytes(zlib.compress(b"hello world")[:-3])
    again = files_case(files_peer, "inflate_file", truncated, tmp_path / "trunc.out")
    assert again.code == 0, again.stderr
    assert again.stdout.startswith("error("), again.stdout


def test_zlib_files_refuse_the_wrong_wrapper(files_peer, tmp_path):
    wrapper = tmp_path / "wrapper.gz"
    wrapper.write_bytes(zlib.compress(b"hi"))
    comp = zlib.compressobj(9, zlib.DEFLATED, -15)
    raw = tmp_path / "raw.deflate"
    raw.write_bytes(comp.compress(b"hi") + comp.flush())
    result = files_case(files_peer, "gunzip_file", wrapper, tmp_path / "wrapper.out")
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout
    plain = tmp_path / "plain.gz"
    plain.write_bytes(gzip.compress(b"hi"))
    again = files_case(files_peer, "inflate_file", plain, tmp_path / "plain.out")
    assert again.code == 0, again.stderr
    assert again.stdout.startswith("error("), again.stdout
    for target in (wrapper, raw):
        refused = files_case(files_peer, "gunzip_file", target, tmp_path / (target.name + ".out"))
        assert refused.code == 0, refused.stderr
        assert refused.stdout.startswith("error("), refused.stdout


def test_zlib_files_refuse_what_is_not_a_regular_file(files_peer, tmp_path):
    missing = files_case(files_peer, "gunzip_file", tmp_path / "missing.gz", tmp_path / "missing.out")
    assert missing.code == 0, missing.stderr
    assert missing.stdout.startswith("error("), missing.stdout
    assert "regular file" in missing.stdout, missing.stdout
    is_dir = files_case(files_peer, "deflate_file", tmp_path, tmp_path / "dir.out")
    assert is_dir.code == 0, is_dir.stderr
    assert "regular file" in is_dir.stdout, is_dir.stdout


@pytest.mark.skipif(sys.platform == "win32", reason="host-only: Windows has no FIFO files and no /dev/null")
def test_zlib_files_refuse_a_fifo_and_a_device_without_waiting(files_peer, tmp_path):
    fifo = tmp_path / "waiting"
    os.mkfifo(fifo)
    refused = files_case(files_peer, "gzip_file", fifo, tmp_path / "fifo.out")
    assert refused.code == 0, refused.stderr
    assert "regular file" in refused.stdout, refused.stdout
    device = files_case(files_peer, "gunzip_file", "/dev/null", tmp_path / "null.out")
    assert device.code == 0, device.stderr
    assert "regular file" in device.stdout, device.stdout


def test_zlib_files_keep_an_existing_destination_intact(files_peer, tmp_path):
    src = tmp_path / "src.gz"
    src.write_bytes(gzip.compress(b"fresh"))
    dst = tmp_path / "dst.out"
    dst.write_bytes(b"keepme")
    result = files_case(files_peer, "gunzip_file", src, dst)
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout
    assert "error opening file" in result.stdout, result.stdout
    assert read_bytes(dst) == b"keepme"


def test_zlib_files_reject_themselves_missing_parents_and_symlink_targets(files_peer, tmp_path):
    src = tmp_path / "self.gz"
    compressed = gzip.compress(b"abc", mtime=0)
    src.write_bytes(compressed)
    assert "error opening file" in files_case(files_peer, "gunzip_file", src, src).stdout
    assert read_bytes(src) == compressed
    assert "error opening file" in files_case(files_peer, "gunzip_file", src, tmp_path / "no-dir" / "out").stdout
    assert not (tmp_path / "no-dir").exists()
    if sys.platform == "win32":
        pytest.skip("host-only: a symbolic link needs a privilege on Windows")
    linked = tmp_path / "linked.gz"
    os.symlink(src, linked)
    out = tmp_path / "linked.out"
    result = files_case(files_peer, "gunzip_file", linked, out)
    assert result.stdout == "ok(3)\n", result.stderr
    assert read_bytes(out) == b"abc"
    dangling = tmp_path / "dangling.out"
    os.symlink(tmp_path / "never.gz", dangling)
    assert "error opening file" in files_case(files_peer, "gunzip_file", src, dangling).stdout


@pytest.mark.parametrize("limit", ["0", "-5", "1073741825"])
def test_zlib_files_reject_a_max_outside_its_bounds(files_peer, tmp_path, limit):
    src = tmp_path / "limit.bin"
    src.write_bytes(b"abc")
    for op in ("deflate_file", "inflate_file", "gzip_file", "gunzip_file"):
        result = files_case(files_peer, op, src, tmp_path / ("limit-%s.out" % op), cap=limit)
        assert result.code == 0, result.stderr
        assert result.stdout.startswith("error("), result.stdout
        assert "max_out_bytes must be between 1 and 1073741824" in result.stdout, result.stdout


@pytest.mark.parametrize("op", ["deflate_file", "inflate_file", "gzip_file", "gunzip_file"])
def test_zlib_files_reject_a_timeout_that_is_not_positive(files_peer, tmp_path, op):
    src = tmp_path / "timeout.bin"
    src.write_bytes(b"abc")
    result = files_case(files_peer, op, src, tmp_path / "timeout.out", timeout=0)
    assert result.code == 0, result.stderr
    assert result.stdout == 'error("filesystem: timeout must be positive milliseconds")\n'


def test_zlib_gunzip_file_stops_at_an_exact_bound_and_above_it(files_peer, tmp_path):
    src = tmp_path / "exact.gz"
    src.write_bytes(gzip.compress(b"abc"))
    assert files_case(files_peer, "gunzip_file", src, tmp_path / "exact-3.out", cap=3).stdout == "ok(3)\n"
    assert read_bytes(tmp_path / "exact-3.out") == b"abc"
    assert "exceeds max_out_bytes" in files_case(files_peer, "gunzip_file", src, tmp_path / "exact-2.out",
                                                  cap=2).stdout
    assert (tmp_path / "exact-2.out").stat().st_size == 0


def test_zlib_files_cut_a_bomb_at_its_cap_and_keep_the_partial(files_peer, tmp_path):
    src = tmp_path / "bomb.gz"
    src.write_bytes(gzip.compress(bytes(8 * CAP_1MIB)))
    dst = tmp_path / "bomb.out"
    result = files_case(files_peer, "gunzip_file", src, dst, cap=CAP_1MIB)
    assert result.code == 0, result.stderr
    assert "exceeds max_out_bytes" in result.stdout, result.stdout
    size = dst.stat().st_size
    assert CAP_1MIB - 65536 < size <= CAP_1MIB, size


@pytest.mark.slow
def test_zlib_gunzip_file_refuses_more_than_256_mib_of_compressed_input(files_peer, tmp_path):
    """A stored-block member past the fixed input cap, written in 1 MiB
    chunks so the fast tier never builds it."""
    src = tmp_path / "huge.gz"
    total = 268435456 + CAP_1MIB
    crc = 0
    with open(src, "wb") as handle:
        handle.write(bytes([0x1F, 0x8B, 0x08, 0, 0, 0, 0, 0, 0x00, 0xFF]))
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
    result = files_case(files_peer, "gunzip_file", src, dst)
    assert result.code == 0, result.stderr
    assert "compressed input exceeds 268435456 bytes" in result.stdout, result.stdout


@pytest.mark.parametrize("op", ["deflate_file", "inflate_file", "gzip_file", "gunzip_file"])
def test_zlib_files_report_denied_fs(files_peer, tmp_path, op):
    src = tmp_path / "denied.bin"
    src.write_bytes(b"abc")
    source = tmp_path / ("denied-%s.agc" % op)
    if op in ("deflate_file", "gzip_file"):
        source.write_text(
            "def main() -> Void\n"
            "  puts(Zlib.%s(System.args()[0], System.args()[1], 6, 100, 30000))\n"
            "end\n" % op, encoding="utf-8")
    else:
        source.write_text(
            "def main() -> Void\n"
            "  puts(Zlib.%s(System.args()[0], System.args()[1], 100, 30000))\n"
            "end\n" % op, encoding="utf-8")
    result = run(cli() + ["--deny-fs", str(source), str(src), str(tmp_path / "denied.out")],
                 env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stdout == 'error("denied: --deny-fs turns off file access")\n', result.stdout


@pytest.mark.skipif(sys.platform == "win32",
                     reason="host-only: Windows reserves the backslash as a separator, "
                     "so no file name holds one")
def test_zlib_files_accept_a_backslash_in_a_path_through_argv(files_peer, tmp_path):
    """A backslash is a valid Linux file name, which proves the Windows shape
    (D:\\a\\...) on this system: argv carries the path, so the generated
    source holds no backslash for the lexer to reject."""
    src = tmp_path / "back\\slash.gz"
    src.write_bytes(gzip.compress(b"abc"))
    dst = tmp_path / "back\\slash.out"
    result = files_case(files_peer, "gunzip_file", src, dst, cap=100)
    assert result.code == 0, result.stderr
    assert result.stdout == "ok(3)\n", result.stdout
    assert read_bytes(dst) == b"abc"


def test_zlib_files_run_beside_other_tasks_and_each_result_is_right(files_peer, tmp_path):
    first = tmp_path / "first.gz"
    first.write_bytes(gzip.compress(bytes((k * 3) % 251 for k in range(70000))))
    second = tmp_path / "second.gz"
    second.write_bytes(gzip.compress(bytes((k * 5) % 251 for k in range(140000))))
    body = (
        "def unzipped(src: String) -> Int\n"
        '  return Zlib.gunzip_file(src, src + ".out", 1073741824, 30000).unwrap!\n'
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


def test_zlib_files_of_a_task_that_ends_are_dropped_like_any_pool_job(tmp_path):
    target = tmp_path / "ended.gz"
    target.write_bytes(gzip.compress(bytes(1000)))
    body = (
        "def unzipped(path: String) -> Int\n"
        '  return Zlib.gunzip_file(path, path + ".out", 1073741824, 30000).unwrap!\n'
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  Task.spawn(&unzipped, System.args()[0])\n"
        '  puts("spawned")\n'
        "end\n"
    )
    result = run_source(tmp_path, "ended.agc", body, [target])
    assert (result.code, result.stdout) == (0, "spawned\n"), result.stderr


def test_zlib_files_of_a_task_cancelled_before_they_run_are_cancelled(tmp_path):
    target = tmp_path / "cancelled.gz"
    target.write_bytes(gzip.compress(bytes(1000)))
    body = (
        "def unzipped(path: String) -> Result[Int]\n"
        '  return ok(Zlib.gzip_file(path, path + ".out", 6, 1073741824, 30000).unwrap!)\n'
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


STREAM_ROUND_TRIP = (
    "def deflate_all(data: List[Int], window_bits: Int, level: Int) -> List[Int]\n"
    "  enc = Zlib.deflate_init(window_bits, level, 1073741824, 1073741824).unwrap!\n"
    "  out: List[Int] = []\n"
    "  rest: List[Int] = data\n"
    "  while rest.size > 0\n"
    "    step = Zlib.deflate_next(enc, List.take(rest, 7), 1).unwrap!\n"
    "    out = List.concat(out, step.output)\n"
    "    rest = List.drop(rest, step.consumed)\n"
    "  end\n"
    "  again = true\n"
    "  while again\n"
    "    tail = Zlib.deflate_finish(enc, 1).unwrap!\n"
    "    out = List.concat(out, tail.output)\n"
    "    again = not tail.finished\n"
    "  end\n"
    "  Zlib.encoder_close(enc).unwrap!\n"
    "  return out\n"
    "end\n"
    "\n"
    "def inflate_all(packed: List[Int], window_bits: Int) -> List[Int]\n"
    "  dec = Zlib.inflate_init(window_bits, 1073741824, 1073741824).unwrap!\n"
    "  out: List[Int] = []\n"
    "  rest: List[Int] = packed\n"
    "  index = 0\n"
    "  while index < rest.size\n"
    "    step = Zlib.inflate_next(dec, List.take(List.drop(rest, index), 1), 1).unwrap!\n"
    "    if step.consumed == 0 and step.output.size == 0\n"
    '      puts("spin")\n'
    "    end\n"
    "    out = List.concat(out, step.output)\n"
    "    index = index + step.consumed\n"
    "    if step.finished\n"
    "      unused = List.drop(rest, index)\n"
    '      puts("unused #{unused.size}")\n'
    "      index = rest.size\n"
    "    end\n"
    "  end\n"
    "  Zlib.inflate_finish(dec).unwrap!\n"
    "  Zlib.decoder_close(dec).unwrap!\n"
    "  return out\n"
    "end\n"
    "\n"
    "def main() -> Void\n"
    "  data: List[Int] = []\n"
    "  n = System.args()[1].to_i!\n"
    "  i = 0\n"
    "  while i < n\n"
    "    data = data.push((i * 7) % 251)\n"
    "    i = i + 1\n"
    "  end\n"
    "  window: Int = System.args()[2].to_i!\n"
    "  packed = deflate_all(data, window, 6)\n"
    "  back = inflate_all(packed, window)\n"
    "  puts(Test.eq(back, data))\n"
    "end\n"
)


def test_zlib_stream_round_trip_through_1_byte_outputs(tmp_path):
    for window in ("15", "-15", "31"):
        for size in ("0", "3", "70000"):
            result = run_source(tmp_path, "round-%s-%s.agc" % (window, size), STREAM_ROUND_TRIP,
                                ["x", size, window])
            assert result.code == 0, result.stderr
            assert "spin" not in result.stdout, result.stdout
            assert "unused 0" in result.stdout, result.stdout
            assert "ok()" in result.stdout, result.stdout


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


def test_zlib_stream_raw_output_matches_python(tmp_path):
    data = bytes((k * 7) % 251 for k in range(70000))
    target = tmp_path / "raw-out.bin"
    body = (
        "def main() -> Void\n"
        "  data: List[Int] = [%s]\n"
        "  enc = Zlib.deflate_init(-15, 6, 1073741824, 1073741824).unwrap!\n"
        "  out: List[Int] = []\n"
        "  rest: List[Int] = data\n"
        "  while rest.size > 0\n"
        "    step = Zlib.deflate_next(enc, List.take(rest, 1000), 1000).unwrap!\n"
        "    out = List.concat(out, step.output)\n"
        "    rest = List.drop(rest, step.consumed)\n"
        "  end\n"
        "  again = true\n"
        "  while again\n"
        "    tail = Zlib.deflate_finish(enc, 1000).unwrap!\n"
        "    out = List.concat(out, tail.output)\n"
        "    again = not tail.finished\n"
        "  end\n"
        "  Zlib.encoder_close(enc).unwrap!\n"
        '  w = File.open(System.args()[0], "write", 30000).unwrap!\n'
        "  File.write_bytes(w, out, 30000).unwrap!\n"
        "  File.close(w, 30000)\n"
        '  puts("wrote")\n'
        "end\n" % ", ".join(str(b) for b in data)
    )
    result = run_source(tmp_path, "raw-produce.agc", body, [target])
    assert result.code == 0, result.stderr
    assert result.stdout == "wrote\n", result.stdout
    assert zlib.decompress(read_bytes(target), -15) == data


def test_zlib_stream_init_rejects_a_bad_shape(tmp_path):
    # A handle Result has no to_s, so the programs print ok? instead: every
    # bad shape below must read false, except inflate_init with a bad level,
    # which takes no level and stays ok (its window and totals are valid).
    body = (
        "def main() -> Void\n"
        "  puts(Zlib.deflate_init(%s, %s, %s, %s).ok?)\n"
        "  puts(Zlib.inflate_init(%s, %s, %s).ok?)\n"
        "end\n"
    )
    bad_windows = ["0", "8", "16", "47", "-8"]
    bad_levels = ["-1", "10"]
    bad_totals = ["0", "1073741825"]
    cases = [(body % (w, "6", "1073741824", "1073741824", w, "1073741824", "1073741824"),
                "false\nfalse\n") for w in bad_windows]
    cases += [(body % ("15", level, "1073741824", "1073741824", "15", "1073741824", "1073741824"),
                 "false\ntrue\n")
                for level in bad_levels]
    cases += [(body % ("15", "6", total, "1073741824", "15", total, "1073741824"),
                 "false\nfalse\n") for total in bad_totals]
    cases += [(body % ("15", "6", "1073741824", total, "15", "1073741824", total),
                 "false\nfalse\n") for total in bad_totals]
    for index, (case, want) in enumerate(cases):
        result = run_source(tmp_path, "init-%d.agc" % index, case, [])
        assert result.code == 0, result.stderr
        assert result.stdout == want, result.stdout


def test_zlib_stream_next_rejects_a_call_past_its_quantum(tmp_path):
    body = (
        "def main() -> Void\n"
        "  enc = Zlib.deflate_init(15, 6, 1073741824, 1073741824).unwrap!\n"
        "  puts(Zlib.deflate_next(enc, List.repeat(1, 65537), 65536))\n"
        "  puts(Zlib.deflate_next(enc, [1], 0))\n"
        "  puts(Zlib.deflate_next(enc, [1], 65537))\n"
        "  dec = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!\n"
        "  puts(Zlib.inflate_next(dec, List.repeat(1, 65537), 65536))\n"
        "  puts(Zlib.inflate_next(dec, [1], 0))\n"
        "  puts(Zlib.inflate_next(dec, [1], 65537))\n"
        "end\n"
    )
    result = run_source(tmp_path, "quantum.agc", body, [])
    assert result.code == 0, result.stderr
    assert result.stdout.startswith("error("), result.stdout


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


def test_zlib_stream_finish_repeats_until_finished(tmp_path):
    body = (
        "def main() -> Void\n"
        "  enc = Zlib.deflate_init(15, 6, 1073741824, 1073741824).unwrap!\n"
        "  first = Zlib.deflate_next(enc, [1, 2, 3], 65536).unwrap!\n"
        "  out: List[Int] = first.output\n"
        " again = true\n"
        "  rounds = 0\n"
        "  while again\n"
        "    step = Zlib.deflate_finish(enc, 1).unwrap!\n"
        "    out = List.concat(out, step.output)\n"
        "    rounds = rounds + 1\n"
        "    again = not step.finished\n"
        "    if rounds > 100000\n"
        '      puts("finish did not end")\n'
        "      again = false\n"
        "    end\n"
        "  end\n"
        "  puts(Test.eq(Zlib.inflate(out, 1048576).unwrap!, [1, 2, 3]))\n"
        "  Zlib.encoder_close(enc).unwrap!\n"
        "end\n"
    )
    result = run_source(tmp_path, "finish.agc", body, [])
    assert result.code == 0, result.stderr
    assert "did not end" not in result.stdout, result.stdout
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


def test_zlib_stream_close_is_idempotent_and_closes_feed_and_finish(tmp_path):
    body = (
        "def main() -> Void\n"
        "  enc = Zlib.deflate_init(15, 6, 1073741824, 1073741824).unwrap!\n"
        "  puts(Zlib.encoder_close(enc))\n"
        "  puts(Zlib.encoder_close(enc))\n"
        "  puts(Zlib.deflate_next(enc, [1], 65536))\n"
        "  puts(Zlib.deflate_finish(enc, 65536))\n"
        "  dec = Zlib.inflate_init(15, 1073741824, 1073741824).unwrap!\n"
        "  puts(Zlib.decoder_close(dec))\n"
        "  puts(Zlib.decoder_close(dec))\n"
        "  puts(Zlib.inflate_next(dec, [1], 65536))\n"
        "  puts(Zlib.inflate_finish(dec))\n"
        "end\n"
    )
    result = run_source(tmp_path, "close.agc", body, [])
    assert result.code == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0] == "ok()", result.stdout
    assert lines[1] == "ok()", result.stdout
    assert lines[2].startswith("error("), result.stdout
    assert lines[3].startswith("error("), result.stdout
    assert lines[4] == "ok()", result.stdout
    assert lines[5] == "ok()", result.stdout
    assert lines[6].startswith("error("), result.stdout
    assert lines[7].startswith("error("), result.stdout


def test_zlib_stream_enforces_the_total_caps(tmp_path):
    data = bytes((k * 3) % 251 for k in range(1000))
    packed = zlib.compress(data)
    in_text = ", ".join(str(b) for b in data)
    packed_text = ", ".join(str(b) for b in packed)
    body = (
        "def main() -> Void\n"
        "  data: List[Int] = [%s]\n"
        "  packed: List[Int] = [%s]\n"
        "  enc = Zlib.deflate_init(15, 6, %d, 1073741824).unwrap!\n"
        "  puts(Zlib.deflate_next(enc, data, 65536))\n"
        "  over = Zlib.deflate_next(enc, [9], 65536)\n"
        "  puts(over.ok?)\n"
        "  Zlib.encoder_close(enc).unwrap!\n"
        "  dec = Zlib.inflate_init(15, %d, %d).unwrap!\n"
        # The totals precheck is quantum-based by contract (safe but strict):
        # the first feed asks for exactly the remaining total, so the call is
        # admitted and its real output fits; a full 65536 quantum here would
        # be refused even though the bytes would fit.
        "  puts(Zlib.inflate_next(dec, packed, %d))\n"
        "  puts(Zlib.inflate_next(dec, [9], 65536).ok?)\n"
        "  Zlib.decoder_close(dec).unwrap!\n"
        "end\n" % (in_text, packed_text, len(data), len(packed), len(data), len(data))
    )
    result = run_source(tmp_path, "totals.agc", body, [])
    assert result.code == 0, result.stderr
    lines = result.stdout.splitlines()
    assert lines[0].startswith("ok("), result.stdout
    assert lines[1] == "false", result.stdout
    assert lines[2].startswith("ok("), result.stdout
    assert lines[3] == "false", result.stdout


def test_zlib_stream_moves_across_tasks_with_spawn_owning(tmp_path):
    body = (
        "def squeeze(enc: ZlibEncoder) -> List[Int]\n"
        "  step = Zlib.deflate_next(enc, [104, 105], 65536).unwrap!\n"
        "  tail = Zlib.deflate_finish(enc, 65536).unwrap!\n"
        "  Zlib.encoder_close(enc).unwrap!\n"
        "  return List.concat(step.output, tail.output)\n"
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  enc = Zlib.deflate_init(15, 6, 1073741824, 1073741824).unwrap!\n"
        "  t: Task[List[Int]] = Task.spawn_owning(&squeeze, enc)\n"
        "  packed = Task.await(t)\n"
        "  puts(Test.eq(Zlib.inflate(packed, 1048576).unwrap!, [104, 105]))\n"
        "end\n"
    )
    result = run_source(tmp_path, "owning.agc", body, [])
    assert result.code == 0, result.stderr
    assert result.stdout == "ok()\n", result.stdout


def test_zlib_stream_used_from_the_wrong_task_halts(tmp_path):
    body = (
        "def hold(enc: ZlibEncoder) -> Int\n"
        "  Task.sleep(200)\n"
        "  return 1\n"
        "end\n"
        "\n"
        "def main() -> Void\n"
        "  enc = Zlib.deflate_init(15, 6, 1073741824, 1073741824).unwrap!\n"
        # Feeding while the holder still owns the handle halts; awaiting
        # first would only see the owner-end close after the holder ends.
        "  t = Task.spawn_owning(&hold, enc)\n"
        "  puts(Zlib.deflate_next(enc, [1], 65536))\n"
        "  Task.await(t)\n"
        "end\n"
    )
    source = tmp_path / "wrong-task.agc"
    source.write_text(body, encoding="utf-8")
    result = run(cli() + ["--json", str(source)], env=vm_environment())
    assert result.code == 1, result.stdout
    assert "RUNTIME-HANDLE-NOT-OWNED" in result.stderr, result.stderr


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
