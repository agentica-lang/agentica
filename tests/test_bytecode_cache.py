"""The bytecode cache of `agentica FILE.agc` and `agentica test` (issue #375), through the CLI.

A hit is proved without timing: the program kept in an entry is swapped for another valid program (with the digest of
the entry's text fixed), and the run then does what the swapped program does, which only a run that read the entry can
do. A miss is an entry that was written again. The layout of an entry is in compiler/io/bytecode_cache.agc.
"""
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess

import pytest

from tests.agentica_test import POSIX_PYTHON, ROOT, STAGE2, WINDOWS, cli, host_only, require, run, tool, vm_environment
from tests.package_support import Workspace, dependency
from tests.test_examples_native_module import EXAMPLE, OUTPUT as EXAMPLE_OUTPUT
from tests.test_vm_native import NATIVE_CALLS

HEAD_BYTES = 18

# root can write into a folder whatever its mode, so the case with a read-only folder does not hold for it.
ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0


def program(message):
    return 'def main() -> Void\n  puts("%s")\nend\n' % message


MAIN = 'import Util from "util"\n\ndef main() -> Void\n  puts(Util.word())\nend\n'
UTIL = 'def word() -> String\n  return "%s"\nend\n'
PASSING = 'def main() -> Void\n  Test.run([Test.test("fine") do\n    ok()\n  end])\nend\n'
FAILING = 'def main() -> Void\n  Test.run([Test.test("fine") do\n    error("changed")\n  end])\nend\n'
TEST_FUNCTIONS = 'def test_fine() -> Result[Void]\n  return ok()\nend\n'


def environment(**extra):
    """The environment of a case: no build folder of the harness, so an entry goes to the `_build/` of the sources."""
    return vm_environment({"AGENTICA_BUILD_DIR": None, **extra})


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
    entry = only_entry(src / "_build" / "bytecode")
    # The _build folder holds a .gitignore of its own, so the bytecode is not committed by mistake.
    assert (src / "_build" / ".gitignore").read_text(encoding="utf-8") == "*\n"
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


def test_check_and_dump_neither_read_nor_write_the_entry_and_compile_reads_and_writes_it(src, tmp_path):
    agentica(src, "main.agc")
    entry = only_entry(src / "_build" / "bytecode")
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    kept = stamp(entry)
    assert agentica(src, "check", "main.agc").code == 0
    assert agentica(src, "--dump", "main.agc").code == 0
    assert stamp(entry) == kept
    # `compile` serves a hit as a run does (#1458), and `--no-cache` compiles the sources.
    assert agentica(src, "compile", "main.agc", "-o", "main.agcb").code == 0
    assert b"from the entry" in (src / "main.agcb").read_bytes()
    assert agentica(src, "--no-cache", "compile", "main.agc", "-o", "main.agcb").code == 0
    assert b"from the entry" not in (src / "main.agcb").read_bytes()
    assert stamp(entry) == kept
    # Where there is no entry, check and dump make none, and compile makes one.
    other = src.parent / "other"
    other.mkdir()
    (other / "main.agc").write_text(program("x"), encoding="utf-8")
    for words in (("check", "main.agc"), ("--dump-ir", "main.agc")):
        assert agentica(other, *words).code == 0
    assert not (other / "_build").exists()
    assert agentica(other, "compile", "main.agc", "-o", "main.agcb").code == 0
    assert only_entry(other / "_build" / "bytecode").is_file()


def test_a_program_of_several_write_pieces_round_trips_through_the_entry_and_compile(tmp_path):
    """One File.write_bytes takes 1 MiB, so the entry and the compiled file of a program of a few MiB are written in
    pieces; a miss and a hit write the same bytes, and both run."""
    (tmp_path / "big.agc").write_text(
        'BIG = "%s"\n\ndef main() -> Void\n  puts(BIG.length)\nend\n' % ("abcdefg" * 360_000), encoding="utf-8"
    )
    assert agentica(tmp_path, "compile", "big.agc", "-o", "miss.agcb").code == 0
    entry = only_entry(tmp_path / "_build" / "bytecode")
    missed = (tmp_path / "miss.agcb").read_bytes()
    assert len(missed) > 2 * 1_048_576 and len(missed) % 1_048_576 != 0
    assert split(entry)[1] == missed
    kept = stamp(entry)
    assert agentica(tmp_path, "compile", "big.agc", "-o", "hit.agcb").code == 0
    assert stamp(entry) == kept
    assert (tmp_path / "hit.agcb").read_bytes() == missed
    for words in (("big.agc",), ("run", "--", "hit.agcb")):
        done = agentica(tmp_path, *words)
        assert (done.code, done.stdout) == (0, "2520000\n"), done.stderr


