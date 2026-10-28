"""std/cgi: HTML escaping and cookies, with the names of Ruby's CGI and Rack.

tests/fixtures/cgi/driver.agc reads one JSON case per line of stdin and prints one JSON reply per line. The fixed
vectors are the values that Ruby gives (written out here); the generated cases are checked against Python's html and
http.cookies, which are not the code under test. Python writes `'` as `&#x27;` where Ruby writes `&#39;`, so the
peer's escape is rewritten. html.unescape also decodes entities without their `;`, names that Ruby does not know and
numbers that are controls or not characters, so the generated text uses only the entities Ruby decodes. http.cookies
reads back what std/cgi writes, and a header built from known pairs gives the expected map of the reader.
"""
import html
import json
import random
from email.utils import formatdate
from http.cookies import SimpleCookie

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

DEFAULTS = {"name": "", "value": "", "path": "", "domain": "", "max_age": -1, "expires": "", "secure": False,
            "http_only": False, "same_site": ""}


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc(FIXTURES / "cgi" / "driver.agc", tmp_path_factory.mktemp("agentica-cgi-") / "driver.agcb")


def call(driver, cases):
    """Run [(op, text_or_cookie_dict)] through the driver and return one reply dict per case."""
    lines = []
    for op, arg in cases:
        cookie = {**DEFAULTS, **arg} if isinstance(arg, dict) else dict(DEFAULTS)
        text = "" if isinstance(arg, dict) else arg
        lines.append(json.dumps({"op": op, "text": text, "cookie": cookie}))
    result = run_vm(driver, stdin=("\n".join(lines) + "\n").encode("utf-8"))
    assert result.code == 0, result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(replies) == len(cases)
    return replies


def texts(driver, op, inputs):
    replies = call(driver, [(op, text) for text in inputs])
    assert all(reply["success"] for reply in replies)
    return [reply["text"] for reply in replies]


ESCAPE_VECTORS = [
    ("", ""),
    ("plain text 123", "plain text 123"),
    ("<script>alert('x') & \"y\"</script>", "&lt;script&gt;alert(&#39;x&#39;) &amp; &quot;y&quot;&lt;/script&gt;"),
    ("&amp; &lt;", "&amp;amp; &amp;lt;"),
    ("é 日 😀\n\t", "é 日 😀\n\t"),
]

# Text that unescape_html decodes: the five named entities, decimal and hex numbers (either `x`, leading zeros), and
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

COOKIE_HEADERS = [
    ("", {}),
    ("a=1; b=2", {"a": "1", "b": "2"}),
    ("a=1;b=2", {"a": "1", "b": "2"}),
    ("a=1; a=2; b=3; a=4", {"a": "1", "b": "3"}),
    ("  a = 1 ;b=x=y ;; c; =d; e=; f", {"a": "1", "b": "x=y", "e": ""}),
    ("a=\"x y\"; b=%41%20; c=é", {"a": "\"x y\"", "b": "%41%20", "c": "é"}),
    ("z=1; y=2; x=3", {"z": "1", "y": "2", "x": "3"}),
    (";;;", {}),
]

# (cookie fields, header) as Rack writes them, the attributes in its order.
SET_COOKIE_VECTORS = [
    ({"name": "sid", "value": "abc"}, "sid=abc"),
    ({"name": "empty", "value": ""}, "empty="),
    ({"name": "sid", "value": "a%20b=c/d"}, "sid=a%20b=c/d"),
    ({"name": "a", "value": "1", "path": "/", "domain": "example.com", "max_age": 3600,
      "expires": "Wed, 21 Oct 2015 07:28:00 GMT", "secure": True, "http_only": True, "same_site": "Lax"},
     "a=1; Domain=example.com; Path=/; Max-Age=3600; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Secure; HttpOnly; "
     "SameSite=Lax"),
    ({"name": "a", "value": "1", "max_age": 0}, "a=1; Max-Age=0"),
    ({"name": "a", "value": "1", "max_age": -5}, "a=1"),
    ({"name": "a", "value": "1", "path": "/a b"}, "a=1; Path=/a b"),
    ({"name": "a", "value": "1", "secure": True}, "a=1; Secure"),
    ({"name": "a", "value": "1", "http_only": True}, "a=1; HttpOnly"),
    ({"name": "a", "value": "1", "same_site": "Strict"}, "a=1; SameSite=Strict"),
    ({"name": "a", "value": "1", "same_site": "None"}, "a=1; SameSite=None"),
    ({"name": "!#$%&'*+-.^_`|~09azAZ", "value": "!#$%&'()*+-./:<=>?@[]^_`{|}~"},
     "!#$%&'*+-.^_`|~09azAZ=!#$%&'()*+-./:<=>?@[]^_`{|}~"),
]

