"""The cache of checked modules of `agentica check` and `agentica type-at` (issue #630), through the CLI.

The rule under test is that the cache changes the time and nothing else: a run with the cache cold, a run with it warm
and a run with `--no-cache` give the same exit status and the same bytes, for `check`, `type-at` and `outline`, whatever
was edited or damaged since the entries were written. A hit is proved without timing: an entry is changed to say
something false about a constant, and only a run that read the entry shows it. The layout of an entry is in
compiler/modules/check_cache.agc.
"""
import json
import os
import re
import stat
from concurrent.futures import ThreadPoolExecutor

import pytest

from tests.agentica_test import POSIX_PYTHON, cli, host_only, run, vm_environment
from tests.package_support import Workspace, dependency
from tests.span_support import where

# No AGENTICA_PATH roots and no user data folder, so only what a case builds resolves.
HERMETIC = {"AGENTICA_PATH": "", "XDG_DATA_HOME": "/nonexistent-agentica-xdg",
            "LOCALAPPDATA": "/nonexistent-agentica-xdg"}

GIT = "https://github.com/owner/greeter.git"

# A module two levels down: a struct, a constant long enough to be blanked in the stub, one that is not, a multi-line
# one, non-ASCII text, a heredoc and a function with a body.
DEEP = '''import Shapes from "shapes"

export SIZE = 7
export ORIGIN = Shapes.Point(x: 0, y: 0)
export CHOICES = [Shapes.Kind.Round(1.5), Shapes.Kind.Flat]
export LABELS = ["alpha", "beta", "gamma", "delta", "épsilon"]
export TABLE = {
  "one": 1,
  "two": 2,
}

export struct Item
  name: String
  count: Int
end

export enum Pick
  One(Item)
  Nothing
end

export def make(name: String) -> Item
  total = SIZE * 2
  note = <<~TEXT
    héllo #{name}
    second line
  TEXT
  return Item(name: name + note, count: total)
end
'''

MID = '''import Deep from "deep"

export def build(name: String) -> Deep.Item
  return Deep.make(name)
end

export def pick(item: Deep.Item) -> Deep.Pick
  return Deep.Pick.One(item)
end
'''

SHAPES = '''export struct Point
  x: Int
  y: Int
end

export enum Kind
  Round(Float)
  Flat
end
'''

GREET = 'export def hello(name: String) -> String\n  return "hello " + name\nend\n'

MAIN = '''import Queue from "std/queue"
import Greet from "pkg/greeter/greet"
import Mid from "mid"
import Deep from "deep"
import Shapes from "shapes"

def main() -> Void
  item = Mid.build("a")
  size: Int = Deep.SIZE
  origin: Shapes.Point = Deep.ORIGIN
  choices: List[Shapes.Kind] = Deep.CHOICES
  start: List[String] = Deep.LABELS
  queue = Queue.push(Queue.new(), item.name)
  puts(Greet.hello(item.name))
  puts(size.to_s)
  puts(Queue.size(queue).to_s)
  puts(origin.x.to_s)
  puts(choices.size.to_s)
  puts(start.join(","))
end
'''


def build(base, extra=""):
    """The project of the cases under `base`; `extra` is text for the end of its manifest."""
    workspace = Workspace(base)
    workspace.add_package("greeter", GIT, {"greet.agc": GREET}, tag="v1.0.0")
    workspace.write_manifest({"greeter": dependency(GIT, tag="v1.0.0")}, extra)
    workspace.write_lock()
    for name, text in (("main", MAIN), ("mid", MID), ("deep", DEEP), ("shapes", SHAPES)):
        (workspace.project / (name + ".agc")).write_text(text, encoding="utf-8")
    return workspace


@pytest.fixture
def ws(tmp_path):
    return build(tmp_path)


def folder_of(ws):
    return getattr(ws, "build", ws.base / "build")


def entries(ws):
    found = folder_of(ws) / "check"
    return sorted(found.glob("*.chk")) if found.is_dir() else []


def environment(ws, **extra):
    return vm_environment({**HERMETIC, **ws.cache_variables, "AGENTICA_BUILD_DIR": str(folder_of(ws)), **extra})


def ask(ws, words, **options):
    return run(cli() + [str(word) for word in words], cwd=ws.project, env=environment(ws), **options)


