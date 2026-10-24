"""examples/ffi/duckdb/*.agc through the CLI against the real pinned DuckDB library.

DUCKDB_LIB is the path of the DuckDB shared library for this system, staged by
tools/provision_duckdb.py from the pinned v2.0.0 asset (the README shows the manual
form). Without it every case skips explicitly: the example cannot run without the
library, and a faked pass would prove nothing. A DUCKDB_LIB that is set but points
nowhere fails instead of skipping, so a broken CI provision cannot go green by
silence. In CI the provision step sets DUCKDB_LIB on all four systems, which turns
those skips into real runs (an unset DUCKDB_LIB there fails the conformance report).
Python's standard library only: ctypes is the independent oracle (no duckdb package),
csv checks the export bytes, and nothing here touches the network.
"""
import csv
import ctypes
import json
import os
import shutil

import pytest

from tests.agentica_test import ROOT, TARGET_OS, WINDOWS, cli, run, vm_environment
from tests.test_vm_native import NATIVE_CALLS

DUCKDB = ROOT / "examples" / "ffi" / "duckdb"
MACOS = TARGET_OS == "darwin"
# The key of this system in the [native.duckdb] table of agentica.toml.
HERE = "windows" if WINDOWS else "macos" if MACOS else "linux"
LIBNAME = {"linux": "libduckdb.so", "macos": "libduckdb.dylib", "windows": "duckdb.dll"}[HERE]

WANT_LINES = [
    "1|10000000000|9.5|Ada",
    "2|-42|-0.25|Böb \"Jr\"",
    "3|0|NULL|NULL",
    "4|7|3.125|O'Brien",
]
WANT_ROWS = [(1, 10000000000, 9.5, "Ada"), (2, -42, -0.25, 'Böb "Jr"'),
             (3, 0, None, None), (4, 7, 3.125, "O'Brien")]
WANT_ERROR = "error: Catalog Error: Table with name no_such_table_xyz does not exist!"


@pytest.fixture(scope="module")
def library():
    """The staged DuckDB library, or an explicit skip / a loud failure."""
    path = os.environ.get("DUCKDB_LIB")
    if not path:
        pytest.skip("DUCKDB_LIB is not set: stage the pinned library "
                    "(tools/provision_duckdb.py --out DIR) to run this module")
    if not os.path.isfile(path):
        pytest.fail("DUCKDB_LIB=%r is set but missing: provisioning failed, not skipping" % path)
    return path


def stage(tmp_path, library):
    """A runnable copy of the real example files, with the library where the manifest points."""
    native = tmp_path / "native" / HERE
    native.mkdir(parents=True)
    shutil.copy(library, native / LIBNAME)
    shutil.copy(DUCKDB / "agentica.toml", tmp_path / "agentica.toml")
    shutil.copy(DUCKDB / "main.agc", tmp_path / "main.agc")
    shutil.copy(DUCKDB / "duckdb.agc", tmp_path / "duckdb.agc")
    return tmp_path


def check_program(main, cwd):
    """`check` of the staged program passes."""
    result = run(cli() + ["check", str(main)], cwd=cwd, env=vm_environment())
    assert (result.code, result.stdout, result.stderr) == (0, "check ok\n", "")


def run_program(main, out_dir, cwd):
    """Run the staged program with OUTPUT_DIR; returns the completed run."""
    return run(cli() + [str(main), str(out_dir)], cwd=cwd, env=vm_environment())


