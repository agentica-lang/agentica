"""stdlib/MODULES, the list of std/ modules that mk/bootstrap.mk embeds in the single binary,
names every source of stdlib/ once and nothing else. It needs no binary."""
from tests.agentica_test import ROOT

STDLIB = ROOT / "stdlib"


def test_the_list_names_each_source_of_the_folder_once():
    names = (STDLIB / "MODULES").read_text(encoding="utf-8").splitlines()
    assert "" not in names
    assert len(names) == len(set(names))
    assert sorted(names) == sorted(
        path.relative_to(STDLIB).as_posix() for path in STDLIB.rglob("*.agc")
    )
