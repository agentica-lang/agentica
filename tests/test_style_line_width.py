"""Line width of the .agc files in compiler/ and stdlib/.

Each agentica.toml under those folders may hold a [style] table with max_line_width (docs/future/45-packages.md,
45.5). The width counts characters (Unicode code points, not bytes) on every line, comments and doc comments
included. This test enforces it until `agentica check` reads [style] itself. A missing tomllib skips the test locally
and fails it in CI.
"""
import unittest

from tests.agentica_test import ROOT, TestCase, require

try:
    import tomllib
except ImportError:  # Python before 3.11
    tomllib = None

STYLED_FOLDERS = ("compiler", "stdlib")


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


class LineWidthTest(TestCase):
    def test_every_styled_folder_has_a_manifest(self):
        folders = {path.parent.relative_to(ROOT).as_posix() for path in manifests()}
        self.assertEqual(folders, set(STYLED_FOLDERS))

    def test_lines_fit_max_line_width(self):
        require(tomllib is not None, "tomllib needs Python 3.11 or later")
        for manifest in manifests():
            with self.subTest(manifest=manifest.relative_to(ROOT).as_posix()):
                limit = tomllib.loads(manifest.read_text(encoding="utf-8"))["style"]["max_line_width"]
                self.assertIsInstance(limit, int)
                found = offenders(manifest.parent, limit)
                self.assertEqual(found, [], "lines longer than %d characters:\n%s" % (limit, "\n".join(found)))


if __name__ == "__main__":
    unittest.main()
