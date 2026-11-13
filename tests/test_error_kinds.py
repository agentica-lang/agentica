"""The kinds of the errors that C builtins build (#671): the enum of vm/error_kinds.h, which the compiler holds every
C call to, has a dotted name for each kind in vm/value.c; each kind is used, and the Error page lists it. The kinds
that the `error(...)` calls of stdlib/ name are dotted and on the Error page too.

`ERROR_KINDS` of compiler/catalog/builtins_data.agc, which `agentica lint` holds an `is_a?` literal to
(LINT-ERROR-KIND), is the C kinds and the std/ kinds.

The kind and the code of real failures are in the goldens tests/fixtures/vm/error-kinds.agc and std-error-kinds.agc;
a permission error, which a golden cannot make, is here.
"""
import os
import re
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS
from tests.vm_os_support import run_program, work  # noqa: F401 (work is a fixture)

ROOT = Path(__file__).resolve().parent.parent
VM = ROOT / "vm"
STDLIB = ROOT / "stdlib"
PAGE = ROOT / "site" / "content" / "library" / "errors" / "error.md"
DOTTED = re.compile(r"[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*")


def kinds():
    """The enum constants of vm/error_kinds.h, in order, without AGC_KIND_COUNT."""
    names = re.findall(r"^  (AGC_KIND_\w+),$", (VM / "error_kinds.h").read_text(encoding="utf-8"), re.M)
    return [name for name in names if name != "AGC_KIND_COUNT"]


def names():
    """The text of each kind, from the table of vm/value.c."""
    table = (VM / "value.c").read_text(encoding="utf-8")
    return dict(re.findall(r'^  \[(AGC_KIND_\w+)\] = "([^"]*)",$', table, re.M))


def test_every_kind_has_one_dotted_name():
    table = names()
    assert kinds() and list(table) == kinds()
    assert all(DOTTED.fullmatch(text) for text in table.values()), table
    assert len(set(table.values())) == len(table)


def test_every_kind_is_used():
    sources = [path for path in sorted(VM.rglob("*.c")) if not {"tests", "third_party"} & set(path.parts)
               and path.name != "value.c"]
    text = "\n".join(path.read_text(encoding="utf-8") for path in sources)
    assert [kind for kind in kinds() if not re.search(rf"\b{kind}\b", text)] == []


def test_the_error_page_lists_every_kind():
    page = PAGE.read_text(encoding="utf-8")
    assert [text for text in names().values() if f"`{text}`" not in page] == []


# A string literal, also one cut by an interpolation that holds a string (`"#{xs.join(", ")}"`): blanking each one
# keeps the parentheses of the code balanced.
STRING = re.compile(r'"(?:[^"\\]|\\.)*"')
COMMENT_LINE = re.compile(r"^[ \t]*#.*$", re.M)

# `kind: "..."` literals of stdlib/ that are not the kind of an Error: the `kind` field of a report row.
NOT_ERROR_KINDS = {"feature", "tests"}

# The `error("...")` literals of stdlib/ that keep the default kind `error`, by file and message, with the reason.
DEFAULT_KIND = {
    ("regex.agc", "no match"): "no match, as List.find",
    ("bdd/match.agc", "no match"): "no match, as List.find",
    ("test/child.agc", "no diagnostic"): "nothing found, as List.find",
    ("prelude/list.agc", "not found"): "List.find, a builtin row of the `error` kind",
    ("prelude/range.agc", "not found"): "Range.find, a builtin row of the `error` kind",
    ("prelude/optional.agc", "unwrap! on none"): "the text of a halt, never returned",
    ("http.agc", ""): "the seed of a Result variable, always replaced before it is read",
    ("bdd.agc", "start a program before using its streams"): "the text of a halt, never returned",
    ("bdd.agc", '#{code}: #{JSON.string(fields["message"]).unwrap_or("")}'): "the text of a halt, never returned",
    ("queue.agc", "queue is empty"): "outside the std/ modules of #671",
    ("analysis.agc", "the cache holds no entry for #{path}"): "outside the std/ modules of #671",
}


def calls(name):
    """(file, call text) of each call of `name` in the code of stdlib/, comments left out."""
    found = []
    for path in sorted(STDLIB.rglob("*.agc")):
        text = COMMENT_LINE.sub(lambda m: " " * len(m.group()), path.read_text(encoding="utf-8"))
        code = STRING.sub(lambda m: '"' + " " * (len(m.group()) - 2) + '"', text)
        for call in re.finditer(rf"\b{name}\(", code):
            depth, at = 0, call.end() - 1
            while True:
                depth += {"(": 1, ")": -1}.get(code[at], 0)
                if depth == 0:
                    break
                at += 1
            found.append((path.relative_to(STDLIB).as_posix(), text[call.start():at + 1]))
    return found


