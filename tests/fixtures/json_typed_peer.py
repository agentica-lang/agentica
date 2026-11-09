"""The parts of the typed JSON peers (json-field-vectors.py, json-optional-vectors.py, json-enum-vectors.py) that the
models share: the scalar rules of JSON.decode, the Optional and list rules of both directions, the text JSON.encode
writes for a scalar, and the writer of a vectors file.

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


NONE = object()
UNHANDLED = object()


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


def vector_row(document, decode, encode):
    """The line of one document: the document, "ok" and the encoded text or "error" and the message, and "same" or
    "changed" (the round trip up to key order) or "-". decode and encode take the parsed document and the decoded
    value."""
    try:
        text = encode(decode(json.loads(document)))
    except DecodeError as problem:
        return "\t".join([document, "error", str(problem), "-"])
    same = "same" if typed(text) == typed(document) else "changed"
    return "\t".join([document, "ok", text, same])


def write_rows(output, header, rows):
    output.write_text(header + "\n" + "\n".join(rows) + "\n", encoding="utf-8")
    print(f"wrote {len(rows)} vectors to {output}")


def write_vectors(output, header, documents, decode, encode):
    """Writes one line per document (vector_row)."""
    write_rows(output, header, [vector_row(document, decode, encode) for document in documents])


def is_optional(kind):
    return isinstance(kind, tuple) and kind[0] == "optional"


def is_list(kind):
    return isinstance(kind, tuple) and kind[0] == "list"


def top_kind_ok(value, kind):
    """The top kind check of an Optional, before its T is decoded; an Optional T makes its own."""
    if is_optional(kind):
        return True
    if kind in EXPECTED:
        return scalar_kind_ok(value, kind)
    if is_list(kind):
        return isinstance(value, list)
    return isinstance(value, dict)


def top_kind_name(kind):
    if is_list(kind):
        return "array"
    return EXPECTED.get(kind, "object")


def decode_common(value, kind, path, decode):
    """The Optional, scalar and list kinds, with decode for the types inside; UNHANDLED for any other kind."""
    if is_optional(kind):
        if value is None:
            return NONE
        if not top_kind_ok(value, kind[1]):
            fail(path, f"{top_kind_name(kind[1])} or null")
        return ("some", decode(value, kind[1], path))
    if kind in EXPECTED:
        return decode_scalar(value, kind, path)
    if is_list(kind):
        if not isinstance(value, list):
            fail(path, "array")
        return [decode(item, kind[1], f"{path}[{index}]") for index, item in enumerate(value)]
    return UNHANDLED


def encode_common(value, kind, encode):
    """The text JSON.encode writes for an Optional, a list or a scalar, with encode for the types inside; UNHANDLED
    for any other kind."""
    if is_optional(kind):
        return "null" if value is NONE else encode(value[1], kind[1])
    if is_list(kind):
        return "[" + ",".join(encode(item, kind[1]) for item in value) + "]"
    if kind in EXPECTED:
        return encode_scalar(value, kind)
    return UNHANDLED


def decode_struct(value, fields, path, decode):
    """A struct from an object: fields are (name, kind) in declaration order; only an Optional field may be missing."""
    if not isinstance(value, dict):
        fail(path, "object")
    record = {}
    for name, kind in fields:
        here = f"{path}.{name}" if path else name
        if name not in value:
            if not is_optional(kind):
                fail(here, "required field")
            record[name] = NONE
        else:
            record[name] = decode(value[name], kind, here)
    return record


def encode_struct(value, fields, encode):
    """The text of a struct: its keys in declaration order, no spaces."""
    parts = [json.dumps(name) + ":" + encode(value[name], kind) for name, kind in fields]
    return "{" + ",".join(parts) + "}"


def struct_codec(structs):
    """The decode and encode of a model whose kinds are the scalars, ("list", T), ("map", T) with String keys,
    ("optional", T) and the names of structs, which maps to their (name, kind) fields. encode writes struct keys in
    declaration order, map keys sorted, no spaces."""

    def decode(value, kind, path):
        found = decode_common(value, kind, path, decode)
        if found is not UNHANDLED:
            return found
        if isinstance(kind, tuple):
            if not isinstance(value, dict):
                fail(path, "object")
            return {key: decode(item, kind[1], f"{path}[{json.dumps(key)}]") for key, item in sorted(value.items())}
        return decode_struct(value, structs[kind], path, decode)

    def encode(value, kind):
        found = encode_common(value, kind, encode)
        if found is not UNHANDLED:
            return found
        if isinstance(kind, tuple):
            return "{" + ",".join(json.dumps(key) + ":" + encode(item, kind[1]) for key, item in value.items()) + "}"
        return encode_struct(value, structs[kind], encode)

    return decode, encode
