"""The kinds of the errors that C builtins build (#671): the enum of vm/error_kinds.h, which the compiler holds every
C call to, has a dotted name for each kind in vm/value.c; each kind is used, and the Error page lists it. The kinds
that the `error(...)` calls of stdlib/ name are dotted and on the Error page too.

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


def std_kinds():
    """The `kind:` literals of the `error(...)` calls in stdlib/."""
    found = set()
    for path in sorted(STDLIB.rglob("*.agc")):
        text = path.read_text(encoding="utf-8")
        code = STRING.sub(lambda m: '"' + " " * (len(m.group()) - 2) + '"', text)
        for call in re.finditer(r"\berror\(", code):
            depth, at = 0, call.end() - 1
            while True:
                depth += {"(": 1, ")": -1}.get(code[at], 0)
                if depth == 0:
                    break
                at += 1
            found.update(re.findall(r'\bkind: "([^"]*)"', text[call.start():at]))
    return found


def test_the_error_page_lists_every_std_kind():
    used = std_kinds()
    assert "archive.unsafe" in used and "regex.syntax" in used
    assert [kind for kind in sorted(used) if not DOTTED.fullmatch(kind)] == []
    page = PAGE.read_text(encoding="utf-8")
    assert [kind for kind in sorted(used) if f"`{kind}`" not in page] == []


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
