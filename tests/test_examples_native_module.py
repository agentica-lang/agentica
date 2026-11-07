"""examples/native_module through the CLI: the run builds native/stats.c and calls the module.

The example runs from a copy of its folder, with the package cache in a temporary folder, as a user runs it: the
`build` table of its agentica.toml has the system C compiler (`cc`, `gcc` on Windows; CC is unset) build the module on
the first run, and `check` needs no build. A module opens its library as an extern block does, so it runs where native
calls do (NATIVE_CALLS). The Platforms workflow runs this module on every system, so the build flags of each one are
tested there.
"""
import re
import shutil

from tests.agentica_test import ROOT, WINDOWS, cli, run, tool, vm_environment
from tests.test_vm_native import NATIVE_CALLS

EXAMPLE = ROOT / "examples" / "native_module"
OUTPUT = """some(Summary(count: 3, min: 2.0, max: 9.0, mean: 5.0))
none
{"name": Cell.Text("kiwi"), "qty": Cell.Number(3.0), "note": Cell.Empty}
{"name": Cell.Text("apple"), "qty": Cell.Number(1.5), "note": Cell.Text("ripe")}
error("a row has another number of cells")
"""


@NATIVE_CALLS
def test_the_example_builds_its_module_and_calls_it_for_a_struct_and_typed_rows(tmp_path):
    tool("gcc" if WINDOWS else "cc")
    folder = shutil.copytree(EXAMPLE, tmp_path / "example", ignore=shutil.ignore_patterns("_build"))
    cache = {"LOCALAPPDATA": tmp_path / "cache"} if WINDOWS else {"XDG_CACHE_HOME": tmp_path / "cache"}
    env = vm_environment({**cache, "CC": None})
    path = folder / "stats.agc"
    checked = run(cli() + ["check", str(path)], cwd=folder, env=env)
    assert (checked.code, checked.stdout, checked.stderr) == (0, "check ok\n", "")
    result = run(cli() + [str(path)], cwd=folder, env=env)
    assert (result.code, result.stdout) == (0, OUTPUT), result.stderr
    assert re.fullmatch(r"built native stats: .+\n", result.stderr), result.stderr