@NATIVE_CALLS
def test_version_check_typed_rows_error_then_csv_and_parquet_roundtrips(tmp_path, library):
    main = stage(tmp_path, library) / "main.agc"
    check_program(main, tmp_path)
    out_dir = tmp_path / "out put's"
    result = run_program(main, out_dir, tmp_path)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout == "".join([
        "duckdb v2.0.0\n",
        "columns: 4\n",
        "rows: 4\n",
        *("%s\n" % line for line in WANT_LINES),
        WANT_ERROR + "\n",
        "csv rows: 4\n",
        "csv header: id,code,score,name\n",
        "parquet rows: 4\n",
    ])
    csv_path = out_dir / "people.csv"
    rows = list(csv.reader(csv_path.read_text(encoding="utf-8").splitlines()))
    assert rows[0] == ["id", "code", "score", "name"]
    assert len(rows) == 5
    for found, (want_id, want_code, want_score, want_name) in zip(rows[1:], WANT_ROWS):
        assert found[0] == str(want_id)
        assert found[1] == str(want_code)
        assert (found[2] == "") == (want_score is None)
        if want_score is not None:
            assert float(found[2]) == want_score
        assert found[3] == (want_name if want_name is not None else "")
    parquet_path = out_dir / "people.parquet"
    framing = parquet_path.read_bytes()
    assert len(framing) > 0 and framing[:4] == b"PAR1" and framing[-4:] == b"PAR1"
    # A second run at the same directory refuses instead of overwriting it.
    before = (csv_path.read_bytes(), framing)
    again = run_program(main, out_dir, tmp_path)
    assert again.code != 0
    assert "refusing" in (again.stdout + again.stderr)
    assert (csv_path.read_bytes(), parquet_path.read_bytes()) == before


@NATIVE_CALLS
def test_usage_and_missing_parent_fail_closed_without_a_panic(tmp_path, library):
    main = stage(tmp_path, library) / "main.agc"
    naked = run(cli() + [str(main)], cwd=tmp_path, env=vm_environment())
    assert naked.code == 2
    assert "usage: main.agc OUTPUT_DIR" in naked.stderr
    missing = run_program(main, tmp_path / "no-such-parent" / "out", tmp_path)
    assert missing.code != 0
    assert missing.stdout == "duckdb v2.0.0\n"
    assert missing.stderr != ""


@NATIVE_CALLS
def test_a_non_library_staged_as_duckdb_fails_closed(tmp_path):
    """Garbage staged where the manifest points at is RUNTIME-NATIVE-LOAD, never a hang."""
    staged = stage(tmp_path, DUCKDB / "duckdb.agc")
    (staged / "native" / HERE / LIBNAME).write_bytes(b"not a shared library\n")
    result = run(cli() + ["--json", str(staged / "main.agc"), str(tmp_path / "out")],
                   cwd=tmp_path, env=vm_environment())
    assert result.code == 1
    assert result.stdout == ""
    line = next(n for n, text in enumerate((DUCKDB / "duckdb.agc").read_text(
        encoding="utf-8").split("\n"), 1) if "def duckdb_library_version(" in text)
    found = json.loads(result.stderr.strip().split("\n")[-1])
    assert found["code"] == "RUNTIME-NATIVE-LOAD"
    assert (found["range"]["start"]["line"], found["range"]["start"]["column"]) == (line, 3)


