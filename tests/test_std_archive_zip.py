"""std/archive extract_zip: the bounded explicit-allowlist ZIP32 extractor.

Peers: Python's struct, zlib and binascii only; every archive is hand-built
byte by byte (no zipfile writer), and small generated Agentica drivers run
through the CLI in temp directories. Expected outputs name the exact
`error(...)` text of std/archive. File contents that must match byte for
byte are compared with binascii/zlib peers, never with zipfile reads.
"""
import binascii
import os
import pathlib

import pytest
import struct
import zlib

from tests.agentica_test import ROOT, binary, run, vm_environment

SIG_LOCAL = b"PK\x03\x04"
SIG_CD = b"PK\x01\x02"
SIG_EOCD = b"PK\x05\x06"
SIG_DS = b"PK\x07\x08"
DESC_MAGIC = 0x08074B50
MADE_BY = 0x031E
NEED = 20
REGULAR = (0o100644 << 16)
SYMLINK = (0o120777 << 16)
DIRECTORY = (0o040755 << 16) | 0x10

STORED_HELLO = b"stored data"
DEEP_DATA = bytes(range(256)) * 3
NESTED_DATA = bytes(range(256)) * 4
HELLO_WORLD = b"hello zip world"


def raw_deflate(data, level=6):
    """Raw deflate bytes (method 8), the peer of the streaming decoder."""
    compressor = zlib.compressobj(level, zlib.DEFLATED, -15)
    return compressor.compress(data) + compressor.flush()


def crc_forced_bytes(want):
    """Four bytes whose CRC32 is `want`: the affine map of four input bytes
    is a bijection, so one 32x32 GF(2) solve inverts it. Verified below."""
    base = binascii.crc32(b"\x00" * 4)
    columns = []
    for i in range(32):
        tweak = bytearray(b"\x00" * 4)
        tweak[i // 8] |= 1 << (i % 8)
        columns.append(base ^ binascii.crc32(bytes(tweak)))
    target = base ^ want
    masks = []
    for row in range(32):
        mask = 0
        for column in range(32):
            if (columns[column] >> row) & 1:
                mask |= 1 << column
        masks.append([mask, (target >> row) & 1])
    where = [-1] * 32
    line = 0
    for column in range(32):
        pick = -1
        for i in range(line, 32):
            if (masks[i][0] >> column) & 1:
                pick = i
                break
        if pick == -1:
            continue
        masks[line], masks[pick] = masks[pick], masks[line]
        where[column] = line
        for i in range(32):
            if i != line and (masks[i][0] >> column) & 1:
                masks[i][0] ^= masks[line][0]
                masks[i][1] ^= masks[line][1]
        line += 1
    solution = 0
    for column in range(32):
        if where[column] != -1 and masks[where[column]][1]:
            solution |= 1 << column
    found = solution.to_bytes(4, "little")
    assert binascii.crc32(found) == want
    return found


class Spec:
    """One archive member: the knobs the builder turns into bytes."""

    def __init__(self, name, data=b"", method=8, flags=0, attrs=REGULAR,
                 local_extra=b"", cd_extra=b"", descriptor="auto", need=NEED):
        self.name = name
        self.data = data
        self.method = method
        self.flags = flags
        self.attrs = attrs
        self.local_extra = local_extra
        self.cd_extra = cd_extra
        self.descriptor = descriptor
        self.need = need


def assemble(specs, comment=b"", made_by=MADE_BY):
    """Build (blob, layout) for `specs`: locals in order, then the central
    directory, then the end record. `layout` records every offset so tests
    can patch bytes. `descriptor` is "auto" (12 bytes, or 16 with the magic
    when bit 3 is set), "sig16", None, or raw bytes.
    """
    locals_blob = b""
    central = b""
    offsets = []
    for spec in specs:
        if spec.method == 0:
            payload = spec.data
        else:
            payload = raw_deflate(spec.data)
        crc = binascii.crc32(spec.data)
        csize = len(payload)
        usize = len(spec.data)
        local_sizes = (0, 0, 0) if spec.flags & 0x08 else (crc, csize, usize)
        head = struct.pack("<IHHHHHIIIHH", 0x04034B50, spec.need, spec.flags,
                           spec.method, 0, 0, *local_sizes, len(spec.name), len(spec.local_extra))
        descriptor = b""
        if spec.flags & 0x08:
            if spec.descriptor == "auto":
                descriptor = struct.pack("<III", crc, csize, usize)
            elif spec.descriptor == "sig16":
                descriptor = struct.pack("<IIII", DESC_MAGIC, crc, csize, usize)
            elif spec.descriptor is not None:
                descriptor = spec.descriptor
        offsets.append(len(locals_blob))
        locals_blob += head + spec.name + spec.local_extra + payload + descriptor
        central += struct.pack("<IHHHHHHIIIHHHHHII", 0x02014B50, made_by, spec.need, spec.flags,
                               spec.method, 0, 0, crc, csize, usize, len(spec.name),
                               len(spec.cd_extra), 0, 0, 0, spec.attrs, offsets[-1])
        central += spec.name + spec.cd_extra
    cd_offset = len(locals_blob)
    blob = locals_blob + central
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, len(specs), len(specs),
                      len(central), cd_offset, len(comment)) + comment
    layout = {"locals": locals_blob, "central": central, "offsets": offsets,
              "cd_offset": cd_offset, "eocd": len(blob)}
    return blob + end, layout


def esc(text):
    return text.replace("\\", "\\\\").replace('"', '\\"')


def quoted(members):
    return ", ".join('"%s"' % esc(member) for member in members)


def options(timeout=30000, max_out=268435456):
    return "Archive.Options(timeout_ms: %d, max_output_bytes: %d)" % (timeout, max_out)


