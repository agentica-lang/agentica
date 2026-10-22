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

from tests.agentica_test import POSIX_PYTHON, WINDOWS, cli, host_only, known_issue, run, vm_environment
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


def test_check_compile_and_dump_neither_read_nor_write_the_entry(src, tmp_path):
    agentica(src, "main.agc")
    entry = only_entry(src / ".agc_cache")
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    kept = stamp(entry)
    assert agentica(src, "check", "main.agc").code == 0
    # `compile` writes the program of the sources, not the one in the entry.
    assert agentica(src, "compile", "main.agc", "-o", "main.agcb").code == 0
    assert b"from the entry" not in (src / "main.agcb").read_bytes()
    assert agentica(src, "--dump", "main.agc").code == 0
    assert stamp(entry) == kept
    # And they make none where there is none.
    other = src.parent / "other"
    other.mkdir()
    (other / "main.agc").write_text(program("x"), encoding="utf-8")
    for words in (("check", "main.agc"), ("compile", "main.agc", "-o", "main.agcb"), ("--dump-ir", "main.agc")):
        assert agentica(other, *words).code == 0
    assert not (other / ".agc_cache").exists()


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


@pytest.mark.parametrize("variable", [False, True], ids=["next to the sources", "AGENTICA_CACHE_DIR"])
def test_no_cache_neither_reads_nor_writes_and_the_variable_moves_the_entries(src, tmp_path, variable):
    elsewhere = tmp_path / "elsewhere"
    extra = {"AGENTICA_CACHE_DIR": str(elsewhere)} if variable else {}
    on = agentica(src, "main.agc", **extra)
    assert (on.code, on.stdout) == (0, "one\n"), on.stderr
    folder = elsewhere if variable else src / ".agc_cache"
    assert (src / ".agc_cache").exists() != variable
    entry = only_entry(folder)
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    kept = stamp(entry)
    skipped = agentica(src, "--no-cache", "main.agc", **extra)
    assert (skipped.code, skipped.stdout) == (0, "one\n"), skipped.stderr
    assert stamp(entry) == kept
    again = agentica(src, "main.agc", **extra)
    assert again.stdout == "from the entry\n", again.stderr


@host_only(WINDOWS, "the folder is made read-only with its mode bits")
def test_a_folder_that_cannot_be_written_still_runs(src):
    src.chmod(stat.S_IRUSR | stat.S_IXUSR)
    try:
        done = agentica(src, "main.agc")
    finally:
        src.chmod(stat.S_IRWXU)
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    # root writes to a folder whatever its mode, so only the run is checked for it.
    assert ROOT_USER or not (src / ".agc_cache").exists()


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


POSIX_ONLY = host_only(not POSIX_PYTHON, "file modes and owners bind a POSIX system")
# The link checks work on Windows too, but a symbolic link there needs a privilege the test cannot count on.
LINKS = known_issue(not POSIX_PYTHON, 568, "the link cases of the bytecode cache have no Windows test")


@POSIX_ONLY
def test_a_folder_that_others_can_write_is_not_used_and_not_written(src, tmp_path):
    agentica(src, "main.agc")
    folder = src / ".agc_cache"
    assert stat.S_IMODE(folder.stat().st_mode) == stat.S_IRWXU
    entry = only_entry(folder)
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    kept = stamp(entry)
    folder.chmod(0o770)
    (src / "util.agc").write_text(UTIL % "two", encoding="utf-8")
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "two\n"), done.stderr
    assert stamp(entry) == kept and [path.name for path in folder.iterdir() if ".tmp-" in path.name] == []
    # The same entry in a folder that is private again is read, so it was the mode that kept it out.
    folder.chmod(0o700)
    (src / "util.agc").write_text(UTIL % "one", encoding="utf-8")
    assert agentica(src, "main.agc").stdout == "from the entry\n"


@POSIX_ONLY
def test_an_entry_that_others_can_write_is_replaced(src, tmp_path):
    agentica(src, "main.agc")
    entry = only_entry(src / ".agc_cache")
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    entry.chmod(0o666)
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    assert stat.S_IMODE(entry.stat().st_mode) == stat.S_IRUSR | stat.S_IWUSR


@LINKS
def test_links_are_never_followed_to_read_or_to_write(src, tmp_path):
    agentica(src, "main.agc")
    folder = src / ".agc_cache"
    entry = only_entry(folder)
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    # A link in place of the entry: not read, and replaced by a file, never written through.
    target = tmp_path / "target.agcb"
    target.write_bytes(entry.read_bytes())
    entry.unlink()
    entry.symlink_to(target)
    kept = target.read_bytes()
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    assert target.read_bytes() == kept and not entry.is_symlink() and entry.is_file()
    # A link in place of the folder: not used, nothing is written where it leads.
    moved = tmp_path / "moved"
    folder.rename(moved)
    folder.symlink_to(moved)
    before = sorted(path.name for path in moved.iterdir())
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    assert sorted(path.name for path in moved.iterdir()) == before and folder.is_symlink()


LIBRARY_MAIN = 'import Foo from "pkg/foo"\n\ndef main() -> Void\n  puts(Foo.word())\nend\n'


