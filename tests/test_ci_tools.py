"""tools/ci_systems.py and tools/probe.py: the systems that platforms.yml and probe.yml pick, and the values a probe
accepts (probe.yml passes them straight from the dispatch inputs)."""
import importlib.util
import json

import pytest

from tests.agentica_test import ROOT


def load_tool(name):
    spec = importlib.util.spec_from_file_location(f"agentica_{name}", ROOT / "tools" / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


systems = load_tool("ci_systems")
probe = load_tool("probe")


def names(picked):
    return [s["platform"] for s in picked]


def test_platforms_runs_all_five_or_the_labelled_systems():
    assert names(systems.platforms(True, [])) == systems.NAMES
    labels = ["platform:macos-arm64", "platform:linux-x86_64", "bug", "platform:windows-x86_64"]
    assert names(systems.platforms(False, labels)) == ["windows-x86_64", "macos-arm64"]
    assert systems.platforms(False, []) == []


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
