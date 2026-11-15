"""Property test (Hypothesis) of `gets` on stdin against a model of its line ends: \\n, \\r\\n and a lone \\r each end a
line, also when the input arrives in pieces and a \\r is the last byte of a piece.

The profiles and the seed of each tier are in tests/conftest.py.
"""
import time
from importlib.util import find_spec

import pytest

from tests.agentica_test import SLOW, compile_text, output_lines, require, start_vm, timeout

require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import example, given, settings, strategies as st  # noqa: E402

PROGRAM = """\
def main() -> Void
  while true
    case gets()
      ok(line) -> puts("line #{OpenSSL.Digest.hexencode(line.bytes)}")
      error(_) -> break
    end
  end
  puts("end")
end
"""

CHUNKS = [b"a", b"abcdefghijklmnopqrstuvwxyz0123456789", "é".encode(), "日本".encode(), b"\n", b"\r", b"\r\n"]


def model_lines(data):
    lines, start, at = [], 0, 0
    while at < len(data):
        if data[at] in b"\r\n":
            lines.append(data[start:at])
            at += 2 if data[at:at + 2] == b"\r\n" else 1
            start = at
        else:
            at += 1
    if start < len(data):
        lines.append(data[start:])
    return lines


@pytest.fixture(scope="module")
def reader(tmp_path_factory):
    return compile_text(PROGRAM, "reader", tmp_path_factory.mktemp("stdin"))


@st.composite
def pieces(draw):
    data = b"".join(draw(st.lists(st.sampled_from(CHUNKS), max_size=24)))
    cuts = sorted(draw(st.lists(st.integers(0, len(data)), max_size=3)))
    return [data[a:b] for a, b in zip([0] + cuts, cuts + [len(data)])]


@timeout(300)
@settings(max_examples=300 if SLOW else 30)
@given(pieces())
@example([b"a\r", b"\nb"])
@example([b"a\r", b"b"])
@example([b"a\r"])
@example([b"\r\r\n\n"])
@example([b"abcdefghijklmnopqrstuvwxyz\rx"])
def test_gets_ends_lines_as_the_model_does(reader, parts):
    """Each `gets` returns the bytes up to the next \\r\\n, \\r or \\n, the last line also without one, whatever pieces
    the input arrives in."""
    vm = start_vm(reader, stdin=True)
    try:
        for part in parts:
            vm.process.stdin.write(part)
            vm.process.stdin.flush()
            time.sleep(0.005)
        vm.close_stdin()
        assert vm.wait() == 0, vm.stderr_text()
        got = output_lines(vm.stdout_text())
    finally:
        vm.stop()
    want = ["line " + line.hex() for line in model_lines(b"".join(parts))] + ["end"]
    assert got == want, parts
