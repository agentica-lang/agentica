"""Writes tests/fixtures/vm/json-field-vectors.stdin, the vectors that json-field-vectors.agc checks.

The peer is Python's json module plus a small model of typed JSON with JsonField
(docs/grammar/06b-builtins.md, "Optional and nullable JSON fields"), written from
the rules and sharing no code with the VM. It decodes each document into the
Patch struct of the fixture and writes one line of four fields joined by a tab:

- the JSON document;
- "ok" or "error";
- for "ok", the text JSON.encode gives for the decoded struct (declaration
  order, an Absent key left out, Null as null); for "error", the message,
  path included;
- for "ok", "same" when that text is the document again up to key order (the
  round trip), else "changed"; for "error", "-".

Run by hand: python3 tests/fixtures/json-field-vectors.py
CI does not run it; commit both files when the vectors change.
"""

import json
import math
from pathlib import Path

OUTPUT = Path(__file__).resolve().parent / "vm" / "json-field-vectors.stdin"
HEADER = (
    "# json-field-vectors.stdin: made by python3 tests/fixtures/json-field-vectors.py "
    "(Python json module); do not edit by hand"
)

INT_MIN, INT_MAX = -(2**63), 2**63 - 1

# The structs of json-field-vectors.agc: (field, type, optional). A type is a scalar name, ("list", item) or a
# struct name.
STRUCTS = {
    "Address": [("zip", "String", False), ("note", "String", True)],
    "Patch": [
        ("id", "Int", False),
        ("name", "String", True),
        ("age", "Int", True),
        ("score", "Float", True),
        ("address", "Address", True),
        ("tags", ("list", "String"), True),
        ("homes", ("list", "Address"), True),
    ],
}

EXPECTED = {
    "Int": "signed 64-bit Int",
    "Float": "finite Float",
    "Bool": "Bool",
    "String": "String",
}

DOCUMENTS = [
    '{"id": 1}',
    '{"id": 1, "name": null, "age": null, "score": null, "address": null, "tags": null, "homes": null}',
    '{"id": 1, "name": "Ana", "age": 30, "score": 2.5, "address": {"zip": "08001"}, "tags": ["a", "b"],'
    ' "homes": [{"zip": "1", "note": null}, {"zip": "2", "note": "x"}]}',
    '{"age": 7, "id": 2}',
    '{"id": 3, "address": {"zip": "z", "note": "n"}, "tags": []}',
    '{"id": 4, "score": 1}',
    '{"id": 5, "extra": true, "name": "x"}',
    "{}",
    '{"name": "x"}',
    '{"id": null}',
    "[]",
    '{"id": 1, "age": "30"}',
    '{"id": 1, "age": 1.5}',
    '{"id": 1, "age": 9223372036854775808}',
    '{"id": 1, "score": "x"}',
    '{"id": 1, "name": 3}',
    '{"id": 1, "address": 3}',
    '{"id": 1, "address": []}',
    '{"id": 1, "address": {}}',
    '{"id": 1, "address": {"zip": 9}}',
    '{"id": 1, "address": {"zip": "z", "note": 9}}',
    '{"id": 1, "tags": {}}',
    '{"id": 1, "tags": [1]}',
    '{"id": 1, "tags": [null]}',
    '{"id": 1, "homes": [{"zip": "a"}, {"note": "b"}]}',
    '{"id": 1, "homes": [{"zip": "a"}, {"zip": "b", "note": false}]}',
]


class DecodeError(Exception):
    pass


ABSENT = object()


def fail(path, expected):
    raise DecodeError(f"{path or '$'}: expected {expected}")


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def top_kind_ok(value, kind):
    """The top kind check of a JsonField field, before its T is decoded."""
    if kind == "Int":
        return is_int(value) and INT_MIN <= value <= INT_MAX
    if kind == "Float":
        return is_int(value) or isinstance(value, float)
    if kind == "String":
        return isinstance(value, str)
    if isinstance(kind, tuple):
        return isinstance(value, list)
    return isinstance(value, dict)


def top_kind_name(kind):
    if isinstance(kind, tuple):
        return "array"
    return EXPECTED.get(kind, "object")


def decode(value, kind, path):
    if kind == "Int":
        if not (is_int(value) and INT_MIN <= value <= INT_MAX):
            fail(path, EXPECTED[kind])
        return value
    if kind == "Float":
        if not (is_int(value) or isinstance(value, float)) or not math.isfinite(float(value)):
            fail(path, EXPECTED[kind])
        return float(value)
    if kind == "String":
        if not isinstance(value, str):
            fail(path, EXPECTED[kind])
        return value
    if isinstance(kind, tuple):
        if not isinstance(value, list):
            fail(path, "array")
        return [decode(item, kind[1], f"{path}[{index}]") for index, item in enumerate(value)]
    if not isinstance(value, dict):
        fail(path, "object")
    record = {}
    for name, field_kind, optional in STRUCTS[kind]:
        here = f"{path}.{name}" if path else name
        if name not in value:
            if not optional:
                fail(here, "required field")
            record[name] = ABSENT
        elif optional and value[name] is None:
            record[name] = None
        elif optional and not top_kind_ok(value[name], field_kind):
            fail(here, f"{top_kind_name(field_kind)} or null")
        else:
            record[name] = decode(value[name], field_kind, here)
    return record


def encode(value, kind):
    """The text JSON.encode writes: struct keys in declaration order, no spaces."""
    if isinstance(kind, tuple):
        return "[" + ",".join(encode(item, kind[1]) for item in value) + "]"
    if kind in STRUCTS:
        parts = []
        for name, field_kind, _optional in STRUCTS[kind]:
            item = value[name]
            if item is ABSENT:
                continue
            text = "null" if item is None else encode(item, field_kind)
            parts.append(json.dumps(name) + ":" + text)
        return "{" + ",".join(parts) + "}"
    if kind == "Float":
        return repr(value)
    return json.dumps(value, ensure_ascii=False)


def typed(text):
    """The document with each number tagged as written, so 1 and 1.0 differ as they do in JSON text."""
    return json.loads(text, parse_int=lambda digits: ("int", int(digits)), parse_float=lambda digits: ("float", digits))


def main():
    rows = []
    for document in DOCUMENTS:
        source = json.loads(document)
        try:
            text = encode(decode(source, "Patch", ""), "Patch")
        except DecodeError as problem:
            rows.append("\t".join([document, "error", str(problem), "-"]))
            continue
        same = "same" if typed(text) == typed(document) else "changed"
        rows.append("\t".join([document, "ok", text, same]))
    OUTPUT.write_text(HEADER + "\n" + "\n".join(rows) + "\n", encoding="utf-8")
    print(f"wrote {len(rows)} vectors to {OUTPUT}")


if __name__ == "__main__":
    main()
