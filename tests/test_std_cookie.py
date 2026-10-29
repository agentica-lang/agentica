"""std/cookie: the Cookie header reader and the Set-Cookie writer, with the behaviour of Rack.

tests/fixtures/cookie/driver.agc reads one JSON case per line of stdin and prints one JSON reply per line. The fixed
vectors are the forms written out from reading Rack (no Ruby ran here); the generated cases are checked against
Python's http.cookies, which is not the code under test. http.cookies reads back what std/cookie writes, and a header
built from known pairs gives the expected map of the reader.
"""
import json
import random
from email.utils import formatdate
from http.cookies import SimpleCookie

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

NO_MAX_AGE = -2 ** 63
DEFAULTS = {"name": "", "value": "", "path": "", "domain": "", "max_age": NO_MAX_AGE, "expires": "", "secure": False,
            "http_only": False, "same_site": ""}


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc(FIXTURES / "cookie" / "driver.agc", tmp_path_factory.mktemp("agentica-cookie-") / "driver.agcb")


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


COOKIE_HEADERS = [
    ("", {}),
    ("a=1;b=2", {"a": "1", "b": "2"}),
    ("  a = 1 ;b=x=y ;; c; =d; e=; f", {"a": "1", "b": "x=y", "e": ""}),
    ("a=\"x y\"; b=%41%20; c=é", {"a": "\"x y\"", "b": "%41%20", "c": "é"}),
    (";;;", {}),
]

# (cookie fields, header). The attributes are in the order of Rack 3; Rack writes their names in lowercase
# (`; path=/`) and this writes them capitalized, so only the order matches.
SET_COOKIE_VECTORS = [
    ({"name": "sid", "value": "abc"}, "sid=abc"),
    ({"name": "empty", "value": ""}, "empty="),
    ({"name": "sid", "value": "a%20b=c/d"}, "sid=a%20b=c/d"),
    ({"name": "a", "value": "1", "path": "/", "domain": "example.com", "max_age": 3600,
      "expires": "Wed, 21 Oct 2015 07:28:00 GMT", "secure": True, "http_only": True, "same_site": "Lax"},
     "a=1; Domain=example.com; Path=/; Max-Age=3600; Expires=Wed, 21 Oct 2015 07:28:00 GMT; Secure; HttpOnly; "
     "SameSite=Lax"),
    ({"name": "a", "value": "1", "max_age": 0}, "a=1; Max-Age=0"),
    ({"name": "a", "value": "1", "max_age": -5}, "a=1; Max-Age=0"),
    ({"name": "a", "value": "1", "max_age": -2 ** 63 + 1}, "a=1; Max-Age=0"),
    ({"name": "a", "value": "1", "path": "/a b"}, "a=1; Path=/a b"),
    ({"name": "a", "value": "1", "secure": True}, "a=1; Secure"),
    ({"name": "a", "value": "1", "http_only": True}, "a=1; HttpOnly"),
    ({"name": "a", "value": "1", "same_site": "Strict"}, "a=1; SameSite=Strict"),
    ({"name": "a", "value": "1", "same_site": "None", "secure": True}, "a=1; Secure; SameSite=None"),
    ({"name": "__Secure-id", "value": "1", "secure": True}, "__Secure-id=1; Secure"),
    ({"name": "__Host-id", "value": "1", "secure": True, "path": "/"}, "__Host-id=1; Path=/; Secure"),
    ({"name": "!#$%&'*+-.^_`|~09azAZ", "value": "!#$%&'()*+-./:<=>?@[]^_`{|}~"},
     "!#$%&'*+-.^_`|~09azAZ=!#$%&'()*+-./:<=>?@[]^_`{|}~"),
]

HOST_ERROR = "invalid cookie name (__Host- needs secure, path / and no domain)"

