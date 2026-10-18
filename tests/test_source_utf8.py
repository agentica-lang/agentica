"""Strict UTF-8 source decoding tests (docs/future/18-front-end-language.md §18.3).

The front end decodes the bytes itself, so an invalid byte is LEX-INVALID-UTF8 at the first byte of the first
sequence that does not decode, not a U+FFFD in the text. Python's strict decoder is the independent oracle of that
place.
"""
import json

import pytest

from tests.agentica_test import cli, run

PROGRAM = 'def main() -> Void\n  puts("ok")\nend\n'
INVALID = [
    ("continuation byte alone", '# café\ndef main() -> Void\n  puts("日', b"\x80", b'")\nend\n'),
    ("CRLF and tab before the bad byte", '# a\r\n\tx = "\t', b"\xff", b'"\r\n'),
    ("byte that never occurs", "# 😀\n", b"\xff", b"\n"),
    ("overlong", 'x = "', b"\xc0\x80", b'"\n'),
    ("overlong three bytes", 'x = "', b"\xe0\x80\x80", b'"\n'),
    ("surrogate", 'x = "', b"\xed\xa0\x80", b'"\n'),
    ("above U+10FFFF", 'x = "', b"\xf4\x90\x80\x80", b'"\n'),
    ("sequence cut by an ASCII byte", 'x = "', b"\xe2\x82", b'a"\n'),
    ("truncated at the end of the file", PROGRAM, b"\xf0\x9f\x98", b""),
]


def check_file(path):
    result = run(cli() + ["--json", "check", str(path)])
    if result.code == 0:
        return None
    assert result.code == 1, result.stderr
    return json.loads(result.stderr)


def make_suite(tmp_path, files):
    for name, text in files.items():
        (tmp_path / f"{name}.agc").write_text(text, encoding="utf-8")
    return tmp_path


@pytest.mark.parametrize("name,prefix,bad,suffix", INVALID, ids=[case[0] for case in INVALID])
def test_invalid_byte_is_reported_where_python_stops(tmp_path, name, prefix, bad, suffix):
    content = prefix.encode("utf-8") + bad + suffix
    with pytest.raises(UnicodeDecodeError) as raised:
        content.decode("utf-8")
    before = content[:raised.value.start].decode("utf-8")
    assert before == prefix
    lines = before.split("\n")
    line, column = len(lines), len(lines[-1]) + 1
    path = tmp_path / "bad.agc"
    path.write_bytes(content)
    problem = check_file(path)
    assert problem["code"] == "LEX-INVALID-UTF8"
    assert problem["file"] == str(path)
    assert problem["range"] == {"start": {"line": line, "column": column},
                                "end": {"line": line, "column": column + 1}}


def test_invalid_byte_in_an_import_names_the_imported_file(tmp_path):
    directory = make_suite(tmp_path, {"root": 'import Bad from "./bad"\n\n' + PROGRAM})
    (directory / "bad.agc").write_bytes(b"export def one() -> Int\n  return \xff\nend\n")
    problem = check_file(directory / "root.agc")
    assert problem["code"] == "LEX-INVALID-UTF8"
    assert problem["file"] == str(directory / "bad.agc")
    assert problem["range"]["start"] == {"line": 2, "column": 10}


def test_source_files_over_1_mib_are_read(tmp_path):
    comment = "# " + "a" * 1100000 + "\n"
    directory = make_suite(tmp_path, {
        "root": 'import Big from "./big"\n\ndef main() -> Void\n  puts(Big.one().to_s)\nend\n',
        "big": comment + "export def one() -> Int\n  return 1\nend\n",
        "alone": comment + PROGRAM,
    })
    for name in ("root", "alone"):
        assert check_file(directory / f"{name}.agc") is None


def test_read_errors_keep_their_codes(tmp_path):
    directory = make_suite(tmp_path, {"root": 'import Gone from "./gone"\nimport Folder from "./dir"\n\n' + PROGRAM})
    missing = run(cli() + ["check", str(directory / "missing.agc")])
    assert missing.code == 2
    assert "cannot read" in missing.stderr
    problem = check_file(directory / "root.agc")
    assert (problem["code"], problem["message"]) == ("CHECK-IMPORT-IO", "cannot read import")
    assert problem["range"]["start"] == {"line": 1, "column": 1}
    (directory / "gone.agc").write_text("export def one() -> Int\n  return 1\nend\n", encoding="utf-8")
    (directory / "dir.agc").mkdir()
    problem = check_file(directory / "root.agc")
    assert (problem["code"], problem["message"]) == ("CHECK-IMPORT-IO", "cannot read import")
    assert problem["range"]["start"] == {"line": 2, "column": 1}