def test_a_damaged_entry_is_built_again(src):
    agentica(src, "main.agc")
    entry = only_entry(src / "_build" / "bytecode")
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


@pytest.mark.parametrize("variable", [False, True], ids=["next to the sources", "AGENTICA_BUILD_DIR"])
def test_no_cache_neither_reads_nor_writes_and_the_variable_moves_the_entries(src, tmp_path, variable):
    elsewhere = tmp_path / "elsewhere"
    extra = {"AGENTICA_BUILD_DIR": str(elsewhere)} if variable else {}
    on = agentica(src, "main.agc", **extra)
    assert (on.code, on.stdout) == (0, "one\n"), on.stderr
    folder = (elsewhere if variable else src / "_build") / "bytecode"
    assert (src / "_build").exists() != variable
    entry = only_entry(folder)
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    kept = stamp(entry)
    skipped = agentica(src, "--no-cache", "main.agc", **extra)
    assert (skipped.code, skipped.stdout) == (0, "one\n"), skipped.stderr
    assert stamp(entry) == kept
    again = agentica(src, "main.agc", **extra)
    assert again.stdout == "from the entry\n", again.stderr


def test_a_front_end_given_with_front_end_neither_reads_nor_writes_the_entry(src, tmp_path):
    """The key of an entry names the binary, not the front end, so one from --front-end uses no cache (#1489)."""
    require(STAGE2.is_file(), "the front end is not built (%s): run make" % STAGE2)
    agentica(src, "main.agc")
    folder = src / "_build" / "bytecode"
    entry = only_entry(folder)
    other = compiled(tmp_path, "other", program("from the entry"))
    swap_program(entry, other)
    kept = stamp(entry)
    given = agentica(src, "--front-end", STAGE2, "main.agc")
    assert (given.code, given.stdout) == (0, "one\n"), given.stderr
    assert stamp(entry) == kept
    entry.unlink()
    for _ in range(2):
        given = agentica(src, "--front-end", STAGE2, "main.agc")
        assert (given.code, given.stdout) == (0, "one\n"), given.stderr
        assert entries(folder) == []
    # The binary's own front end still writes and reads the entry.
    assert agentica(src, "main.agc").stdout == "one\n"
    swap_program(only_entry(folder), other)
    assert agentica(src, "main.agc").stdout == "from the entry\n"


@host_only(WINDOWS, "the folder is made read-only with its mode bits")
def test_a_folder_that_cannot_be_written_still_runs(src):
    src.chmod(stat.S_IRUSR | stat.S_IXUSR)
    try:
        done = agentica(src, "main.agc")
    finally:
        src.chmod(stat.S_IRWXU)
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    # root writes to a folder whatever its mode, so only the run is checked for it.
    assert ROOT_USER or not (src / "_build").exists()


GREETER = "https://github.com/owner/greeter.git"
GREET = {"greet.agc": 'def hello() -> String\n  return "hi"\nend\n'}


def greeter_project(tmp_path):
    """A project whose main.agc prints "hi" from the locked package greeter (which has a manifest and no native
    files), and the variables that keep its runs to its own folders."""
    ws = Workspace(tmp_path)
    ws.add_package("greeter", GREETER, GREET, tag="v1.0.0", dependencies={})
    ws.write_manifest({"greeter": dependency(GREETER, tag="v1.0.0")})
    ws.write_lock()
    (ws.project / "main.agc").write_text(
        'import Greet from "pkg/greeter/greet"\n\ndef main() -> Void\n  puts(Greet.hello())\nend\n', encoding="utf-8")
    return ws, {"AGENTICA_PATH": "", **ws.cache_variables}


