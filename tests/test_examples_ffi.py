"""examples/ffi/*.agc through the CLI: build demo.c and run the actual example files.

Each demo runs from a fresh project folder holding a copy of the real example
file and the real agentica.toml, with the freshly built library placed where
the manifest points; nothing is edited to fake a pass. Native calls need
libffi (Linux and macOS on x86_64 and arm64, Windows x64), like
tests/test_vm_native.py; the system C compiler builds the library (a missing
compiler skips locally and fails in CI, as tests/agentica_test.py requires).
Expectations are computed in Python; only exit codes and exact known outputs
are asserted, never diagnostic text (AGENTS.md).
"""
import shutil

import pytest

from tests.agentica_test import ROOT, TARGET_OS, WINDOWS, cli, run, vm_environment
from tests.test_vm_native import NATIVE_CALLS, library_name, shared_library

FFI = ROOT / "examples" / "ffi"
MACOS = TARGET_OS == "darwin"
# The key of this system in the [native.demo] table of agentica.toml.
HERE = "windows" if WINDOWS else "macos" if MACOS else "linux"


@pytest.fixture(scope="module")
def library(tmp_path_factory):
    """The bytes of the demo library, built once for the module."""
    return shared_library(tmp_path_factory, "demo", source=FFI / "demo.c").read_bytes()


def stage(tmp_path, library, name):
    """A runnable copy of the example NAME: the real file and manifest, and the library where it points."""
    native = tmp_path / "native" / HERE
    native.mkdir(parents=True)
    (native / library_name("demo")).write_bytes(library)
    shutil.copy(FFI / "agentica.toml", tmp_path / "agentica.toml")
    return shutil.copy(FFI / name, tmp_path / name)


def check_program(path, cwd):
    """`check` of the staged program passes."""
    result = run(cli() + ["check", str(path)], cwd=cwd, env=vm_environment())
    assert (result.code, result.stdout, result.stderr) == (0, "check ok\n", "")


def run_program(path, cwd):
    """Run the staged program; returns its stdout."""
    result = run(cli() + [str(path)], cwd=cwd, env=vm_environment())
    assert (result.code, result.stderr) == (0, "")
    return result.stdout


@NATIVE_CALLS
def test_calls_runs_plain_typed_calls_and_a_compute_call(tmp_path, library):
    path = stage(tmp_path, library, "calls.agc")
    check_program(path, tmp_path)
    assert run_program(path, tmp_path) == "%d\n%s\n%d\n" % (40 + 2, 1.5 * -2.0, sum(range(1, 101)))


@NATIVE_CALLS
def test_records_and_buffers_cross_a_struct_a_resource_and_a_float_buffer(tmp_path, library):
    path = stage(tmp_path, library, "records_and_buffers.agc")
    check_program(path, tmp_path)
    assert run_program(path, tmp_path) == "%d\n%d\n%s\n%s\n" % (
        4 + 3, 10 + 5 - 2, 'error("demo_acc_open returned NULL")', sum(k * 0.5 for k in range(4)))


@NATIVE_CALLS
def test_function_table_dispatches_through_c_function_pointers(tmp_path, library):
    path = stage(tmp_path, library, "function_table.agc")
    check_program(path, tmp_path)
    assert run_program(path, tmp_path) == "%d\n%s\n%s\n%s\n" % (40 + 2, 1.5 * -2.0, "true", "demo-api-1")
