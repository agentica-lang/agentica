"""std/mime: media types by file extension, the names and fallback of Ruby's Rack::Mime.

tests/fixtures/mime/driver.agc reads one JSON case per line of stdin and prints one JSON reply per line. TABLE below
is the whole table of std/mime, written out so a change to it shows in review. Python's mimetypes (built without the
system's mime.types files, so the answer does not depend on the machine) is the independent peer for the extensions
it knows. It differs in a few, which KNOWN_DIFFERENCES lists with the values that Python versions give:
application/javascript for js before 3.12, text/xml for xml, audio/x-wav for wav. It has no entry at all for map, yaml,
toml, agc, the fonts and ogg, or for avif and md in older versions, and it treats gz as an encoding, not a type.
"""
import json
import mimetypes
import random

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

TABLE = {
    "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
    "json": "application/json", "map": "application/json", "webmanifest": "application/manifest+json",
    "txt": "text/plain", "csv": "text/csv", "xml": "application/xml", "md": "text/markdown",
    "yaml": "application/yaml", "yml": "application/yaml", "toml": "application/toml", "agc": "text/plain",
    "svg": "image/svg+xml", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
    "webp": "image/webp", "avif": "image/avif", "ico": "image/vnd.microsoft.icon", "woff": "font/woff",
    "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf", "pdf": "application/pdf", "zip": "application/zip",
    "gz": "application/gzip", "tar": "application/x-tar", "wasm": "application/wasm", "mp4": "video/mp4",
    "webm": "video/webm", "mp3": "audio/mpeg", "wav": "audio/wav", "ogg": "audio/ogg",
}

# The extensions where Python's answer differs from the table, with the answers that Python versions give.
KNOWN_DIFFERENCES = {
    "js": {"application/javascript"},
    "mjs": {"application/javascript"},
    "xml": {"text/xml"},
    "wav": {"audio/x-wav"},
}

OCTET_STREAM = "application/octet-stream"


@pytest.fixture(scope="module")
def driver(tmp_path_factory):
    return compile_agc(FIXTURES / "mime" / "driver.agc", tmp_path_factory.mktemp("agentica-mime-") / "driver.agcb")


def call(driver, cases):
    """Run [(op, text, fallback_or_None)] through the driver and return one reply dict per case."""
    lines = [json.dumps({"op": op, "text": text, "fallback": fallback or "", "has_fallback": fallback is not None})
             for op, text, fallback in cases]
    result = run_vm(driver, stdin=("\n".join(lines) + "\n").encode("utf-8"))
    assert result.code == 0, result.stderr
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert len(replies) == len(cases)
    assert all(reply["message"] == "" for reply in replies), replies
    return replies


def types(driver, paths, fallback=None):
    return [reply["text"] for reply in call(driver, [("type_for", path, fallback) for path in paths])]


def test_every_extension_of_the_table(driver):
    exts = list(TABLE)
    assert types(driver, [f"file.{ext}" for ext in exts]) == [TABLE[ext] for ext in exts]


# (input, type) for the forms of a path and an extension. Only the last extension counts, whatever the case.
PATH_VECTORS = [
    ("index.html", "text/html"),
    ("INDEX.HTML", "text/html"),
    ("App.Js", "text/javascript"),
    ("public/css/site.min.CSS", "text/css"),
    ("/var/www/a.b.c/logo.png", "image/png"),
    ("archive.tar.gz", "application/gzip"),
    ("archive.gz.tar", "application/x-tar"),
    (".css", "text/css"),
    (".CSS", "text/css"),
    ("css", "text/css"),
    ("JSON", "application/json"),
    ("dir/.json", "application/json"),
    ("...txt", "text/plain"),
    ("a..txt", "text/plain"),
    ("naïve café.pdf", "application/pdf"),
]

# Inputs with no extension that is in the table.
PATH_FALLBACKS = [
    "", ".", "..", "a.", "a/", "dir/", "a.b/", "README", "Makefile", "dir/README", "a/css", "/json", "dir.html/file",
    ".gitignore", "photo.unknown", "photo.html5", "photo.htm l", "a.png/", "a.png?v=1", "a.png#top", "a\\b.png/",
]


