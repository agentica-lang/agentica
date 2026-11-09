"""Writes tests/fixtures/vm/json-list-vectors.stdin, the vectors that json-list-vectors.agc checks.

The peer is Python's json module plus the model of typed JSON in json_typed_peer.py
(docs/grammar/06b-builtins.md, "JSON"), written from the rules and sharing no code
with the VM. It decodes each document into the target its first field names,
List[Item] ("list") or Map[String, Item] ("map"), and writes one line of five
fields joined by a tab:

- the target;
- the JSON document;
- "ok" or "error";
- for "ok", the text JSON.encode gives for the decoded value (struct keys in
  declaration order, map keys sorted, none as null); for "error", the message,
  path included;
- for "ok", "same" when that text is the document again up to key order (the
  round trip), else "changed"; for "error", "-".

Run by hand: python3 tests/fixtures/json-list-vectors.py
CI does not run it; commit both files when the vectors change.
"""

from pathlib import Path

from json_typed_peer import struct_codec, vector_row, write_rows

OUTPUT = Path(__file__).resolve().parent / "vm" / "json-list-vectors.stdin"
HEADER = (
    "# json-list-vectors.stdin: made by python3 tests/fixtures/json-list-vectors.py "
    "(Python json module); do not edit by hand"
)

# The struct of json-list-vectors.agc: (field, type), as in json-optional-vectors.py.
ITEM = [("name", "String"), ("count", ("optional", "Int"))]

TARGETS = {"list": ("list", "Item"), "map": ("map", "Item")}

DOCUMENTS = [
    ("list", "[]"),
    ("list", '[{"name": "a", "count": 1}, {"name": "b"}]'),
    ("list", '[{"name": "a", "count": null}]'),
    ("list", '[{"name": "a"}, {"name": 2}]'),
    ("list", '[{"name": "a"}, null]'),
    ("list", "[[]]"),
    ("list", '{"name": "a"}'),
    ("list", "null"),
    ("map", "{}"),
    ("map", '{"b": {"name": "x"}, "a": {"name": "y", "count": 2}}'),
    ("map", '{"a": {"count": 1}}'),
    ("map", '{"a": []}'),
    ("map", '[{"name": "a"}]'),
    ("map", '"text"'),
]


decode, encode = struct_codec({"Item": ITEM})


def main():
    rows = []
    for target, document in DOCUMENTS:
        kind = TARGETS[target]
        row = vector_row(document, lambda value: decode(value, kind, ""), lambda value: encode(value, kind))
        rows.append(f"{target}\t{row}")
    write_rows(OUTPUT, HEADER, rows)


if __name__ == "__main__":
    main()
