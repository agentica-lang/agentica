"""Property tests (Hypothesis) of the VM codecs against the Python standard library: JSON, text encodings, base64, hex.

The profiles and the seed of each tier are in tests/conftest.py. One VM answers every example of the module.
"""
import base64
import binascii
import json
import math
import re
import struct
from importlib.util import find_spec

import pytest

from tests.agentica_test import compile_agc, require, scaled, start_vm, timeout

require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import example, given, strategies as st  # noqa: E402

CODEC_PROGRAM = """\
def hex(data: Bytes) -> String = OpenSSL.Digest.hexencode(data)

def text(data: Bytes) -> String = String.from_bytes(data).unwrap!

def bytes_reply(result: Result[Bytes]) -> String
  case result
    ok(data) -> "ok #{hex(data)}"
    error(e) -> "error #{hex(e.message.bytes)}"
  end
end

def text_reply(result: Result[String]) -> String
  case result
    ok(s) -> "ok #{hex(s.bytes)}"
    error(e) -> "error #{hex(e.message.bytes)}"
  end
end

def value_reply(result: Result[JSON.Value]) -> String
  case result
    ok(j) -> "ok #{hex(JSON.encode(j).bytes)}"
    error(e) -> "error #{hex(e.message.bytes)}"
  end
end

def ints_reply(result: Result[List[Int]]) -> String
  case result
    ok(xs) -> "ok #{hex(JSON.encode(xs).bytes)}"
    error(e) -> "error #{hex(e.message.bytes)}"
  end
end

def floats_reply(result: Result[List[Float]]) -> String
  case result
    ok(xs) -> "ok #{hex(JSON.encode(xs).bytes)}"
    error(e) -> "error #{hex(e.message.bytes)}"
  end
end

def run(op: String, data: Bytes) -> String
  case op
    "json" -> value_reply(JSON.parse(text(data)))
    "ints" -> ints_reply(JSON.decode(text(data), List[Int]))
    "floats" -> floats_reply(JSON.decode(text(data), List[Float]))
    "utf8" -> text_reply(String.from_bytes(data))
    "b64" -> "ok #{hex(Base64.strict_encode64(data).bytes)}"
    "b64lines" -> "ok #{hex(Base64.encode64(data).bytes)}"
    "b64url" -> "ok #{hex(Base64.urlsafe_encode64(data).bytes)}"
    "b64urlnopad" -> "ok #{hex(Base64.urlsafe_encode64(data, false).bytes)}"
    "unb64strict" -> bytes_reply(Base64.strict_decode64(text(data)))
    "unb64url" -> bytes_reply(Base64.urlsafe_decode64(text(data)))
    "unb64" -> "ok #{hex(Base64.decode64(text(data)))}"
    "hex" -> "ok #{hex(hex(data).bytes)}"
    "unhex" -> bytes_reply(OpenSSL.Digest.hexdecode(text(data)))
    _ ->
      parts = op.split(":")
      if parts[0] == "decode"
        return text_reply(data.decode(parts[1]))
      end

      bytes_reply(text(data).encode(parts[1]))
  end
end

def payload(word: String) -> Bytes
  if word == "-"
    return "".bytes
  end

  OpenSSL.Digest.hexdecode(word).unwrap!
end

# Each line is a case number, an operation and the hex of its input. The answer repeats the number, then "ok" and the
# hex of the result, or "error" and the hex of the message.
def main() -> Void
  while !IO.eof?
    words = gets!.split(" ")
    puts("#{words[0]} #{run(words[1], payload(words[2]))}")
    IO.flush()
  end
end
"""


class CodecVm:
    def __init__(self, vm):
        self.vm = vm
        self.cases = 0

    def ask(self, op, data):
        """The VM's answer to `op` on `data` (bytes): the result bytes, or None for an error Result."""
        assert self.vm.process.poll() is None, "the VM ended (exit %r)" % self.vm.process.poll()
        self.cases += 1
        line = b"%d %s %s\n" % (self.cases, op.encode("ascii"), data.hex().encode("ascii") or b"-")
        self.vm.process.stdin.write(line)
        self.vm.process.stdin.flush()
        number, status, *rest = self.vm.next_line(timeout=scaled(30)).split(" ")
        assert number == str(self.cases), (number, op, data)
        return bytes.fromhex(rest[0] if rest else "") if status == "ok" else None


@pytest.fixture(scope="module")
def codec(tmp_path_factory):
    directory = tmp_path_factory.mktemp("codec")
    source = directory / "codec.agc"
    source.write_text(CODEC_PROGRAM, encoding="utf-8")
    vm = start_vm(compile_agc(source, directory / "codec.agcb"), stdin=True)
    try:
        yield CodecVm(vm)
        vm.close_stdin()
        assert vm.wait() == 0, vm.stderr_text()
    finally:
        vm.stop()


