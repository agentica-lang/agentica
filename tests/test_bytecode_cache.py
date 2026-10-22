"""The bytecode cache of `agentica FILE.agc` and `agentica test` (issue #375), through the CLI.

A hit is proved without timing: the program kept in an entry is swapped for another valid program (with the digest of
the entry's text fixed), and the run then does what the swapped program does, which only a run that read the entry can
do. A miss is an entry that was written again. The layout of an entry is in compiler/io/bytecode_cache.agc.
"""
import hashlib
import json
import os
import stat

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, vm_environment
from tests.package_support import Workspace, dependency

HEAD_BYTES = 18

# root can write into a folder whatever its mode, so the case with a read-only folder does not hold for it.
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0


def program(message):
    return 'def main() -> Void\n  puts("%s")\nend\n' % message


MAIN = 'import Util from "util"\n\ndef main() -> Void\n  puts(Util.word())\nend\n'
UTIL = 'export def word() -> String\n  return "%s"\nend\n'
PASSING = 'def main() -> Void\n  Test.run([Test.test("fine") do\n    ok()\n  end])\nend\n'
FAILING = 'def main() -> Void\n  Test.run([Test.test("fine") do\n    error("changed")\n  end])\nend\n'


def environment(**extra):
    """The environment of a case: no cache folder of the harness, so a run keeps its entry next to the sources."""
    return vm_environment({"AGENTICA_CACHE_DIR": None, **extra})


def agentica(folder, *words, **extra):
    return run(cli() + [str(word) for word in words], cwd=folder, env=environment(**extra))


def entries(folder):
    """The cache entries (not the .gitignore) in `folder`."""
    return sorted(folder.glob("*.agcb")) if folder.is_dir() else []


def only_entry(folder):
    found = entries(folder)
    assert len(found) == 1, found
    return found[0]


def stamp(path):
    """What changes when an entry is written again."""
    return path.stat().st_mtime_ns, path.read_bytes()


def split(path):
    """The text of an entry and the bytes of its program."""
    data = path.read_bytes()
    size = int(data[len(b"AGCCACHE "):HEAD_BYTES - 1])
    return data[HEAD_BYTES:HEAD_BYTES + size].decode("utf-8"), data[HEAD_BYTES + size:]


def swap_program(entry, bytecode):
    """Puts `bytecode` in the entry in place of its program, with the digest in its text to match."""
    text, _ = split(entry)
    lines = text.split("\n")
    at = next(index for index, line in enumerate(lines) if line.startswith("program "))
    lines[at] = "program " + hashlib.sha256(bytecode).hexdigest()
    body = "\n".join(lines).encode("utf-8")
    entry.write_bytes(b"AGCCACHE %08d\n" % len(body) + body + bytecode)


def compiled(folder, name, source):
    """The bytes `agentica compile` writes for `source`."""
    (folder / (name + ".agc")).write_text(source, encoding="utf-8")
    done = agentica(folder, "compile", name + ".agc", "-o", name + ".agcb")
    assert done.code == 0, done.stderr
    return (folder / (name + ".agcb")).read_bytes()


@pytest.fixture
def src(tmp_path):
    folder = tmp_path / "src"
    folder.mkdir()
    (folder / "main.agc").write_text(MAIN, encoding="utf-8")
    (folder / "util.agc").write_text(UTIL % "one", encoding="utf-8")
    return folder


def test_a_second_run_reads_the_entry_and_an_edit_of_any_source_file_misses(src, tmp_path):
    first = agentica(src, "main.agc")
    assert (first.code, first.stdout) == (0, "one\n"), first.stderr
    entry = only_entry(src / ".agc_cache")
    # The folder holds a .gitignore of its own, so the bytecode is not committed by mistake.
    assert (src / ".agc_cache" / ".gitignore").read_text(encoding="utf-8") == "*\n"
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    kept = stamp(entry)
    second = agentica(src, "main.agc")
    assert (second.code, second.stdout) == (0, "from the entry\n"), second.stderr
    assert stamp(entry) == kept
    for name, text, shown in (("util.agc", UTIL % "two", "two\n"), ("main.agc", MAIN + "\n", "two\n")):
        (src / name).write_text(text, encoding="utf-8")
        again = agentica(src, "main.agc")
        assert (again.code, again.stdout) == (0, shown), again.stderr
        assert stamp(entry) != kept
        kept = stamp(entry)


def test_check_and_compile_keep_no_entry(src):
    assert agentica(src, "check", "main.agc").code == 0
    assert agentica(src, "compile", "main.agc", "-o", "main.agcb").code == 0
    assert agentica(src, "--dump", "main.agc").code == 0
    assert not (src / ".agc_cache").exists()


