"""An independent CBOR codec (RFC 8949) for the subset that Term.encode writes, written from the RFC alone: the peer of
the differential tests of Term (vm/term.c). Standard library only.

Items: int (major 0 and 1), bool, None, str, bytes, list, CborMap (a list of (key, value) pairs: the order is the
order of the bytes), F64 and F32 (the bits of a float, so a NaN payload and -0.0 are kept). The decoder is strict:
only what the encoder writes (shortest heads, definite lengths, no tags, the simple values false, true and null,
floats of 4 or 8 bytes, no bytes after the item).
"""
import struct


class PeerError(ValueError):
    pass


class CborMap(list):
    """A CBOR map, as a list of (key, value) pairs in the order of the bytes."""


class F64:
    def __init__(self, bits):
        self.bits = bits

    def __eq__(self, other):
        return isinstance(other, F64) and self.bits == other.bits

    def __repr__(self):
        return f"F64({self.bits:#018x})"

    @classmethod
    def of(cls, value):
        return cls(struct.unpack(">Q", struct.pack(">d", value))[0])


class F32:
    def __init__(self, bits):
        self.bits = bits

    def __eq__(self, other):
        return isinstance(other, F32) and self.bits == other.bits

    def __repr__(self):
        return f"F32({self.bits:#010x})"

    @classmethod
    def of(cls, value):
        return cls(struct.unpack(">I", struct.pack(">f", value))[0])


def head(major, argument):
    """RFC 8949 section 3: the initial byte and the argument, in the fewest bytes."""
    if not 0 <= argument < 1 << 64:
        raise PeerError(f"argument {argument} is outside 0 to 2^64 - 1")
    if argument < 24:
        return bytes([major << 5 | argument])
    for additional, size in ((24, 1), (25, 2), (26, 4), (27, 8)):
        if argument < 1 << (8 * size):
            return bytes([major << 5 | additional]) + argument.to_bytes(size, "big")
    raise PeerError("unreachable")


def encode(item):
    if item is None:
        return b"\xf6"
    if item is True:
        return b"\xf5"
    if item is False:
        return b"\xf4"
    if isinstance(item, int):
        return head(0, item) if item >= 0 else head(1, -1 - item)
    if isinstance(item, F64):
        return b"\xfb" + item.bits.to_bytes(8, "big")
    if isinstance(item, F32):
        return b"\xfa" + item.bits.to_bytes(4, "big")
    if isinstance(item, str):
        data = item.encode("utf-8")
        return head(3, len(data)) + data
    if isinstance(item, bytes):
        return head(2, len(item)) + item
    if isinstance(item, CborMap):
        return head(5, len(item)) + b"".join(encode(k) + encode(v) for k, v in item)
    if isinstance(item, list):
        return head(4, len(item)) + b"".join(encode(x) for x in item)
    raise PeerError(f"no CBOR form for {item!r}")


def decode(data):
    item, end = _read(data, 0)
    if end != len(data):
        raise PeerError("trailing bytes after the item")
    return item


def _argument(data, at, additional):
    """The argument of a head whose initial byte has ADDITIONAL, read at AT, and where the head ends."""
    if additional < 24:
        return additional, at
    if additional > 27:
        raise PeerError(f"additional information {additional} is not definite")
    size = 1 << (additional - 24)
    if at + size > len(data):
        raise PeerError("the head is cut short")
    argument = int.from_bytes(data[at:at + size], "big")
    least = {24: 24, 25: 1 << 8, 26: 1 << 16, 27: 1 << 32}[additional]
    if argument < least:
        raise PeerError("a head that is not the shortest")
    return argument, at + size


def _read(data, at):
    if at >= len(data):
        raise PeerError("the item is cut short")
    major, additional = data[at] >> 5, data[at] & 31
    at += 1
    if major == 7:
        return _simple(data, at, additional)
    argument, at = _argument(data, at, additional)
    if major == 0:
        return argument, at
    if major == 1:
        return -1 - argument, at
    if major in (2, 3):
        if at + argument > len(data):
            raise PeerError("the string is cut short")
        body = data[at:at + argument]
        if major == 2:
            return bytes(body), at + argument
        try:
            return body.decode("utf-8"), at + argument
        except UnicodeDecodeError as error:
            raise PeerError("a text that is not UTF-8") from error
    if major == 6:
        raise PeerError("a tag")
    if argument > len(data) - at:
        raise PeerError("more items than bytes")
    if major == 4:
        items = []
        for _ in range(argument):
            item, at = _read(data, at)
            items.append(item)
        return items, at
    pairs = CborMap()
    for _ in range(argument):
        key, at = _read(data, at)
        value, at = _read(data, at)
        pairs.append((key, value))
    return pairs, at


def _simple(data, at, additional):
    if additional == 20:
        return False, at
    if additional == 21:
        return True, at
    if additional == 22:
        return None, at
    if additional in (26, 27):
        size = 4 if additional == 26 else 8
        if at + size > len(data):
            raise PeerError("the float is cut short")
        bits = int.from_bytes(data[at:at + size], "big")
        return (F32(bits) if size == 4 else F64(bits)), at + size
    raise PeerError(f"simple value or float form {additional} is outside the subset")