def same(a, b):
    """Equal JSON values with the same types, floats compared by their bits (so -0.0 is not 0.0)."""
    if type(a) is not type(b):
        return False
    if isinstance(a, float):
        return struct.pack("<d", a) == struct.pack("<d", b)
    if isinstance(a, list):
        return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
    if isinstance(a, dict):
        return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
    return a == b


def representable(value):
    """What JSON.parse keeps: no non-finite number and no lone surrogate (a String is UTF-8)."""
    if isinstance(value, float):
        return math.isfinite(value)
    if isinstance(value, str):
        return not any(0xD800 <= ord(c) <= 0xDFFF for c in value)
    if isinstance(value, list):
        return all(map(representable, value))
    if isinstance(value, dict):
        return all(representable(k) and representable(v) for k, v in value.items())
    return True


INVALID = object()


def python_json(text):
    """json.loads of `text`, or INVALID where JSON.parse must fail. A mantissa of only zeros is 0.0 whatever its sign
    (docs/vm/02-reference-behavior.md); a negative number that rounds to zero is -0.0."""
    def refuse(constant):
        raise ValueError(constant)

    def number(digits):
        mantissa = re.split("[eE]", digits)[0]
        return 0.0 if mantissa.strip("-0.") == "" else float(digits)

    try:
        value = json.loads(text, parse_constant=refuse, parse_float=number)
    except ValueError:
        return INVALID
    return value if representable(value) else INVALID


JSON_VALUES = st.recursive(
    st.none() | st.booleans() | st.integers() | st.integers(-2**63, 2**63 - 1)
    | st.floats(allow_nan=False, allow_infinity=False) | st.text(),
    lambda inner: st.lists(inner, max_size=4) | st.dictionaries(st.text(max_size=4), inner, max_size=4),
    max_leaves=12,
)


@st.composite
def json_texts(draw):
    """JSON text from Python, sometimes with characters put in that may break it."""
    text = json.dumps(draw(JSON_VALUES), ensure_ascii=draw(st.booleans()))
    for _ in range(draw(st.integers(0, 2))):
        at = draw(st.integers(0, len(text)))
        text = text[:at] + draw(st.sampled_from(['{', '}', '[', ']', ',', ':', '"', '\\', ' ', '0', 'e', '.', '-', '+',
                                                 '\x01', '\\ud800', '\\udc00'])) + text[at:]
    return text


@timeout(300)
@given(json_texts())
@example("-0.0")
@example('{"a": 1, "a": 2}')
@example("[" * 500 + "]" * 500)
def test_json_parse_accepts_what_python_accepts_and_keeps_the_value(codec, text):
    """JSON.parse accepts a text if and only if json.loads does and its value is finite UTF-8 text; what it writes back
    reads in Python as the same value, with the same types and float bits."""
    want = python_json(text)
    got = codec.ask("json", text.encode("utf-8"))
    assert (got is None) == (want is INVALID), (text, got)
    if got is not None:
        assert same(json.loads(got), want), (text, got)


NUMBER_TEXTS = st.one_of(
    st.integers().map(str),
    st.sampled_from([2**63 - 1, -2**63, 2**63, -2**63 - 1]).map(str),
    st.floats(allow_nan=False, allow_infinity=False).map(repr),
    st.builds("{}.{}e{}".format, st.integers(-99, 99), st.integers(0, 10**20), st.integers(-340, 320)),
    st.sampled_from(["-0", "-0.0", "1E+2", "1e-400", "-1e-400", "1e400", "2.2250738585072014e-308",
                     "4.9406564584124654e-324", "1.7976931348623159e308", "9007199254740993", "01", "1.", ".5", "+1"]),
)


@timeout(300)
@given(st.lists(NUMBER_TEXTS, min_size=1, max_size=4))
def test_json_decode_reads_numbers_as_python_does(codec, numbers):
    """List[Int] takes exactly the integers that fit 64 bits; List[Float] takes every finite number, rounded as Python
    rounds it, and writes it back with the same bits."""
    text = "[" + ",".join(numbers) + "]"
    values = python_json(text)
    ints = codec.ask("ints", text.encode("ascii"))
    fits = values is not INVALID and all(type(v) is int and -2**63 <= v < 2**63 for v in values)
    assert (ints is not None) == fits, (text, ints)
    if fits:
        assert json.loads(ints) == values, (text, ints)
    floats = codec.ask("floats", text.encode("ascii"))
    finite = values is not INVALID and all(math.isfinite(float(v)) for v in values)
    assert (floats is not None) == finite, (text, floats)
    if finite:
        assert same([float(v) for v in json.loads(floats)], [float(v) for v in values]), (text, floats)