def test_a_change_of_the_lock_misses(tmp_path):
    ws, hermetic = greeter_project(tmp_path)
    other = ws.add_package("greeter", GREETER, GREET, tag="v1.0.0", dependencies={}, commit="b" * 40)
    ws.locked.remove(other)
    ws.write_lock()
    first = agentica(ws.project, "main.agc", **hermetic)
    assert (first.code, first.stdout) == (0, "hi\n"), first.stderr
    entry = only_entry(ws.project / "_build" / "bytecode")
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
    first = agentica(tmp_path, "--json", "test", folder, AGENTICA_BUILD_DIR=str(cache))
    assert first.code == 0, first.stdout + first.stderr
    entry = only_entry(cache / "bytecode")
    assert not (folder / "_build").exists()
    swap_program(entry, compiled(tmp_path, "failing_test", FAILING))
    kept = stamp(entry)
    second = agentica(tmp_path, "--json", "test", folder, AGENTICA_BUILD_DIR=str(cache))
    assert second.code == 1, second.stdout + second.stderr
    assert "changed" in second.stdout
    assert stamp(entry) == kept
    # --no-cache compiles the file again, and leaves the entry as it is.
    third = agentica(tmp_path, "--no-cache", "--json", "test", folder, AGENTICA_BUILD_DIR=str(cache))
    assert third.code == 0, third.stdout + third.stderr
    assert stamp(entry) == kept
    assert json.loads(third.stdout)["files"]


def test_a_test_file_compiled_for_agentica_test_has_its_own_entry(tmp_path):
    # `agentica test` adds the `main` of the test functions; a run of the same file must not get that program.
    folder = tmp_path / "specs"
    folder.mkdir()
    (folder / "one_test.agc").write_text(TEST_FUNCTIONS, encoding="utf-8")
    cache = tmp_path / "cache"
    tested = agentica(tmp_path, "--json", "test", folder, AGENTICA_BUILD_DIR=str(cache))
    assert tested.code == 0, tested.stdout + tested.stderr
    only_entry(cache / "bytecode")
    ran = agentica(tmp_path, "--json", folder / "one_test.agc", AGENTICA_BUILD_DIR=str(cache))
    assert ran.code == 1
    assert json.loads(ran.stderr.strip().split("\n")[-1])["code"] == "CHECK-MAIN"
    (folder / "one_test.agc").write_text(PASSING, encoding="utf-8")
    agentica(tmp_path, folder / "one_test.agc", AGENTICA_BUILD_DIR=str(cache))
    assert len(entries(cache / "bytecode")) == 2


POSIX_ONLY = host_only(not POSIX_PYTHON, "file modes and owners bind a POSIX system")


@POSIX_ONLY
@pytest.mark.parametrize("level", ["_build", "bytecode"])
def test_a_folder_that_others_can_write_is_not_used_and_not_written(src, tmp_path, level):
    agentica(src, "main.agc")
    folder = src / "_build" / "bytecode"
    at_level = folder if level == "bytecode" else src / "_build"
    assert stat.S_IMODE(at_level.stat().st_mode) == stat.S_IRWXU
    entry = only_entry(folder)
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    kept = stamp(entry)
    at_level.chmod(0o770)
    (src / "util.agc").write_text(UTIL % "two", encoding="utf-8")
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "two\n"), done.stderr
    assert stamp(entry) == kept and [path.name for path in folder.iterdir() if ".tmp-" in path.name] == []
    # The same entry in a folder that is private again is read, so it was the mode that kept it out.
    at_level.chmod(0o700)
    (src / "util.agc").write_text(UTIL % "one", encoding="utf-8")
    assert agentica(src, "main.agc").stdout == "from the entry\n"


@POSIX_ONLY
def test_an_entry_that_others_can_write_is_replaced(src, tmp_path):
    agentica(src, "main.agc")
    entry = only_entry(src / "_build" / "bytecode")
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    entry.chmod(0o666)
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    assert stat.S_IMODE(entry.stat().st_mode) == stat.S_IRUSR | stat.S_IWUSR


def test_a_link_in_place_of_the_entry_is_not_read_and_not_written_through(src, tmp_path):
    agentica(src, "main.agc")
    entry = only_entry(src / "_build" / "bytecode")
    swap_program(entry, compiled(tmp_path, "other", program("from the entry")))
    target = tmp_path / "target.agcb"
    target.write_bytes(entry.read_bytes())
    entry.unlink()
    entry.symlink_to(target)
    kept = target.read_bytes()
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    assert target.read_bytes() == kept and not entry.is_symlink() and entry.is_file()


