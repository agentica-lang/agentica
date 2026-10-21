"""The stages reach the machine only through the Workspace record (compiler/modules/workspace.agc).

fixtures/frontend/workspace/in-memory.agc builds a Workspace over an in-memory table of files and links two roots with
it: a program with an import, and one whose import is missing. Nothing it links exists on the disk, so a read that
bypassed the Workspace would fail the first root. fixtures/frontend/workspace/end-to-end.agc goes on through the
checker, the lowering and the writer, for a program with a sibling module, a package from the package cache and a std/
module from std_source, and writes the .agcb, which the test then runs with the CLI.

The end-to-end case is the dynamic proof for reads: its table is keyed under a folder of the test, where the test has
written garbage at every path of the tree (main.agc, util.agc, the manifest, the lock and the package), so a stage that
read the disk, even with a fallback to the Workspace, would parse the garbage and fail. It does not see a call that
reads nothing (a File.stat with its answer ignored, or a pure Path call), nor a stage that asks the Workspace first and
the disk after it: tests/test_style_core_purity.py is the static half, and covers the calls it knows.
"""
import pytest

from tests.agentica_test import FIXTURES, ROOT, WINDOWS, cli, run
from tests.package_support import COMMIT, cache_path, package_hash

PROGRAM = FIXTURES / "frontend" / "workspace" / "in-memory.agc"
END_TO_END = FIXTURES / "frontend" / "workspace" / "end-to-end.agc"

GIT = "https://github.com/acme/greet.git"
GREET = """\
export def hello(name: String) -> String
  return "hello " + name
end
"""
GARBAGE = "}}} nothing the front end reads {{{\n"


def test_the_linker_reads_files_from_a_workspace_that_is_not_the_disk():
    result = run(cli() + [str(PROGRAM)], cwd=ROOT)
    assert result.code == 0, result.stderr
    assert result.stdout.splitlines() == [
        'module "root.agc" first=0 next=9',
        'module "util.agc" first=9 next=19',
        'ERROR CHECK-IMPORT-IO 0:1:1-30:2:1 "cannot read import" - file="broken.agc"',
    ]


def write_decoys(root, windows):
    """Garbage at every path that the fixture keeps in memory, under `root`."""
    pkg = "cache/agentica/cache/pkg" if windows else "cache/agentica/pkg"
    for relative in [
        "project/src/main.agc",
        "project/src/util.agc",
        "project/agentica.toml",
        "project/agentica.lock",
        f"{pkg}/{cache_path(GIT)}/{COMMIT}/greet.agc",
    ]:
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(GARBAGE, encoding="utf-8")


# Both variants run on a Linux host with forward slashes only; no backslash path is tried.
@pytest.mark.parametrize("windows", [False, True], ids=["posix", "windows"])
def test_the_whole_pure_core_compiles_a_program_over_an_in_memory_workspace(tmp_path, windows):
    # The windows base is the drive path C:/mem. On a Linux host that is a relative path, so the decoys go to ./C:/mem
    # under the folder that the fixture runs in (the cwd). On a Windows host it is a real drive: no decoy there.
    decoys = tmp_path / "mem"
    base = decoys.as_posix()
    if windows:
        base, decoys = "C:/mem", None if WINDOWS else tmp_path / "C:" / "mem"
    if decoys is not None:
        write_decoys(decoys, windows)

    package = tmp_path / "greet-package"
    package.mkdir()
    (package / "greet.agc").write_text(GREET, encoding="utf-8")
    version = (ROOT / "VERSION").read_text(encoding="utf-8").strip()
    out = tmp_path / "out.agcb"

    arguments = [base, version, COMMIT, GIT, GREET, package_hash(package), str(out)]
    result = run(cli() + [str(END_TO_END)] + arguments + (["windows"] if windows else []), cwd=tmp_path)
    assert result.code == 0, result.stderr
    # "ok" is the end of the pipeline; a stage that failed prints its code and the file instead.
    assert result.stdout.splitlines() == ["ok"]

    # The bytes link the four files into one program that does what main says: 9 capped to 5, doubled, greeted.
    ran = run(cli() + ["run", "--", str(out)], cwd=tmp_path)
    assert ran.code == 0, ran.stderr
    assert ran.stdout.splitlines() == ["hello 10"]
