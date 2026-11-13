"""The kinds of the errors that C builtins build (#671): the enum of vm/error_kinds.h, which the compiler holds every
C call to, has a dotted name for each kind in vm/value.c; each kind is used, and the Error page lists it.

The kind and the code of real failures are in the golden tests/fixtures/vm/error-kinds.agc; a permission error,
which a golden cannot make, is here.
"""
import os
import re
from pathlib import Path

import pytest

from tests.agentica_test import WINDOWS
from tests.vm_os_support import run_program, work  # noqa: F401 (work is a fixture)

ROOT = Path(__file__).resolve().parent.parent
VM = ROOT / "vm"
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
