"""Writes tests/fixtures/vm/json-list-vectors.stdin, the vectors that json-list-vectors.agc checks.

The peer is Python's json module plus the model of typed JSON in json_typed_peer.py
(docs/grammar/06b-builtins.md, "JSON"), written from the rules and sharing no code
with the VM. It decodes each document into the target its first field names
(TARGETS: List[Item] is "list", Map[String, Item] "map", and so on), and writes
one line of five fields joined by a tab:

- the target;
- the JSON document;
- "ok" or "error";
- for "ok", the text JSON.encode gives for the decoded value (struct keys in
  declaration order, map keys sorted, none as null, a Color as {"tag": name,
  "values": []}); for "error", the message, path included;
- for "ok", "same" when that text is the document again up to key order (the
  round trip), else "changed"; for "error", "-".

Run by hand: python3 tests/fixtures/json-list-vectors.py
CI does not run it; commit both files when the vectors change.
"""

import json
from pathlib import Path

from json_typed_peer import UNHANDLED, enum_tag, fail, join, struct_codec, vector_row, write_rows

OUTPUT = Path(__file__).resolve().parent / "vm" / "json-list-vectors.stdin"
HEADER = (
    "# json-list-vectors.stdin: made by python3 tests/fixtures/json-list-vectors.py "
    "(Python json module); do not edit by hand"
)

# The struct and the enum of json-list-vectors.agc: (field, type), as in json-optional-vectors.py, and the variants
# of Color, which have no payload. The program has no Optional but the one of the "optionals" target.
ITEM = [("name", "String"), ("count", "Int")]
COLORS = ["Red", "Blue"]

TARGETS = {
    "list": ("list", "Item"),
    "map": ("map", "Item"),
    "ints": ("list", "Int"),
    "optionals": ("list", ("optional", "Int")),
    "colors": ("list", "Color"),
    "grid": ("list", ("list", "Item")),
    "groups": ("map", ("list", "Item")),
}

DOCUMENTS = [
    ("list", "[]"),
    ("list", '[{"name": "a", "count": 1}, {"count": 2, "name": "b", "extra": true}]'),
    ("list", '[{"name": "a", "count": 1}, {"name": 2, "count": 1}]'),
    ("list", '[{"name": "a", "count": 1}, null]'),
    ("list", '[{"name": "a"}]'),
    ("list", "[[]]"),
    ("list", '{"name": "a", "count": 1}'),
    ("list", "null"),
    ("map", "{}"),
    ("map", '{"b": {"name": "x", "count": 1}, "a": {"name": "y", "count": 2}}'),
    ("map", '{"a": {"count": 1}}'),
    ("map", '{"a": []}'),
    ("map", '[{"name": "a", "count": 1}]'),
    ("map", '"text"'),
    ("ints", "[1, -2, 9223372036854775807]"),
    ("ints", "[1, 2.5]"),
    ("ints", "[9223372036854775808]"),
    ("ints", '{"a": 1}'),
    ("optionals", "[1, null, 3]"),
    ("optionals", "[]"),
    ("optionals", '[1, "x"]'),
    ("colors", '[{"tag": "Red"}, {"tag": "Blue", "values": []}]'),
    ("colors", '[{"tag": "Green"}]'),
    ("colors", '[{"tag": "Red", "values": [1]}]'),
    ("colors", '["Red"]'),
    ("grid", '[[{"name": "a", "count": 1}], []]'),
    ("grid", '[[{"name": "a", "count": 1}, {"count": 2}]]'),
    ("grid", '[[{"name": "a", "count": 1}], {"name": "b", "count": 2}]'),
    ("groups", '{"x": [{"name": "a", "count": 1}], "y": []}'),
    ("groups", '{"x": [{"name": "a", "count": "1"}]}'),
    ("groups", '{"x": {"name": "a", "count": 1}}'),
]


def decode_color(value, kind, path):
    """A Color from {"tag": name}, with "values" left out or empty: its variants have no payload."""
    if kind != "Color":
        return UNHANDLED
    tag = enum_tag(value, COLORS, path)
    if "values" in value:
        if not isinstance(value["values"], list):
            fail(join(path, "values"), "array")
        if value["values"]:
            fail(join(path, "values"), "array of 0 items")
    return tag


def encode_color(value, kind):
    if kind != "Color":
        return UNHANDLED
    return '{"tag":' + json.dumps(value) + ',"values":[]}'


decode, encode = struct_codec({"Item": ITEM}, (decode_color, encode_color))


def main():
    rows = []
    for target, document in DOCUMENTS:
        kind = TARGETS[target]
        row = vector_row(document, lambda value: decode(value, kind, ""), lambda value: encode(value, kind))
        rows.append(f"{target}\t{row}")
    write_rows(OUTPUT, HEADER, rows)


if __name__ == "__main__":
    main()