def answers(ws, *flags, source=MAIN, needle="Mid.build"):
    """What the three commands print for main.agc, as (code, stdout, stderr) each; `flags` (`--no-cache`) go before
    the command. The type is asked on `needle` in `source`, the text of main.agc."""
    position = "main.agc:%d:%d" % where(source, needle, 5)
    results = []
    for words in (["--json", *flags, "check", "main.agc"], ["--json", *flags, "type-at", position],
                  ["--json", *flags, "outline", "main.agc"]):
        done = ask(ws, words)
        results.append((done.code, done.stdout, done.stderr))
    return results


def settled(ws, *flags, **asked):
    """The answers with the cache cold (first run), warm (second) and off, which must be one; the answers."""
    cold = answers(ws, *flags, **asked)
    warm = answers(ws, *flags, **asked)
    off = answers(ws, "--no-cache", *flags, **asked)
    assert cold == warm == off
    return warm


def edit(ws, name, old, new):
    path = ws.project / (name + ".agc")
    text = path.read_text(encoding="utf-8")
    assert old in text
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def test_warm_cold_and_off_answer_alike_and_a_hit_skips_the_check(ws):
    first = settled(ws)
    assert first[0] == (0, '{"ok":true}\n', "")
    kept = entries(ws)
    # One entry for each file but the root: mid, deep, the package module and the standard library module.
    assert len(kept) >= 4
    # A run that finds every entry in place writes nothing.
    stamps = [(path.stat().st_mtime_ns, path.read_bytes()) for path in kept]
    answers(ws)
    assert [(path.stat().st_mtime_ns, path.read_bytes()) for path in entries(ws)] == stamps
    # An entry that lies about the type of `Deep.SIZE` changes what the root gets: only a run that read it can.
    tampered = [path for path in kept if b"\nconst SIZE i" in path.read_bytes()]
    assert len(tampered) == 1
    assert any(b"\nconst ORIGIN T@" in path.read_bytes() for path in kept)
    tampered[0].write_bytes(tampered[0].read_bytes().replace(b"\nconst SIZE i", b"\nconst SIZE s"))
    assert answers(ws)[0][0] == 1
    assert answers(ws, "--no-cache")[0] == (0, '{"ok":true}\n', "")


EDITS = [
    ("main", "puts(size.to_s)", "puts(size.to_s + 1.to_s)"),
    ("mid", "return Deep.make(name)", "return Deep.make(name + name)"),
    # Two levels down, in a body, in a constant and in a signature the root and the middle module use.
    ("deep", "total = SIZE * 2", "total = SIZE * 3"),
    ("deep", "export SIZE = 7", "export SIZE = 8"),
    ("deep", '"épsilon"', '"epsilon", "zeta"'),
    ("deep", "count: Int\nend", "count: Int\n  extra: Int = 0\nend"),
    # Errors: in the module two levels down, in the middle one, and in the root, each once the entries are there.
    ("deep", "total = SIZE * 2", "total = SIZE * missing"),
    ("mid", "Deep.make(name)", "Deep.make(1)"),
    ("main", "size: Int = Deep.SIZE", "size: String = Deep.SIZE"),
    ("deep", "export def make(name: String)", "export def make(name: Int)"),
    ("shapes", "x: Int", "x: Float"),
    ("shapes", "Flat\n", "Flat\n  Third\n"),
    ("greeter", 'return "hello " + name', "return 1 + name"),
]


@pytest.mark.parametrize("name,old,new", EDITS, ids=["%s-%d" % (step[0], at) for at, step in enumerate(EDITS)])
def test_an_edit_gives_the_answers_of_a_run_without_the_cache(ws, name, old, new):
    assert settled(ws)[0][0] == 0
    if name == "greeter":
        # A package is read from deps/ and checked by its hash in the lock: the file is changed in place and the lock
        # follows it, as `agentica install` would leave it.
        path = ws.deps / "greeter" / "greet.agc"
        path.write_text(path.read_text(encoding="utf-8").replace(old, new), encoding="utf-8")
        ws.locked.clear()
        ws.add_package("greeter", GIT, {"greet.agc": path.read_text(encoding="utf-8")}, tag="v1.0.0")
        ws.write_lock()
    else:
        edit(ws, name, old, new)
    assert settled(ws)[0][0] in (0, 1)


def test_a_package_changed_behind_its_lock_is_refused_with_entries_in_place(ws):
    assert settled(ws)[0][0] == 0
    path = ws.deps / "greeter" / "greet.agc"
    path.write_text(path.read_text(encoding="utf-8").replace("hello ", "bye "), encoding="utf-8")
    refused = settled(ws)
    assert refused[0][0] == 1
    assert json.loads(refused[0][2])["code"] == "PKG-HASH-MISMATCH"


