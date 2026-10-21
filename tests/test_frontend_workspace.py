"""The stages reach the machine only through the Workspace record (compiler/modules/workspace.agc).

fixtures/frontend/workspace/in-memory.agc builds a Workspace over an in-memory table of files and links two roots with
it: a program with an import, and one whose import is missing. Nothing it links exists on the disk, so a read that
bypassed the Workspace would fail the first root. fixtures/frontend/workspace/end-to-end.agc goes on through the
checker, the lowering and the writer, for a program with a sibling module, a package from the package cache and a std/
module from std_source, once with POSIX paths and once with `windows: true` and drive paths. A stage that read the disk
would fail on the paths, which exist nowhere. tests/test_style_core_purity.py is the static half of the same rule.
"""
import pytest

from tests.agentica_test import FIXTURES, ROOT, cli, run

PROGRAM = FIXTURES / "frontend" / "workspace" / "in-memory.agc"
END_TO_END = FIXTURES / "frontend" / "workspace" / "end-to-end.agc"


def test_the_linker_reads_files_from_a_workspace_that_is_not_the_disk():
    result = run(cli() + [str(PROGRAM)], cwd=ROOT)
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [
        'module "root.agc" first=0 next=9',
        'module "util.agc" first=9 next=19',
        'ERROR CHECK-IMPORT-IO 0:1:1-30:2:1 "cannot read import" - file="broken.agc"',
    ]


@pytest.mark.parametrize("flags", [[], ["windows"]], ids=["posix", "windows"])
def test_the_whole_pure_core_compiles_a_program_over_an_in_memory_workspace(flags):
    result = run(cli() + [str(END_TO_END)] + flags, cwd=ROOT)
    assert result.code == 0, result.stderr
    # One line for each linked file, with its stored name, which the writer keeps in the bytes: a failure of a stage
    # would print its code instead.
    assert result.stdout.splitlines() == [
        "main.agc in-bytes=true",
        "pkg/greet@v1.0.0/greet.agc in-bytes=true",
        "std/mini.agc in-bytes=true",
        "util.agc in-bytes=true",
    ]
