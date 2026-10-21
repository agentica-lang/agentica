"""stdlib/MODULES, the list of std/ modules that mk/bootstrap.mk embeds in the single binary,
names every source of stdlib/ once and nothing else; stdlib/CORE lists the files of compiler/ that std/analysis
embeds with them. It needs no binary."""
import posixpath
import re

from tests.agentica_test import ROOT

STDLIB = ROOT / "stdlib"


def test_the_list_names_each_source_of_the_folder_once():
    names = (STDLIB / "MODULES").read_text(encoding="utf-8").splitlines()
    assert "" not in names
    assert len(names) == len(set(names))
    assert sorted(names) == sorted(
        path.relative_to(STDLIB).as_posix() for path in STDLIB.rglob("*.agc")
    )


def test_the_core_list_is_what_std_analysis_imports():
    """stdlib/CORE names the files of compiler/ that std/analysis compiles into a program as std/internal/compiler/:
    its imports and everything they import (no stage entry program, no lowering), each once, in order."""
    names = (STDLIB / "CORE").read_text(encoding="utf-8").splitlines()
    assert names == sorted(set(names))
    prefix = "std/internal/compiler/"
    roots = [name[len(prefix):] + ".agc" for name in imported(STDLIB / "analysis.agc") if name.startswith(prefix)]
    wanted, todo = set(), roots
    while todo:
        name = todo.pop()
        if name in wanted:
            continue
        wanted.add(name)
        folder = posixpath.dirname(name)
        todo += [posixpath.normpath(posixpath.join(folder, target)) + ".agc"
                 for target in imported(ROOT / "compiler" / name) if not target.startswith("std/")]
    assert names == sorted(wanted)


def imported(path):
    """The paths that the `import ... from "path"` lines of a source file name; an import list may span lines."""
    return re.findall(r'^import\s+[^"]*?\bfrom\s+"([^"]+)"', path.read_text(encoding="utf-8"), re.M)