@pytest.mark.parametrize("level", ["_build", "bytecode"])
def test_a_link_in_place_of_a_folder_is_not_used_and_nothing_is_written_where_it_leads(src, tmp_path, level):
    agentica(src, "main.agc")
    folder = src / "_build" / "bytecode" if level == "bytecode" else src / "_build"
    swap_program(only_entry(src / "_build" / "bytecode"), compiled(tmp_path, "other", program("from the entry")))
    moved = tmp_path / "moved"
    folder.rename(moved)
    folder.symlink_to(moved, target_is_directory=True)
    before = sorted(path.name for path in moved.iterdir())
    (src / "util.agc").write_text(UTIL % "two", encoding="utf-8")
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "two\n"), done.stderr
    assert sorted(path.name for path in moved.iterdir()) == before and folder.is_symlink()


LIBRARY_MAIN = 'import Foo from "pkg/foo"\n\ndef main() -> Void\n  puts(Foo.word())\nend\n'


def library_project(tmp_path):
    """A program that imports pkg/foo, with the library in the user's folder (`later`), and the environment for it."""
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.agc").write_text(LIBRARY_MAIN, encoding="utf-8")
    # The user folder is <data>/agentica/lib, with <data> from XDG_DATA_HOME, or from %LOCALAPPDATA% on Windows (which
    # reads neither XDG_DATA_HOME nor HOME).
    data = tmp_path / "data"
    (data / "agentica" / "lib").mkdir(parents=True)
    (data / "agentica" / "lib" / "foo.agc").write_text(UTIL % "later", encoding="utf-8")
    return src, {"HOME": None, "XDG_DATA_HOME": str(data), "LOCALAPPDATA": str(data), "AGENTICA_PATH": ""}


