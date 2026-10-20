"""tools/conformance.py: every test module is in an area or excluded with a reason, and the report judges evidence."""
import importlib.util
import json

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


def test_the_reviewed_host_only_modules_exist():
    for found in conformance.HOST_ONLY_ALLOWED.values():
        assert found <= set(conformance.all_modules())


def junit(directory, area, module, cases):
    """Write a JUnit file for one module; a case is (outcome, message)."""
    body = []
    for index, (outcome, message) in enumerate(cases):
        inner = {"pass": "", "fail": "<failure message='boom'/>", "skip": f"<skipped message='{message}'/>"}[outcome]
        body.append(f"<testcase classname='tests.{module}' name='case{index}'>{inner}</testcase>")
    target = directory / area
    target.mkdir(parents=True, exist_ok=True)
    (target / (module + ".xml")).write_text(f"<testsuites><testsuite>{''.join(body)}</testsuite></testsuites>")


def fill(directory, system="linux-x86_64", skip_message=None, skip_module="tests/test_vm_stop.py", failing=None):
    """Evidence for every module: one passed case, the given skip in one module, a failing module, and the environment
    of each area."""
    for area, (_, mods) in conformance.AREAS.items():
        (directory / area).mkdir(parents=True, exist_ok=True)
        (directory / area / "env.txt").write_text("slow= sweep=sampled" if area == "golden" else "slow= sweep=")
        for module in mods:
            stem = module.split("/")[-1][:-3]
            cases = [("pass", "")]
            if skip_message and module == skip_module:
                cases.append(("skip", skip_message))
            if module == failing:
                cases.append(("fail", ""))
            junit(directory, area, stem, cases)


def fill_destructive(directory, system):
    cases = "".join(f"<testcase classname='tests.{m.split('/')[-1][:-3]}' name='case'/>"
                    for m in conformance.destructive_modules(system))
    (directory / "destructive").mkdir(parents=True, exist_ok=True)
    (directory / "destructive" / "remove-actions.xml").write_text(f"<testsuites><testsuite>{cases}</testsuite></testsuites>")


def evidence(tmp_path, system, **options):
    fill(tmp_path, system, **options)
    fill_destructive(tmp_path, system)
    return conformance.report(tmp_path, system)


def test_a_report_with_a_passed_case_in_every_module_and_reviewed_host_only_skips_is_evidence(tmp_path):
    text, ok = evidence(tmp_path, "windows-x86_64", skip_message="host-only: SIGALRM does not exist on Windows")
    assert ok, text
    assert "SIGALRM does not exist on Windows" in text
    assert "Test tier: fast in every area. Golden sweep: sampled." in text


def test_a_host_only_skip_that_is_not_on_the_reviewed_list_is_missing_evidence(tmp_path):
    text, ok = evidence(tmp_path, "linux-x86_64", skip_message="host-only: Linux has no such thing")
    assert not ok
    assert "not on the reviewed list of linux-x86_64" in text
    # The same skip in a Windows-only module is reviewed on the other systems.
    text, ok = evidence(tmp_path, "linux-x86_64", skip_message="host-only: Windows handles",
                        skip_module="tests/test_process_windows.py")
    assert ok, text


@pytest.mark.parametrize("message", ["node is required (not found on PATH)", "Linux only"])
def test_a_skip_without_a_host_only_reason_is_missing_evidence(tmp_path, message):
    text, ok = evidence(tmp_path, "macos-arm64", skip_message=message)
    assert not ok
    assert "skipped without a host-only reason" in text


def test_a_failed_case_and_a_module_that_did_not_finish_are_missing_evidence(tmp_path):
    assert not evidence(tmp_path, "windows-x86_64", failing="tests/test_process.py")[1]
    fill(tmp_path, "windows-x86_64")
    (tmp_path / "network" / "test_vm_tcp.xml").unlink()
    text, ok = conformance.report(tmp_path, "windows-x86_64")
    assert not ok and "did not finish" in text


def test_a_module_that_is_host_only_on_this_system_needs_no_passed_case(tmp_path):
    fill(tmp_path)
    fill_destructive(tmp_path, "linux-x86_64")
    junit(tmp_path, "processes", "test_process_windows", [("skip", "host-only: needs native Windows")])
    text, ok = conformance.report(tmp_path, "linux-x86_64")
    assert ok, text
    assert "test_process_windows.py is host-only here" in text


def test_a_golden_variant_is_host_only_on_the_other_family_of_systems_only(tmp_path):
    reason = "system-env-case-windows.agc holds the answers of Windows"
    assert conformance.host_only_allowed("linux-x86_64", "tests/test_vm_diff_2.py", reason)
    assert not conformance.host_only_allowed("windows-x86_64", "tests/test_vm_diff_2.py", reason)


def test_a_skip_for_an_open_issue_is_listed_as_an_open_gap_and_the_number_must_be_known(tmp_path):
    text, ok = evidence(tmp_path, "windows-x86_64", skip_message="known-issue: #437 Ctrl+C has no test")
    assert ok, text
    assert "Open gaps" in text and "#437" in text
    assert not evidence(tmp_path, "windows-x86_64", skip_message="known-issue: Ctrl+C has no test")[1]
    text, ok = evidence(tmp_path, "windows-x86_64", skip_message="known-issue: #99999 not an issue of the list")
    assert not ok and "not in KNOWN_ISSUES" in text


def test_the_destructive_group_must_have_run_in_ci_and_every_module_of_it_passed(tmp_path, monkeypatch):
    monkeypatch.setenv("CI", "true")
    fill(tmp_path)
    text, ok = conformance.report(tmp_path, "linux-x86_64")
    assert not ok and "destructive" in text
    fill_destructive(tmp_path, "linux-x86_64")
    assert conformance.report(tmp_path, "linux-x86_64")[1]


def test_a_case_that_ran_on_no_system_fails_the_merge_of_the_four_summaries(tmp_path):
    cases = {"tests/a.py::t::ok": "pass", "tests/a.py::t::posix": "pass"}
    for platform_name in conformance.PLATFORMS:
        found = dict(cases)
        found["tests/a.py::t::nowhere"] = "host-only" if platform_name != "linux-x86_64" else "known-issue"
        (tmp_path / platform_name).mkdir()
        (tmp_path / platform_name / "summary.json").write_text(json.dumps({"platform": platform_name, "cases": found}))
    text, ok = conformance.merge(tmp_path)
    assert not ok and "ran on no system: tests/a.py::t::nowhere" in text
    for platform_name in conformance.PLATFORMS:
        path = tmp_path / platform_name / "summary.json"
        data = json.loads(path.read_text())
        data["cases"]["tests/a.py::t::nowhere"] = "pass" if platform_name == "windows-x86_64" else "host-only"
        path.write_text(json.dumps(data))
    text, ok = conformance.merge(tmp_path)
    assert ok, text
    # A slow-tier case is skipped everywhere in the fast tier; a system that also names an issue does not change that.
    for platform_name in conformance.PLATFORMS:
        path = tmp_path / platform_name / "summary.json"
        data = json.loads(path.read_text())
        data["cases"]["tests/a.py::t::slow"] = "known-issue" if platform_name == "windows-x86_64" else "tier"
        path.write_text(json.dumps(data))
    text, ok = conformance.merge(tmp_path)
    assert ok, text
    (tmp_path / "macos-arm64" / "summary.json").unlink()
    assert not conformance.merge(tmp_path)[1]
