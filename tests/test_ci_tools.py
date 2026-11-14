"""tools/ci_systems.py, tools/probe.py and tools/ci_changes.py: the systems that platforms.yml and probe.yml pick, the
values a probe accepts (probe.yml passes them straight from the dispatch inputs), and the `changes` job of ci.yml."""
import importlib.util
import json
import subprocess

import pytest

from tests.agentica_test import ROOT


def load_tool(name):
    spec = importlib.util.spec_from_file_location(f"agentica_{name}", ROOT / "tools" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


systems = load_tool("ci_systems")
probe = load_tool("probe")
changes = load_tool("ci_changes")


def names(picked):
    return [s["platform"] for s in picked]


def test_platforms_runs_all_five_or_none():
    assert names(systems.platforms(True)) == systems.NAMES
    assert systems.platforms(False) == []


def test_the_files_that_need_platforms_run_all_five(capsys):
    for path in ("vm/interp.c", "vm/jit/emit_a64.c", "vm/third_party/libuv", "tests/fixtures/native/peer.c",
                 "examples/ffi/main.agc", "examples/native_module/agentica.toml", "Makefile", "mk/release.mk",
                 ".gitmodules", "bootstrap/stage0.agcb", "VERSION", "tools/release.py", "tools/release-check.sh",
                 ".github/workflows/release.yml", ".github/workflows/platforms.yml", ".github/actions/msys2/action.yml",
                 "tools/ci_systems.py", "tools/conformance.py", "tests/agentica_test.py", "tests/conftest.py",
                 "tests/windows_support.py", "tests/test_windows_process_cleanup.py", "tests/test_process_lifecycle.py",
                 "tests/test_filesystem.py", "tests/test_bdd_posix.py"):
        assert changes.classify(["compiler/app/cli.agc", path])["platforms"], path
    assert "platforms: all five (vm/interp.c)" in capsys.readouterr().err
    for files in (["compiler/app/cli.agc", "compiler/check/check_call.agc"], ["stdlib/cache.agc"], ["docs/x.md"],
                  ["tests/test_vm_bits.py", "tests/fixtures/vm/hello.agc"], [".github/workflows/ci.yml"]):
        assert not changes.classify(files)["platforms"], files
    assert "platforms: none (no file needs them)" in capsys.readouterr().err


def test_a_probe_names_systems_and_shorthands_and_refuses_an_unknown_one():
    assert names(systems.probe("macos")) == ["macos-x86_64", "macos-arm64"]
    assert names(systems.probe("macos-arm64, linux-x86_64")) == ["linux-x86_64", "macos-arm64"]
    assert names(systems.probe("all")) == systems.NAMES
    for bad in ("", " , ", "macos-arm", "darwin"):
        with pytest.raises(ValueError):
            systems.probe(bad)


def test_the_output_lines_are_a_matrix_of_the_whole_rows(capsys):
    assert systems.main(["probe", "windows"]) == 0
    lines = dict(line.split("=", 1) for line in capsys.readouterr().out.splitlines())
    assert json.loads(lines["matrix"]) == {"include": [systems.SYSTEMS[2]]}
    assert (lines["count"], lines["all"]) == ("1", "false")
    assert systems.main(["probe", "nothing"]) == 2


def test_a_probe_takes_only_values_that_cannot_reach_a_shell():
    good = probe.settings({"TESTS": "tests/test_vm_bits.py tests/test_process.py::test_x[a-b]", "K": "a or b",
                           "TARGET": "conformance-area/processes JOBS=2", "PROGRAM": "examples/classify.agc",
                           "REPEAT": "3", "SCHEDULERS": "4"}, full=True)
    assert good["target"] == ["conformance-area/processes", "JOBS=2"] and good["repeat"] == 3
    for env in ({}, {"TESTS": "tests/../x.py"}, {"TESTS": "tests/test_none.py"}, {"TARGET": "vm-test;id"},
                {"TARGET": "X=$(shell id)"}, {"TARGET": "-f/etc/passwd"}, {"PROGRAM": "/etc/x.agc"},
                {"PROGRAM": "../x.agc"}, {"TESTS": "tests/test_vm_bits.py", "REPEAT": "0"},
                {"TESTS": "tests/test_vm_bits.py", "SCHEDULERS": "many"},
                {"TESTS": "tests/test_vm_os_remove.py", "PROBE_ISOLATED": "tests/test_vm_os_remove.py"}):
        with pytest.raises(probe.Usage):
            probe.settings(env, full=True)


TREE = {
    "compiler/app/main.agc": 'import Front from "std/front"\n',
    "stdlib/front.agc": 'import Dep from "std/dep"\n',
    "stdlib/dep.agc": "",
    "stdlib/prelude/list.agc": "",
    "stdlib/port.agc": "",
    "stdlib/user.agc": 'import Port from "std/port"\n',
    "stdlib/lone.agc": "",
    "tests/std/port_test.agc": 'import Port from "std/port"\n',
    "tests/test_std_port.py": 'DRIVER = FIXTURES / "port" / "driver.agc"\n',
    "tests/test_spec_user.py": 'SOURCE = "import User from \\"std/user\\""\n',
    "tests/test_frontend_modules.py": "",
    "tests/fixtures/port/driver.agc": 'import Port from "std/port"\n',
    "tests/fixtures/vm/uses-port.agc": 'import Port from "std/port"\n',
    "tests/fixtures/vm/uses-port.expected": "std/port\n",
    "tests/fixtures/frontend/modules/port/root.agc": 'import Port from "std/port"\n',
    "tests/fixtures/frontend/frozen/corpus/stdlib.json": '{"std/lone": ""}\n',
    "tests/fixtures/orphan.agc": 'import Lone from "std/lone"\n',
}


@pytest.fixture
def tree(tmp_path):
    for name, text in TREE.items():
        (tmp_path / name).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / name).write_text(text, encoding="utf-8")
    subprocess.run(["git", "init", "-q", str(tmp_path)], check=True)
    subprocess.run(["git", "-C", str(tmp_path), "add", "."], check=True)
    (tmp_path / "tests" / "__pycache__").mkdir()
    (tmp_path / "tests" / "__pycache__" / "test_x.pyc").write_text('"std/port"', encoding="utf-8")
    return tmp_path