def test_a_damaged_entry_is_built_again(src):
    agentica(src, "main.agc")
    entry = only_entry(src / ".agc_cache")
    good = entry.read_bytes()
    text, bytecode = split(entry)
    # The last line of the text names a source file; a NUL in the path must not stop the front end.
    body = (text + "\0").encode("utf-8")
    nul = b"AGCCACHE %08d\n" % len(body) + body + bytecode
    multibyte = b"AGCCACHE " + "\u00e9".encode("utf-8") * 4 + b"\n" + good[HEAD_BYTES:]
    for damaged in (good[:-1], good[:-20] + bytes([good[-20] ^ 1]) + good[-19:], b"AGCCACHE 00000000\n", b"junk", b"",
                    nul, multibyte):
        entry.write_bytes(damaged)
        done = agentica(src, "main.agc")
        assert (done.code, done.stdout) == (0, "one\n"), done.stderr
        assert entry.read_bytes() == good


def test_no_cache_and_the_cache_folder_variable(src, tmp_path):
    off = agentica(src, "--no-cache", "main.agc")
    assert (off.code, off.stdout) == (0, "one\n"), off.stderr
    assert not (src / ".agc_cache").exists()
    elsewhere = tmp_path / "elsewhere"
    on = agentica(src, "main.agc", AGENTICA_CACHE_DIR=str(elsewhere))
    assert (on.code, on.stdout) == (0, "one\n"), on.stderr
    assert not (src / ".agc_cache").exists()
    entry = only_entry(elsewhere)
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    # --no-cache neither reads nor writes the entry.
    kept = stamp(entry)
    skipped = agentica(src, "--no-cache", "main.agc", AGENTICA_CACHE_DIR=str(elsewhere))
    assert (skipped.code, skipped.stdout) == (0, "one\n"), skipped.stderr
    assert stamp(entry) == kept


@pytest.mark.skipif(ROOT_USER, reason="root can write to a read-only folder")
@host_only(WINDOWS, "the folder is made read-only with its mode bits")
def test_a_folder_that_cannot_be_written_still_runs(src):
    src.chmod(stat.S_IRUSR | stat.S_IXUSR)
    try:
        done = agentica(src, "main.agc")
    finally:
        src.chmod(stat.S_IRWXU)
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    assert not (src / ".agc_cache").exists()


def test_a_change_of_the_lock_misses(tmp_path):
    ws = Workspace(tmp_path)
    git = "https://github.com/owner/greeter.git"
    ws.add_package("greeter", git, {"greet.agc": 'export def hello() -> String\n  return "hi"\nend\n'}, tag="v1.0.0")
    other = ws.add_package("greeter", git, {"greet.agc": 'export def hello() -> String\n  return "hi"\nend\n'},
                           tag="v1.0.0", commit="b" * 40)
    ws.locked.remove(other)
    ws.write_manifest({"greeter": dependency(git, tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(
        'import Greet from "pkg/greeter/greet"\n\ndef main() -> Void\n  puts(Greet.hello())\nend\n', encoding="utf-8")
    hermetic = {"AGENTICA_PATH": "", **ws.cache_variables}
    first = agentica(ws.project, "main.agc", **hermetic)
    assert (first.code, first.stdout) == (0, "hi\n"), first.stderr
    entry = only_entry(ws.project / ".agc_cache")
    kept = stamp(entry)
    # The same lock reads the entry; the lock that names the other commit (same files, same bytes) does not.
    assert agentica(ws.project, "main.agc", **hermetic).stdout == "hi\n"
    assert stamp(entry) == kept
    ws.locked[:] = [other]
    ws.write_lock()
    again = agentica(ws.project, "main.agc", **hermetic)
    assert (again.code, again.stdout) == (0, "hi\n"), again.stderr
    assert stamp(entry) != kept


def test_agentica_test_reads_and_keeps_the_entry_of_a_test_file(tmp_path):
    folder = tmp_path / "specs"
    folder.mkdir()
    (folder / "one_test.agc").write_text(PASSING, encoding="utf-8")
    cache = tmp_path / "cache"
    first = agentica(tmp_path, "--json", "test", folder, AGENTICA_CACHE_DIR=str(cache))
    assert first.code == 0, first.stdout + first.stderr
    entry = only_entry(cache)
    assert not (folder / ".agc_cache").exists()
    swap_program(entry, compiled(tmp_path, "failing_test", FAILING))
    kept = stamp(entry)
    second = agentica(tmp_path, "--json", "test", folder, AGENTICA_CACHE_DIR=str(cache))
    assert second.code == 1, second.stdout + second.stderr
    assert "changed" in second.stdout
    assert stamp(entry) == kept
    # --no-cache compiles the file again, and leaves the entry as it is.
    third = agentica(tmp_path, "--no-cache", "--json", "test", folder, AGENTICA_CACHE_DIR=str(cache))
    assert third.code == 0, third.stdout + third.stderr
    assert stamp(entry) == kept
    assert json.loads(third.stdout)["files"]
