"""Writes tests/fixtures/vm/json-optional-vectors.stdin, the vectors that json-optional-vectors.agc checks.

The peer is Python's json module plus a small model of typed JSON with Optional
(docs/grammar/06b-builtins.md, "Optional and nullable JSON fields"), written from
the rules and sharing no code with the VM. It decodes each document into the
Person struct of the fixture and writes one line of four fields joined by a tab:

- the JSON document;
- "ok" or "error";
- for "ok", the text JSON.encode gives for the decoded struct (declaration
  order, none as null, some(x) as x); for "error", the message, path included;
- for "ok", "same" when that text is the document again up to key order (the
  round trip), else "changed" (a missing key comes back as null); for "error",
  "-".

Run by hand: python3 tests/fixtures/json-optional-vectors.py
CI does not run it; commit both files when the vectors change.
"""

from pathlib import Path

from json_typed_peer import struct_codec, write_vectors

OUTPUT = Path(__file__).resolve().parent / "vm" / "json-optional-vectors.stdin"
HEADER = (
    "# json-optional-vectors.stdin: made by python3 tests/fixtures/json-optional-vectors.py "
    "(Python json module); do not edit by hand"
)

def opt(kind):
    return ("optional", kind)


# The structs of json-optional-vectors.agc: (field, type). A type is a scalar name, ("list", item), ("map", value),
# ("optional", item) or a struct name.
STRUCTS = {
    "Address": [("city", "String"), ("zip", opt("String"))],
    "Person": [
        ("id", "Int"),
        ("name", opt("String")),
        ("age", opt("Int")),
        ("score", opt("Float")),
        ("address", opt("Address")),
        ("tags", ("list", opt("String"))),
        ("nicks", opt(("list", "String"))),
        ("limits", ("map", opt("Int"))),
        ("deep", opt(opt("Int"))),
    ],
}

DOCUMENTS = [
    '{"id": 1, "tags": [], "limits": {}}',
    '{"id": 1, "name": null, "age": null, "score": null, "address": null, "tags": [], "nicks": null,'
    ' "limits": {}, "deep": null}',
    '{"id": 1, "name": "Ana", "age": 30, "score": 2.5, "address": {"city": "Bcn", "zip": "08001"},'
    ' "tags": ["a", null], "nicks": ["x"], "limits": {"a": 1, "b": null}, "deep": 7}',
    '{"id": 2, "address": {"city": "Bcn"}, "tags": [null, null], "limits": {"z": null}}',
    '{"id": 3, "score": 1, "tags": [], "limits": {}}',
    '{"id": 4, "extra": true, "name": "x", "tags": [], "limits": {}}',
    '{"tags": [], "limits": {}}',
    '{"id": 1, "limits": {}}',
    '{"id": 1, "tags": null, "limits": {}}',
    '{"id": 1, "age": "30", "tags": [], "limits": {}}',
    '{"id": 1, "age": 1.5, "tags": [], "limits": {}}',
    '{"id": 1, "age": 9223372036854775808, "tags": [], "limits": {}}',
    '{"id": 1, "name": 3, "tags": [], "limits": {}}',
    '{"id": 1, "address": [], "tags": [], "limits": {}}',
    '{"id": 1, "address": {"zip": null}, "tags": [], "limits": {}}',
    '{"id": 1, "address": {"city": "c", "zip": 9}, "tags": [], "limits": {}}',
    '{"id": 1, "tags": [1], "limits": {}}',
    '{"id": 1, "tags": ["a", 2], "limits": {}}',
    '{"id": 1, "nicks": [null], "tags": [], "limits": {}}',
    '{"id": 1, "nicks": "x", "tags": [], "limits": {}}',
    '{"id": 1, "tags": [], "limits": {"a": "b"}}',
    '{"id": 1, "tags": [], "limits": {}, "deep": "s"}',
]


decode, encode = struct_codec(STRUCTS)


def main():
    write_vectors(
        OUTPUT, HEADER, DOCUMENTS, lambda source: decode(source, "Person", ""), lambda value: encode(value, "Person")
    )


if __name__ == "__main__":
    main()