SET_COOKIE_ERRORS = [
    ({"name": "", "value": "1"}, "invalid cookie name ()"),
    ({"name": "a b", "value": "1"}, "invalid cookie name (a b)"),
    ({"name": "a=b", "value": "1"}, "invalid cookie name (a=b)"),
    ({"name": "a;b", "value": "1"}, "invalid cookie name (a;b)"),
    ({"name": "é", "value": "1"}, "invalid cookie name (é)"),
    # Control bytes are left out of the echoed text.
    ({"name": "a\r\nb", "value": "1"}, "invalid cookie name (ab)"),
    # A value is never echoed: the error gives the position of the first bad byte.
    ({"name": "a", "value": "se cret"}, "invalid cookie value (byte 2)"),
    ({"name": "a", "value": "\"x\""}, "invalid cookie value (byte 0)"),
    ({"name": "a", "value": "xy,"}, "invalid cookie value (byte 2)"),
    ({"name": "a", "value": "x;y"}, "invalid cookie value (byte 1)"),
    ({"name": "a", "value": "x\\y"}, "invalid cookie value (byte 1)"),
    ({"name": "a", "value": "aé"}, "invalid cookie value (byte 1)"),
    ({"name": "a", "value": "x\r\nSet-Cookie: b=1"}, "invalid cookie value (byte 1)"),
    ({"name": "a", "value": "x\u007f"}, "invalid cookie value (byte 1)"),
    ({"name": "a", "value": "1", "path": "/a;b"}, "invalid cookie path (/a;b)"),
    ({"name": "a", "value": "1", "path": "/\n"}, "invalid cookie path (/)"),
    ({"name": "a", "value": "1", "path": " /"}, "invalid cookie path ( /)"),
    ({"name": "a", "value": "1", "domain": "é.com"}, "invalid cookie domain (é.com)"),
    ({"name": "a", "value": "1", "domain": "a b.com"}, "invalid cookie domain (a b.com)"),
    ({"name": "a", "value": "1", "expires": "x; Secure"}, "invalid cookie expires (x; Secure)"),
    ({"name": "a", "value": "1", "expires": "Wed, 21 Oct 2015 "}, "invalid cookie expires (Wed, 21 Oct 2015 )"),
    ({"name": "a", "value": "1", "same_site": "lax"}, "invalid cookie same_site (lax)"),
    ({"name": "a", "value": "1", "same_site": "Strict; Secure"}, "invalid cookie same_site (Strict; Secure)"),
    ({"name": "a", "value": "1", "same_site": "None"}, "invalid cookie same_site (None needs secure)"),
    ({"name": "__Secure-id", "value": "1"}, "invalid cookie name (__Secure- needs secure)"),
    ({"name": "__secure-id", "value": "1"}, "invalid cookie name (__Secure- needs secure)"),
    ({"name": "__Host-id", "value": "1", "path": "/"}, HOST_ERROR),
    ({"name": "__Host-id", "value": "1", "secure": True}, HOST_ERROR),
    ({"name": "__Host-id", "value": "1", "secure": True, "path": "/", "domain": "example.com"}, HOST_ERROR),
]


def test_max_age_default_is_the_smallest_int(driver):
    replies = call(driver, [("default_max_age", ""), ("no_max_age", "")])
    assert [reply["text"] for reply in replies] == [str(NO_MAX_AGE)] * 2


def test_parse_vectors(driver):
    replies = call(driver, [("parse", header) for header, _ in COOKIE_HEADERS])
    for (header, expected), reply in zip(COOKIE_HEADERS, replies):
        assert reply["cookies"] == expected, header
        assert list(reply["cookies"]) == list(expected), header


def test_set_header_vectors(driver):
    replies = call(driver, [("set_header", cookie) for cookie, _ in SET_COOKIE_VECTORS])
    for (cookie, expected), reply in zip(SET_COOKIE_VECTORS, replies):
        assert (reply["success"], reply["text"]) == (True, expected), cookie


def test_set_header_errors_name_the_field_and_never_halt(driver):
    replies = call(driver, [("set_header", cookie) for cookie, _ in SET_COOKIE_ERRORS])
    for (cookie, message), reply in zip(SET_COOKIE_ERRORS, replies):
        assert (reply["success"], reply["message"]) == (False, message), cookie


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
    if cookie.get("same_site") == "None":
        cookie["secure"] = True
    return cookie


def test_set_header_is_read_back_by_http_cookies_and_parse(driver):
    rng = random.Random(4)
    cookies = [random_cookie(rng) for _ in range(300)]
    replies = call(driver, [("set_header", cookie) for cookie in cookies])
    heads = call(driver, [("parse", reply["text"].split("; ")[0]) for reply in replies])
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


def test_parse_matches_the_pairs_it_was_built_from_and_http_cookies(driver):
    rng = random.Random(5)
    cases = [random_cookie_header(rng) for _ in range(500)]
    replies = call(driver, [("parse", header) for header, _, _ in cases])
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