def std_kinds():
    """Every `kind: "..."` literal of stdlib/ (in `error(...)` and in `e.with(...)`) and the kind that `add_cap` of
    std/internal/archive_zip takes as its last argument."""
    found = set()
    for path in sorted(STDLIB.rglob("*.agc")):
        found.update(re.findall(r'\bkind: "([^"]*)"', path.read_text(encoding="utf-8")))
    found -= NOT_ERROR_KINDS
    for _file, call in calls("add_cap"):
        if not call.startswith("add_cap(a: Int"):
            found.add(re.search(r'"([^"]*)"\s*,?\s*\)$', call).group(1))
    return found


def test_the_error_page_lists_every_std_kind():
    used = std_kinds()
    assert {"archive.unsafe", "regex.syntax", "archive.format", "archive.too_large"} <= used
    assert [kind for kind in sorted(used) if not DOTTED.fullmatch(kind)] == []
    page = PAGE.read_text(encoding="utf-8")
    assert [kind for kind in sorted(used) if f"`{kind}`" not in page] == []


def test_every_std_error_literal_names_its_kind():
    kindless = set()
    for file, call in calls("error"):
        literal = re.fullmatch(r'error\(\s*"((?:[^"\\]|\\.|#\{[^}]*\})*)"\s*,?\s*\)', call, re.S)
        if literal:
            kindless.add((file, literal.group(1)))
    assert sorted(kindless - set(DEFAULT_KIND)) == []
    assert sorted(set(DEFAULT_KIND) - kindless) == []


def test_the_kinds_of_the_catalog_are_the_c_kinds_and_the_std_kinds():
    data = (ROOT / "compiler" / "catalog" / "builtins_data.agc").read_text(encoding="utf-8")
    table = re.search(r"^export ERROR_KINDS: List\[String\] = \[\n(.*?)^\]$", data, re.M | re.S).group(1)
    listed = re.findall(r'^  "([^"]*)",$', table, re.M)
    assert len(listed) == len(table.splitlines()) == len(set(listed))
    c_kinds = list(names().values())
    assert listed[:len(c_kinds)] == c_kinds
    assert sorted(listed[len(c_kinds):]) == sorted(std_kinds() - set(c_kinds))


PERMISSION_PROGRAM = """\
def main() -> Void
  case File.read_text(System.args()[0], 5000)
    ok(_) -> puts("ok")
    error(e) -> puts("#{e.kind} #{e.code} #{e.is_a?("io")}")
  end
end
"""


@pytest.mark.skipif(WINDOWS or os.geteuid() == 0, reason="host-only: a mode of 000 stops no read on Windows or as root")
def test_a_file_without_read_permission_is_io_permission(tmp_path, work):
    locked = tmp_path / "locked.txt"
    locked.write_text("secret", encoding="utf-8")
    locked.chmod(0)
    try:
        assert run_program(tmp_path, work, PERMISSION_PROGRAM, "permission", locked) == ["io.permission some(13) true"]
    finally:
        locked.chmod(0o600)


POSIX_PROGRAM = """\
def show[T](label: String, result: Result[T]) -> Void
  case result
    ok(_) -> puts("#{label}: ok")
    error(e) -> puts("#{label}: #{e.kind} #{e.code}")
  end
end

def main() -> Void
  dir = System.args()[0]
  show("stat through a file", File.stat(dir + "/file.txt/x", 5000))
  show("stat in a locked folder", File.stat(dir + "/locked/x", 5000))
  show("out is a folder", Process.spawn("true", [], Process.Options(timeout_ms: 5000, out: dir)))
  long = Result.unwrap!(Process.spawn("head", ["-c", "1048577", "/dev/zero"]))
  show("long line", Process.read_line(long, 5000))
  captured = Result.unwrap!(Process.spawn_captured("head", ["-c", "2097152", "/dev/zero"]))
  _ = Process.wait(captured, 5000)
  show("long output", Process.read_bytes(captured, 0, 5000))
end
"""


@pytest.mark.skipif(WINDOWS or os.geteuid() == 0,
                    reason="host-only: a mode of 000, true, head and /dev/zero are POSIX; root ignores the mode")
def test_stat_process_and_long_lines_take_the_kind_of_the_failure(tmp_path, work):
    (tmp_path / "file.txt").write_text("x", encoding="utf-8")
    locked = tmp_path / "locked"
    locked.mkdir()
    locked.chmod(0)
    try:
        assert run_program(tmp_path, work, POSIX_PROGRAM, "posix", tmp_path) == [
            "stat through a file: io.not_directory some(20)",
            "stat in a locked folder: io.permission some(13)",
            "out is a folder: io.is_directory some(21)",
            "long line: process.too_large none",
            "long output: process.too_large none",
        ]
    finally:
        locked.chmod(0o700)
