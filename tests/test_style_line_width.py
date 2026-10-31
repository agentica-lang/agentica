"""Line width of the .agc files in stdlib/.

`agentica check` enforces `[style] max_line_width` as CHECK-LINE-TOO-LONG for the files of a project, and CI runs it
over compiler/ (`make check-compiler`). The files of stdlib/ are not files of a project: they load as `std/` modules,
library files that no style rule covers, and most of them cannot be checked as a root of their own, since they use
names only std/ may use. So this test keeps their width: the `max_line_width` of stdlib/agentica.toml, counted in
characters (Unicode code points, not bytes) on every line, comments and doc comments included. A missing tomllib
skips the test locally and fails it in CI.
"""
import os

import pytest

from tests.agentica_test import ROOT

try:
    import tomllib
except ImportError:  # Python before 3.11
    tomllib = None

STYLED_FOLDERS = ("stdlib",)


def manifests():
    found = []
    for folder in STYLED_FOLDERS:
        found += sorted((ROOT / folder).rglob("agentica.toml"))
    return found


def offenders(folder, limit):
    """file:line:length for every line of a .agc file under folder that is longer than limit characters."""
    found = []
    for path in sorted(folder.rglob("*.agc")):
        text = path.read_bytes().decode("utf-8")
        # Split on LF only, as the lexer does: splitlines would also split on form feeds and U+2028.
        for number, line in enumerate(text.split("\n"), start=1):
            line = line.removesuffix("\r")
            if len(line) > limit:
                found.append("%s:%d:%d" % (path.relative_to(ROOT), number, len(line)))
    return found


def test_every_styled_folder_has_a_manifest():
    folders = {path.parent.relative_to(ROOT).as_posix() for path in manifests()}
    assert folders == set(STYLED_FOLDERS)


@pytest.mark.parametrize("manifest", manifests(), ids=lambda path: path.parent.relative_to(ROOT).as_posix())
def test_lines_fit_max_line_width(manifest):
    if tomllib is None:
        message = "tomllib needs Python 3.11 or later"
        if os.environ.get("CI"):
            pytest.fail(message)
        pytest.skip(message)
    limit = tomllib.loads(manifest.read_text(encoding="utf-8"))["style"]["max_line_width"]
    assert isinstance(limit, int)
    found = offenders(manifest.parent, limit)
    assert found == [], "lines longer than %d characters:\n%s" % (limit, "\n".join(found))
