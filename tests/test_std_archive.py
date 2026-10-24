"""std/archive: the explicit-allowlist TAR extractor on the VM.

Peers: Python's stdlib tarfile, gzip and io only. The cases run small
generated Agentica drivers through the CLI in temp directories, so every
archive is hermetic and no downloaded library is ever executed. Expected
outputs name the exact `error(...)` text of std/archive.
"""
import gzip
import io
import os
import tarfile

import pytest

from tests.agentica_test import binary, host_only, run, vm_environment

WINDOWS = os.name == "nt"


def call_text(src, quoted, dest, options):
    return 'Archive.extract_tar("%s", [%s], "%s", %s)' % (src, quoted, dest, options)


SHOW = (
    'import Archive from "std/archive"\n'
    "def oneline(text: String) -> String\n"
    '  return String.join(String.split(text, String.from_code(10)), " | ")\n'
    "end\n"
    "\n"
    "def show(label: String, r: Result[List[Int]]) -> Void\n"
    "  case r\n"
    '    ok(counts) -> puts("#{label} ok #{counts}")\n'
    '    error(message) -> puts("#{label} error #{oneline(message)}")\n'
    "  end\n"
    "end\n\n"
)


def driver(calls):
    """An Agentica program that prints one line per `Archive.extract_tar` call.

    Each call is (label, src, quoted-members, dest, options) with the members
    already quoted as Agentica source.
    """
    lines = [SHOW.rstrip("\n"), "", "def main() -> Void"]
    for label, src, quoted, dest, options in calls:
        lines.append('  show("%s", %s)' % (label, call_text(src, quoted, dest, options)))
    lines.append("end")
    return "\n".join(lines) + "\n"


def opts(timeout=30000, max_out=268435456):
    return "Archive.Options(timeout_ms: %d, max_output_bytes: %d)" % (timeout, max_out)


def q(*members):
    return ", ".join('"%s"' % member for member in members)


def run_driver(work, name, text):
    program = work / (name + ".agc")
    program.write_text(text, encoding="utf-8")
    result = run([str(binary()), str(program)], cwd=work, env=vm_environment())
    assert result.code == 0, "%s: %s" % (name, result.stderr)
    assert result.stderr == "", name
    return result.stdout.split("\n")


def ustar_header(name, size, typeflag=b"0", prefix=b"", magic=b"ustar\x00", bad_checksum=False):
    assert len(name) <= 100 and len(prefix) <= 155
    head = bytearray(512)
    head[0:len(name)] = name
    head[100:108] = b"0000777\x00"
    head[108:116] = b"0000000\x00"
    head[116:124] = b"0000000\x00"
    head[124:136] = ("%011o\x00" % size).encode("ascii")
    head[136:148] = b"00000000000\x00"
    head[148:156] = b"        "
    head[156:157] = typeflag
    head[257:257 + len(magic)] = magic
    head[257 + 6:257 + 8] = b"00"
    head[345:345 + len(prefix)] = prefix
    digest = sum(head)
    head[148:156] = ("%06o\x00 " % digest).encode("ascii")
    if bad_checksum:
        head[148] = (head[148] + 1) % 256
    return bytes(head)


def entry(name, data, typeflag=b"0", **header_kwargs):
    head = ustar_header(name, len(data), typeflag, **header_kwargs)
    pad = b"\x00" * ((512 - len(data) % 512) % 512)
    return head + data + pad


def finish(blocks):
    return b"".join(blocks) + b"\x00" * 1024


def pax_block(records):
    body = b""
    for key, value in records:
        line = b"%s=%s\n" % (key, value)
        for length in range(len(line) + 3, len(line) + 12):
            if len(str(length)) + 1 + len(line) == length:
                body += ("%d " % length).encode("ascii") + line
                break
    return entry(b"././@PaxHeader", body, b"x")


def longname_block(name):
    return entry(b"././@LongLink", name + b"\x00", b"L")


# A PAX-format archive from Python's tarfile, the realistic upstream shape.
def pax_tar(work, name, files):
    path = work / name
    with tarfile.open(path, "w", format=tarfile.PAX_FORMAT) as tar:
        for arcname, data in files:
            info = tarfile.TarInfo(arcname)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return path.name