def program(label, src, members, dest, opts):
    return (
        'import Archive from "std/archive"\n'
        "\n"
        "def flat(text: String) -> String\n"
        '  return String.join(String.split(text, String.from_code(10)), " | ")\n'
        "end\n"
        "\n"
        "def show(tag: String, r: Result[List[Int]]) -> Void\n"
        "  case r\n"
        '    ok(counts) -> puts("#{tag} ok #{counts}")\n'
        '    error(message) -> puts("#{tag} error #{flat(message)}")\n'
        "  end\n"
        "end\n"
        "\n"
        "def main() -> Void\n"
        '  show("%s", Archive.extract_zip("%s", [%s], "%s", %s))\n'
        "end\n" % (label, esc(src), quoted(members), esc(dest), opts)
    )


def run_zip(work, name, src, members, dest, opts="Archive.options()"):
    path = work / (name + ".agc")
    path.write_text(program(name, src, members, dest, opts), encoding="utf-8")
    result = run([str(binary()), str(path)], cwd=work, env=vm_environment())
    assert result.code == 0, "%s: %s" % (name, result.stderr)
    assert result.stderr == "", name
    return result.stdout.split("\n")


def stored_case(work):
    blob, _ = assemble([
        Spec(b"plain.txt", STORED_HELLO, method=0),
        Spec(b"empty.txt", b"", method=0),
        Spec(b"sub/deep.bin", DEEP_DATA, method=0),
    ])
    (work / "stored.zip").write_bytes(blob)


def deflated_case(work):
    blob, _ = assemble([
        Spec(b"hello.txt", HELLO_WORLD),
        Spec(b"sub/nested.bin", NESTED_DATA),
        Spec(b"empty.txt", b""),
    ])
    (work / "deflated.zip").write_bytes(blob)


def test_stored_and_deflated_roundtrips_keep_order_and_counts(tmp_path):
    work = tmp_path
    stored_case(work)
    deflated_case(work)
    lines = run_zip(work, "stored", "stored.zip",
                    ["sub/deep.bin", "plain.txt", "empty.txt"], "o1")
    assert lines == ["stored ok [%d, %d, 0]" % (len(DEEP_DATA), len(STORED_HELLO)), ""]
    assert (work / "o1" / "plain.txt").read_bytes() == STORED_HELLO
    assert (work / "o1" / "empty.txt").read_bytes() == b""
    assert (work / "o1" / "sub" / "deep.bin").read_bytes() == DEEP_DATA
    lines = run_zip(work, "deflated", "deflated.zip",
                    ["sub/nested.bin", "hello.txt", "empty.txt"], "o2")
    assert lines == ["deflated ok [%d, %d, 0]" % (len(NESTED_DATA), len(HELLO_WORLD)), ""]
    assert (work / "o2" / "hello.txt").read_bytes() == HELLO_WORLD
    assert (work / "o2" / "sub" / "nested.bin").read_bytes() == NESTED_DATA


def test_dot_prefix_selects_the_same_member(tmp_path):
    work = tmp_path
    deflated_case(work)
    lines = run_zip(work, "order", "deflated.zip",
                    ["empty.txt", "./sub/nested.bin", "hello.txt"], "o1",
                    options(max_out=2000))
    assert lines == ["order ok [0, %d, %d]" % (len(NESTED_DATA), len(HELLO_WORLD)), ""]
    assert (work / "o1" / "empty.txt").read_bytes() == b""


def test_unicode_flag_and_unflagged_ascii_names(tmp_path):
    work = tmp_path
    name = "café-日本語.txt".encode("utf-8")
    content = "héllo".encode("utf-8")
    blob, _ = assemble([
        Spec(name, content, flags=0x800),
        Spec(b"plain-ascii.txt", b"ascii"),
        Spec(b"unselected.bin", b"z" * 1000),
    ])
    (work / "u.zip").write_bytes(blob)
    lines = run_zip(work, "utf8", "u.zip", ["café-日本語.txt", "plain-ascii.txt"], "o1")
    assert lines == ["utf8 ok [%d, 5]" % len(content), ""]
    assert (work / "o1" / "café-日本語.txt").read_bytes() == content
    assert sorted(path.name for path in (work / "o1").iterdir()) == ["café-日本語.txt", "plain-ascii.txt"]


def test_non_utf8_names_are_refused_never_misdecoded(tmp_path):
    work = tmp_path
    blob, _ = assemble([Spec("caf\xe9".encode("latin-1"), b"latin")])
    (work / "cp437.zip").write_bytes(blob)
    lines = run_zip(work, "cp437", "cp437.zip", ["cafe"], "o1")
    assert lines == ["cp437 error archive: non-ASCII names need the UTF-8 flag at entry 1", ""]
    blob, _ = assemble([Spec(b"bad-\xff-name", b"x", flags=0x800)])
    (work / "bad.zip").write_bytes(blob)
    lines = run_zip(work, "bad", "bad.zip", ["x"], "o1")
    assert lines == ["bad error archive: entry name is not valid UTF-8 at entry 1", ""]
    blob, _ = assemble([Spec(b"ok.txt", b"y"), Spec("caf\xe9".encode("latin-1"), b"z")])
    (work / "unselected.zip").write_bytes(blob)
    lines = run_zip(work, "unsel", "unselected.zip", ["ok.txt"], "o1")
    assert lines == ["unsel error archive: non-ASCII names need the UTF-8 flag at entry 2", ""]


