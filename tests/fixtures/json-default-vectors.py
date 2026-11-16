"""Writes tests/fixtures/vm/json-default-vectors.stdin, the vectors that json-default-vectors.agc checks.

The peer is Python's json module plus a small model of typed JSON with field
defaults (docs/grammar/06b-builtins.md, "Optional and nullable JSON fields"),
written from the rules and sharing no code with the VM: a missing key of a field
with a default gives the default, and null stays an error. It decodes each
document into the Order struct of the fixture and writes one line of four fields
joined by a tab:

- the JSON document;
- "ok" or "error";
- for "ok", the text JSON.encode gives for the decoded struct (declaration
  order, every field written); for "error", the message, path included;
- for "ok", "same" when that text is the document again up to key order (the
  round trip), else "changed" (a missing key comes back with its default); for
  "error", "-".

Run by hand: python3 tests/fixtures/json-default-vectors.py
CI does not run it; commit both files when the vectors change.
"""

from pathlib import Path

from json_typed_peer import struct_codec, write_vectors

OUTPUT = Path(__file__).resolve().parent / "vm" / "json-default-vectors.stdin"
HEADER = (
    "# json-default-vectors.stdin: made by python3 tests/fixtures/json-default-vectors.py "
    "(Python json module); do not edit by hand"
)

# The structs of json-default-vectors.agc: (field, type) or (field, type, default). A type is a scalar name,
# ("list", item), ("map", value) or a struct name.
STRUCTS = {
    "Item": [("sku", "String"), ("qty", "Int", 1), ("price", "Float", 0.5)],
    "Order": [
        ("id", "Int"),
        ("note", "String", ""),
        ("rush", "Bool", False),
        ("ratio", "Float", -2.5),
        ("count", "Int", -7),
        ("tags", ("list", "String"), []),
        ("limits", ("map", "Int"), {}),
        ("items", ("list", "Item"), []),
        ("main", "Item"),
    ],
}

MAIN = '"main": {"sku": "m"}'

DOCUMENTS = [
    '{"id": 1, ' + MAIN + "}",
    '{"id": 1, "note": "n", "rush": true, "ratio": 1.25, "count": 3, "tags": ["a"], "limits": {"a": 1},'
    ' "items": [{"sku": "x", "qty": 2, "price": 3.5}], "main": {"sku": "m", "qty": 9, "price": 1.5}}',
    '{"id": 2, "items": [{"sku": "x"}, {"sku": "y", "qty": 4}], ' + MAIN + "}",
    '{"id": 3, "tags": [], "limits": {}, ' + MAIN + "}",
    '{"id": 4, "extra": 1, ' + MAIN + "}",
    '{"id": 5, "ratio": 2, ' + MAIN + "}",
    '{"note": "x", ' + MAIN + "}",
    '{"id": 1}',
    '{"id": 1, "note": null, ' + MAIN + "}",
    '{"id": 1, "rush": null, ' + MAIN + "}",
    '{"id": 1, "tags": null, ' + MAIN + "}",
    '{"id": 1, "count": "3", ' + MAIN + "}",
    '{"id": 1, "items": [{"qty": 2}], ' + MAIN + "}",
    '{"id": 1, "items": [{"sku": "x", "qty": null}], ' + MAIN + "}",
    '{"id": 1, "main": {"price": 1}}',
    '{"id": 1, "limits": {"a": "b"}, ' + MAIN + "}",
]


decode, encode = struct_codec(STRUCTS)


def main():
    write_vectors(
        OUTPUT, HEADER, DOCUMENTS, lambda source: decode(source, "Order", ""), lambda value: encode(value, "Order")
    )


if __name__ == "__main__":
    main()
