"""Strict UTF-8 source decoding through `agentica --json check`.

The front end decodes the bytes itself, so an invalid byte is LEX-INVALID-UTF8 at the first byte of the first
sequence that does not decode, not a U+FFFD in the text. Python's strict decoder is the independent oracle of that
place. Every kind of bad sequence, the read edges and files over 1 MiB, in the root file and in an import, are cases of
tests/test_frontend_modules.py; these two show the diagnostic of the command line.
"""
import json
from pathlib import Path

import pytest

from tests.agentica_test import cli, run, write_files

PROGRAM = 'def main() -> Void\n  puts("ok")\nend\n'


def check_file(path):
    result = run(cli() + ["--json", "check", str(path)])
    assert result.code == 1, result.stderr
    return json.loads(result.stderr)


def test_invalid_byte_is_reported_where_python_stops(tmp_path):
    content = '# café\ndef main() -> Void\n  puts("日'.encode("utf-8") + b'\x80")\nend\n'
    with pytest.raises(UnicodeDecodeError) as raised:
        content.decode("utf-8")
    lines = content[:raised.value.start].decode("utf-8").split("\n")
    line, column = len(lines), len(lines[-1]) + 1
    path = tmp_path / "bad.agc"
    path.write_bytes(content)
    problem = check_file(path)
    assert problem["code"] == "LEX-INVALID-UTF8"
    assert Path(problem["file"]) == path
    assert problem["range"] == {"start": {"line": line, "column": column},
                                "end": {"line": line, "column": column + 1}}


def test_invalid_byte_in_an_import_names_the_imported_file(tmp_path):
    write_files(tmp_path, {"root.agc": 'import Bad from "./bad"\n\n' + PROGRAM})
    (tmp_path / "bad.agc").write_bytes(b"export def one() -> Int\n  return \xff\nend\n")
    problem = check_file(tmp_path / "root.agc")
    assert problem["code"] == "LEX-INVALID-UTF8"
    assert Path(problem["file"]) == tmp_path / "bad.agc"
    assert problem["range"]["start"] == {"line": 2, "column": 10}
