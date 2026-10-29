"""std/uri: percent-encoding and query strings, the names and rules of Ruby's URI.

tests/fixtures/uri/driver.agc reads one JSON case per line of stdin and prints one JSON reply per line. The fixed
vectors are the values that Ruby gives (written out here); the generated cases are checked against Python's
urllib.parse, which is not the code under test. Python differs from Ruby in two bytes, `*` (Ruby keeps it) and `~`
(Ruby encodes it), so the peer's encoders are asked to keep `*` and their `~` is rewritten. Python also repairs bad
input (a bad `%` stays in the text, bad UTF-8 becomes U+FFFD) where std/uri returns an error, so the peer is asked
for strict decoding and the bad `%` is found with a regular expression.
"""
import json
import random
import re
from urllib.parse import parse_qsl, quote, quote_plus, unquote, unquote_plus, urlencode

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

BAD_PERCENT = re.compile(r"%(?![0-9A-Fa-f]{2})")


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc(FIXTURES / "uri" / "driver.agc", tmp_path_factory.mktemp("agentica-uri-") / "driver.agcb")


def call(driver, cases):
    """Run [(op, text_or_pairs)] through the driver and return one reply dict per case.

    Pairs are [name, value] lists here, as Python's urllib has them; the driver takes and gives {"name", "value"}.
    """
    lines = []
    for op, arg in cases:
        pairs = [{"name": n, "value": v} for n, v in arg] if isinstance(arg, list) else []
        text = "" if isinstance(arg, list) else arg
        lines.append(json.dumps({"op": op, "text": text, "pairs": pairs}))
    result = run_vm(driver, stdin=("\n".join(lines) + "\n").encode("utf-8"))
    assert result.code == 0, result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    for reply in replies:
        reply["pairs"] = [[pair["name"], pair["value"]] for pair in reply["pairs"]]
    assert len(replies) == len(cases)
    return replies


def one(driver, op, arg):
    return call(driver, [(op, arg)])[0]


def ruby_quote_plus(text, safe="", encoding=None, errors=None):
    return quote_plus(text, safe="*").replace("~", "%7E")


def ruby_quote(text):
    return quote(text, safe="*").replace("~", "%7E")


# (text, encode_www_form_component, encode_uri_component) as Ruby gives them: the kept set is A-Z a-z 0-9 * - . _
COMPONENT_VECTORS = [
    ("", "", ""),
    ("AZaz09*-._", "AZaz09*-._", "AZaz09*-._"),
    ("a b", "a+b", "a%20b"),
    ("a+b", "a%2Bb", "a%2Bb"),
    ("~", "%7E", "%7E"),
    ("é", "%C3%A9", "%C3%A9"),
    ("😀", "%F0%9F%98%80", "%F0%9F%98%80"),
    ("a/b?c=d&e#f%g", "a%2Fb%3Fc%3Dd%26e%23f%25g", "a%2Fb%3Fc%3Dd%26e%23f%25g"),
    ("\u0000\n\x7f", "%00%0A%7F", "%00%0A%7F"),
]

# (op, input, output) that only the decoders show: either hex case, `+` in the two styles, text that is not ASCII.
DECODE_VECTORS = [
    ("decode_www_form_component", "a+b%20c", "a b c"),
    ("decode_uri_component", "a+b%20c", "a+b c"),
    ("decode_www_form_component", "%c3%A9%F0%9f%98%80", "é😀"),
    ("decode_uri_component", "%7e%7E", "~~"),
    ("decode_www_form_component", "é+ü", "é ü"),
]

FORM_VECTORS = [
    ("", []),
    ("a=1", [["a", "1"]]),
    ("a=1&a=2&b=", [["a", "1"], ["a", "2"], ["b", ""]]),
    ("=x", [["", "x"]]),
    ("a=1&&b=2", [["a", "1"], ["b", "2"]]),
    ("&", []),
    ("&&&", []),
    ("a=1&", [["a", "1"]]),
    ("k", [["k", ""]]),
    ("k&m=", [["k", ""], ["m", ""]]),
    ("a=b=c", [["a", "b=c"]]),
    ("a=", [["a", ""]]),
    ("=", [["", ""]]),
    ("q=caf%C3%A9+au+lait&x=%F0%9F%98%80", [["q", "café au lait"], ["x", "😀"]]),
    ("a%26b=c%3Dd", [["a&b", "c=d"]]),
    ("a;b=1", [["a;b", "1"]]),
]

