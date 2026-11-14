"""Property test (Hypothesis) of the C compiler in the key of the bytecode cache (#1568).

`CacheFiles.compiler_path` names the files a native build would start for CC; the first must be the one that
`Process.spawn_captured` runs. Each example builds a tree of folders with stand-in compilers (a C probe that prints its
own path), plain files, folders and links of the compiler's names, then runs tests/fixtures/cache/compiler_lookup.agc
with a generated PATH and CC: it prints the key's compiler and what the start of the same name ran. The profiles and the
seed of each tier are in tests/conftest.py; this module draws 25 examples in the fast tier and 300 in the slow one.
"""
import os
import shutil
import tempfile
from importlib.util import find_spec
from pathlib import Path

import pytest

from tests.agentica_test import ROOT, SLOW, WINDOWS, cli, require, run, tool, vm_environment

require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import given, settings, strategies as st  # noqa: E402

FIXTURES = ROOT / "tests" / "fixtures" / "cache"
FOLDERS = ["d0", "d1", "d2", "d;3" if WINDOWS else "d3"]
NAMES = ["agcc", "agcc.exe", "agcc.com", "AGCC.EXE", "agcc.cmd", "agcc.", "agcc.x"] if WINDOWS else ["agcc", "ag.cc"]
KINDS = ["none", "probe", "plain", "folder"] + ([] if WINDOWS else ["link", "dangling"])


@pytest.fixture(scope="module")
def tools(tmp_path_factory):
    """The compiled lookup program, the probe binary and a folder for the trees."""
    work = tmp_path_factory.mktemp("cache-compiler")
    probe = work / ("probe.exe" if WINDOWS else "probe")
    built = run([tool("gcc" if WINDOWS else "cc"), "-o", str(probe), str(FIXTURES / "compiler_probe.c")])
    assert built.code == 0, built
    lookup = work / "lookup.agcb"
    compiled = run(cli() + ["compile", str(FIXTURES / "compiler_lookup.agc"), "-o", str(lookup)])
    assert compiled.code == 0, compiled
    return lookup, probe, work


def file_names(name):
    """The files a start of `name` may run: NAME, and on Windows NAME.exe and NAME.com."""
    return [name, name + ".exe", name + ".com"] if WINDOWS else [name]


@st.composite
def cases(draw):
    name = draw(st.sampled_from(NAMES))
    # None is a missing folder; "." is the working folder, where the program runs.
    folders = {folder: draw(st.none() | st.dictionaries(st.sampled_from(file_names(name)), st.sampled_from(KINDS)))
               for folder in FOLDERS + ["."]}
    entry = st.one_of(
        st.sampled_from(FOLDERS).map(lambda folder: ("absolute", folder)),
        st.sampled_from(FOLDERS).map(lambda folder: ("slash", folder)),
        st.sampled_from(FOLDERS).map(lambda folder: ("relative", folder)),
        st.just(("text", "")),
        st.just(("text", ".")),
        st.just(("missing", "gone")),
        *([st.sampled_from(FOLDERS).map(lambda folder: ("quoted", folder)), st.just(("text", '""'))] if WINDOWS else []))
    path = draw(st.none() | st.lists(entry, max_size=6))
    command = draw(st.one_of(
        st.just(("bare", "")),
        st.sampled_from(FOLDERS).map(lambda folder: ("absolute", folder)),
        st.sampled_from(FOLDERS).map(lambda folder: ("relative", folder))))
    return name, folders, path, command


def build(root, probe, folders):
    store = root / "store"
    store.mkdir()
    shutil.copy(probe, store / "linked")
    for folder, files in folders.items():
        if files is None:
            continue
        place = root / folder
        place.mkdir(exist_ok=True)
        for file, kind in files.items():
            target = place / file
            if kind == "probe":
                shutil.copy(probe, target)
            elif kind == "plain":
                target.write_bytes(b"not a program\n")
                target.chmod(0o644)
            elif kind == "folder":
                target.mkdir()
            elif kind == "link":
                target.symlink_to(store / "linked")
            elif kind == "dangling":
                target.symlink_to(store / "gone")


def path_value(root, path):
    if path is None:
        return None
    separator = ";" if WINDOWS else ":"
    words = {
        "absolute": lambda folder: str(root / folder),
        "slash": lambda folder: str(root / folder) + os.sep,
        "relative": lambda folder: folder,
        "quoted": lambda folder: '"%s"' % (root / folder),
        "missing": lambda folder: str(root / folder),
        "text": lambda text: text,
    }
    return separator.join(words[kind](value) for kind, value in path)


def command_value(root, name, command):
    kind, folder = command
    if kind == "bare":
        return name
    return str(root / folder / name) if kind == "absolute" else folder + "/" + name


def same_file(a, b):
    return os.path.normcase(os.path.realpath(a)) == os.path.normcase(os.path.realpath(b))


def runs(path, probe):
    """Whether the file the key names starts: a probe the user may execute."""
    return os.path.isfile(path) and os.access(path, os.X_OK) and open(path, "rb").read() == probe.read_bytes()


@settings(max_examples=300 if SLOW else 25)
@given(cases())
def test_the_compiler_in_the_cache_key_is_the_file_that_a_start_by_name_runs(tools, case):
    lookup, probe, work = tools
    name, folders, path, command = case
    root = tempfile.mkdtemp(dir=work)
    try:
        root = Path(root)
        build(root, probe, folders)
        cc = command_value(root, name, command)
        result = run(cli() + ["run", "--", str(lookup)], cwd=root,
                     env=vm_environment({"CC": cc, "PATH": path_value(root, path)}))
        assert result.code == 0, result
        key, ran = result.stdout.rstrip().split("\n", 1)
        words = key.split(" ") if key else []
        assert len(words) % 2 == 0, key
        if not words:
            assert ran.startswith("error") and "unavailable" in ran, (key, ran)
        elif runs(words[1], probe):
            assert ran.startswith("ran ") and same_file(ran[4:], words[1]), (key, ran)
        else:
            assert ran.startswith("error") and "unavailable" not in ran, (key, ran)
    finally:
        shutil.rmtree(root, ignore_errors=True)
