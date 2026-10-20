"""`agentica test` cases that need a POSIX system: file modes and links, a shell script as the binary, and the first
binary of the bootstrap (its driver is the one of stage0, which does not know the Windows temporary folder).

The Windows job does not run this module (the cases are not skipped there, they are not listed): a folder made
unreadable with chmod, a symbolic link, a name that is not valid UTF-8 and a `#!/bin/sh` script have no Windows
counterpart that the test could build with the standard library. Every other `agentica test` case is in
tests/test_bdd.py, which the Linux CI and the Windows job run.
"""
import json
import os
import re

import pytest

from tests.agentica_test import ROOT, binary, run, vm_environment
from tests.test_bdd import ADDS_TEST, HANDLERS, BddCli, bdd, file_error  # noqa: F401  (bdd is the fixture of that module)

# The first binary of the bootstrap (the Makefile links it with stage0 and builds the release mode only).
BOOTSTRAP = ROOT / "build" / "vm" / "release" / "bootstrap" / "agentica"


def fake_binary(directory, script):
    """A shell script for the binary that `agentica test` starts again: it prints the given stderr lines when it is
    asked to run the runner, and runs the real binary for anything else."""
    path = os.path.join(directory, "agentica.sh")
    with open(path, "w") as binary_script:
        binary_script.write("#!/bin/sh\ncase \"$*\" in\n*runner.agcb*)\n"
                            + "".join("  echo '%s' >&2\n" % line for line in script)
                            + "  exit 3 ;;\nesac\nexec '%s' \"$@\"\n" % binary())
    os.chmod(path, 0o700)
    return path


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


def test_a_crashed_runner_is_reported_with_the_error_not_the_last_stack_frame(bdd):
    directory = bdd.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})
    fake = fake_binary(directory, [
        "runner.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]",
        "index 5 is outside a list of length 3",
        "  = stack, innermost first:",
        "    main at runner.agc:11:8"])
    result = bdd.agentica_test("--json", os.path.join(directory, "a.feature"), binary_path=fake)
    assert result.code == 2
    error = json.loads(result.stdout)["files"][0]["error"]
    assert error["code"] == "RUNTIME-BDD-INFRA"
    assert re.search("RUNTIME-INDEX-OUT-OF-RANGE", error["message"])


def test_the_infrastructure_message_names_the_runners_final_diagnostic_not_an_earlier_task_crash(bdd):
    directory = bdd.suite({"a.feature": "Feature: A\nScenario: a\nThen 1 is fine\n"})
    fake = fake_binary(directory, [
        "runner.agc:5:9 error[RUNTIME-DIVISION-BY-ZERO] in a task",
        "division by zero",
        "runner.agc:2:13 error[RUNTIME-INDEX-OUT-OF-RANGE]",
        "index 5 is outside a list of length 3",
        "  = stack, innermost first:"])
    result = bdd.agentica_test("--json", os.path.join(directory, "a.feature"), binary_path=fake)
    assert result.code == 2
    message = file_error(json.loads(result.stdout))["message"]
    assert re.search("RUNTIME-INDEX-OUT-OF-RANGE", message)
    assert not re.search("DIVISION-BY-ZERO", message)


@pytest.mark.skipif(os.geteuid() == 0, reason="root can make folders anywhere")
def test_a_temporary_directory_that_cannot_be_written_is_an_infrastructure_error_that_names_it(bdd, request):
    scratch = bdd.make_suite({"nothing.txt": ""}, "agentica-bdd-readonly-")
    temporary = scratch / "tmp"
    temporary.mkdir(0o500)
    request.addfinalizer(lambda: os.chmod(temporary, 0o700))
    env = {"TMPDIR": temporary}
    result = bdd.agentica_test("--json", scratch / "missing.feature", env=env, cwd=scratch)
    assert (result.code, result.stderr) == (2, "")
    problem = file_error(json.loads(result.stdout))
    assert problem["code"] == "RUNTIME-BDD-INFRA"
    assert ("cannot make a private directory in %s" % temporary) in problem["message"]
    assert "ermission denied" in problem["message"]
    assert os.listdir(temporary) == []


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