ERROR_CASES = [
    ("decode_www_form_component", "%zz", "invalid %-encoding (%zz)"),
    ("decode_uri_component", "a%4", "invalid %-encoding (a%4)"),
    ("decode_www_form_component", "%", "invalid %-encoding (%)"),
    ("decode_www_form_component", "100%", "invalid %-encoding (100%)"),
    ("decode_www_form_component", "%4g", "invalid %-encoding (%4g)"),
    ("decode_www_form_component", "%%41", "invalid %-encoding (%%41)"),
    ("decode_uri_component", "%ff", "invalid UTF-8 after decoding (%ff)"),
    ("decode_www_form_component", "%C3", "invalid UTF-8 after decoding (%C3)"),
    ("decode_www_form_component", "%C0%80", "invalid UTF-8 after decoding (%C0%80)"),
    ("decode_www_form_component", "%ED%A0%80", "invalid UTF-8 after decoding (%ED%A0%80)"),
    ("decode_www_form_component", "%F4%90%80%80", "invalid UTF-8 after decoding (%F4%90%80%80)"),
    ("decode_www_form", "a=1&b=%zz", "invalid %-encoding (%zz)"),
    ("decode_www_form", "%4=1", "invalid %-encoding (%4)"),
    ("decode_www_form", "a=%ff", "invalid UTF-8 after decoding (%ff)"),
]


def test_component_vectors_encode_and_decode_back(driver):
    cases = []
    for text, form, uri in COMPONENT_VECTORS:
        cases += [("encode_www_form_component", text), ("encode_uri_component", text),
                  ("decode_www_form_component", form), ("decode_uri_component", uri)]
    replies = call(driver, cases)
    for index, (text, form, uri) in enumerate(COMPONENT_VECTORS):
        got = [r["text"] for r in replies[4 * index:4 * index + 4]]
        assert [r["success"] for r in replies[4 * index:4 * index + 4]] == [True] * 4, text
        assert got == [form, uri, text, text], text


def test_decode_vectors(driver):
    replies = call(driver, [(op, text) for op, text, _ in DECODE_VECTORS])
    for (op, text, expected), reply in zip(DECODE_VECTORS, replies):
        assert (reply["success"], reply["text"]) == (True, expected), (op, text)


def test_decode_www_form_vectors_keep_names_values_and_order(driver):
    replies = call(driver, [("decode_www_form", query) for query, _ in FORM_VECTORS])
    for (query, expected), reply in zip(FORM_VECTORS, replies):
        assert (reply["success"], reply["pairs"]) == (True, expected), query


def test_encode_www_form_vectors(driver):
    cases = [
        ([], ""),
        ([["a", "1"], ["a", "2"], ["b", ""]], "a=1&a=2&b="),
        ([["", "x"]], "=x"),
        ([["q", "café au lait"], ["x", "😀"]], "q=caf%C3%A9+au+lait&x=%F0%9F%98%80"),
        ([["a&b", "c=d"]], "a%26b=c%3Dd"),
    ]
    replies = call(driver, [("encode_www_form", pairs) for pairs, _ in cases])
    for (pairs, expected), reply in zip(cases, replies):
        assert (reply["success"], reply["text"]) == (True, expected), pairs


def test_bad_input_is_an_error_with_the_text_and_never_a_halt(driver):
    replies = call(driver, [(op, arg) for op, arg, _ in ERROR_CASES])
    for (op, arg, message), reply in zip(ERROR_CASES, replies):
        assert (reply["success"], reply["message"]) == (False, message), (op, arg)


# The alphabet mixes the bytes the encoders keep, the ones they encode, the form syntax, and characters of one, two,
# three and four UTF-8 bytes.
ALPHABET = list("abcXYZ0189*-._~ +%&=;/?#[]\"'<>\\\n\t\x00\x7f") + ["é", "ü", "ñ", "€", "日", "本", "😀", "🚀", "%41"]


def random_text(rng, longest=24):
    return "".join(rng.choice(ALPHABET) for _ in range(rng.randint(0, longest)))


def generated_texts(seed, count):
    rng = random.Random(seed)
    texts = [random_text(rng) for _ in range(count)]
    # Every code point class around the UTF-8 length limits, and a long text for the cost of one pass.
    texts += [chr(c) for c in (0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xE000, 0xFFFF, 0x10000, 0x10FFFF)]
    texts.append("".join(rng.choice(ALPHABET) for _ in range(100000)))
    return texts