def test_basic_roundtrips_keep_member_order_and_counts(tmp_path):
    work = tmp_path
    pax_tar(work, "p.tar", [("lib.so", b"hello lib"), ("sub/nested.bin", b"nested!"), ("readme.txt", b"readme text")])
    with tarfile.open(work / "u.tar", "w", format=tarfile.USTAR_FORMAT) as tar:
        for arcname, data in [("a.txt", b"12345"), ("b/c.txt", b"xy")]:
            info = tarfile.TarInfo(arcname)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    with tarfile.open(work / "g.tar", "w", format=tarfile.GNU_FORMAT) as tar:
        info = tarfile.TarInfo("g" * 120)
        info.size = 4
        tar.addfile(info, io.BytesIO(b"data"))
    with open(work / "p.tar", "rb") as raw:
        (work / "p.tar.gz").write_bytes(gzip.compress(raw.read()))
    options = "Archive.options()"
    defaults_text = (
        'import Archive from "std/archive"\n'
        "\n"
        "def main() -> Void\n"
        "  o = Archive.options()\n"
        '  puts("defaults #{o.timeout_ms} #{o.max_output_bytes}")\n'
        "end\n"
    )
    assert run_driver(work, "defaults", defaults_text) == ["defaults 30000 268435456", ""]
    calls = [
        ("pax", "p.tar", q("readme.txt", "lib.so", "sub/nested.bin"), "d1", options),
        ("dot", "p.tar", q("./sub/nested.bin"), "d2", options),
        ("ustar", "u.tar", q("b/c.txt", "a.txt"), "d3", options),
        ("gnu", "g.tar", q("g" * 120), "d4", options),
        ("gzip", "p.tar.gz", q("lib.so", "sub/nested.bin"), "d5", options),
    ]
    lines = run_driver(work, "basic", driver(calls))
    assert lines[0] == "pax ok [11, 9, 7]"
    assert lines[1] == "dot ok [7]"
    assert lines[2] == "ustar ok [2, 5]"
    assert lines[3] == "gnu ok [4]"
    assert lines[4] == "gzip ok [9, 7]"
    assert (work / "d1" / "lib.so").read_bytes() == b"hello lib"
    assert (work / "d1" / "sub" / "nested.bin").read_bytes() == b"nested!"
    assert (work / "d2" / "sub" / "nested.bin").read_bytes() == b"nested!"
    assert (work / "d3" / "b" / "c.txt").read_bytes() == b"xy"
    assert (work / "d4" / ("g" * 120)).read_bytes() == b"data"
    assert (work / "d5" / "lib.so").read_bytes() == b"hello lib"


def test_dot_prefixed_names_normalize_both_ways(tmp_path):
    work = tmp_path
    blocks = [entry(b"./lib.so", b"0123456789"), entry(b"plain.txt", b"abc")]
    (work / "a.tar").write_bytes(finish(blocks))
    options = "Archive.options()"
    calls = [
        ("plain", "a.tar", q("lib.so"), "d1", options),
        ("dotted", "a.tar", q("./plain.txt"), "d2", options),
    ]
    assert run_driver(work, "dots", driver(calls)) == ["plain ok [10]", "dotted ok [3]", ""]
    assert (work / "d1" / "lib.so").read_bytes() == b"0123456789"
    assert (work / "d2" / "plain.txt").read_bytes() == b"abc"


def test_archive_of_dot_allows_its_root_header(tmp_path):
    work = tmp_path
    (work / "src").mkdir()
    (work / "src" / "lib.so").write_bytes(b"hello lib")
    with tarfile.open(work / "dot.tar", "w") as tar:
        tar.add(work / "src", ".")
    lines = run_driver(work, "dotroot", driver([("root", "dot.tar", q("lib.so"), "out", "Archive.options()")]))
    assert lines == ["root ok [9]", ""]
    assert (work / "out" / "lib.so").read_bytes() == b"hello lib"