class DuckdbOracle:
    """The same SQL through ctypes, independent of the Agentica FFI layer."""

    def __init__(self, path):
        self.lib = ctypes.CDLL(str(path))
        api = self.lib
        api.duckdb_library_version.restype = ctypes.c_char_p
        api.duckdb_open.argtypes = [ctypes.c_char_p, ctypes.c_void_p]
        api.duckdb_open.restype = ctypes.c_int32
        api.duckdb_close.argtypes = [ctypes.c_void_p]
        api.duckdb_connect.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
        api.duckdb_connect.restype = ctypes.c_int32
        api.duckdb_disconnect.argtypes = [ctypes.c_void_p]
        api.duckdb_query.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p]
        api.duckdb_query.restype = ctypes.c_int32
        api.duckdb_destroy_result.argtypes = [ctypes.c_void_p]
        api.duckdb_result_error.argtypes = [ctypes.c_void_p]
        api.duckdb_result_error.restype = ctypes.c_void_p
        api.duckdb_free.argtypes = [ctypes.c_void_p]
        api.duckdb_column_count.argtypes = [ctypes.c_void_p]
        api.duckdb_column_count.restype = ctypes.c_int64
        api.duckdb_column_type.argtypes = [ctypes.c_void_p, ctypes.c_int64]
        api.duckdb_column_type.restype = ctypes.c_int32
        api.duckdb_row_count.argtypes = [ctypes.c_void_p]
        api.duckdb_row_count.restype = ctypes.c_int64
        api.duckdb_value_is_null.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64]
        api.duckdb_value_is_null.restype = ctypes.c_bool
        api.duckdb_value_int32.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64]
        api.duckdb_value_int32.restype = ctypes.c_int32
        api.duckdb_value_int64.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64]
        api.duckdb_value_int64.restype = ctypes.c_int64
        api.duckdb_value_double.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64]
        api.duckdb_value_double.restype = ctypes.c_double
        api.duckdb_value_varchar.argtypes = [ctypes.c_void_p, ctypes.c_int64, ctypes.c_int64]
        api.duckdb_value_varchar.restype = ctypes.c_void_p
        self.db_slot = ctypes.create_string_buffer(8)
        self.conn_slot = ctypes.create_string_buffer(8)

    def open(self):
        assert self.lib.duckdb_open(b":memory:", self.db_slot) == 0
        assert ctypes.cast(self.db_slot, ctypes.POINTER(ctypes.c_void_p)).contents.value is not None
        assert self.lib.duckdb_connect(self.handle(self.db_slot), self.conn_slot) == 0

    def close(self):
        self.lib.duckdb_disconnect(self.conn_slot)
        self.lib.duckdb_close(self.db_slot)

    @staticmethod
    def handle(slot):
        return ctypes.cast(slot, ctypes.POINTER(ctypes.c_void_p)).contents.value

    def query(self, sql):
        buf = ctypes.create_string_buffer(48)
        state = self.lib.duckdb_query(self.handle(self.conn_slot), sql, buf)
        if state != 0:
            at = self.lib.duckdb_result_error(buf)
            message = ctypes.string_at(at).decode("utf-8") if at else "query failed"
            self.lib.duckdb_destroy_result(buf)
            raise AssertionError("oracle query failed: %s: %s" % (sql, message))
        return buf

    def destroy(self, buf):
        self.lib.duckdb_destroy_result(buf)

    def cell(self, buf, col, row):
        if self.lib.duckdb_value_is_null(buf, col, row):
            return None
        if col == 0:
            return self.lib.duckdb_value_int32(buf, col, row)
        if col == 1:
            return self.lib.duckdb_value_int64(buf, col, row)
        if col == 2:
            return self.lib.duckdb_value_double(buf, col, row)
        at = self.lib.duckdb_value_varchar(buf, col, row)
        assert at is not None
        try:
            return ctypes.string_at(at).decode("utf-8")
        finally:
            self.lib.duckdb_free(at)


def sql_literal(path):
    """A filesystem path as a SQL string literal: single quotes double."""
    return "'" + str(path).replace("'", "''") + "'"


@NATIVE_CALLS
def test_ctypes_oracle_matches_typed_values_and_the_parquet_file(tmp_path, library):
    main = stage(tmp_path, library) / "main.agc"
    out_dir = tmp_path / "oracle out's"
    result = run_program(main, out_dir, tmp_path)
    assert (result.code, result.stderr) == (0, "")
    oracle = DuckdbOracle(library)
    assert oracle.lib.duckdb_library_version() == b"v2.0.0"
    oracle.open()
    try:
        buf = oracle.query(b"SELECT 1 AS id, 10000000000 AS code, CAST(9.5 AS DOUBLE) AS score, 'Ada' AS name")
        try:
            assert oracle.lib.duckdb_column_count(buf) == 4
            assert [oracle.lib.duckdb_column_type(buf, col) for col in range(4)] == [4, 5, 11, 17]
            assert oracle.lib.duckdb_row_count(buf) == 1
            assert [oracle.cell(buf, col, 0) for col in range(4)] == [1, 10000000000, 9.5, "Ada"]
        finally:
            oracle.destroy(buf)
        parquet = sql_literal(out_dir / "people.parquet").encode("utf-8")
        rows = oracle.query(b"SELECT id, code, score, name FROM read_parquet(" + parquet + b") ORDER BY id")
        try:
            assert oracle.lib.duckdb_row_count(rows) == 4
            assert [[oracle.cell(rows, col, row) for col in range(4)] for row in range(4)] == [
                list(row) for row in WANT_ROWS]
        finally:
            oracle.destroy(rows)
    finally:
        oracle.close()