def test_encoders_match_urllib_for_generated_text(driver):
    texts = generated_texts(1, 400)
    form = call(driver, [("encode_www_form_component", t) for t in texts])
    uri = call(driver, [("encode_uri_component", t) for t in texts])
    for text, a, b in zip(texts, form, uri):
        assert a["text"] == ruby_quote_plus(text), text[:60]
        assert b["text"] == ruby_quote(text), text[:60]


def decoded_by_urllib(decode, text):
    """What the peer decodes, or None where std/uri must return an error (bad `%` or bytes that are not UTF-8)."""
    if BAD_PERCENT.search(text):
        return None
    try:
        return decode(text, errors="strict")
    except UnicodeDecodeError:
        return None


def test_decoders_match_urllib_for_generated_text_good_and_bad(driver):
    texts = generated_texts(2, 600)
    # Bytes made by percent-encoding random bytes: valid UTF-8 only some of the time, so both outcomes are covered.
    rng = random.Random(3)
    for _ in range(300):
        texts.append("".join("%%%02x" % rng.choice([0x41, 0x7F, 0xC3, 0xA9, 0x80, 0xE2, 0x82, 0xAC, 0xF0, 0x9F, 0x98,
                                                    0xFF]) for _ in range(rng.randint(1, 5))))
    form = call(driver, [("decode_www_form_component", t) for t in texts])
    uri = call(driver, [("decode_uri_component", t) for t in texts])
    seen_error = seen_ok = 0
    for text, a, b in zip(texts, form, uri):
        for reply, decode in ((a, unquote_plus), (b, unquote)):
            expected = decoded_by_urllib(decode, text)
            assert reply["success"] == (expected is not None), text[:60]
            if expected is None:
                assert reply["message"].startswith(("invalid %-encoding (", "invalid UTF-8 after decoding (")), text[:60]
                seen_error += 1
            else:
                assert reply["text"] == expected, text[:60]
                seen_ok += 1
    assert seen_error > 100 and seen_ok > 400


def random_query(rng):
    pieces = []
    for _ in range(rng.randint(0, 6)):
        kind = rng.randint(0, 5)
        if kind == 0:
            pieces.append("")
        elif kind == 1:
            pieces.append(quote_plus(random_text(rng, 8)))
        else:
            pieces.append(quote_plus(random_text(rng, 8)) + "=" + quote_plus(random_text(rng, 8)))
    query = "&".join(pieces)
    if rng.randint(0, 9) == 0:
        query += "%" + rng.choice(["", "4", "zz", "ff"])
    return query


def test_decode_www_form_matches_parse_qsl_for_generated_queries(driver):
    rng = random.Random(5)
    queries = [random_query(rng) for _ in range(500)]
    replies = call(driver, [("decode_www_form", q) for q in queries])
    seen_pairs = seen_error = 0
    for query, reply in zip(queries, replies):
        try:
            expected = None if BAD_PERCENT.search(query) else [
                list(p) for p in parse_qsl(query, keep_blank_values=True, separator="&", errors="strict")]
        except UnicodeDecodeError:
            expected = None
        assert reply["success"] == (expected is not None), query
        if expected is None:
            seen_error += 1
        else:
            assert reply["pairs"] == expected, query
            seen_pairs += len(expected)
    assert seen_pairs > 500 and seen_error > 10


def test_encode_www_form_matches_urlencode(driver):
    rng = random.Random(6)
    cases = [[[random_text(rng, 8), random_text(rng, 8)] for _ in range(rng.randint(0, 5))] for _ in range(300)]
    encoded = call(driver, [("encode_www_form", pairs) for pairs in cases])
    for pairs, reply in zip(cases, encoded):
        assert reply["text"] == urlencode([tuple(p) for p in pairs], quote_via=ruby_quote_plus), pairs


def test_what_the_encoders_write_the_decoders_read_back(driver):
    texts = generated_texts(4, 300)
    form = call(driver, [("encode_www_form_component", t) for t in texts])
    uri = call(driver, [("encode_uri_component", t) for t in texts])
    back_form = call(driver, [("decode_www_form_component", r["text"]) for r in form])
    back_uri = call(driver, [("decode_uri_component", r["text"]) for r in uri])
    assert [r["text"] for r in back_form] == texts
    assert [r["text"] for r in back_uri] == texts
    rng = random.Random(6)
    cases = [[[random_text(rng, 8), random_text(rng, 8)] for _ in range(rng.randint(0, 5))] for _ in range(300)]
    encoded = call(driver, [("encode_www_form", pairs) for pairs in cases])
    decoded = call(driver, [("decode_www_form", r["text"]) for r in encoded])
    assert [r["pairs"] for r in decoded] == cases