def test_option_and_member_validation(tmp_path):
    work = tmp_path
    (work / "empty.tar").write_bytes(b"")
    members_257 = ", ".join('"f%d"' % i for i in range(257))
    text = (
        "def main() -> Void\n"
        '  nul = "a#{String.from_code(0)}b"\n'
        '  show("empty-m", %s)\n'
        '  show("many-m", %s)\n'
        '  show("nul-m", %s)\n'
        '  show("t0", %s)\n'
        '  show("tneg", %s)\n'
        '  show("tbig", %s)\n'
        '  show("o0", %s)\n'
        '  show("obig", %s)\n'
        '  show("missing", %s)\n'
        '  show("isdir", %s)\n'
        '  show("destfile", %s)\n'
        '  show("destdir", %s)\n'
        '  show("noparent", %s)\n'
        'end\n'
        % (
            call_text("empty.tar", "", "d", "Archive.options()"),
            call_text("empty.tar", members_257, "d", "Archive.options()"),
            call_text("empty.tar", "nul", "d", "Archive.options()"),
            call_text("empty.tar", q("a"), "d", opts(timeout=0)),
            call_text("empty.tar", q("a"), "d", opts(timeout=-1)),
            call_text("empty.tar", q("a"), "d", opts(timeout=86400001)),
            call_text("empty.tar", q("a"), "d", opts(max_out=0)),
            call_text("empty.tar", q("a"), "d", opts(max_out=1073741825)),
            call_text("gone.tar", q("a"), "d", "Archive.options()"),
            call_text("sub", q("a"), "d", "Archive.options()"),
            call_text("empty.tar", q("a"), "taken", "Archive.options()"),
            call_text("empty.tar", q("a"), "sub", "Archive.options()"),
            call_text("empty.tar", q("a"), "no/such/d", "Archive.options()"),
        )
    )
    (work / "sub").mkdir()
    (work / "taken").write_bytes(b"keep")
    text = SHOW + text
    program = work / "validation.agc"
    program.write_text(text, encoding="utf-8")
    result = run([str(binary()), str(program)], cwd=work, env=vm_environment())
    assert result.code == 0, result.stderr
    lines = result.stdout.split("\n")
    assert lines[0] == "empty-m error archive: members must select 1..256 files"
    assert lines[1] == "many-m error archive: members must select 1..256 files"
    assert lines[2].startswith("nul-m error archive: member ")
    assert lines[3] == "t0 error archive: options.timeout_ms must be 1..86400000"
    assert lines[4] == "tneg error archive: options.timeout_ms must be 1..86400000"
    assert lines[5] == "tbig error archive: options.timeout_ms must be 1..86400000"
    assert lines[6] == "o0 error archive: options.max_output_bytes must be 1..1073741824"
    assert lines[7] == "obig error archive: options.max_output_bytes must be 1..1073741824"
    assert lines[8].startswith("missing error archive: cannot use gone.tar: ")
    assert lines[9] == "isdir error archive: source is not a regular file: sub"
    assert lines[10].startswith("destfile error archive: cannot create taken: ")
    assert lines[11].startswith("destdir error archive: cannot create sub: ")
    assert lines[12].startswith("noparent error archive: cannot create no/such/d: ")
    assert (work / "taken").read_bytes() == b"keep"
    assert not (work / "d").exists()


@pytest.mark.parametrize("member", [
    ".", "./", "/", "/abs/path", "C:/drive", "C:drive", "\\\\unc\\share", "back\\slash",
    "with:colon", "a/../up", "a//empty", "a/", "trailing/.",
])
def test_unsafe_members_rejected_before_touching_disk(tmp_path, member):
    work = tmp_path
    (work / "empty.tar").write_bytes(b"")
    escaped = member.replace("\\", "\\\\").replace('"', '\\"')
    text = (
        "def main() -> Void\n"
        '  show("m", %s)\n'
        '  puts("d-exists #{File.stat("d", 30000).ok?}")\n'
        "end\n" % call_text("empty.tar", '"%s"' % escaped, "d", "Archive.options()")
    )
    lines = run_driver(work, "unsafe", SHOW + text)
    assert lines[0].startswith("m error archive: "), member
    assert lines[1] == "d-exists false", member
    assert not (work / "d").exists()


