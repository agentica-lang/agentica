"""Writes tests/fixtures/vm/json-kind-vectors.stdin, the vectors that json-kind-vectors.agc checks.

The peer is Python's json module: `parse_int` and `parse_float` tell a number
written without fraction or exponent ("int") from one with either ("float"), so
it shares no code with the VM's reader. Each line is three fields joined by a
tab: a JSON document, a path to one of its values, and that value's kind. The
path is "." for the root, or its steps joined by "/": "#3" is an array index,
anything else an object key.

Run by hand: python3 tests/fixtures/json-kind-vectors.py
CI does not run it; commit both files when the vectors change.
"""

import json
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent / "vm" / "json-kind-vectors.stdin"
HEADER = (
    "# json-kind-vectors.stdin: made by python3 tests/fixtures/json-kind-vectors.py "
    "(Python json module); do not edit by hand"
)

DOCUMENTS = [
    "null",
    "true",
    "false",
    "0",
    "-0",
    "1",
    "1.0",
    "-0.0",
    "1e2",
    "1E-2",
    "2.5e+3",
    "9223372036854775807",
    "-9223372036854775808",
    "9223372036854775808",
    "-9223372036854775809",
    "99999999999999999999",
    "1" + "0" * 400,
    '""',
    '"1"',
    '"null"',
    "[]",
    "{}",
    '[1, 1.0, -0, 1e2, 99999999999999999999, null, true, "s", {}, [[]]]',
    '{"i": 7, "f": 2.5, "big": -12345678901234567890, "o": {"a": [false, {"b": null}]}, "e": []}',
]


class Number:
    def __init__(self, kind):
        self.kind = kind


def kind(value):
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, Number):
        return value.kind
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    return "object"


def walk(value, path, rows, document):
    rows.append("\t".join([document, "/".join(path) or ".", kind(value)]))
    if isinstance(value, list):
        for index, item in enumerate(value):
            walk(item, path + [f"#{index}"], rows, document)
    elif isinstance(value, dict):
        for key, item in value.items():
            walk(item, path + [key], rows, document)


def main():
    rows = []
    for document in DOCUMENTS:
        value = json.loads(
            document,
            parse_int=lambda _text: Number("int"),
            parse_float=lambda _text: Number("float"),
        )
        walk(value, [], rows, document)
    OUTPUT.write_text(HEADER + "\n" + "\n".join(rows) + "\n", encoding="utf-8")
    print(f"wrote {len(rows)} vectors to {OUTPUT}")


if __name__ == "__main__":
    main()
