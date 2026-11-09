"""Writes tests/fixtures/vm/json-enum-vectors.stdin, the vectors that json-enum-vectors.agc checks.

The peer is Python's json module plus a small model of typed JSON for enums (docs/grammar/06b-builtins.md,
"JSON for enums"), written from the rules and sharing no code with the VM. It decodes each document into the Page
struct of the fixture and writes one line of four fields joined by a tab:

- the JSON document;
- "ok" or "error";
- for "ok", the text JSON.encode gives for the decoded struct (declaration order; an enum value as
  {"tag": name, "values": [...]}, both keys always; none as null); for "error", the message, path included;
- for "ok", "same" when that text is the document again up to key order (the round trip), else "changed" (a missing
  key, such as an omitted "values", comes back written); for "error", "-".

Run by hand: python3 tests/fixtures/json-enum-vectors.py
CI does not run it; commit both files when the vectors change.
"""

import json
from pathlib import Path

from json_typed_peer import (
    UNHANDLED,
    decode_common,
    decode_struct,
    encode_common,
    encode_struct,
    enum_tag,
    fail,
    join,
    write_vectors,
)

OUTPUT = Path(__file__).resolve().parent / "vm" / "json-enum-vectors.stdin"
HEADER = (
    "# json-enum-vectors.stdin: made by python3 tests/fixtures/json-enum-vectors.py "
    "(Python json module); do not edit by hand"
)


def opt(kind):
    return ("optional", kind)


def lst(kind):
    return ("list", kind)


# The enum and the struct of json-enum-vectors.agc. A type is a scalar name, ("list", item), ("optional", item),
# ("enum", name) or the struct name Page. A variant is (name, [payload types]).
SHAPE = ("enum", "Shape")
ENUMS = {
    "Shape": [
        ("Circle", ["Float"]),
        ("Rect", ["Float", "Float"]),
        ("Label", ["String", opt("Int")]),
        ("Group", [lst(SHAPE)]),
        ("Empty", []),
    ],
}
PAGE = [("title", "String"), ("main", SHAPE), ("shapes", lst(SHAPE)), ("spare", opt(SHAPE))]

DOCUMENTS = [
    '{"title": "t", "main": {"tag": "Empty"}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Empty", "values": []}, "shapes": [], "spare": null}',
    '{"title": "t", "main": {"tag": "Circle", "values": [2.5]}, "shapes": [{"values": [1, 2], "tag": "Rect"}],'
    ' "spare": {"tag": "Label", "values": ["x", null]}}',
    '{"title": "t", "main": {"tag": "Label", "values": ["x", 7]}, "shapes": [{"tag": "Group", "values":'
    ' [[{"tag": "Empty"}, {"tag": "Group", "values": [[]]}]]}], "extra": true}',
    '{"title": "t", "main": {"tag": "Circle", "values": [3], "note": "ignored"}, "shapes": []}',
    '{"title": "t", "main": 3, "shapes": []}',
    '{"title": "t", "main": [], "shapes": []}',
    '{"title": "t", "main": {}, "shapes": []}',
    '{"title": "t", "main": {"values": [1.0]}, "shapes": []}',
    '{"title": "t", "main": {"tag": 7}, "shapes": []}',
    '{"title": "t", "main": {"tag": null}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Square"}, "shapes": []}',
    '{"title": "t", "main": {"tag": "circle"}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Circle"}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Circle", "values": null}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Circle", "values": {}}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Circle", "values": []}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Circle", "values": [1.0, 2.0]}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Empty", "values": [1]}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Rect", "values": [1.0, "x"]}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Label", "values": ["a", "b"]}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Label", "values": [1, null]}, "shapes": []}',
    '{"title": "t", "main": {"tag": "Empty"}, "shapes": [{"tag": "Empty"}, 5]}',
    '{"title": "t", "main": {"tag": "Empty"}, "shapes": [{"tag": "Rect", "values": [1.0]}]}',
    '{"title": "t", "main": {"tag": "Empty"}, "shapes": [{"tag": "Group", "values": [[{"tag": "Nope"}]]}]}',
    '{"title": "t", "main": {"tag": "Empty"}, "shapes": [{"tag": "Group", "values": [3]}]}',
    '{"title": "t", "main": {"tag": "Empty"}, "shapes": [], "spare": 5}',
    '{"title": "t", "main": {"tag": "Empty"}, "shapes": [], "spare": {"tag": "Rect", "values": [1.0, true]}}',
    '{"title": "t", "main": {"tag": "Empty"}, "shapes": [], "spare": []}',
    '{"main": {"tag": "Empty"}, "shapes": []}',
    '{"title": "t", "shapes": []}',
    "[]",
]


def decode_enum(value, name, path):
    """An enum from {"tag": ..., "values": [...]}: a variant with no payload may leave "values" out."""
    variants = ENUMS[name]
    tag = enum_tag(value, [variant for variant, _ in variants], path)
    payload = dict(variants)[tag]
    if "values" not in value:
        if payload:
            fail(join(path, "values"), "required field")
        items = []
    else:
        items = value["values"]
        if not isinstance(items, list):
            fail(join(path, "values"), "array")
        if len(items) != len(payload):
            fail(join(path, "values"), f"array of {len(payload)} items")
    values = [decode(item, kind, join(path, f"values[{index}]")) for index, (item, kind) in enumerate(zip(items, payload))]
    return ("variant", value["tag"], values)


def decode(value, kind, path):
    found = decode_common(value, kind, path, decode)
    if found is not UNHANDLED:
        return found
    if isinstance(kind, tuple) and kind[0] == "enum":
        return decode_enum(value, kind[1], path)
    return decode_struct(value, PAGE, path, decode)


def encode(value, kind):
    """The text JSON.encode writes: struct keys in declaration order, enum keys tag then values, no spaces."""
    found = encode_common(value, kind, encode)
    if found is not UNHANDLED:
        return found
    if isinstance(kind, tuple) and kind[0] == "enum":
        _, tag, values = value
        payload = dict(ENUMS[kind[1]])[tag]
        written = ",".join(encode(item, item_kind) for item, item_kind in zip(values, payload))
        return '{"tag":' + json.dumps(tag) + ',"values":[' + written + "]}"
    return encode_struct(value, PAGE, encode)


def main():
    write_vectors(
        OUTPUT, HEADER, DOCUMENTS, lambda source: decode(source, "Page", ""), lambda value: encode(value, "Page")
    )


if __name__ == "__main__":
    main()