SET_COOKIE_ERRORS = [
    ({"name": "", "value": "1"}, "invalid cookie name ()"),
    ({"name": "a b", "value": "1"}, "invalid cookie name (a b)"),
    ({"name": "a=b", "value": "1"}, "invalid cookie name (a=b)"),
    ({"name": "a;b", "value": "1"}, "invalid cookie name (a;b)"),
    ({"name": "a\"", "value": "1"}, "invalid cookie name (a\")"),
    ({"name": "é", "value": "1"}, "invalid cookie name (é)"),
    ({"name": "a\r\nb", "value": "1"}, "invalid cookie name (a\r\nb)"),
    ({"name": "a", "value": "x y"}, "invalid cookie value (x y)"),
    ({"name": "a", "value": "\"x\""}, "invalid cookie value (\"x\")"),
    ({"name": "a", "value": "x,y"}, "invalid cookie value (x,y)"),
    ({"name": "a", "value": "x;y"}, "invalid cookie value (x;y)"),
    ({"name": "a", "value": "x\\y"}, "invalid cookie value (x\\y)"),
    ({"name": "a", "value": "é"}, "invalid cookie value (é)"),
    ({"name": "a", "value": "x\r\nSet-Cookie: b=1"}, "invalid cookie value (x\r\nSet-Cookie: b=1)"),
    ({"name": "a", "value": "x\u007f"}, "invalid cookie value (x\u007f)"),
    ({"name": "a", "value": "1", "path": "/a;b"}, "invalid cookie path (/a;b)"),
    ({"name": "a", "value": "1", "path": "/\n"}, "invalid cookie path (/\n)"),
    ({"name": "a", "value": "1", "domain": "é.com"}, "invalid cookie domain (é.com)"),
    ({"name": "a", "value": "1", "expires": "x; Secure"}, "invalid cookie expires (x; Secure)"),
    ({"name": "a", "value": "1", "same_site": "lax"}, "invalid cookie same_site (lax)"),
    ({"name": "a", "value": "1", "same_site": "Strict; Secure"}, "invalid cookie same_site (Strict; Secure)"),
]


def test_escape_html_vectors(driver):
    assert texts(driver, "escape_html", [text for text, _ in ESCAPE_VECTORS]) == [out for _, out in ESCAPE_VECTORS]


def test_unescape_html_decodes_what_ruby_decodes_and_leaves_the_rest(driver):
    assert texts(driver, "unescape_html", [text for text, _ in UNESCAPE_VECTORS]) == [out for _, out in UNESCAPE_VECTORS]
    assert texts(driver, "unescape_html", UNESCAPE_UNCHANGED) == UNESCAPE_UNCHANGED


def test_parse_cookies_header_vectors(driver):
    replies = call(driver, [("parse_cookies_header", header) for header, _ in COOKIE_HEADERS])
    for (header, expected), reply in zip(COOKIE_HEADERS, replies):
        assert reply["cookies"] == expected, header
        assert list(reply["cookies"]) == list(expected), header


def test_set_cookie_header_vectors(driver):
    replies = call(driver, [("set_cookie_header", cookie) for cookie, _ in SET_COOKIE_VECTORS])
    for (cookie, expected), reply in zip(SET_COOKIE_VECTORS, replies):
        assert (reply["success"], reply["text"]) == (True, expected), cookie


def test_set_cookie_header_errors_name_the_field_and_never_halt(driver):
    replies = call(driver, [("set_cookie_header", cookie) for cookie, _ in SET_COOKIE_ERRORS])
    for (cookie, message), reply in zip(SET_COOKIE_ERRORS, replies):
        assert (reply["success"], reply["message"]) == (False, message), cookie


# The alphabet mixes the five characters that are escaped, entity-like text, and characters of one to four UTF-8 bytes.
ALPHABET = list("abcXYZ019 .,-_/?=#;:\n\t\x00\x7f") + ["&", "<", ">", "\"", "'", "&amp;", "&#39;", "é", "日", "😀"]


def random_text(rng, longest=40):
    return "".join(rng.choice(ALPHABET) for _ in range(rng.randint(0, longest)))


def generated_texts(seed, count):
    rng = random.Random(seed)
    values = [random_text(rng) for _ in range(count)]
    values.append("".join(rng.choice(ALPHABET) for _ in range(100000)))
    return values


def test_escape_html_matches_html_escape_for_generated_text(driver):
    values = generated_texts(1, 400)
    for value, got in zip(values, texts(driver, "escape_html", values)):
        assert got == html.escape(value, quote=True).replace("&#x27;", "&#39;"), value[:60]


# The entities that Ruby and html.unescape decode alike, and filler that html.unescape leaves: numbers it does not map
# (controls, C1, noncharacters, surrogates) and entities it knows but Ruby does not are not generated.
ENTITIES = ["&lt;", "&gt;", "&amp;", "&quot;", "&apos;", "&#39;", "&#x41;", "&#X41;", "&#0065;", "&#233;", "&#xe9;",
            "&#8364;", "&#x1F600;", "&#128512;", "&#55295;", "&#57344;", "&#1114109;", "&#x20;"]
FILLER = list("abcXYZ019 .,-_/?=#:\n\t<>\"'é日😀") + ["& ", "&;", "&#;", "&#x;", "&xyzzy;", "&#xZZ;"]


def entity_text(rng):
    return "".join(rng.choice(ENTITIES if rng.randint(0, 2) == 0 else FILLER) for _ in range(rng.randint(0, 30)))