@pytest.mark.parametrize("first,second", [
    ("lib.so", "lib.so"),
    ("./lib.so", "lib.so"),
    ("Lib.so", "lib.so"),
    ("sub/a.txt", "SUB/a.txt"),
])
def test_duplicate_and_case_colliding_members_rejected(tmp_path, first, second):
    work = tmp_path
    (work / "empty.tar").write_bytes(b"")
    text = (
        "def main() -> Void\n"
        '  show("m", %s)\n'
        '  puts("d-exists #{File.stat("d", 30000).ok?}")\n'
        "end\n" % call_text("empty.tar", '"%s", "%s"' % (first, second), "d", "Archive.options()")
    )
    lines = run_driver(work, "dups", SHOW + text)
    assert lines[0].startswith("m error archive: members "), (first, second)
    assert lines[1] == "d-exists false"
    assert not (work / "d").exists()


@host_only(WINDOWS, "Windows needs privileges to create a symbolic link")
def test_symlink_source_is_refused(tmp_path):
    work = tmp_path
    (work / "real.tar").write_bytes(finish([entry(b"a.txt", b"hi")]))
    (work / "link.tar").symlink_to(work / "real.tar")
    lines = run_driver(work, "linksrc", driver([("link", "link.tar", q("a.txt"), "d", "Archive.options()")]))
    assert lines == ["link error archive: source is not a regular file: link.tar", ""]
    assert not (work / "d").exists()


def test_missing_member_and_duplicates_and_bad_checksum(tmp_path):
    work = tmp_path
    good = entry(b"wanted.txt", b"0123456789")
    (work / "m.tar").write_bytes(finish([good, entry(b"other.txt", b"xy"), entry(b"late.txt", b"zz")]))
    (work / "d.tar").write_bytes(finish([good, entry(b"./wanted.txt", b"0123456789")]))
    (work / "c.tar").write_bytes(
        finish([good, entry(b"late.txt", b"zz", bad_checksum=True), entry(b"wanted.txt", b"zz")]))
    options = "Archive.options()"
    calls = [
        ("missing", "m.tar", q("wanted.txt", "gone.txt"), "d1", options),
        ("dup", "d.tar", q("wanted.txt"), "d2", options),
        ("checksum", "c.tar", q("wanted.txt", "late.txt"), "d3", options),
    ]
    lines = run_driver(work, "scan", driver(calls))
    assert lines[0] == "missing error archive: member not found: gone.txt"
    assert lines[1] == "dup error archive: the same archive holds wanted.txt twice"
    assert lines[2] == "checksum error archive: bad header checksum at entry 2"
    # The selected payload written before the failure is kept but unusable alone.
    assert (work / "d3" / "wanted.txt").read_bytes() == b"0123456789"