def test_empty_files_verify_zero_crc(tmp_path):
    work = tmp_path
    blob, _ = assemble([
        Spec(b"e0.txt", b"", method=0),
        Spec(b"e8.txt", b"", method=8),
    ])
    (work / "empty.zip").write_bytes(blob)
    lines = run_zip(work, "empty", "empty.zip", ["e0.txt", "e8.txt"], "o1")
    assert lines == ["empty ok [0, 0]", ""]
    assert (work / "o1" / "e0.txt").read_bytes() == b""
    assert (work / "o1" / "e8.txt").read_bytes() == b""


def test_selected_crc_and_size_mismatches_fail(tmp_path):
    work = tmp_path
    data = b"0123456789ABCDEF"
    blob, _ = assemble([Spec(b"a.txt", data)])
    (work / "good.zip").write_bytes(blob)
    changed = bytearray(data)
    changed[3] ^= 0xFF
    blob, layout = assemble([Spec(b"a.txt", bytes(changed))])
    bad = bytearray(blob)
    struct.pack_into("<I", bad, layout["offsets"][0] + 14, binascii.crc32(data))
    struct.pack_into("<I", bad, layout["cd_offset"] + 16, binascii.crc32(data))
    (work / "badcrc.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "crc", "badcrc.zip", ["a.txt"], "o1")
    assert lines == ["crc error archive: CRC32 mismatch for a.txt: expected %d, got %d"
                     % (binascii.crc32(data), binascii.crc32(bytes(changed))), ""]
    bad = bytearray(blob)
    bad[layout["offsets"][0] + 30 + len(b"a.txt")] ^= 0xFF
    (work / "baddeflate.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "baddeflate", "baddeflate.zip", ["a.txt"], "o4")
    assert lines[0].startswith("baddeflate error archive: deflate data is invalid for a.txt")
    blob, layout = assemble([Spec(b"b.txt", data)])
    bad = bytearray(blob)
    struct.pack_into("<I", bad, layout["offsets"][0] + 22, len(data) + 1)
    struct.pack_into("<I", bad, layout["cd_offset"] + 24, len(data) + 1)
    (work / "badsize.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "size", "badsize.zip", ["b.txt"], "o2")
    assert lines == ["size error archive: size mismatch for b.txt: expected %d, got %d"
                     % (len(data) + 1, len(data)), ""]
    blob, layout = assemble([Spec(b"c.txt", data, method=0)])
    bad = bytearray(blob)
    struct.pack_into("<I", bad, layout["offsets"][0] + 14, 0x12345678)
    struct.pack_into("<I", bad, layout["cd_offset"] + 16, 0x12345678)
    (work / "badcrc0.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "crc0", "badcrc0.zip", ["c.txt"], "o3")
    assert lines == ["crc0 error archive: CRC32 mismatch for c.txt: expected 305419896, got %d"
                     % binascii.crc32(data), ""]


def test_data_descriptors_with_and_without_magic(tmp_path):
    work = tmp_path
    first = b"twelve-byte descriptor, no magic"
    second = b"sixteen-byte descriptor, magic-led"
    blob, _ = assemble([
        Spec(b"s12.txt", first, flags=0x08),
        Spec(b"s16.txt", second, flags=0x08, descriptor="sig16"),
    ])
    (work / "desc.zip").write_bytes(blob)
    lines = run_zip(work, "desc", "desc.zip", ["s12.txt", "s16.txt"], "o1")
    assert lines == ["desc ok [%d, %d]" % (len(first), len(second)), ""]
    assert (work / "o1" / "s12.txt").read_bytes() == first
    assert (work / "o1" / "s16.txt").read_bytes() == second


def test_crc_equal_to_the_descriptor_magic_resolves_by_bounds(tmp_path):
    work = tmp_path
    forced = crc_forced_bytes(DESC_MAGIC)
    after = b"offsets stay exact past a magic CRC"
    blob, _ = assemble([
        Spec(b"magic.bin", forced, method=0, flags=0x08),
        Spec(b"after.txt", after),
    ])
    (work / "magic.zip").write_bytes(blob)
    lines = run_zip(work, "magic", "magic.zip", ["magic.bin", "after.txt"], "o1")
    assert lines == ["magic ok [%d, %d]" % (len(forced), len(after)), ""]
    assert (work / "o1" / "magic.bin").read_bytes() == forced
    assert (work / "o1" / "after.txt").read_bytes() == after
    after2 = b"sixteen-byte form"
    blob, _ = assemble([
        Spec(b"magic16.bin", forced, method=0, flags=0x08, descriptor="sig16"),
        Spec(b"after2.txt", after2),
    ])
    (work / "magic16.zip").write_bytes(blob)
    lines = run_zip(work, "magic16", "magic16.zip", ["magic16.bin", "after2.txt"], "o2")
    assert lines == ["magic16 ok [%d, %d]" % (len(forced), len(after2)), ""]


def test_bad_descriptors_fail(tmp_path):
    work = tmp_path
    blob, layout = assemble([Spec(b"a.txt", b"stored descriptor", method=0, flags=0x08),
                             Spec(b"b.txt", b"second", method=0)])
    bad = bytearray(blob)
    bad[layout["offsets"][0] + 30 + len(b"a.txt") + len(b"stored descriptor") + 8] ^= 0x01
    (work / "baddesc.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "baddesc", "baddesc.zip", ["a.txt", "b.txt"], "o1")
    assert lines == ["baddesc error archive: bad data descriptor for a.txt", ""]
    blob, layout = assemble([Spec(b"a.txt", b"deflated descriptor here", flags=0x08),
                             Spec(b"b.txt", b"second")])
    bad = bytearray(blob)
    csize = len(raw_deflate(b"deflated descriptor here"))
    bad[layout["offsets"][0] + 30 + len(b"a.txt") + csize + 8] ^= 0x01
    (work / "baddesc8.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "baddesc8", "baddesc8.zip", ["a.txt"], "o4")
    assert lines == ["baddesc8 error archive: bad data descriptor for a.txt", ""]
    blob, _ = assemble([Spec(b"a.txt", b"data here now", flags=0x08, descriptor=b"\x00" * 12),
                        Spec(b"b.txt", b"second")])
    (work / "zerodesc.zip").write_bytes(blob)
    lines = run_zip(work, "zerodesc", "zerodesc.zip", ["a.txt"], "o5")
    assert lines == ["zerodesc error archive: bad data descriptor for a.txt", ""]


def test_unselected_wrong_checksums_are_never_inflated(tmp_path):
    work = tmp_path
    blob, layout = assemble([
        Spec(b"good.txt", b"checked"),
        Spec(b"unchecked.bin", b"payload here"),
    ])
    bad = bytearray(blob)
    second = layout["offsets"][1]
    second_cd = layout["cd_offset"] + 46 + len(b"good.txt")
    struct.pack_into("<I", bad, second + 14, 0xDEADBEEF)
    struct.pack_into("<I", bad, second_cd + 16, 0xDEADBEEF)
    (work / "unchecked.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "unchecked", "unchecked.zip", ["good.txt"], "o1")
    assert lines == ["unchecked ok [7]", ""]
    assert (work / "o1" / "good.txt").read_bytes() == b"checked"
    assert sorted(path.name for path in (work / "o1").iterdir()) == ["good.txt"]


def test_unselected_bad_descriptor_still_fails_structurally(tmp_path):
    work = tmp_path
    blob, _ = assemble([
        Spec(b"good.txt", b"checked"),
        Spec(b"skip.txt", b"skipped payload", flags=0x08, descriptor=b"\x00" * 12),
    ])
    (work / "skipdesc.zip").write_bytes(blob)
    lines = run_zip(work, "skipdesc", "skipdesc.zip", ["good.txt"], "o1")
    assert lines == ["skipdesc error archive: bad data descriptor for skip.txt", ""]


def test_missing_and_duplicate_members(tmp_path):
    work = tmp_path
    deflated_case(work)
    lines = run_zip(work, "missing", "deflated.zip", ["hello.txt", "gone.txt"], "o1")
    assert lines == ["missing error archive: member not found: gone.txt", ""]
    lines = run_zip(work, "missingdot", "deflated.zip", ["./gone.txt"], "o2")
    assert lines == ["missingdot error archive: member not found: ./gone.txt", ""]
    blob, _ = assemble([Spec(b"dup.txt", b"first"), Spec(b"dup.txt", b"second")])
    (work / "dup.zip").write_bytes(blob)
    lines = run_zip(work, "dup", "dup.zip", ["dup.txt"], "o3")
    assert lines == ["dup error archive: the same archive holds dup.txt twice", ""]


def test_corruption_after_a_selected_file_still_fails(tmp_path):
    work = tmp_path
    blob, layout = assemble([Spec(b"first.txt", b"selected first", method=0),
                             Spec(b"second.txt", b"selected second", method=0)])
    bad = bytearray(blob)
    bad[layout["offsets"][1]] ^= 0xFF
    (work / "latebad.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "latebad", "latebad.zip", ["first.txt", "second.txt"], "o1")
    assert lines == ["latebad error archive: bad local header at offset %d" % layout["offsets"][1], ""]
    assert (work / "o1" / "first.txt").read_bytes() == b"selected first"
    blob, layout = assemble([Spec(b"first.txt", b"selected first", method=0),
                             Spec(b"second.txt", b"selected second", method=0)])
    bad = bytearray(blob)
    second_head = layout["cd_offset"] + 46 + len(b"first.txt")
    bad[second_head + 28] = 6
    (work / "latecd.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "latecd", "latecd.zip", ["first.txt"], "o2")
    assert lines == ["latecd error archive: the central directory holds 107 of 111 bytes", ""]


def test_end_record_rules(tmp_path):
    work = tmp_path
    deflated_case(work)
    blob = (work / "deflated.zip").read_bytes()
    (work / "notzip.bin").write_bytes(b"this is not a zip file at all....")
    (work / "empty.zip").write_bytes(b"")
    (work / "short.zip").write_bytes(b"PK\x03\x04")
    (work / "trailing.zip").write_bytes(blob + b"\x00")
    bad = bytearray(blob)
    struct.pack_into("<H", bad, len(bad) - 2, 3)
    (work / "commentlen.zip").write_bytes(bytes(bad))
    (work / "comment.zip").write_bytes(blob[:-22] + blob[-22:-2] + struct.pack("<H", 4) + b"hey!")
    lines = run_zip(work, "notzip", "notzip.bin", ["a"], "o1")
    assert lines == ["notzip error archive: the end of the central directory was not found: notzip.bin", ""]
    lines = run_zip(work, "empty", "empty.zip", ["a"], "o2")
    assert lines == ["empty error archive: empty.zip is empty, not a ZIP archive", ""]
    lines = run_zip(work, "short", "short.zip", ["a"], "o3")
    assert lines == ["short error archive: short.zip is not a ZIP archive", ""]
    lines = run_zip(work, "trailing", "trailing.zip", ["hello.txt"], "o4")
    assert lines == ["trailing error archive: the end record does not end the file", ""]
    lines = run_zip(work, "commentlen", "commentlen.zip", ["hello.txt"], "o5")
    assert lines == ["commentlen error archive: the end record does not end the file", ""]
    lines = run_zip(work, "comment", "comment.zip", ["hello.txt"], "oc")
    assert lines == ["comment ok [%d]" % len(HELLO_WORLD), ""]


def test_multidisk_and_zip64_are_refused(tmp_path):
    work = tmp_path
    deflated_case(work)
    blob = (work / "deflated.zip").read_bytes()
    eocd = blob.rfind(SIG_EOCD)
    bad = bytearray(blob)
    struct.pack_into("<H", bad, eocd + 4, 1)
    (work / "disk.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "disk", "disk.zip", ["hello.txt"], "o1")
    assert lines == ["disk error archive: multi-disk archives are not supported: disk.zip", ""]
    bad = bytearray(blob)
    struct.pack_into("<H", bad, eocd + 8, 1)
    (work / "diskcount.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "diskcount", "diskcount.zip", ["hello.txt"], "o2")
    assert lines == ["diskcount error archive: multi-disk archives are not supported: diskcount.zip", ""]
    bad = bytearray(blob)
    struct.pack_into("<I", bad, eocd + 12, 0xFFFFFFFF)
    (work / "zip64eo.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "zip64eo", "zip64eo.zip", ["hello.txt"], "o3")
    assert lines == ["zip64eo error archive: ZIP64 is not supported: zip64eo.zip", ""]
    blob, _ = assemble([Spec(b"a.txt", b"data", cd_extra=b"\x01\x00\x00\x00")])
    (work / "zip64x.zip").write_bytes(blob)
    lines = run_zip(work, "zip64x", "zip64x.zip", ["a.txt"], "o4")
    assert lines == ["zip64x error archive: ZIP64 is not supported at entry 1", ""]
    blob, _ = assemble([Spec(b"a.txt", b"data", local_extra=b"\x01\x00\x00\x00")])
    (work / "zip64l.zip").write_bytes(blob)
    lines = run_zip(work, "zip64l", "zip64l.zip", ["a.txt"], "o5")
    assert lines == ["zip64l error archive: ZIP64 is not supported at entry 1", ""]


def test_central_directory_rules(tmp_path):
    work = tmp_path
    blob, layout = assemble([Spec(b"a.txt", b"data", method=0)])
    cases = []
    bad = bytearray(blob)
    bad[layout["cd_offset"]] ^= 0xFF
    cases.append(("badmagic", bytes(bad), "bad central directory entry at entry 1"))
    bad = bytearray(blob)
    struct.pack_into("<H", bad, layout["cd_offset"] + 8, 0x0001)
    cases.append(("encrypted", bytes(bad), "encrypted entries are not supported at entry 1"))
    bad = bytearray(blob)
    struct.pack_into("<H", bad, layout["cd_offset"] + 8, 0x4000)
    cases.append(("badflags", bytes(bad), "unsupported flags 16384 at entry 1"))
    bad = bytearray(blob)
    struct.pack_into("<H", bad, layout["cd_offset"] + 10, 12)
    cases.append(("badmethod", bytes(bad), "unsupported method 12 at entry 1"))
    bad = bytearray(blob)
    struct.pack_into("<H", bad, layout["cd_offset"] + 6, 64)
    cases.append(("badversion", bytes(bad), "unsupported version 64 at entry 1"))
    bad = bytearray(blob)
    struct.pack_into("<H", bad, layout["cd_offset"] + 34, 2)
    cases.append(("baddisk", bytes(bad), "multi-disk archives are not supported at entry 1"))
    for label, data, needle in cases:
        (work / (label + ".zip")).write_bytes(data)
        lines = run_zip(work, label, label + ".zip", ["a.txt"], "o_" + label)
        assert lines == ["%s error archive: %s" % (label, needle), ""], lines
    long_blob, _ = assemble([Spec(b"x" * 1025, b"data", method=0)])
    (work / "longname.zip").write_bytes(long_blob)
    lines = run_zip(work, "longname", "longname.zip", ["x"], "ol")
    assert lines == ["longname error archive: entry name is too long at entry 1", ""]
    dup_blob, layout2 = assemble([Spec(b"a.txt", b"one", method=0), Spec(b"b.txt", b"two", method=0)])
    bad = bytearray(dup_blob)
    struct.pack_into("<I", bad, layout2["cd_offset"] + 51 + 42, layout2["offsets"][0])
    (work / "dupoff.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "dupoff", "dupoff.zip", ["a.txt"], "od")
    assert lines == ["dupoff error archive: duplicate local offset 0 at entry 2", ""]


def test_local_records_must_be_contiguous(tmp_path):
    work = tmp_path
    blob, layout = assemble([Spec(b"a.txt", b"0123456789", method=0),
                             Spec(b"b.txt", b"data", method=0)])
    bad = bytearray(b"\x00" * 10 + blob)
    eocd = bytes(bad).rfind(SIG_EOCD)
    struct.pack_into("<I", bad, eocd + 16, layout["cd_offset"] + 10)
    struct.pack_into("<I", bad, layout["cd_offset"] + 10 + 42, 10)
    struct.pack_into("<I", bad, layout["cd_offset"] + 10 + 51 + 42, 10 + 45)
    (work / "sfx.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "sfx", "sfx.zip", ["a.txt"], "o1")
    assert lines == ["sfx error archive: the archive does not start with a local header", ""]
    bad = bytearray(blob)
    struct.pack_into("<I", bad, layout["cd_offset"] + 51 + 42, layout["offsets"][1] + 5)
    (work / "gap.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "gap", "gap.zip", ["a.txt", "b.txt"], "o2")
    assert lines == ["gap error archive: local records overlap or leave a gap at offset 45", ""]
    bad = bytearray(blob)
    bad[layout["offsets"][1]] ^= 0xFF
    (work / "localmagic.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "localmagic", "localmagic.zip", ["a.txt"], "o3")
    assert lines == ["localmagic error archive: bad local header at offset 45", ""]
    bad = bytearray(blob)
    bad[layout["offsets"][1] + 30 + 1] ^= 0xFF
    (work / "localname.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "localname", "localname.zip", ["b.txt"], "o4")
    assert lines == ["localname error archive: local and central names differ at entry 2", ""]
    bad = bytearray(blob)
    struct.pack_into("<I", bad, layout["offsets"][1] + 18, 999)
    (work / "localsize.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "localsize", "localsize.zip", ["b.txt"], "o5")
    assert lines == ["localsize error archive: local and central sizes differ at entry 2", ""]
    bad = bytearray(blob)
    bad[layout["offsets"][1] + 6] ^= 0x08
    (work / "localflags.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "localflags", "localflags.zip", ["b.txt"], "o6")
    assert lines == ["localflags error archive: local and central flags differ at entry 2", ""]


def test_out_of_order_central_directory_still_extracts(tmp_path):
    work = tmp_path
    blob, _ = assemble([Spec(b"a.txt", b"first file", method=0),
                        Spec(b"sub/b.txt", b"second file", method=0)])
    split = blob.find(SIG_CD)
    eocd_at = blob.rfind(SIG_EOCD)
    locals_blob = blob[:split]
    first_len = 46 + len(b"a.txt")
    reordered = blob[split + first_len:eocd_at] + blob[split:split + first_len]
    (work / "reorder.zip").write_bytes(locals_blob + reordered + blob[eocd_at:])
    lines = run_zip(work, "reorder", "reorder.zip", ["sub/b.txt", "a.txt"], "o1")
    assert lines == ["reorder ok [11, 10]", ""]
    assert (work / "o1" / "a.txt").read_bytes() == b"first file"


def test_selected_non_regular_files_are_errors(tmp_path):
    work = tmp_path
    target = b"link-target"
    blob, _ = assemble([
        Spec(b"file.txt", b"regular", method=0),
        Spec(b"dir/", b"", method=0, attrs=DIRECTORY),
        Spec(b"link", target, method=0, attrs=SYMLINK),
        Spec(b"dosdir", b"", method=0, attrs=0x10),
        Spec(b"blk", b"", method=0, attrs=(0o060644 << 16)),
    ])
    (work / "kinds.zip").write_bytes(blob)
    lines = run_zip(work, "dir", "kinds.zip", ["dir"], "o1")
    assert lines == ["dir error archive: member is not a regular file: dir", ""]
    lines = run_zip(work, "link", "kinds.zip", ["link"], "o2")
    assert lines == ["link error archive: member is not a regular file: link", ""]
    lines = run_zip(work, "dosdir", "kinds.zip", ["dosdir"], "o3")
    assert lines == ["dosdir error archive: member is not a regular file: dosdir", ""]
    lines = run_zip(work, "blk", "kinds.zip", ["blk"], "o4")
    assert lines == ["blk error archive: member is not a regular file: blk", ""]
    lines = run_zip(work, "file", "kinds.zip", ["file.txt"], "o5")
    assert lines == ["file ok [7]", ""]
    assert sorted(path.name for path in (work / "o5").iterdir()) == ["file.txt"]
    assert (work / "o1").is_dir() and not any((work / "o1").iterdir())


def test_unsafe_and_repeated_members_are_refused_before_io(tmp_path):
    work = tmp_path
    stored_case(work)
    long_member = "x" * 1025
    cases = [
        ("empty", [], "members must select 1..256 files"),
        ("many", ["f%d.txt" % i for i in range(257)], "members must select 1..256 files"),
        ("dup", ["plain.txt", "plain.txt"], "members select the same file twice: plain.txt"),
        ("normdup", ["./plain.txt", "plain.txt"], "members select the same file twice: plain.txt"),
        ("casedup", ["plain.txt", "PLAIN.TXT"],
         "members collide on a case-insensitive system: plain.txt and PLAIN.TXT"),
        ("abs", ["/abs.txt"], "member /abs.txt is absolute"),
        ("dots", ["../up.txt"], "member ../up.txt is not a safe relative path"),
        ("dotseg", ["a/./b.txt"], "member a/./b.txt is not a safe relative path"),
        ("slash", ["a//b.txt"], "member a//b.txt is not a safe relative path"),
        ("back", ["a\\b.txt"], "member a\\b.txt holds a portable separator"),
        ("colon", ["a:b.txt"], "member a:b.txt holds a portable separator"),
        ("drive", ["C:x.txt"], "member C:x.txt holds a portable separator"),
        ("root", ["."], "a member must name a file, not the root: ."),
        ("rootslash", ["./"], "a member must name a file, not the root: ./"),
        ("toolong", [long_member], "member is too long: " + long_member),
    ]
    for label, members, needle in cases:
        lines = run_zip(work, label, "stored.zip", members, "o_" + label)
        assert lines == ["%s error archive: %s" % (label, needle), ""], lines
        assert not (work / ("o_" + label)).exists()


def test_destination_rules_and_case_collisions(tmp_path):
    work = tmp_path
    stored_case(work)
    (work / "exists").mkdir()
    lines = run_zip(work, "exists", "stored.zip", ["plain.txt"], "exists")
    assert lines[0].startswith("exists error archive: cannot create exists: ")
    lines = run_zip(work, "noparent", "stored.zip", ["plain.txt"], "nodir/o1")
    assert lines[0].startswith("noparent error archive: cannot create nodir/o1: ")
    blob, _ = assemble([
        Spec(b"sub/k.txt", b"nested", method=0),
        Spec(b"SUB", b"clashing file", method=0),
    ])
    (work / "clash.zip").write_bytes(blob)
    lines = run_zip(work, "clash1", "clash.zip", ["sub/k.txt", "SUB"], "o1")
    assert lines[0].startswith("clash1 error archive: selected files collide on a case-insensitive system: o1/")
    lines = run_zip(work, "clash2", "clash.zip", ["SUB", "sub/k.txt"], "o2")
    assert lines[0].startswith("clash2 error archive: selected files collide on a case-insensitive system: o2/")
    blob, _ = assemble([
        Spec(b"sub", b"a file", method=0),
        Spec(b"sub/k.txt", b"nested", method=0),
    ])
    (work / "fileparent.zip").write_bytes(blob)
    lines = run_zip(work, "fileparent", "fileparent.zip", ["sub", "sub/k.txt"], "o3")
    assert lines[0].startswith("fileparent error archive: cannot create o3/sub/k.txt: ")


def test_option_ranges_and_output_caps(tmp_path):
    work = tmp_path
    stored_case(work)
    lines = run_zip(work, "t0", "stored.zip", ["plain.txt"], "o1", options(timeout=0))
    assert lines == ["t0 error archive: options.timeout_ms must be 1..86400000", ""]
    lines = run_zip(work, "tbig", "stored.zip", ["plain.txt"], "o1", options(timeout=86400001))
    assert lines == ["tbig error archive: options.timeout_ms must be 1..86400000", ""]
    lines = run_zip(work, "m0", "stored.zip", ["plain.txt"], "o1", options(max_out=0))
    assert lines == ["m0 error archive: options.max_output_bytes must be 1..1073741824", ""]
    lines = run_zip(work, "mbig", "stored.zip", ["plain.txt"], "o1", options(max_out=1073741825))
    assert lines == ["mbig error archive: options.max_output_bytes must be 1..1073741824", ""]
    lines = run_zip(work, "exact", "stored.zip", ["plain.txt"], "o1", options(max_out=len(STORED_HELLO)))
    assert lines == ["exact ok [%d]" % len(STORED_HELLO), ""]
    lines = run_zip(work, "short", "stored.zip", ["plain.txt", "empty.txt"], "o2",
                    options(max_out=len(STORED_HELLO)))
    assert lines == ["short ok [%d, 0]" % len(STORED_HELLO), ""]
    lines = run_zip(work, "over", "stored.zip", ["plain.txt", "empty.txt"], "o3",
                    options(max_out=len(STORED_HELLO) - 1))
    assert lines == ["over error archive: output exceeds %d bytes" % (len(STORED_HELLO) - 1), ""]
    lines = run_zip(work, "single", "stored.zip", ["sub/deep.bin"], "o4",
                    options(max_out=len(DEEP_DATA) - 1))
    assert lines == ["single error archive: output exceeds %d bytes" % (len(DEEP_DATA) - 1), ""]


def test_truncated_archives_fail(tmp_path):
    work = tmp_path
    data = b"0123456789ABCDEF"
    blob, layout = assemble([Spec(b"a.txt", data, method=0), Spec(b"b.txt", data)])
    bad = bytearray(blob)
    struct.pack_into("<I", bad, layout["offsets"][0] + 18, 100026)
    struct.pack_into("<I", bad, layout["offsets"][0] + 22, 100026)
    struct.pack_into("<I", bad, layout["cd_offset"] + 20, 100026)
    struct.pack_into("<I", bad, layout["cd_offset"] + 24, 100026)
    (work / "cutstored.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "cutstored", "cutstored.zip", ["a.txt"], "o1")
    assert lines == ["cutstored error archive: truncated ZIP data, needed 65536 bytes for file data of a.txt", ""]
    blob, layout = assemble([Spec(b"a.txt", data, method=0), Spec(b"b.txt", data)])
    bad = bytearray(blob)
    struct.pack_into("<I", bad, layout["offsets"][1] + 18, 999)
    struct.pack_into("<I", bad, layout["cd_offset"] + 51 + 20, 999)
    (work / "cutdeflated.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "cutdeflated", "cutdeflated.zip", ["b.txt"], "o2")
    assert lines[0].startswith("cutdeflated error archive: truncated ZIP data, needed ")
    assert lines[0].endswith("compressed data of b.txt"), lines
    blob, layout = assemble([Spec(b"a.txt", data, method=0)])
    cut_at = layout["cd_offset"] + 20
    end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 1, 1, 20, layout["cd_offset"], 0)
    (work / "cutcd.zip").write_bytes(blob[:cut_at] + end)
    lines = run_zip(work, "cutcd", "cutcd.zip", ["a.txt"], "o3")
    assert lines == ["cutcd error archive: truncated ZIP data, needed 46 bytes for a central directory entry", ""]
    (work / "garbage.bin").write_bytes(bytes(range(256)) * 4)
    lines = run_zip(work, "garbage", "garbage.bin", ["a.txt"], "o4")
    assert lines == ["garbage error archive: the end of the central directory was not found: garbage.bin", ""]


def test_trailing_data_before_the_central_directory_fails(tmp_path):
    work = tmp_path
    blob, layout = assemble([Spec(b"a.txt", b"data", method=0), Spec(b"b.txt", b"more", method=0)])
    trailing = blob[:layout["cd_offset"]] + b"\x00" * 8 + blob[layout["cd_offset"]:]
    eocd = trailing.rfind(SIG_EOCD)
    bad = bytearray(trailing)
    struct.pack_into("<I", bad, eocd + 16, layout["cd_offset"] + 8)
    (work / "trailingcd.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "trailingcd", "trailingcd.zip", ["a.txt"], "o1")
    assert lines == ["trailingcd error archive: trailing data before the central directory", ""]
    bad = bytearray(blob)
    bad[layout["cd_offset"] + 51] ^= 0xFF
    (work / "junkcd.zip").write_bytes(bytes(bad))
    lines = run_zip(work, "junkcd", "junkcd.zip", ["a.txt"], "o2")
    assert lines == ["junkcd error archive: bad central directory entry at entry 2", ""]


def test_expired_deadline_aborts_long_reads(tmp_path):
    work = tmp_path
    blob, _ = assemble([Spec(b"z.bin", b"\x00" * 10000000, method=0)])
    (work / "big.zip").write_bytes(blob)
    tiny = options(timeout=1)
    lines = run_zip(work, "stored", "big.zip", ["z.bin"], "o1", tiny)
    assert lines[0].startswith("stored error archive: ") and "timed out" in lines[0]
    blob, _ = assemble([Spec(b"z.bin", b"\x00" * 10000000)])
    (work / "bigd.zip").write_bytes(blob)
    lines = run_zip(work, "deflated", "bigd.zip", ["z.bin"], "o2", tiny)
    assert lines[0].startswith("deflated error archive: ") and "timed out" in lines[0]


@pytest.mark.parametrize("variant", ["fwd", "back", "mixed", "cacheroot"])
def test_destination_spellings_with_backslashes_extract(tmp_path, variant):
    """A destination may hold host backslashes (a cache root from the OS does): the join the
    extractor uses normalizes them, so each spelling extracts on every system with no host skip."""
    work = tmp_path
    stored_case(work)
    root = str(work)
    if variant == "fwd":
        dest = root.replace(os.sep, "/") + "/d-fwd"
    elif variant == "back":
        dest = root + "\\d-back"
    elif variant == "mixed":
        dest = root.replace(os.sep, "/") + "\\d-mix"
    else:
        dest = root + "/d-cache"
    lines = run_zip(work, variant, "stored.zip", ["plain.txt", "sub/deep.bin"], dest)
    assert lines == ["%s ok [%d, %d]" % (variant, len(STORED_HELLO), len(DEEP_DATA)), ""], lines
    assert (pathlib.Path(dest) / "plain.txt").read_bytes() == STORED_HELLO
    assert (pathlib.Path(dest) / "sub" / "deep.bin").read_bytes() == DEEP_DATA


def test_absolute_destination_extracts(tmp_path):
    work = tmp_path
    stored_case(work)
    dest = str(work / "abs-out")
    lines = run_zip(work, "absolute", "stored.zip", ["plain.txt", "sub/deep.bin"], dest)
    assert lines == ["absolute ok [%d, %d]" % (len(STORED_HELLO), len(DEEP_DATA)), ""]
    assert (work / "abs-out" / "plain.txt").read_bytes() == STORED_HELLO
    assert (work / "abs-out" / "sub" / "deep.bin").read_bytes() == DEEP_DATA


def test_empty_archive_reports_missing_members(tmp_path):
    work = tmp_path
    blob, _ = assemble([])
    (work / "empty.zip").write_bytes(blob)
    lines = run_zip(work, "empty", "empty.zip", ["a.txt"], "o1")
    assert lines == ["empty error archive: member not found: a.txt", ""]
    assert (work / "o1").is_dir()


CAPPED_IMPORT = 'import Zip from "std/internal/archive_zip"'


def write_capped(work, archive_name, zip_name, chunk, cap):
    """Copies of the real stdlib modules with only the ceilings narrowed, so
    exact boundaries are testable without 256 MiB fixtures. The archive copy
    imports its sibling instead of the private std module, which only std/
    modules may name: the code is otherwise byte-identical."""
    src = (ROOT / "stdlib" / "archive.agc").read_text(encoding="utf-8")
    assert src.count("CHUNK = 65536") == 1
    assert src.count(CAPPED_IMPORT) == 1
    (work / archive_name).write_text(src.replace(CAPPED_IMPORT, 'import Zip from "%s"' % zip_name[:-4]),
                                     encoding="utf-8")
    zipped = (ROOT / "stdlib" / "internal" / "archive_zip.agc").read_text(encoding="utf-8")
    assert zipped.count("CHUNK = 65536") == 1
    assert zipped.count("INPUT_BYTES = 268435456") == 1
    zipped = zipped.replace("CHUNK = 65536", "CHUNK = %d" % chunk)
    zipped = zipped.replace("INPUT_BYTES = 268435456", "INPUT_BYTES = %d" % cap)
    (work / zip_name).write_text(zipped, encoding="utf-8")


def test_narrowed_copies_count_physical_bytes_exactly(tmp_path):
    work = tmp_path
    data = b"0123456789ABCDEF"
    blob, _ = assemble([Spec(b"a.txt", data, method=0)])
    assert len(blob) > 64
    (work / "tiny.zip").write_bytes(blob)
    write_capped(work, "archive_exact.agc", "archive_zip_exact.agc", 8, len(blob))
    write_capped(work, "archive_short.agc", "archive_zip_short.agc", 8, len(blob) - 1)
    show = (
        'import Exact from "archive_exact"\n'
        'import Short from "archive_short"\n'
        "\n"
        "def show(label: String, r: Result[List[Int]]) -> Void\n"
        "  case r\n"
        '    ok(counts) -> puts("#{label} ok #{counts}")\n'
        '    error(message) -> puts("#{label} error #{message}")\n'
        "  end\n"
        "end\n"
        "\n"
        "def main() -> Void\n"
        '  show("exact", Exact.extract_zip("tiny.zip", ["a.txt"], "o1", Exact.options()))\n'
        '  show("short", Short.extract_zip("tiny.zip", ["a.txt"], "o2", Short.options()))\n'
        "end\n"
    )
    path = work / "capped.agc"
    path.write_text(show, encoding="utf-8")
    result = run([str(binary()), str(path)], cwd=work, env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stderr == ""
    lines = result.stdout.split("\n")
    assert lines[0] == "exact ok [%d]" % len(data)
    assert lines[1] == "short error archive: source exceeds %d bytes" % (len(blob) - 1)
    assert (work / "o1" / "a.txt").read_bytes() == data