def test_unescape_html_matches_html_unescape_and_undoes_escape_html(driver):
    rng = random.Random(2)
    values = [entity_text(rng) for _ in range(500)]
    for value, got in zip(values, texts(driver, "unescape_html", values)):
        assert got == html.unescape(value), value
    raw = generated_texts(3, 300)
    escaped = texts(driver, "escape_html", raw)
    assert texts(driver, "unescape_html", escaped) == raw


TOKEN = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-.^_`|~"
# cookie-octet: printable ASCII except space, `"`, `,`, `;` and `\`.
OCTETS = "".join(c for c in map(chr, range(33, 127)) if c not in '",;\\')
# Path characters that http.cookies can read back (it takes fewer than RFC 6265 allows; the vectors hold a space).
PATH_CHARS = "abcXYZ019/-_.~%!*+:@$&'"
RESERVED = {"expires", "path", "comment", "domain", "max-age", "secure", "httponly", "version", "samesite"}


def random_name(rng):
    # A leading `c` keeps it from being one of the attribute names that http.cookies reserves.
    return "c" + "".join(rng.choice(TOKEN) for _ in range(rng.randint(0, 10)))


def random_cookie(rng):
    cookie = {"name": random_name(rng), "value": "".join(rng.choice(OCTETS) for _ in range(rng.randint(0, 20)))}
    if rng.randint(0, 1):
        cookie["path"] = "/" + "".join(rng.choice(PATH_CHARS) for _ in range(rng.randint(0, 8)))
    if rng.randint(0, 1):
        cookie["domain"] = "".join(rng.choice("abcdefghij.-0123456789") for _ in range(rng.randint(1, 12)))
    if rng.randint(0, 1):
        cookie["max_age"] = rng.choice([0, 1, 60, 31536000, 2 ** 40])
    if rng.randint(0, 1):
        cookie["expires"] = formatdate(rng.randint(0, 4_000_000_000), usegmt=True)
    cookie["secure"] = bool(rng.randint(0, 1))
    cookie["http_only"] = bool(rng.randint(0, 1))
    if rng.randint(0, 1):
        cookie["same_site"] = rng.choice(["Strict", "Lax", "None"])
    return cookie


def test_set_cookie_header_is_read_back_by_http_cookies_and_parse_cookies_header(driver):
    rng = random.Random(4)
    cookies = [random_cookie(rng) for _ in range(300)]
    replies = call(driver, [("set_cookie_header", cookie) for cookie in cookies])
    heads = call(driver, [("parse_cookies_header", reply["text"].split("; ")[0]) for reply in replies])
    for cookie, reply, head in zip(cookies, replies, heads):
        assert reply["success"], cookie
        parsed = SimpleCookie()
        parsed.load(reply["text"])
        assert list(parsed) == [cookie["name"]], reply["text"]
        morsel = parsed[cookie["name"]]
        assert morsel.value == cookie["value"], reply["text"]
        for field, attribute in (("path", "path"), ("domain", "domain"), ("expires", "expires"),
                                 ("same_site", "samesite")):
            assert morsel[attribute] == cookie.get(field, ""), reply["text"]
        assert morsel["max-age"] == str(cookie.get("max_age", "")), reply["text"]
        assert bool(morsel["secure"]) == cookie["secure"], reply["text"]
        assert bool(morsel["httponly"]) == cookie["http_only"], reply["text"]
        assert head["cookies"] == {cookie["name"]: cookie["value"]}, reply["text"]


def random_cookie_header(rng):
    """A header built from known pairs, the map the reader must give, and whether http.cookies can read it too.

    http.cookies reads only `; ` between pairs and keeps the last of a repeated name, so the other cases are checked
    against the pairs alone.
    """
    plain = rng.randint(0, 1) == 0
    separators = ["; "] if plain else ["; ", ";", " ;  ", ";;"]
    pairs = []
    for _ in range(rng.randint(0, 6)):
        name = rng.choice(pairs)[0] if pairs and rng.randint(0, 4) == 0 else random_name(rng)
        pairs.append((name, "".join(rng.choice(OCTETS) for _ in range(rng.randint(0, 12)))))
    header = rng.choice(separators).join(f"{name}={value}" for name, value in pairs)
    expected = {}
    for name, value in pairs:
        expected.setdefault(name, value)
    return header, expected, plain and len(expected) == len(pairs)


def test_parse_cookies_header_matches_the_pairs_it_was_built_from_and_http_cookies(driver):
    rng = random.Random(5)
    cases = [random_cookie_header(rng) for _ in range(500)]
    replies = call(driver, [("parse_cookies_header", header) for header, _, _ in cases])
    compared = 0
    for (header, expected, unique), reply in zip(cases, replies):
        assert reply["cookies"] == expected, header
        assert list(reply["cookies"]) == list(expected), header
        if unique and header:
            peer = SimpleCookie()
            peer.load(header)
            assert {name: morsel.value for name, morsel in peer.items()} == expected, header
            compared += 1
    assert compared > 100
