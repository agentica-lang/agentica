"""Property test (Hypothesis) of the text search behind String#index_of, include?, replace and split against Python's
str methods: patterns of one byte, of up to 8 bytes and longer, matches next to each other and far apart.

The profiles and the seed of each tier are in tests/conftest.py. One VM answers every example of the module.
"""
import json
from importlib.util import find_spec

import pytest

from tests.agentica_test import compile_text, require, scaled, start_vm, timeout

require(find_spec("hypothesis") is not None, "hypothesis is required (poetry install --only test --no-root)")

from hypothesis import example, given, strategies as st  # noqa: E402

PROGRAM = """\
def text(word: String) -> String
  if word == "-"
    return ""
  end

  String.from_bytes(OpenSSL.Digest.hexdecode(word).unwrap!).unwrap!
end

def found(s: String, part: String) -> Int
  case s.index_of(part)
    some(at) -> at
    none -> -1
  end
end

# Each line is a case number and the hex of a text and of a pattern; the answer repeats the number, then JSON of what
# index_of, include?, replace and split give.
def main() -> Void
  while !IO.eof?
    words = gets!.split(" ")
    s = text(words[1])
    part = text(words[2])
    replaced = s.replace(part, "<>")
    pieces = s.split(part)
    puts("#{words[0]} #{found(s, part)} #{s.include?(part)} #{JSON.encode(replaced)} #{JSON.encode(pieces)}")
    IO.flush()
  end
end
"""

PATTERNS = [",", " ", "é", "日", "ab", "aab", "a b", "日本", "abcdefgh", "abcdefghi", "abcabcabcab", " x é"]
FILLER = ["a", "b", "c", "x", "é", "日", "本", "abcdefghijklmnopqrstuvwxyz"]


@pytest.fixture(scope="module")
def search(tmp_path_factory):
    vm = start_vm(compile_text(PROGRAM, "search", tmp_path_factory.mktemp("search")), stdin=True)
    cases = iter(range(1, 1 << 30))

    def ask(text, part):
        number = next(cases)
        line = "%d %s %s\n" % (number, text.encode().hex() or "-", part.encode().hex() or "-")
        vm.process.stdin.write(line.encode("ascii"))
        vm.process.stdin.flush()
        return vm.next_line(timeout=scaled(30)), number

    try:
        yield ask
        vm.close_stdin()
        assert vm.wait() == 0, vm.stderr_text()
    finally:
        vm.stop()


@st.composite
def search_cases(draw):
    """A pattern and a text of filler and copies of it: next to each other, a few bytes apart, or more than 16."""
    part = draw(st.sampled_from(PATTERNS))
    text = "".join(draw(st.lists(st.sampled_from(FILLER + [part] * 3), max_size=30)))
    return text, part


@timeout(300)
@given(search_cases())
@example(("", ","))
@example((",,,", ","))
@example(("a" * 40 + ",", ","))
@example(("a" * 16 + "," + "a" * 15 + ",", ","))
@example(("x" * 17 + "日本", "日本"))
@example(("abcabcabcabcabcab", "abcabcabcab"))
def test_search_agrees_with_python(search, case):
    """index_of is Python's str.find in code points (-1 for none), include? is `in`, and replace and split give
    Python's str.replace and str.split."""
    text, part = case
    line, number = search(text, part)
    words = line.split(" ", 3)
    assert words[0] == str(number), (line, case)
    assert int(words[1]) == text.find(part), (line, case)
    assert words[2] == ("true" if part in text else "false"), (line, case)
    decoder = json.JSONDecoder()
    replaced, end = decoder.raw_decode(words[3])
    pieces = decoder.raw_decode(words[3][end:].lstrip())[0]
    assert replaced == text.replace(part, "<>"), (line, case)
    assert pieces == text.split(part), (line, case)