def test_truncations_and_end_blocks(tmp_path):
    work = tmp_path
    whole = finish([entry(b"a.txt", b"0123456789"), entry(b"b.txt", b"xy")])
    (work / "full.tar").write_bytes(whole)
    (work / "cut-data.tar").write_bytes(whole[:512 + 4])
    (work / "cut-head.tar").write_bytes(whole[:700])
    (work / "cut-entries.tar").write_bytes(whole[:2048])
    (work / "one-zero.tar").write_bytes(whole[: len(whole) - 512])
    extra = bytearray(1024)
    extra[100] = 7
    (work / "nonzero-pad.tar").write_bytes(whole + bytes(extra))
    garbage = whole[:1024] + b"not a header" + b"\x00" * 501 + b"\x00" * 1024
    (work / "garbage.tar").write_bytes(garbage)
    (work / "one-byte.tar").write_bytes(b"x")
    (work / "empty.tar").write_bytes(b"")
    options = "Archive.options()"
    calls = [
        ("full", "full.tar", q("a.txt", "b.txt"), "d0", options),
        ("cut-data", "cut-data.tar", q("a.txt"), "d1", options),
        ("cut-head", "cut-head.tar", q("a.txt"), "d2", options),
        ("cut-entries", "cut-entries.tar", q("a.txt"), "d3", options),
        ("one-zero", "one-zero.tar", q("a.txt"), "d4", options),
        ("nonzero-pad", "nonzero-pad.tar", q("a.txt"), "d5", options),
        ("garbage", "garbage.tar", q("a.txt"), "d6", options),
        ("one-byte", "one-byte.tar", q("a.txt"), "d7", options),
        ("empty", "empty.tar", q("a.txt"), "d8", options),
    ]
    lines = run_driver(work, "trunc", driver(calls))
    assert lines[0] == "full ok [10, 2]"
    assert lines[1] == "cut-data error archive: truncated TAR data, needed 10 bytes for file data of a.txt"
    assert lines[2].startswith("cut-head error archive: truncated TAR data, ")
    assert lines[3] == "cut-entries error archive: truncated archive, missing the two zero end blocks"
    assert lines[4] == "one-zero error archive: truncated archive, missing the two zero end blocks"
    assert lines[5] == "nonzero-pad error archive: non-zero padding after the archive end"
    assert lines[6] == "garbage error archive: bad header checksum at entry 2"
    assert lines[7].startswith("one-byte error archive: truncated TAR data, ")
    assert lines[8] == "empty error archive: empty.tar is empty, not a TAR archive"


def test_non_regular_selections_and_output_safety(tmp_path):
    work = tmp_path
    blocks = [
        entry(b"dir/", b"", b"5"),
        entry(b"link.txt", b"target", b"2"),
        entry(b"dev.txt", b"", b"3"),
        entry(b"afile/sub.txt", b"2222"),
        entry(b"afile", b"1111"),
        entry(b"pre.txt", b"3333"),
    ]
    (work / "n.tar").write_bytes(finish(blocks))
    options = "Archive.options()"
    calls = [
        ("dir", "n.tar", q("dir"), "o1", options),
        ("link", "n.tar", q("link.txt"), "o2", options),
        ("dev", "n.tar", q("dev.txt"), "o3", options),
        ("fold", "n.tar", q("afile/sub.txt", "afile"), "o4", options),
        ("pre", "n.tar", q("pre.txt"), "o5", options),
        ("trav", "n.tar", q("../outside.txt"), "o6", options),
    ]
    (work / "o5").mkdir()
    (work / "o5" / "pre.txt").write_bytes(b"original")
    lines = run_driver(work, "safety", driver(calls))
    assert lines[0] == "dir error archive: member is not a regular file: dir"
    assert lines[1] == "link error archive: member is not a regular file: link.txt"
    assert lines[2] == "dev error archive: member is not a regular file: dev.txt"
    assert lines[3].startswith("fold error archive: selected files collide on a case-insensitive system: ")
    assert lines[4].startswith("pre error archive: cannot create ")
    assert lines[5].startswith("trav error archive: member ")
    # Nothing escaped: the pre-existing file is intact and no outside file exists.
    assert (work / "o5" / "pre.txt").read_bytes() == b"original"
    assert not (work / "outside.txt").exists()
    assert not list(work.glob("o6"))


def test_sparse_typeflag_is_not_a_regular_file(tmp_path):
    work = tmp_path
    sparse = ustar_header(b"sparse.bin", 10, b"S") + b"0123456789" + b"\x00" * 502
    (work / "s.tar").write_bytes(finish([sparse, entry(b"plain.txt", b"ok")]))
    options = "Archive.options()"
    calls = [
        ("sparse", "s.tar", q("sparse.bin"), "o1", options),
        ("plain", "s.tar", q("plain.txt"), "o2", options),
    ]
    lines = run_driver(work, "sparseflag", driver(calls))
    assert lines[0] == "sparse error archive: member is not a regular file: sparse.bin"
    assert lines[1] == "plain ok [2]"
    assert (work / "o2" / "plain.txt").read_bytes() == b"ok"


