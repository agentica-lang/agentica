"""std/mime: media types by file extension, with the name and the fallback of Ruby's Rack::Mime.mime_type.

tests/fixtures/mime/driver.agc reads one JSON case per line of stdin and prints one JSON reply per line. TABLE below
is the whole table of std/mime, written out so a change to it shows in review. Python's mimetypes (built without the
system's mime.types files, so the answer does not depend on the machine) is the independent peer for the extensions
where the choice is not ours alone. For the extensions in KNOWN_DIFFERENCES the answer of Python is not compared: it
differs between versions (js) or from the registered type (xml, wav), or the extension is not a type there (gz is an
encoding). Python has no entry at all for several of the others (map, yaml, toml, agc, fonts, ogg...), which are
skipped.
"""
import json
import mimetypes

import pytest

from tests.agentica_test import FIXTURES, compile_agc, run_vm

TABLE = {
    "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript", "mjs": "text/javascript",
    "cjs": "text/javascript", "json": "application/json", "map": "application/json",
    "jsonld": "application/ld+json", "webmanifest": "application/manifest+json", "txt": "text/plain",
    "csv": "text/csv", "xml": "application/xml", "xhtml": "application/xhtml+xml", "rss": "application/rss+xml",
    "atom": "application/atom+xml", "ics": "text/calendar", "md": "text/markdown", "yaml": "application/yaml",
    "yml": "application/yaml", "toml": "application/toml", "agc": "text/plain", "svg": "image/svg+xml",
    "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
    "avif": "image/avif", "ico": "image/vnd.microsoft.icon", "bmp": "image/bmp", "tif": "image/tiff",
    "tiff": "image/tiff", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
    "pdf": "application/pdf", "zip": "application/zip", "gz": "application/gzip", "tar": "application/x-tar",
    "bz2": "application/x-bzip2", "7z": "application/x-7z-compressed", "wasm": "application/wasm",
    "mp4": "video/mp4", "webm": "video/webm", "mp3": "audio/mpeg", "m4a": "audio/mp4", "flac": "audio/flac",
    "wav": "audio/wav", "ogg": "audio/ogg",
}

# The extensions whose answer in Python is not compared (see the module docstring).
KNOWN_DIFFERENCES = {"js", "mjs", "cjs", "xml", "wav", "gz", "m4a", "7z", "bz2", "ics", "xhtml"}

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
    return [reply["text"] for reply in call(driver, [("mime_type", path, fallback) for path in paths])]


def test_every_extension_of_the_table(driver):
    exts = list(TABLE)
    assert types(driver, [f"file.{ext}" for ext in exts]) == [TABLE[ext] for ext in exts]


# (input, type): an extension with its dot, and the forms of a path. Only the last extension counts, in any case.
PATH_VECTORS = [
    (".css", "text/css"),
    (".CSS", "text/css"),
    (".tar.gz", "application/gzip"),
    ("index.html", "text/html"),
    ("INDEX.HTML", "text/html"),
    ("App.Js", "text/javascript"),
    ("public/css/site.min.CSS", "text/css"),
    ("/var/www/a.b.c/logo.png", "image/png"),
    ("archive.tar.gz", "application/gzip"),
    ("archive.gz.tar", "application/x-tar"),
    (".env.json", "application/json"),
    ("dir/.env.json", "application/json"),
    ("a..txt", "text/plain"),
    ("a.png?v=1", "image/png"),
    ("a.png#top", "image/png"),
    ("a.png?x=a.css#b.js", "image/png"),
    ("/a/b.css?next=/c/d.js", "text/css"),
    ("a\\b.png", "image/png"),
    ("dir.d/file.svg", "image/svg+xml"),
    ("naïve café.pdf", "application/pdf"),
]

# Inputs with no extension that is in the table: a bare name, a dotfile (its leading dot does not start an extension),
# an empty or unknown extension, and a query or fragment that holds the dot.
PATH_FALLBACKS = [
    "", ".", "..", "...", "...txt", "a.", "a/", "dir/", "a.b/", "README", "Makefile", "dir/README", "css", "map",
    "JSON", "a/css", "/json", "dir/.json", "dir/.css", "a/.env/.json", "dir.html/file", ".gitignore", ".css/",
    ".a/b.css/", "photo.unknown", "photo.html5", "photo.htm l", "a.png/", "?a.png", "#a.png", "a?.png", "a#.png",
    "a.png/?x", "x.y/z?q=a.png", "a\\.png/",
]


def test_mime_type_path_forms(driver):
    assert types(driver, [path for path, _ in PATH_VECTORS]) == [expected for _, expected in PATH_VECTORS]


def test_mime_type_without_a_known_extension_gives_the_fallback(driver):
    assert types(driver, PATH_FALLBACKS) == [OCTET_STREAM] * len(PATH_FALLBACKS)
    assert types(driver, PATH_FALLBACKS, fallback="text/plain") == ["text/plain"] * len(PATH_FALLBACKS)
    assert types(driver, ["a.png", "a"], fallback="") == ["image/png", ""]


def test_table_agrees_with_python_where_python_has_the_extension(driver):
    peer = mimetypes.MimeTypes()
    exts = [ext for ext in TABLE if ext not in KNOWN_DIFFERENCES and peer.guess_type(f"file.{ext}", strict=True)[0]]
    assert len(exts) > 15
    for ext, mine in zip(exts, types(driver, [f"file.{ext}" for ext in exts])):
        assert mine == peer.guess_type(f"file.{ext}", strict=True)[0], ext


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
    binary = {"png", "jpg", "jpeg", "gif", "webp", "avif", "ico", "bmp", "tif", "tiff", "woff", "woff2", "ttf", "otf",
              "pdf", "zip", "gz", "tar", "bz2", "7z", "wasm", "mp4", "webm", "mp3", "m4a", "flac", "wav", "ogg"}
    exts = sorted(TABLE)
    flags = [r["flag"] for r in call(driver, [("text?", TABLE[ext], None) for ext in exts])]
    assert {ext: flag for ext, flag in zip(exts, flags)} == {ext: ext not in binary for ext in exts}
