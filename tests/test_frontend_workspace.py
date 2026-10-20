"""The linker reaches the machine only through the Workspace record (compiler/modules/workspace.agc).

fixtures/frontend/workspace/in-memory.agc builds a Workspace over an in-memory table of files and links two roots with
it: a program with an import, and one whose import is missing. Nothing it links exists on the disk, so a read that
bypassed the Workspace would fail the first root. tests/test_style_core_purity.py is the static half of the same rule.
"""
from tests.agentica_test import FIXTURES, ROOT, cli, run

PROGRAM = FIXTURES / "frontend" / "workspace" / "in-memory.agc"


def test_the_linker_reads_files_from_a_workspace_that_is_not_the_disk():
    result = run(cli() + [str(PROGRAM)], cwd=ROOT)
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [
        'module "root.agc" first=0 next=9',
        'module "util.agc" first=9 next=19',
        'ERROR CHECK-IMPORT-IO 0:1:1-30:2:1 "cannot read import" - file="broken.agc"',
    ]