def test_sparse_pax_marker_is_refused(tmp_path):
    work = tmp_path
    blocks = [pax_block([(b"GNU.sparse.size", b"10")]) + ustar_header(b"psparse.bin", 0)]
    (work / "p.tar").write_bytes(finish(blocks))
    lines = run_driver(work, "sparsepax", driver([("sparse", "p.tar", q("psparse.bin"), "o1", "Archive.options()")]))
    assert lines == ["sparse error archive: sparse entries are not supported at entry 1", ""]


def test_gnu_long_names_and_name_cap(tmp_path):
    work = tmp_path
    (work / "g.tar").write_bytes(finish([longname_block(b"n" * 150) + entry(b"n" * 100, b"long!")]))
    (work / "t.tar").write_bytes(finish([longname_block(b"m" * 1025) + entry(b"m" * 100, b"x")]))
    options = "Archive.options()"
    calls = [
        ("gnu", "g.tar", q("n" * 150), "o1", options),
        ("toolong", "t.tar", q("m" * 300), "o2", options),
    ]
    lines = run_driver(work, "gnulong", driver(calls))
    assert lines[0] == "gnu ok [5]"
    assert lines[1] == "toolong error archive: entry name is too long at entry 1"
    assert (work / "o1" / ("n" * 150)).read_bytes() == b"long!"


def test_gnu_name_over_1024_bytes_is_refused(tmp_path):
    work = tmp_path
    (work / "t.tar").write_bytes(finish([longname_block(b"m" * 1025) + entry(b"m" * 100, b"x")]))
    lines = run_driver(work, "gnucap", driver([("cap", "t.tar", q("plain"), "o1", "Archive.options()")]))
    assert lines == ["cap error archive: entry name is too long at entry 1", ""]


def test_pax_size_override_and_global_header(tmp_path):
    work = tmp_path
    pax = pax_block([(b"path", b"renamed.txt"), (b"size", b"4"), (b"comment", b"ignored")])
    blocks = [pax + entry(b"orig.txt", b"0123456789"), pax_block([(b"size", b"999")])]
    (work / "p.tar").write_bytes(finish(blocks) + b"\x00" * 1024)
    options = "Archive.options()"
    calls = [
        ("renamed", "p.tar", q("renamed.txt"), "o1", options),
        ("orig", "p.tar", q("orig.txt"), "o2", options),
    ]
    lines = run_driver(work, "paxsize", driver(calls))
    assert lines[0] == "renamed ok [4]"
    assert lines[1] == "orig error archive: member not found: orig.txt"
    assert (work / "o1" / "renamed.txt").read_bytes() == b"0123"


def test_limits_and_streaming_chunks(tmp_path):
    work = tmp_path
    big = bytes(i % 251 for i in range(200000))
    (work / "big.bin").write_bytes(big)
    with tarfile.open(work / "big.tar", "w") as tar:
        info = tarfile.TarInfo("big.bin")
        info.size = len(big)
        tar.addfile(info, io.BytesIO(big))
        info = tarfile.TarInfo("small.txt")
        info.size = 3
        tar.addfile(info, io.BytesIO(b"abc"))
    with open(work / "big.tar", "rb") as raw:
        (work / "big.tar.gz").write_bytes(gzip.compress(raw.read()))
    huge_size = ustar_header(b"huge.bin", 2 * 1073741824)
    (work / "huge.tar").write_bytes(finish([huge_size]))
    meta = ustar_header(b"././@PaxHeader", 70000, b"x")
    (work / "meta.tar").write_bytes(meta + b"\x00" * 1024)
    options = "Archive.options()"
    calls = [
        ("big", "big.tar", q("big.bin", "small.txt"), "o1", options),
        ("big-gz", "big.tar.gz", q("big.bin"), "o2", options),
        ("cap-each", "big.tar", q("big.bin"), "o3", opts(max_out=100000)),
        ("cap-total", "big.tar", q("big.bin", "small.txt"), "o4", opts(max_out=200001)),
        ("huge", "huge.tar", q("huge.bin"), "o5", options),
        ("meta", "meta.tar", q("anything"), "o6", options),
    ]
    lines = run_driver(work, "limits", driver(calls))
    assert lines[0] == "big ok [200000, 3]"
    assert lines[1] == "big-gz ok [200000]"
    assert lines[2] == "cap-each error archive: output exceeds 100000 bytes"
    assert lines[3] == "cap-total error archive: output exceeds 200001 bytes"
    assert lines[4] == "huge error archive: entry size exceeds 1073741824 bytes at entry 1"
    assert lines[5] == "meta error archive: metadata exceeds 65536 bytes at entry 1"
    assert (work / "o1" / "big.bin").read_bytes() == big
    assert (work / "o2" / "big.bin").read_bytes() == big


