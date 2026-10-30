"""The parts of the typed JSON peers (json-field-vectors.py, json-optional-vectors.py) that both models share: the
scalar rules of JSON.decode, the text JSON.encode writes for a scalar, and the writer of a vectors file.

Python's json module and the rules of docs/grammar/06b-builtins.md only; no code is shared with the VM.
"""

import json
import math

INT_MIN, INT_MAX = -(2**63), 2**63 - 1

EXPECTED = {
    "Int": "signed 64-bit Int",
    "Float": "finite Float",
    "Bool": "Bool",
    "String": "String",
}


class DecodeError(Exception):
    pass


def fail(path, expected):
    raise DecodeError(f"{path or '$'}: expected {expected}")


def is_int(value):
    return isinstance(value, int) and not isinstance(value, bool)


def scalar_kind_ok(value, kind):
    """The top kind check of a nullable scalar before it is decoded: a Float takes any number, even one too big."""
    if kind == "Int":
        return is_int(value) and INT_MIN <= value <= INT_MAX
    if kind == "Float":
        return is_int(value) or isinstance(value, float)
    if kind == "Bool":
        return isinstance(value, bool)
    return isinstance(value, str)


def decode_scalar(value, kind, path):
    """An Int, Float, Bool or String as JSON.decode reads it."""
    if kind == "Int":
        if not (is_int(value) and INT_MIN <= value <= INT_MAX):
            fail(path, EXPECTED[kind])
        return value
    if kind == "Float":
        if not (is_int(value) or isinstance(value, float)) or not math.isfinite(float(value)):
            fail(path, EXPECTED[kind])
        return float(value)
    if not scalar_kind_ok(value, kind):
        fail(path, EXPECTED[kind])
    return value


def encode_scalar(value, kind):
    if kind == "Float":
        return repr(value)
    return json.dumps(value, ensure_ascii=False)


def typed(text):
    """The document with each number tagged as written, so 1 and 1.0 differ as they do in JSON text."""
    return json.loads(text, parse_int=lambda digits: ("int", int(digits)), parse_float=lambda digits: ("float", digits))


def write_vectors(output, header, documents, decode, encode):
    """Writes one line per document: the document, "ok" and the encoded text or "error" and the message, and
    "same" or "changed" (the round trip up to key order) or "-". decode and encode take the parsed document and the
    decoded value."""
    rows = []
    for document in documents:
        try:
            text = encode(decode(json.loads(document)))
        except DecodeError as problem:
            rows.append("\t".join([document, "error", str(problem), "-"]))
            continue
        same = "same" if typed(text) == typed(document) else "changed"
        rows.append("\t".join([document, "ok", text, same]))
    output.write_text(header + "\n" + "\n".join(rows) + "\n", encoding="utf-8")
    print(f"wrote {len(rows)} vectors to {output}")
