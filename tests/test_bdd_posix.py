"""`agentica test` cases that need a POSIX system: file modes and links, and the first binary of the bootstrap (its
driver is the one of stage0, which does not know the Windows temporary folder).

On Windows the cases are skipped one by one (host-only). A folder made unreadable with chmod, a symbolic link and a
name that is not valid UTF-8 do not exist there, and a temporary folder that cannot be written with chmod has a
counterpart in tests/test_windows_process_cleanup.py (an access list). Every other `agentica test` case is in
tests/test_bdd.py, which every system runs, the cases of a crashed runner (a stand-in for the binary) included.
"""
import json
import os

import pytest

from tests.agentica_test import ROOT, WINDOWS, host_only, run, vm_environment
from tests.test_bdd import (  # noqa: F401  (bdd is the fixture of that module)
    ADDS_TEST, HANDLERS, BddCli, assert_unwritable_temporary_is_an_infrastructure_error, bdd)

ROOT_USER = hasattr(os, "geteuid") and os.geteuid() == 0

# The first binary of the bootstrap (the Makefile links it with stage0 and builds the release mode only).
BOOTSTRAP = ROOT / "build" / "vm" / "release" / "bootstrap" / ("agentica.exe" if os.name == "nt" else "agentica")


@host_only(WINDOWS, "a folder made unreadable with chmod 000, symbolic links and a name that is not valid UTF-8 do not exist on Windows")
def test_discovery_reports_unreadable_folders_broken_links_bad_names_and_large_files_and_skips_folder_links(bdd, request):
    directory = bdd.suite({
        "a.feature": "Feature: A\nScenario: a\nThen the remembered number is 1\nWhen I remember 1\n"})
    locked = os.path.join(directory, "locked")
    os.mkdir(locked)
    with open(os.path.join(locked, "hidden.feature"), "w") as hidden:
        hidden.write("Feature: Hidden\nScenario: hidden\nThen an assertion fails\n")
    os.chmod(locked, 0o000)
    # Registered after the directory's own cleanup, so it runs first and lets rmtree enter the folder.
    request.addfinalizer(lambda: os.chmod(locked, 0o700))
    os.symlink(".", os.path.join(directory, "self"))
    os.symlink("missing.feature", os.path.join(directory, "broken.feature"))
    # APFS refuses a name that is not valid UTF-8 (EILSEQ), so on macOS the case checks the other entries only.
    try:
        with open(os.path.join(os.fsencode(directory), b"bad\xff.feature"), "w") as bad:
            bad.write("Feature: Bad\n")
        bad_name = [("bad\ufffd.feature", "RUNTIME-BDD-INFRA")]
    except OSError:
        bad_name = []
    with open(os.path.join(directory, "big.feature"), "w") as big:
        big.write("Feature: Big\n" + "#" * 1048576)
    status, report = bdd.json_test(directory, "--steps", HANDLERS)
    assert status == 2
    codes = []
    for file in report["files"]:
        problem = file["error"]
        codes.append((os.path.basename(file["path"]), problem["code"] if isinstance(problem, dict) else None))
    assert sorted(codes) == sorted([
        ("locked", "RUNTIME-BDD-INFRA"), ("broken.feature", "RUNTIME-BDD-INFRA"),
        ("a.feature", None), ("big.feature", "RUNTIME-BDD-IO")] + bad_name)
    assert report["failed"] == 1


@host_only(WINDOWS, "a folder that cannot be written is made with chmod 0500; Windows has no mode bits (test_a_temporary_directory_that_cannot_be_written_is_an_infrastructure_error_that_names_it in test_windows_process_cleanup.py denies the user in its access list)")
@pytest.mark.skipif(ROOT_USER, reason="root can make folders anywhere")
def test_a_temporary_directory_that_cannot_be_written_is_an_infrastructure_error_that_names_it(bdd, request):
    scratch = bdd.make_suite({"nothing.txt": ""}, "agentica-bdd-readonly-")
    temporary = scratch / "tmp"
    temporary.mkdir(0o500)
    request.addfinalizer(lambda: os.chmod(temporary, 0o700))
    assert_unwritable_temporary_is_an_infrastructure_error(bdd, scratch, temporary, "ermission denied")


def test_the_first_binary_of_the_bootstrap_still_tests_with_the_driver_of_stage0(bdd):
    """That binary has the driver of stage0: it compiles the runner and the steps from the std/ sources of this
    checkout, writes the configuration it always wrote, and knows no embedded program. The current runner must
    read that configuration."""
    if not BOOTSTRAP.is_file():
        pytest.skip("the first binary is not built (%s): run make" % BOOTSTRAP)
    directory = bdd.suite({"c_test.agc": ADDS_TEST})
    result = run([BOOTSTRAP, "test", "--json", directory], env=vm_environment())
    assert (result.code, result.stderr) == (0, "")
    assert json.loads(result.stdout)["passed"] == 1
    result = run([BOOTSTRAP, "run", "--embedded", "runner", "--", "config.jsonl"], env=vm_environment())
    assert (result.code, result.stdout) == (2, "")
    assert result.stderr != ""