def test_gzip_trailer_and_concat_rejected(tmp_path):
    work = tmp_path
    mini = finish([entry(b"a.txt", b"0123456789")])
    single = gzip.compress(mini)
    (work / "one.tar.gz").write_bytes(single)
    (work / "concat.tar.gz").write_bytes(single + single)
    (work / "trailing.tar.gz").write_bytes(single + b"junk-bytes")
    (work / "zeros.tar.gz").write_bytes(single + b"\x00" * 16)
    (work / "cut.tar.gz").write_bytes(single[: len(single) // 2])
    corrupted = bytearray(single)
    corrupted[20] ^= 1
    (work / "crc.tar.gz").write_bytes(bytes(corrupted))
    (work / "fake.tar.gz").write_bytes(b"\x1f\x8b" + b"not really gzip" * 100)
    options = "Archive.options()"
    calls = [
        ("one", "one.tar.gz", q("a.txt"), "o1", options),
        ("concat", "concat.tar.gz", q("a.txt"), "o2", options),
        ("trailing", "trailing.tar.gz", q("a.txt"), "o3", options),
        ("zeros", "zeros.tar.gz", q("a.txt"), "o4", options),
        ("cut", "cut.tar.gz", q("a.txt"), "o5", options),
        ("crc", "crc.tar.gz", q("a.txt"), "o6", options),
        ("fake", "fake.tar.gz", q("a.txt"), "o7", options),
    ]
    lines = run_driver(work, "gz", driver(calls))
    assert lines[0] == "one ok [10]"
    assert lines[1] == "concat error archive: trailing bytes after the gzip member"
    assert lines[2] == "trailing error archive: trailing bytes after the gzip member"
    assert lines[3] == "zeros error archive: trailing bytes after the gzip member"
    assert lines[4] == "cut error archive: gzip stream is truncated"
    assert lines[5].startswith("crc error archive: gzip input is invalid: ")
    assert lines[6].startswith("fake error archive: gzip input is invalid: ")
    assert (work / "o1" / "a.txt").read_bytes() == b"0123456789"


def test_entry_cap_trips_past_8192(tmp_path):
    work = tmp_path
    tiny = []
    for i in range(8193):
        tiny.append(entry(("f%05d.txt" % i).encode("ascii"), b"x"))
    (work / "ok.tar").write_bytes(finish(tiny[:8192]))
    (work / "over.tar").write_bytes(finish(tiny))
    options = "Archive.options()"
    calls = [
        ("ok", "ok.tar", q("f08191.txt"), "o1", options),
        ("over", "over.tar", q("f08192.txt"), "o2", options),
    ]
    lines = run_driver(work, "entrycap", driver(calls))
    assert lines[0] == "ok ok [1]"
    assert lines[1] == "over error archive: too many entries, past 8192"
    assert (work / "o1" / "f08191.txt").read_bytes() == b"x"


def test_utf8_names_and_skipped_entries_do_not_materialize(tmp_path):
    work = tmp_path
    name = "café-日本語.txt".encode("utf-8")
    blocks = [entry(name, "héllo".encode("utf-8")), entry(b"unselected.bin", b"z" * 100000)]
    (work / "u.tar").write_bytes(finish(blocks))
    selector = "café-日本語.txt"
    calls = [("utf8", "u.tar", q(selector), "o1", "Archive.options()")]
    lines = run_driver(work, "utf8", driver(calls))
    assert lines == ["utf8 ok [6]", ""]
    assert (work / "o1" / selector).read_bytes() == "héllo".encode("utf-8")
    assert sorted(path.name for path in (work / "o1").iterdir()) == [selector]
