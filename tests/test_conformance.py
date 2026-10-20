"""tools/conformance.py: every test module is in an area or excluded with a reason, and the report judges evidence."""
import importlib.util

import pytest

from tests.agentica_test import ROOT


def load_conformance():
    spec = importlib.util.spec_from_file_location("agentica_conformance_tool", ROOT / "tools" / "conformance.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


conformance = load_conformance()


def test_every_test_module_is_in_an_area_or_excluded_with_a_reason():
    assert conformance.unclassified() == []
    listed = [m for _, mods in conformance.AREAS.values() for m in mods]
    assert len(listed) == len(set(listed)), "a module is in two areas"
    assert not set(listed) & set(conformance.EXCLUDED)
    assert all(conformance.EXCLUDED.values())
    assert set(listed) | set(conformance.EXCLUDED) <= set(conformance.all_modules()), "a listed module does not exist"


def junit(directory, area, module, cases):
    """Write a JUnit file for one module; a case is (outcome, message)."""
    body = []
    for index, (outcome, message) in enumerate(cases):
        inner = {"pass": "", "fail": "<failure message='boom'/>", "skip": f"<skipped message='{message}'/>"}[outcome]
        body.append(f"<testcase classname='{module}' name='case{index}'>{inner}</testcase>")
    target = directory / area
    target.mkdir(parents=True, exist_ok=True)
    (target / (module + ".xml")).write_text(f"<testsuites><testsuite>{''.join(body)}</testsuite></testsuites>")


def fill(directory, skip_message=None, failing=None):
    """Evidence for every module: one passed case, plus the given skip and failing module."""
    for area, (_, mods) in conformance.AREAS.items():
        for module in mods:
            stem = module.split("/")[-1][:-3]
            cases = [("pass", "")]
            if skip_message:
                cases.append(("skip", skip_message))
            if module == failing:
                cases.append(("fail", ""))
            junit(directory, area, stem, cases)


def test_a_report_with_a_passed_case_in_every_module_and_host_only_skips_is_evidence(tmp_path):
    fill(tmp_path, "host-only: Windows has no /proc")
    text, ok = conformance.report(tmp_path, "linux-x86_64")
    assert ok, text
    assert "Windows has no /proc" in text


@pytest.mark.parametrize("message", ["node is required (not found on PATH)", "Linux only"])
def test_a_skip_without_a_host_only_reason_is_missing_evidence(tmp_path, message):
    fill(tmp_path, message)
    text, ok = conformance.report(tmp_path, "macos-arm64")
    assert not ok
    assert "skipped without a host-only reason" in text


def test_a_failed_case_and_a_module_that_did_not_finish_are_missing_evidence(tmp_path):
    fill(tmp_path, failing="tests/test_process.py")
    assert not conformance.report(tmp_path, "windows-x86_64")[1]
    fill(tmp_path)
    (tmp_path / "network" / "test_vm_tcp.xml").unlink()
    text, ok = conformance.report(tmp_path, "windows-x86_64")
    assert not ok and "did not finish" in text


def test_a_module_that_is_host_only_on_this_system_needs_no_passed_case(tmp_path):
    fill(tmp_path)
    junit(tmp_path, "processes", "test_process_windows", [("skip", "host-only: needs native Windows")])
    text, ok = conformance.report(tmp_path, "linux-x86_64")
    assert ok, text
    assert "test_process_windows.py is host-only here" in text


def test_a_skip_for_a_product_bug_needs_an_issue_number_and_is_listed_as_an_open_gap(tmp_path):
    fill(tmp_path, "known-issue: #425 the pkg roots ignore the semicolon on Windows")
    text, ok = conformance.report(tmp_path, "windows-x86_64")
    assert ok, text
    assert "Open gaps" in text and "#425" in text
    fill(tmp_path, "known-issue: the pkg roots ignore the semicolon on Windows")
    assert not conformance.report(tmp_path, "windows-x86_64")[1]


def test_the_golden_paths_of_windows_come_back_as_tokens_in_every_spelling_the_vm_prints():
    from tests.vm_diff_support import relocate_windows
    from pathlib import PureWindowsPath
    folder = PureWindowsPath("D:/a/_temp/fixtures")
    text = 'D:\\a\\_temp\\fixtures\\vm\\x.agc "D:\\\\a\\\\_temp\\\\fixtures\\\\y" D:/a/_temp/fixtures/z/w.agc:3'
    assert relocate_windows(text, folder, "@fixtures") == '@fixtures/vm/x.agc "@fixtures/y" @fixtures/z/w.agc:3'
