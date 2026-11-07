"""examples/native_module through the CLI: build stats.c and run the example file.

The example runs from a fresh project folder with a copy of the real file and agentica.toml and the freshly built
module where the manifest points, as tests/test_examples_ffi.py does for the extern blocks. A module opens its
library as an extern block does, so it runs where native calls do (NATIVE_CALLS).
"""
import shutil

from tests.agentica_test import ROOT, cli, run, vm_environment
from tests.test_examples_ffi import HERE
from tests.test_vm_native import NATIVE_CALLS, library_name, shared_library

EXAMPLE = ROOT / "examples" / "native_module"
OUTPUT = """some(Summary(count: 3, min: 2.0, max: 9.0, mean: 5.0))
none
{"name": Cell.Text("kiwi"), "qty": Cell.Number(3.0), "note": Cell.Empty}
{"name": Cell.Text("apple"), "qty": Cell.Number(1.5), "note": Cell.Text("ripe")}
error("a row has another number of cells")
"""


@NATIVE_CALLS
def test_the_example_calls_its_module_for_a_struct_and_typed_rows(tmp_path, tmp_path_factory):
    native = tmp_path / "native" / HERE
    native.mkdir(parents=True)
    built = shared_library(tmp_path_factory, "stats", "-std=c11", source=EXAMPLE / "stats.c")
    shutil.copy(built, native / library_name("stats"))
    shutil.copy(EXAMPLE / "agentica.toml", tmp_path / "agentica.toml")
    path = shutil.copy(EXAMPLE / "stats.agc", tmp_path / "stats.agc")
    checked = run(cli() + ["check", str(path)], cwd=tmp_path, env=vm_environment())
    assert (checked.code, checked.stdout, checked.stderr) == (0, "check ok\n", "")
    result = run(cli() + [str(path)], cwd=tmp_path, env=vm_environment())
    assert (result.code, result.stdout, result.stderr) == (0, OUTPUT, "")