ENCODINGS = {
    "utf-8": "utf-8", "utf-16le": "utf-16-le", "utf-16be": "utf-16-be", "utf-32le": "utf-32-le",
    "utf-32be": "utf-32-be", "ascii": "ascii", "latin-1": "latin-1", "iso-8859-15": "iso8859-15",
    "windows-1252": "cp1252", "utf-16": "utf-16", "utf-32": "utf-32",
}
BOMS = [b"", b"\xfe\xff", b"\xff\xfe", b"\x00\x00\xfe\xff", b"\xff\xfe\x00\x00"]


def python_decode(data, name):
    """Plain utf-16 and utf-32 drop a byte order mark and read big-endian without one (Unicode's rule, not Python's)."""
    codec = ENCODINGS[name]
    if name in ("utf-16", "utf-32"):
        unit = 2 if name == "utf-16" else 4
        codec = name + "-be"
        if data[:unit] == "\ufeff".encode(name + "-le"):
            codec = name + "-le"
        if data[:unit] in ("\ufeff".encode(name + "-le"), "\ufeff".encode(name + "-be")):
            data = data[unit:]
    try:
        return data.decode(codec)
    except UnicodeDecodeError:
        return None


# The upper halves of the one-byte encodings (the euro sign, the Latin-9 letters, the Windows-1252 quotes), which a
# plain st.text() seldom draws.
HIGH_CHARS = sorted({bytes([b]).decode(codec, "ignore") for b in range(0x80, 0x100)
                     for codec in ("latin-1", "iso8859-15", "cp1252")} - {""})
ENCODE_TEXTS = st.text(st.sampled_from(HIGH_CHARS) | st.characters(exclude_categories=("Cs",)), max_size=12)


@timeout(300)
@given(st.sampled_from(sorted(ENCODINGS)), st.sampled_from(BOMS), st.binary(max_size=24), ENCODE_TEXTS)
def test_text_codecs_agree_with_python(codec, name, bom, data, text):
    """Bytes#decode fails if and only if Python's codec does, else gives the same text; String#encode the same, and
    the Unicode encodings never fail. String.from_bytes is the utf-8 decode."""
    data = bom + data
    want = python_decode(data, name)
    got = codec.ask("decode:" + name, data)
    assert (got is None) == (want is None), (name, data, got)
    if got is not None:
        assert got.decode("utf-8") == want, (name, data, got)
    if name == "utf-8":
        assert codec.ask("utf8", data) == got, data
    try:
        want = text.encode(ENCODINGS[name] if name not in ("utf-16", "utf-32") else name + "-be")
        if name in ("utf-16", "utf-32"):
            want = "\ufeff".encode(name + "-be") + want
    except UnicodeEncodeError:
        want = None
    assert codec.ask("encode:" + name, text.encode("utf-8")) == want, (name, text)


BASE64_TEXTS = st.one_of(
    st.binary(max_size=16).map(base64.b64encode),
    st.binary(max_size=16).map(base64.urlsafe_b64encode),
    st.text("ABCab+/=-_09 \n", max_size=12).map(str.encode),
)


@timeout(300)
@given(st.binary(max_size=100), BASE64_TEXTS)
def test_base64_and_hex_agree_with_python(codec, data, encoded):
    """The encoders write what Python writes (encode64 in Ruby's lines of 60), and every encoding decodes back. The
    strict decoders take exactly the canonical text, the URL form also without padding; hexdecode takes an even count
    of hex digits."""
    lines = b"".join(base64.b64encode(data[i:i + 45]) + b"\n" for i in range(0, len(data), 45))
    assert codec.ask("b64", data) == base64.b64encode(data)
    assert codec.ask("b64url", data) == base64.urlsafe_b64encode(data)
    assert codec.ask("b64urlnopad", data) == base64.urlsafe_b64encode(data).rstrip(b"=")
    assert codec.ask("b64lines", data) == lines
    assert codec.ask("unb64", lines) == data
    assert codec.ask("hex", data) == data.hex().encode("ascii")
    assert codec.ask("unhex", data.hex().upper().encode("ascii")) == data

    def canonical(text):
        try:
            decoded = base64.b64decode(text, validate=True)
        except binascii.Error:
            return None
        return decoded if base64.b64encode(decoded) == text else None

    assert codec.ask("unb64strict", encoded) == canonical(encoded), encoded
    url = encoded if encoded.endswith(b"=") else encoded + b"=" * (-len(encoded) % 4)
    assert codec.ask("unb64url", encoded) == canonical(url.replace(b"-", b"+").replace(b"_", b"/")), encoded
    digits = encoded.replace(b"=", b"f")
    want = bytes.fromhex(digits.decode()) if all(chr(c) in "0123456789abcdefABCDEF" for c in digits) \
        and len(digits) % 2 == 0 else None
    assert codec.ask("unhex", digits) == want, digits