@pytest.mark.parametrize("earlier", [
    "agc_libs",
    "agc_libs beside a link",
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
    entry = only_entry(src / "_build" / "bytecode")
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
    entry = only_entry(src / "_build" / "bytecode")
    kept = stamp(entry)
    extra["AGENTICA_PATH"] = str(tmp_path / "two")
    again = agentica(src, "main.agc", **extra)
    assert (again.code, again.stdout) == (0, "from two\n"), again.stderr
    assert stamp(entry) != kept


def keeps_its_entry(folder, output, tmp_path, **hermetic):
    """The first run of main.agc in `folder` writes an entry with no compiler line, and runs with another `cc` in PATH,
    another CC and another CPATH read it."""
    first = agentica(folder, "main.agc", CC=None, **hermetic)
    assert (first.code, first.stdout) == (0, output), first.stderr
    entry = only_entry(folder / "_build" / "bytecode")
    kept = stamp(entry)
    assert "\ncompiler " not in split(entry)[0]
    executable(tmp_path / "other" / ("gcc.exe" if WINDOWS else "cc"))
    path = f"{tmp_path / 'other'}{os.pathsep}{os.environ['PATH']}"
    for extra in ({"CC": None, "PATH": path}, {"CC": "another-compiler"}, {"CC": None, "CPATH": str(tmp_path)}):
        hit = agentica(folder, "main.agc", **hermetic, **extra)
        assert (hit.code, hit.stdout, stamp(entry)) == (0, output, kept), hit.stderr


def test_a_program_with_no_native_module_keeps_its_entry_when_the_c_compiler_changes(src, tmp_path):
    """Only a native module is built with the C compiler, so the entry of any other program does not hold it, and a
    start does not look for it (#1551). A package with no native files changes nothing."""
    keeps_its_entry(src, "one\n", tmp_path)
    ws, hermetic = greeter_project(tmp_path / "packaged")
    keeps_its_entry(ws.project, "hi\n", tmp_path, **hermetic)


def executable(path, text="#!/bin/sh\n"):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


class Native:
    """A copy of examples/native_module, whose run builds a module with the C compiler, with a package cache of its
    own. `run` gives the result and the entry's stamp after it."""

    def __init__(self, tmp_path):
        self.compiler = tool("gcc" if WINDOWS else "cc")
        self.folder = shutil.copytree(EXAMPLE, tmp_path / "native", ignore=shutil.ignore_patterns("_build"))
        self.cache = {"LOCALAPPDATA": tmp_path / "cache"} if WINDOWS else {"XDG_CACHE_HOME": tmp_path / "cache"}

    def run(self, path, **extra):
        result = agentica(self.folder, "stats.agc", **{"CC": None, "PATH": path, **self.cache, **extra})
        return result, stamp(only_entry(self.folder / "_build" / "bytecode"))

    def first(self, path):
        """The stamp of the entry that the first run makes."""
        result, kept = self.run(path)
        assert (result.code, result.stdout) == (0, EXAMPLE_OUTPUT), result.stderr
        assert "\ncompiler " in split(only_entry(self.folder / "_build" / "bytecode"))[0]
        return kept

    def wrapper(self, path):
        """A stand-in compiler at `path` that runs the real one."""
        executable(path, f'#!/bin/sh\nexec "{self.compiler}" "$@"\n')


@pytest.fixture
def native(tmp_path):
    return Native(tmp_path)


@NATIVE_CALLS
def test_with_a_native_module_a_change_of_cc_or_of_a_search_variable_misses(native, tmp_path):
    path = os.environ["PATH"]
    kept = native.first(path)
    for extra in ({"CC": "gcc" if WINDOWS else "cc"}, {"CPATH": tmp_path}):
        miss, after = native.run(path, **extra)
        assert (miss.code, miss.stdout) == (0, EXAMPLE_OUTPUT), miss.stderr
        assert after != kept
        hit, kept = native.run(path, **extra)
        assert (hit.code, kept) == (0, after), hit.stderr


@NATIVE_CALLS
@host_only(WINDOWS, "the stand-in compiler is a shell script")
def test_with_a_native_module_another_path_hits_unless_it_finds_another_c_compiler(native, tmp_path):
    """The entry of a program with a native module holds the C compiler file the build runs (`cc` found in PATH), not
    PATH: a venv-like folder in front of PATH keeps the entry, and one whose `cc` shadows the system's misses."""
    kept = native.first(os.environ["PATH"])
    venv = tmp_path / "venv"
    executable(venv / "python3")
    hit, after = native.run(f"{venv}{os.pathsep}{os.environ['PATH']}")
    assert (hit.code, hit.stdout, after) == (0, EXAMPLE_OUTPUT, kept), hit.stderr
    native.wrapper(venv / "cc")
    miss, after = native.run(f"{venv}{os.pathsep}{os.environ['PATH']}")
    assert (miss.code, miss.stdout) == (0, EXAMPLE_OUTPUT), miss.stderr
    assert after != kept


@NATIVE_CALLS
@host_only(WINDOWS, "the stand-in compilers are shell scripts")
def test_a_wrapper_like_ccache_misses_when_the_compiler_after_it_changes(native, tmp_path):
    """`cc` in a ccache-like folder is a link to the wrapper, which runs the next `cc` of PATH: the entry holds that
    one too, so a PATH that puts another compiler after the wrapper misses."""
    native.wrapper(tmp_path / "ccache")
    (tmp_path / "wrap").mkdir()
    (tmp_path / "wrap" / "cc").symlink_to(tmp_path / "ccache")
    native.wrapper(tmp_path / "first" / "cc")
    native.wrapper(tmp_path / "second" / "cc")
    with_first = os.pathsep.join([str(tmp_path / "wrap"), str(tmp_path / "first"), os.environ["PATH"]])
    with_second = os.pathsep.join([str(tmp_path / "wrap"), str(tmp_path / "second"), os.environ["PATH"]])
    kept = native.first(with_first)
    hit, after = native.run(with_first)
    assert (hit.code, after) == (0, kept), hit.stderr
    miss, after = native.run(with_second)
    assert (miss.code, miss.stdout) == (0, EXAMPLE_OUTPUT), miss.stderr
    assert after != kept


@NATIVE_CALLS
@host_only(WINDOWS, "the stand-in PATH is that of POSIX")
def test_an_unset_path_finds_no_compiler_and_an_empty_entry_is_skipped(native):
    """Process.spawn searches only the non-empty entries of PATH, and none when PATH is unset (resolve in
    vm/process.c): empty entries keep the entry, and an unset PATH misses, so the build runs and finds no compiler."""
    default = "/usr/bin:/bin"
    kept = native.first(default)
    empty, after = native.run(":" + default + ":")
    assert (empty.code, after) == (0, kept), empty.stderr
    unset, _ = native.run(None)
    assert unset.code != 0 and "PKG-NATIVE-BUILD" in unset.stderr, unset.stderr


@NATIVE_CALLS
@host_only(not WINDOWS, "the .exe and .com search of Process.spawn is that of Windows")
def test_on_windows_a_gcc_com_before_the_gcc_exe_that_was_found_misses(native, tmp_path):
    """Process.spawn tries NAME.exe, then NAME.com, in each folder of PATH in turn, so a gcc.com in an earlier folder
    is the compiler that runs: the entry misses, and the build fails on the stand-in."""
    (tmp_path / "first").mkdir()
    path = os.pathsep.join([str(tmp_path / "first"), os.environ["PATH"]])
    kept = native.first(path)
    hit, after = native.run(path)
    assert (hit.code, after) == (0, kept), hit.stderr
    (tmp_path / "first" / "gcc.com").write_bytes(b"")
    miss, _ = native.run(path)
    assert miss.code != 0 and "PKG-NATIVE-BUILD" in miss.stderr, miss.stderr


def test_the_entries_of_a_project_go_to_its_root_and_a_manifest_that_appears_in_a_parent_folder_misses(src):
    inner = src / "inner"
    inner.mkdir()
    (inner / "main.agc").write_text(program("deep"), encoding="utf-8")
    assert agentica(inner, "main.agc").stdout == "deep\n"
    # No project: the folder is beside the file.
    entry = only_entry(inner / "_build" / "bytecode")
    kept = stamp(entry)
    assert agentica(inner, "main.agc").stdout == "deep\n" and stamp(entry) == kept
    (src / "agentica.toml").write_text('name = "app"\n\n[dependencies]\n', encoding="utf-8")
    # The manifest changes the key, so the old entry is not read, and the new one is in the folder of the project.
    again = agentica(inner, "main.agc")
    assert (again.code, again.stdout) == (0, "deep\n"), again.stderr
    assert stamp(entry) == kept
    moved = only_entry(src / "_build" / "bytecode")
    swap_program(moved, compiled(src.parent, "other", program("from the entry")))
    assert agentica(inner, "main.agc").stdout == "from the entry\n"


def test_an_import_through_a_link_that_is_retargeted_misses(tmp_path):
    src = tmp_path / "src"
    src.mkdir()
    (src / "main.agc").write_text(MAIN.replace('"util"', '"link"'), encoding="utf-8")
    (src / "a.agc").write_text(UTIL % "A", encoding="utf-8")
    (src / "b.agc").write_text(UTIL % "B", encoding="utf-8")
    (src / "link.agc").symlink_to("a.agc")
    assert agentica(src, "main.agc").stdout == "A\n"
    entry = only_entry(src / "_build" / "bytecode")
    kept = stamp(entry)
    (src / "link.agc").unlink()
    (src / "link.agc").symlink_to("b.agc")
    again = agentica(src, "main.agc")
    assert (again.code, again.stdout) == (0, "B\n"), again.stderr
    assert stamp(entry) != kept


def test_a_run_that_writes_removes_the_old_temporary_files_and_nothing_else(src):
    agentica(src, "main.agc")
    folder = src / "_build" / "bytecode"
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
    entry = only_entry(src / "_build" / "bytecode")
    entry.unlink()
    entry.mkdir()
    (entry / "inside").write_text("x", encoding="utf-8")
    done = agentica(src, "main.agc")
    assert (done.code, done.stdout) == (0, "one\n"), done.stderr
    assert (entry / "inside").is_file()

# The launcher (compiler/app/cli_hit.agc) serves a hit without the front end; the front end serves everything else. A
# case is the files of a folder, the words after `agentica` and whether the program compiles (a hit follows). The exit
# status of EXITS is the one a launcher that missed ends with (MISSED_STATUS).
ARGS = 'def main() -> Void\n  puts(System.args())\nend\n'
EXITS = 'def main() -> Void\n  puts("before")\n  System.exit(3)\nend\n'
FAILS = 'def main() -> Void\n  xs: List[Int] = [1]\n  puts(xs[System.args().size + 3])\nend\n'
REJECTED = 'def main() -> Void\n  puts(nope)\nend\n'
LOOPS = 'def main() -> Void\n  n = 0\n  while n >= 0\n    n += 1\n  end\nend\n'
READS = 'def main() -> Void\n  puts(File.read_text("main.agc", 1000).ok?)\nend\n'
LAUNCHES = [
    ("arguments", {"main.agc": ARGS}, ["main.agc", "a", "--json", "b c"], True),
    ("options end", {"main.agc": ARGS}, ["--", "main.agc", "-x"], True),
    ("modules", {"main.agc": MAIN, "util.agc": UTIL % "one"}, ["main.agc"], True),
    ("exit status", {"main.agc": EXITS}, ["main.agc"], True),
    ("runtime error", {"main.agc": FAILS}, ["main.agc"], True),
    ("runtime error json", {"main.agc": FAILS}, ["--json", "main.agc"], True),
    ("runtime error ai", {"main.agc": FAILS}, ["--ai", "main.agc"], True),
    ("check error", {"main.agc": REJECTED}, ["main.agc"], False),
    ("check error json", {"main.agc": REJECTED}, ["--json", "main.agc"], False),
    ("missing file", {}, ["main.agc"], False),
    ("step limit", {"main.agc": LOOPS}, ["--max-steps", "500", "main.agc"], True),
    ("step limit json", {"main.agc": LOOPS}, ["--json", "--max-steps", "500", "main.agc"], True),
    ("denied", {"main.agc": READS}, ["--deny-fs", "main.agc"], True),
    ("allowed", {"main.agc": READS}, ["main.agc"], True),
    ("unknown option", {"main.agc": ARGS}, ["--nope", "main.agc"], False),
    ("option after the file", {"main.agc": ARGS}, ["main.agc", "--max-steps"], False),
]


def loads(result):
    """How many programs the run loaded, from the loader trace on stderr."""
    return result.stderr.count(" loader file bytes=")


def untraced(result):
    return result.code, result.stdout, "".join(
        line for line in result.stderr.splitlines(keepends=True) if not line.startswith("agc-trace "))


def traced_build():
    return b"trace off" not in subprocess.run(cli() + ["run", "--version"], capture_output=True).stdout


@pytest.mark.parametrize("name, files, words, compiles", LAUNCHES, ids=[case[0] for case in LAUNCHES])
def test_without_the_cache_on_a_miss_and_on_a_hit_a_run_prints_and_ends_alike(tmp_path, name, files, words, compiles):
    """`--no-cache` is the front end alone. The first run with the cache is a miss, which the launcher leaves to the
    front end, and the second a hit, which the launcher serves (when the program compiled): the three print the same
    and end with the same status."""
    for file, text in files.items():
        (tmp_path / file).write_text(text, encoding="utf-8")
    plain = agentica(tmp_path, "--no-cache", *words)
    miss = agentica(tmp_path, *words, AGENTICA_VM_TRACE="loader")
    hit = agentica(tmp_path, *words, AGENTICA_VM_TRACE="loader")
    assert untraced(miss) == untraced(hit) == (plain.code, plain.stdout, plain.stderr)
    if compiles and traced_build():
        # A miss: the launcher, the front end, the program. A hit: the launcher and the program.
        assert (loads(miss), loads(hit)) == (3, 2), miss.stderr + hit.stderr


def test_a_hit_loads_the_launcher_and_the_program_and_no_front_end(src):
    require(traced_build(), "a binary with the trace built in")
    traced = {"AGENTICA_VM_TRACE": "loader"}
    plain = agentica(src, "--no-cache", "main.agc")
    miss = agentica(src, "main.agc", **traced)
    hit = agentica(src, "main.agc", **traced)
    assert untraced(miss) == untraced(hit) == (0, "one\n", "") == (plain.code, plain.stdout, plain.stderr)
    # A miss: the launcher, the front end, the program. A hit: the launcher and the program.
    assert (loads(miss), loads(hit)) == (3, 2), miss.stderr + hit.stderr
    # A command is the front end's alone, and a run that turns the cache off starts no launcher.
    assert loads(agentica(src, "check", "main.agc", **traced)) == 1
    assert loads(agentica(src, "--no-cache", "main.agc", **traced)) == 2


def test_the_commands_that_skip_the_launcher_in_c_are_those_of_the_command_line():
    """vm/agentica.c does not start the launcher for a command; its list is CliRun.COMMANDS."""
    driver = (ROOT / "vm" / "agentica.c").read_text(encoding="utf-8")
    listed = re.search(r"static const char \*const commands\[\] = \{(.*?)\};", driver, re.S).group(1)
    run = (ROOT / "compiler" / "app" / "cli_run.agc").read_text(encoding="utf-8")
    declared = re.search(r"^COMMANDS = \[(.*?)^\]", run, re.S | re.M).group(1)
    assert re.findall(r'"([^"]+)"', listed) == re.findall(r'"([^"]+)"', declared) != []