def test_type_for_path_forms(driver):
    assert types(driver, [path for path, _ in PATH_VECTORS]) == [expected for _, expected in PATH_VECTORS]


def test_type_for_without_a_known_extension_gives_the_fallback(driver):
    assert types(driver, PATH_FALLBACKS) == [OCTET_STREAM] * len(PATH_FALLBACKS)
    assert types(driver, PATH_FALLBACKS, fallback="text/plain") == ["text/plain"] * len(PATH_FALLBACKS)
    assert types(driver, ["a.png", "a"], fallback="") == ["image/png", ""]


def test_table_agrees_with_python_where_python_has_the_extension(driver):
    peer = mimetypes.MimeTypes()
    exts = [ext for ext in TABLE if peer.guess_type(f"file.{ext}", strict=True)[0] is not None]
    assert len(exts) > 15
    for ext, mine in zip(exts, types(driver, [f"file.{ext}" for ext in exts])):
        theirs = peer.guess_type(f"file.{ext}", strict=True)[0]
        assert mine == theirs or theirs in KNOWN_DIFFERENCES.get(ext, set()), (ext, mine, theirs)


def test_generated_paths_agree_with_python(driver):
    rng = random.Random(7)
    known = list(TABLE)
    exts = known + ["unknown", "html5", "x", "tar", "bz2", "c", "py"]
    paths = []
    for _ in range(400):
        dirs = "".join(rng.choice(["a/", "public/", "x.y/", "/", "My Dir/", "é/"]) for _ in range(rng.randint(0, 3)))
        stem = "".join(rng.choice("abcXYZ019 -_é.") for _ in range(rng.randint(1, 8))).strip(".") or "f"
        ext = rng.choice(exts)
        ext = "".join(c.upper() if rng.randint(0, 1) else c for c in ext)
        paths.append(f"{dirs}{stem}.{ext}")
    peer = mimetypes.MimeTypes()
    compared = 0
    for path, mine in zip(paths, types(driver, paths)):
        ext = path.rsplit(".", 1)[1].lower()
        theirs, encoding = peer.guess_type(path, strict=True)
        if encoding is not None:
            continue
        if ext not in TABLE:
            assert mine == OCTET_STREAM, path
            assert theirs is None or ext not in KNOWN_DIFFERENCES, path
        elif theirs is not None:
            assert mine == theirs or theirs in KNOWN_DIFFERENCES.get(ext, set()), (path, mine, theirs)
            compared += 1
    assert compared > 100


TEXT_VECTORS = [
    ("text/html", True), ("text/plain; charset=utf-8", True), ("TEXT/CSS", True), ("text/", True),
    ("application/json", True), ("Application/JSON; charset=utf-8", True), ("application/xml", True),
    ("application/yaml", True), ("application/toml", True), ("application/javascript", True),
    ("image/svg+xml", True), ("application/manifest+json", True), ("application/atom+xml", True),
    (" text/html ", True), ("text/html ;charset=utf-8", True),
    ("image/png", False), ("application/octet-stream", False), ("application/pdf", False), ("font/woff2", False),
    ("application/wasm", False), ("application/gzip", False), ("audio/mpeg", False), ("video/mp4", False),
    ("textual/plain", False), ("x/text/plain", False), ("application/json-seq", False), ("", False),
]


def test_text_says_which_types_take_a_charset(driver):
    replies = call(driver, [("text?", type_, None) for type_, _ in TEXT_VECTORS])
    for (type_, expected), reply in zip(TEXT_VECTORS, replies):
        assert reply["flag"] is expected, type_


def test_every_text_extension_of_the_table_is_text_and_the_binary_ones_are_not(driver):
    binary = {"png", "jpg", "jpeg", "gif", "webp", "avif", "ico", "woff", "woff2", "ttf", "otf", "pdf", "zip", "gz",
              "tar", "wasm", "mp4", "webm", "mp3", "wav", "ogg"}
    exts = sorted(TABLE)
    flags = [r["flag"] for r in call(driver, [("text?", TABLE[ext], None) for ext in exts])]
    assert {ext: flag for ext, flag in zip(exts, flags)} == {ext: ext not in binary for ext in exts}