def library_project(tmp_path):
    """A program that imports pkg/foo, with the library in the user's folder (`later`), and the environment for it."""
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.agc").write_text(LIBRARY_MAIN, encoding="utf-8")
    home = tmp_path / "home"
    (home / ".local" / "share" / "agentica" / "lib").mkdir(parents=True)
    (home / ".local" / "share" / "agentica" / "lib" / "foo.agc").write_text(UTIL % "later", encoding="utf-8")
    return src, {"HOME": str(home), "XDG_DATA_HOME": None, "AGENTICA_PATH": ""}


@pytest.mark.parametrize("earlier", [
    "agc_libs",
    pytest.param("agc_libs beside a link", marks=LINKS),
    "AGENTICA_PATH",
])
def test_a_library_that_appears_in_an_earlier_folder_of_the_search_misses(tmp_path, earlier):
    src, extra = library_project(tmp_path)
    where = src / "agc_libs"
    if earlier == "AGENTICA_PATH":
        where = tmp_path / "first"
        where.mkdir()
        extra["AGENTICA_PATH"] = str(where)
    else:
        where.mkdir()
    if earlier == "agc_libs beside a link":
        # Any .agc link in a folder of the search used to make the listing of it a constant.
        (tmp_path / "x.agc").write_text(UTIL % "x", encoding="utf-8")
        (where / "x.agc").symlink_to(tmp_path / "x.agc")
    first = agentica(src, "main.agc", **extra)
    assert (first.code, first.stdout) == (0, "later\n"), first.stderr
    entry = only_entry(src / ".agc_cache")
    kept = stamp(entry)
    assert agentica(src, "main.agc", **extra).stdout == "later\n"
    assert stamp(entry) == kept
    (where / "foo.agc").write_text(UTIL % "earlier", encoding="utf-8")
    again = agentica(src, "main.agc", **extra)
    assert (again.code, again.stdout) == (0, "earlier\n"), again.stderr
    assert stamp(entry) != kept


def test_a_change_of_the_library_path_misses(tmp_path):
    src, extra = library_project(tmp_path)
    for name, word in (("one", "from one"), ("two", "from two")):
        (tmp_path / name).mkdir()
        (tmp_path / name / "foo.agc").write_text(UTIL % word, encoding="utf-8")
    extra["AGENTICA_PATH"] = str(tmp_path / "one")
    assert agentica(src, "main.agc", **extra).stdout == "from one\n"
    entry = only_entry(src / ".agc_cache")
    kept = stamp(entry)
    extra["AGENTICA_PATH"] = str(tmp_path / "two")
    again = agentica(src, "main.agc", **extra)
    assert (again.code, again.stdout) == (0, "from two\n"), again.stderr
    assert stamp(entry) != kept


def test_a_manifest_that_appears_in_a_parent_folder_misses(src, tmp_path):
    inner = src / "inner"
    inner.mkdir()
    (inner / "main.agc").write_text(program("deep"), encoding="utf-8")
    assert agentica(inner, "main.agc").stdout == "deep\n"
    entry = only_entry(inner / ".agc_cache")
    kept = stamp(entry)
    assert agentica(inner, "main.agc").stdout == "deep\n" and stamp(entry) == kept
    (src / "agentica.toml").write_text('name = "app"\n\n[dependencies]\n', encoding="utf-8")
    again = agentica(inner, "main.agc")
    assert (again.code, again.stdout) == (0, "deep\n"), again.stderr
    assert stamp(entry) != kept


@LINKS
def test_an_import_through_a_link_that_is_retargeted_misses(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.agc").write_text(MAIN.replace('"util"', '"link"'), encoding="utf-8")
    (src / "a.agc").write_text(UTIL % "A", encoding="utf-8")
    (src / "b.agc").write_text(UTIL % "B", encoding="utf-8")
    (src / "link.agc").symlink_to("a.agc")
    assert agentica(src, "main.agc").stdout == "A\n"
    entry = only_entry(src / ".agc_cache")
    kept = stamp(entry)
    (src / "link.agc").unlink()
    (src / "link.agc").symlink_to("b.agc")
    again = agentica(src, "main.agc")
    assert (again.code, again.stdout) == (0, "B\n"), again.stderr
    assert stamp(entry) != kept


def test_a_run_that_writes_removes_the_old_temporary_files_and_nothing_else(src):
    agentica(src, "main.agc")
    folder = src / ".agc_cache"
    names = ("a.agcb.tmp-1", "b.agcb.tmp-2", "c.txt", "d.agcb.tmp-3")
    old, fresh, other, kept_folder = (folder / name for name in names)
    for path in (old, fresh, other):
        path.write_text("x", encoding="utf-8")
    kept_folder.mkdir()
    long_ago = old.stat().st_mtime - 2 * 3600
    for path in (old, other, kept_folder):
        os.utime(path, (long_ago, long_ago))
    (src / "util.agc").write_text(UTIL % "two", encoding="utf-8")
    assert agentica(src, "main.agc").stdout == "two\n"
    assert not old.exists()
    assert fresh.exists() and other.exists() and kept_folder.is_dir()


def test_a_folder_at_the_name_of_the_entry_is_not_removed(src):
    agentica(src, "main.agc")
    entry = only_entry(src / ".agc_cache")
    entry.unlink()
    entry.mkdir()
    (entry / "inside").write_text("x", encoding="utf-8")
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    assert (entry / "inside").is_file()
