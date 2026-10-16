"""stdlib/MODULES, the list of std/ modules that the Makefile embeds in the single binary,
names every source of stdlib/ once and nothing else. It needs no binary."""
from tests.agentica_test import ROOT, TestCase

STDLIB = ROOT / "stdlib"


class StdlibModules(TestCase):
    def test_the_list_names_each_source_of_the_folder_once(self):
        names = (STDLIB / "MODULES").read_text().splitlines()
        self.assertNotIn("", names)
        self.assertEqual(len(names), len(set(names)))
        self.assertEqual(sorted(names), sorted(path.relative_to(STDLIB).as_posix() for path in STDLIB.rglob("*.agc")))