def test_a_portable_std_module_with_its_tests_and_docs_takes_the_light_path(tree):
    out = changes.classify(["stdlib/port.agc", "tests/std/port_test.agc", "tests/fixtures/port/driver.agc",
                            "CHANGELOG.md", "site/content/library/port.md", ".agents/skills/x/SKILL.md", ""], tree)
    assert out["std_only"] and not (out["c"] or out["cchecker"] or out["trace"])
    tests = out["std_tests"].split()
    assert set(tests) == set(changes.ALWAYS) | {"tests/test_spec_user.py", "tests/test_std_port.py"}
    assert tests == sorted(tests) and out["std_fixtures"] == "uses-port"


def test_the_front_end_std_modules_and_any_other_file_take_the_full_path(tree, capsys):
    for files in (["stdlib/dep.agc"], ["stdlib/front.agc"], ["stdlib/prelude/list.agc"], ["stdlib/MODULES"],
                  ["stdlib/port.agc", "compiler/app/main.agc"], ["stdlib/port.agc", "tests/test_vm_bits.py"],
                  ["tests/std/front_test.agc"], ["docs/x.md"], ["stdlib/lone.agc"],
                  ["stdlib/port.agc", "tests/README.md"], ["stdlib/port.agc", "site/layouts/page.html"]):
        out = changes.classify(files, tree)
        assert not out["std_only"] and out["std_tests"] == out["std_fixtures"] == "", files
    assert "tests/fixtures/orphan.agc uses std/lone" in capsys.readouterr().err


def test_the_c_trace_and_cchecker_outputs_and_a_run_of_everything(capsys):
    def picked(files):
        out = changes.classify(files)
        return [key for key in ("c", "trace", "cchecker") if out[key]]

    assert picked(["vm/trace.c"]) == ["c", "trace", "cchecker"]
    assert picked(["tests/fixtures/native/peer.c", "examples/ffi/lib.c"]) == ["c"]
    assert picked(["cchecker-baseline.json"]) == ["cchecker"]
    assert picked(["compiler/app/cli.agc", "examples/ffi/main.agc"]) == []
    changes.main(["ci_changes.py", "--all"])
    assert capsys.readouterr().out.splitlines() == ["c=true", "trace=true", "cchecker=true", "platforms=true",
                                                    "std_only=false", "std_tests=", "std_fixtures="]


def test_the_std_modules_that_the_front_end_imports_are_not_portable():
    modules = changes.std_modules(changes.ROOT)
    front = changes.front_end_std(changes.ROOT, modules)
    assert {"toml", "regex", "http", "uri", "binary", "archive", "bdd", "bdd/tags", "test/runner", "test/report",
            "analysis", "prelude/list"} <= front
    assert {"logger", "utc", "actor", "eag", "html"} <= front
    assert {"cache", "cookie", "option_parser", "supervisor"}.isdisjoint(front)