def test_the_entries_of_a_clean_tree_serve_a_second_root_and_an_edited_buffer(ws):
    settled(ws)
    # The LSP form: the root is the text on stdin, the imports are the files, which the cache serves.
    buffer = MAIN.replace("puts(size.to_s)", "puts(size + 1.5)")
    answers_cached = ask(ws, ["--json", "check", "--stdin", "main.agc"], stdin=buffer)
    answers_off = ask(ws, ["--json", "--no-cache", "check", "--stdin", "main.agc"], stdin=buffer)
    assert (answers_cached.code, answers_cached.stdout, answers_cached.stderr) == (
        answers_off.code, answers_off.stdout, answers_off.stderr)
    assert answers_cached.code == 1


def change_digit(found):
    """The match of the stub line with the first hex digit of its digest changed."""
    return found.group(1) + (b"1" if found.group(2) == b"0" else b"0")


def corrupt_cases(head):
    """Entries that are not what a run wrote, each as a function from the good bytes."""
    lines = head.split(b"\n")
    return {
        "empty": lambda good: b"",
        "garbage": lambda good: bytes(range(256)) * 4,
        "truncated": lambda good: good[:len(good) // 2],
        "head only": lambda good: b"\n".join(lines[:4]) + b"\n",
        "other version": lambda good: good.replace(b"version ", b"version x", 1),
        "other binary": lambda good: good.replace(b"\nbuild ", b"\nbuild 1", 1),
        "stub size too large": lambda good: good.replace(b"\nstub ", b"\nstub 9", 1),
        "stub size negative": lambda good: good.replace(b"\nstub ", b"\nstub -", 1),
        "stub size not a number": lambda good: good.replace(b"\nstub ", b"\nstub x", 1),
        "stub digest wrong": lambda good: re.sub(rb"(\nstub \d+ )([0-9a-f])", change_digit, good, count=1),
        "stub digest missing": lambda good: re.sub(rb"(\nstub \d+) [0-9a-f]{64}", rb"\1", good, count=1),
        "constant line wrong": lambda good: good + b"\nconst",
        "constant type wrong": lambda good: good.replace(b"\nconst SIZE i", b"\nconst SIZE T9:no", 1),
        "constant type deep": lambda good: good.replace(b"\nconst SIZE i", b"\nconst SIZE " + b"L" * 500 + b"i", 1),
        "tree not hex": lambda good: good.replace(b"\ntree ", b"\ntree zz", 1),
        "text digest of another": lambda good: good.replace(b"\ntext ", b"\ntext 0", 1),
        "trailing text": lambda good: good + b"\nstray",
    }


@pytest.mark.parametrize("case", sorted(corrupt_cases(b"")), ids=str)
def test_a_corrupt_entry_is_a_miss_and_never_a_different_answer(ws, case):
    expected = settled(ws)
    assert entries(ws)
    for path in entries(ws):
        good = path.read_bytes()
        path.write_bytes(corrupt_cases(good)[case](good))
    assert answers(ws) == expected
    assert answers(ws) == expected


def test_a_misaligned_stub_is_a_miss(ws):
    expected = settled(ws)
    for path in entries(ws):
        good = path.read_bytes()
        # The stub is replaced by text of the same length that declares something else.
        path.write_bytes(good.replace(b"export struct Item", b"export struct Itex", 1))
    assert answers(ws) == expected


def test_no_cache_writes_nothing_and_leaves_what_is_there(ws):
    answers(ws, "--no-cache")
    assert not folder_of(ws).exists()
    settled(ws)
    kept = {path: path.read_bytes() for path in entries(ws)}
    answers(ws, "--no-cache")
    assert {path: path.read_bytes() for path in entries(ws)} == kept


@host_only(not POSIX_PYTHON, "file modes and links")
def test_a_folder_or_entry_that_is_not_private_is_not_used(ws):
    expected = settled(ws)
    kept = {path: path.read_bytes() for path in entries(ws)}
    victim = entries(ws)[0]
    # An entry other users can write.
    victim.chmod(0o666)
    assert answers(ws) == expected
    victim.chmod(0o600)
    # An entry that is a link to a good entry of another file.
    other = entries(ws)[1]
    victim.unlink()
    victim.symlink_to(other)
    assert answers(ws) == expected
    victim.unlink()
    victim.write_bytes(kept[victim])
    # The folder other users can write: nothing is read from it and nothing is written to it.
    folder = folder_of(ws) / "check"
    folder.chmod(0o777)
    before = {path.name: path.read_bytes() for path in folder.iterdir()}
    edit(ws, "deep", "total = SIZE * 2", "total = SIZE * 5")
    assert answers(ws) == answers(ws, "--no-cache")
    assert {path.name: path.read_bytes() for path in folder.iterdir()} == before
    folder.chmod(stat.S_IRWXU)
    # The folder itself a link.
    moved = folder_of(ws) / "elsewhere"
    folder.rename(moved)
    folder.symlink_to(moved)
    assert answers(ws) == answers(ws, "--no-cache")
    assert os.path.islink(folder)


def stamps(ws):
    return {path.name: (path.stat().st_mtime_ns, path.read_bytes()) for path in entries(ws)}


def test_a_path_with_a_space_still_hits(tmp_path):
    # The type of a struct or enum constant holds the key of its file, which has the spaces of the path.
    spaced = build(tmp_path / "my project")
    expected = settled(spaced)
    assert expected[0] == (0, '{"ok":true}\n', "")
    assert any(b"\nconst ORIGIN T@" in path.read_bytes() and b" project" in path.read_bytes() for path in entries(spaced))
    kept = stamps(spaced)
    assert answers(spaced) == expected
    assert stamps(spaced) == kept


def test_a_program_without_imports_makes_no_build_folder(tmp_path):
    (tmp_path / "hello.agc").write_text('def main() -> Void\n  puts("hi")\nend\n', encoding="utf-8")
    env = vm_environment({"AGENTICA_BUILD_DIR": None})
    for words in (["check", "hello.agc"], ["type-at", "hello.agc:2:3"]):
        done = run(cli() + ["--json", *words], cwd=tmp_path, env=env)
        assert done.code == 0, done.stderr
    assert not (tmp_path / "_build").exists()


def test_two_projects_with_one_build_folder_keep_their_own_entries(tmp_path):
    shared = tmp_path / "shared"
    first = build(tmp_path / "one")
    second = build(tmp_path / "two", extra="\n[style]\nmax_line_width = 100\n")
    first.build = second.build = shared
    expected = (settled(first), settled(second))
    # Both import std/queue: with one name for its entry they would replace each other on every run.
    kept = stamps(first)
    assert answers(first) == expected[0]
    assert answers(second) == expected[1]
    assert stamps(first) == kept


def test_runs_at_the_same_time_give_one_answer_and_leave_valid_entries(ws):
    expected = answers(ws, "--no-cache")
    with ThreadPoolExecutor(max_workers=6) as pool:
        together = list(pool.map(lambda _: answers(ws), range(6)))
    assert together == [expected] * 6
    assert not list((folder_of(ws) / "check").glob("*tmp*"))
    # Every entry is valid: another run finds all of them and writes nothing.
    kept = stamps(ws)
    assert answers(ws) == expected
    assert stamps(ws) == kept


# A facade that passes on a function, a type and a constant of deep.agc (`export Alias.name`), and a root that uses them
# through it.
FACADE = '''import Deep from "deep"

export Deep.make
export Deep.Item
export Deep.SIZE
'''

THROUGH_FACADE = '''import Facade from "facade"
import Deep from "deep"

def main() -> Void
  item: Deep.Item = Facade.make("a")
  size: Int = Facade.SIZE
  puts(item.name)
  puts(size.to_s)
end
'''


def test_a_module_that_re_exports_answers_alike_cold_warm_and_off_and_after_edits(ws):
    (ws.project / "facade.agc").write_text(FACADE, encoding="utf-8")
    (ws.project / "main.agc").write_text(THROUGH_FACADE, encoding="utf-8")
    asked = {"source": THROUGH_FACADE, "needle": "Facade.make"}
    first = settled(ws, **asked)
    assert first[0] == (0, '{"ok":true}\n', "")
    # The type of the name through the facade is the one of the original declaration.
    assert json.loads(first[1][1])["definition"]["file"].endswith("deep.agc")
    # An entry exists for the facade, and an edit of the original reaches the root through it.
    assert len(entries(ws)) >= 3
    edit(ws, "deep", "export SIZE = 7", "export SIZE = 8")
    assert settled(ws, **asked)[0][0] == 0
    edit(ws, "deep", "export def make(name: String)", "export def make(name: Int)")
    assert settled(ws, **asked)[0][0] == 1
    edit(ws, "facade", "export Deep.SIZE", "export Deep.SIZES")
    assert settled(ws, **asked)[0][0] == 1
