"""std/html: HTML escaping, with the behaviour of Ruby's cgi/escape.

tests/fixtures/html/driver.agc reads one JSON case per line of stdin and prints one JSON string per line. The fixed
vectors are the forms written out from reading Ruby's cgi/util (no Ruby ran here); the generated cases are checked
against Python's html, which is not the code under test. Python writes `'` as `&#x27;` where Ruby writes `&#39;`, so
the peer's escape is rewritten. html.unescape also decodes entities without their `;`, names that Ruby does not know
and numbers that are controls or not characters, so the generated text uses only the entities Ruby decodes.
"""
import html
import json
import random

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc(FIXTURES / "html" / "driver.agc", tmp_path_factory.mktemp("agentica-html-") / "driver.agcb")


def texts(driver, op, inputs):
    """Run each input through `op` of the driver and return one reply string per input."""
    lines = [json.dumps({"op": op, "text": text}) for text in inputs]
    result = run_vm(driver, stdin=("\n".join(lines) + "\n").encode("utf-8"))
    assert result.code == 0, result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(replies) == len(inputs)
    return replies


ESCAPE_VECTORS = [
    ("", ""),
    ("plain text 123", "plain text 123"),
    ("<script>alert('x') & \"y\"</script>", "&lt;script&gt;alert(&#39;x&#39;) &amp; &quot;y&quot;&lt;/script&gt;"),
    ("&amp; &lt;", "&amp;amp; &amp;lt;"),
    ("é 日 😀\n\t", "é 日 😀\n\t"),
]

# Text that unescape decodes: the five named entities, decimal and hex numbers (either `x`, leading zeros), and
# one pass only.
UNESCAPE_VECTORS = [
    ("&lt;&gt;&amp;&quot;&apos;", "<>&\"'"),
    ("&#39;&#x27;&#X27;&#0039;&#x0027;", "'''''"),
    ("&#65;&#x41;&#x1F600;&#233;&#x20AC;", "AA😀é€"),
    ("&amp;lt;&amp;#65;", "&lt;&#65;"),
    ("&&amp;&amp;&", "&&&&"),
    ("&#0;&#x0;&#1;", "\u0000\u0000\u0001"),
    ("&#x10FFFF;&#1114111;", "\U0010FFFF\U0010FFFF"),
    ("a &lt; b &amp;&amp; c &gt; d", "a < b && c > d"),
]

# Text that stays as it is: an entity Ruby does not decode, a number that is not a scalar value, a missing `;`, and
# digits that cannot be read.
UNESCAPE_UNCHANGED = [
    "", "no entities", "a & b", "&", "&;", "&#;", "&#x;", "&#xZZ;", "&#12a;", "&#x1G;", "&# 65;", "&#-65;",
    "&nbsp;", "&copy;", "&AMP;", "&Lt;", "&amp", "&lt &gt", "&#65", "&bogus;", "& amp;", "&am p;",
    "&#1114112;", "&#x110000;", "&#xD800;", "&#xDFFF;", "&#55296;", "&#57343;", "&#99999999999999999999;",
    "&#x" + "F" * 40 + ";", "&" * 5,
]


def test_escape_vectors(driver):
    assert texts(driver, "escape", [text for text, _ in ESCAPE_VECTORS]) == [out for _, out in ESCAPE_VECTORS]


def test_unescape_decodes_what_ruby_decodes_and_leaves_the_rest(driver):
    decoded = texts(driver, "unescape", [text for text, _ in UNESCAPE_VECTORS])
    assert decoded == [out for _, out in UNESCAPE_VECTORS]
    assert texts(driver, "unescape", UNESCAPE_UNCHANGED) == UNESCAPE_UNCHANGED


# The alphabet mixes the five characters that are escaped, entity-like text, and characters of one to four UTF-8 bytes.
ALPHABET = list("abcXYZ019 .,-_/?=#;:\n\t\x00\x7f") + ["&", "<", ">", "\"", "'", "&amp;", "&#39;", "é", "日", "😀"]


def random_text(rng, longest=40):
    return "".join(rng.choice(ALPHABET) for _ in range(rng.randint(0, longest)))


def generated_texts(seed, count, long=False):
    rng = random.Random(seed)
    values = [random_text(rng) for _ in range(count)]
    if long:
        # One long text for the cost of one pass.
        values.append("".join(rng.choice(ALPHABET) for _ in range(100000)))
    return values


def test_escape_matches_html_escape_for_generated_text(driver):
    values = generated_texts(1, 400, long=True)
    for value, got in zip(values, texts(driver, "escape", values)):
        assert got == html.escape(value, quote=True).replace("&#x27;", "&#39;"), value[:60]


# The entities that Ruby and html.unescape decode alike, and filler that html.unescape leaves: numbers it does not map
# (controls, C1, noncharacters, surrogates) and entities it knows but Ruby does not are not generated.
ENTITIES = ["&lt;", "&gt;", "&amp;", "&quot;", "&apos;", "&#39;", "&#x41;", "&#X41;", "&#0065;", "&#233;", "&#xe9;",
            "&#8364;", "&#x1F600;", "&#128512;", "&#55295;", "&#57344;", "&#1114109;", "&#x20;"]
FILLER = list("abcXYZ019 .,-_/?=#:\n\t<>\"'é日😀") + ["& ", "&;", "&#;", "&#x;", "&xyzzy;", "&#xZZ;"]


def entity_text(rng):
    return "".join(rng.choice(ENTITIES if rng.randint(0, 2) == 0 else FILLER) for _ in range(rng.randint(0, 30)))


def test_unescape_matches_html_unescape_and_undoes_escape(driver):
    rng = random.Random(2)
    values = [entity_text(rng) for _ in range(500)]
    for value, got in zip(values, texts(driver, "unescape", values)):
        assert got == html.unescape(value), value
    raw = generated_texts(3, 300)
    escaped = texts(driver, "escape", raw)
    assert texts(driver, "unescape", escaped) == raw
