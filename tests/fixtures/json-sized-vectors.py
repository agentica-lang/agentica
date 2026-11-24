"""Writes tests/fixtures/vm/json-sized-vectors.stdin, the vectors that json-sized-vectors.agc checks.

The peer is Python's json module plus the model of typed JSON in json_typed_peer.py, with the ranges of the narrow
integer types (Int8 to UInt32) as Python ints, sharing no code with the VM. It decodes each document into the Sample
struct of the fixture and writes one line of four fields joined by a tab, as json-optional-vectors.py does: the
document, "ok" and the text JSON.encode gives or "error" and the message, and "same", "changed" or "-".

Run by hand: python3 tests/fixtures/json-sized-vectors.py
CI does not run it; commit both files when the vectors change.
"""

import json
from pathlib import Path

from json_typed_peer import RANGES, struct_codec, write_vectors

OUTPUT = Path(__file__).resolve().parent / "vm" / "json-sized-vectors.stdin"
HEADER = (
    "# json-sized-vectors.stdin: made by python3 tests/fixtures/json-sized-vectors.py "
    "(Python json module); do not edit by hand"
)

NARROW = ["Int8", "Int16", "Int32", "UInt8", "UInt16", "UInt32"]

# The struct of json-sized-vectors.agc: one field of each narrow type, then the types inside an Optional, a List and a
# Map.
STRUCTS = {
    "Sample": [(name.lower(), name) for name in NARROW]
    + [
        ("byte", ("optional", "UInt8")),
        ("shorts", ("list", "Int16")),
        ("counts", ("map", "UInt32")),
    ],
}

GOOD = {"int8": 0, "int16": 0, "int32": 0, "uint8": 0, "uint16": 0, "uint32": 0, "shorts": [], "counts": {}}


def document(**changes) -> str:
    """A Sample document: GOOD with the given fields changed, or left out when the change is ...."""
    fields = {**GOOD, **changes}
    return json.dumps({key: value for key, value in fields.items() if value is not ...})


def documents() -> list[str]:
    found = [document(), document(byte=None), document(byte=255, shorts=[-32768, 32767], counts={"a": 4294967295})]
    for name in NARROW:
        field = name.lower()
        low, high = RANGES[name]
        for value in (low - 1, low, high, high + 1, 2**63, 1.0, "1", None, True):
            found.append(document(**{field: value}))
        found.append(document(**{field: ...}))
    for value in (-1, 256, 0.5, "x", 2**64):
        found.append(document(byte=value))
    found += [
        document(shorts=[1, 32768]),
        document(shorts=[None]),
        document(counts={"a": -1}),
        document(counts={"a": 4294967296}),
        document(counts={"a": None}),
    ]
    return found


decode, encode = struct_codec(STRUCTS)


def main():
    write_vectors(
        OUTPUT, HEADER, documents(), lambda source: decode(source, "Sample", ""), lambda value: encode(value, "Sample")
    )


if __name__ == "__main__":
    main()
