"""The cleanup and hand-off promises of the processes that only Windows has, checked with Windows means.

Most cleanup cases run on every system: the output of a captured child, a failed scenario, a killed driver and a crashed
runner pick their child or their stand-in for the binary by system (tests/test_vm_diff_8.py, tests/test_bdd_integration.py,
tests/test_bdd.py). The cases here have no POSIX form, and the POSIX cases they replace are host-only and name them:

- Windows has no SIGTERM: libuv ends a child with TerminateProcess at once, and the job object of the VM ends the
  children of a child that is a VM. So "SIGTERM first, SIGKILL after a second" becomes "close ends the child and its
  children, never waits, and a child that ignores the console signals is stopped".
- The input of --driver-pid is private when its access list names only its owner, where POSIX reads mode 600.
- A temporary folder cannot be written when its access list denies the user, where POSIX uses chmod 0500.
"""
import os

import pytest

from tests.agentica_test import (FIXTURES, PYTHON, kill_process, run, run_vm, scaled, start_vm, vm_binary,
                                 vm_command, vm_environment)
from tests.test_bdd import assert_unwritable_temporary_is_an_infrastructure_error, bdd  # noqa: F401  (a fixture)
from tests.test_process_lifecycle import bytecode, gone
from tests.windows_support import COPY_PROGRAM, current_user_sid, icacls, without_backup_restore_privileges

pytestmark = pytest.mark.skipif(os.name != "nt", reason="host-only: TerminateProcess, job objects and access lists exist on Windows only")

PEER = FIXTURES / "process-peer.py"
WAIT = scaled(20)

# The VM that is the child of the test prints its own pid and the pid of the Python peer that it starts.
INNER_PROGRAM = """\
def main() -> Void
  args = System.args()
  p = Result.unwrap!(Process.spawn(args[0], [args[1], "hold"], 60000))
  puts("#{System.pid()} #{Result.unwrap!(Process.read_line(p, 60000))}")
  IO.flush()
  Task.sleep(60000)
end
"""

# The parent starts that VM as a captured child, reports the two pids, then closes it (or lets a read time out) and
# stays alive, so that the test sees what the close alone did.
OUTER_PROGRAM = """\
def main() -> Void
  args = System.args()
  words = ["run", "--", args[1], args[3], args[4]]
  child = Result.unwrap!(Process.spawn_captured(args[0], words, ".", 60000))
  puts(Result.unwrap!(Process.read_line(child, 60000)))
  IO.flush()
  if args[2] == "close"
    Process.close(child)
  else
    IO.inspect(Process.read_line(child, 200))
  end
  puts("released")
  IO.flush()
  Task.sleep(60000)
end
"""

# A captured Python child that prints its pid. The stubborn one also ignores Ctrl+Break and Ctrl+C, the only polite
# stops Windows has, and does not look at its input: close must end it all the same.
PLAIN_CHILD = "import os,sys,time;sys.stdout.reconfigure(newline='\\n');print(os.getpid(),flush=True);time.sleep(120)"
STUBBORN_CHILD = ("import os,signal,sys,time;signal.signal(signal.SIGBREAK,signal.SIG_IGN);"
                  "signal.signal(signal.SIGINT,signal.SIG_IGN);" + PLAIN_CHILD.split(";", 1)[1])

CLOSE_PROGRAM = """\
def main() -> Void
  args = System.args()
  p = Result.unwrap!(Process.spawn_captured(args[0], ["-c", args[1]], ".", 60000))
  puts(Result.unwrap!(Process.read_line(p, 60000)))
  IO.flush()
  start = Time.monotonic_ms()
  Process.close(p)
  puts(Time.monotonic_ms() - start)
  IO.flush()
  if args[2] == "stay"
    Task.sleep(60000)
  end
end
"""

HELLO_PROGRAM = 'def main() -> Void\n  puts("hi")\nend\n'


def pids_of(line, request):
    """The pids in a line of the program; each is killed when the test ends if it is still there."""
    pids = line.split()
    assert len(pids) >= 1 and all(word.isdigit() for word in pids), line
    for pid in pids:
        request.addfinalizer(lambda found=pid: kill_process(found))
    return pids


# The POSIX case closes the child with SIGTERM, so that a VM child stops its own children before it ends. Windows has
# no such signal: the VM child is ended with TerminateProcess, and the job object that it made for its own children
# ends them when it dies. The promise is the same, no process of the tree stays, and it is checked while the parent
# is alive, so the end of the run does not do the work of the close.
@pytest.mark.parametrize("mode", ["close", "timeout"])
def test_closing_a_captured_vm_child_ends_the_child_and_its_own_child(adopt, request, tmp_path, mode):
    inner = bytecode(INNER_PROGRAM, tmp_path, "captured-inner")
    outer = bytecode(OUTER_PROGRAM, tmp_path, "captured-outer")
    parent = adopt(start_vm(outer, vm_binary(), inner, mode, PYTHON, PEER))
    pids = pids_of(parent.next_line(WAIT), request)
    assert len(pids) == 2
    if mode == "timeout":
        assert parent.next_line(WAIT) == 'error("network: operation timed out")'
    assert parent.next_line(WAIT) == "released"
    for pid in pids:
        assert gone(pid), "%s: %s" % (mode, pid)
    assert parent.process.poll() is None  # the parent is still running: the close did it


# The POSIX case sends SIGTERM and then SIGKILL to a child that traps SIGTERM. Windows has only TerminateProcess, which
# a child cannot trap, so the child here ignores the console signals and the close must still be quick and final.
@pytest.mark.parametrize("child_code", [PLAIN_CHILD, STUBBORN_CHILD], ids=["plain", "stubborn"])
@pytest.mark.parametrize("then", ["stay", "exit"])
def test_close_never_waits_for_a_captured_child_and_one_that_ignores_the_console_signals_is_killed(
        adopt, request, tmp_path, child_code, then):
    grace = bytecode(CLOSE_PROGRAM, tmp_path, "captured-grace")
    vm = adopt(start_vm(grace, PYTHON, child_code, then))
    pid = pids_of(vm.next_line(WAIT), request)[0]
    # A close that waited for the child would end by the 1-second timer of the close: above this bound, which leaves
    # room for a slow runner.
    assert int(vm.next_line(WAIT)) < 900
    if then == "stay":
        assert gone(pid)
        assert vm.process.poll() is None
    else:
        assert vm.wait(WAIT) == 0
        assert gone(pid)


# The POSIX case makes the input private with chmod 600, and refuses mode 644 and a symbolic link. Windows has an
# access list for the owner only (create_private), refuses one that names anyone else, a link and a second name.
def test_the_hidden_driver_pid_flag_loads_only_a_private_input_and_then_deletes_it(tmp_path):
    hello = bytecode(HELLO_PROGRAM, tmp_path, "hello")
    copier = bytecode(COPY_PROGRAM, tmp_path, "copy-private")
    copy = tmp_path / "driver-copy.agcb"
    environment = vm_environment()

    def make_private(path=copy):
        made = run_vm(copier, args=[hello, path], env=environment, cwd=tmp_path)
        assert (made.code, made.stderr) == (0, ""), made

    def driven(pid, path=copy):
        result = run(vm_command() + ["--driver-pid", str(pid), "--", path], env=environment, cwd=tmp_path)
        return result.code, result.stdout, result.stderr

    def refused(pid, why, path=copy):
        code, output, errors = driven(pid, path)
        assert (code, output) == (2, ""), errors
        assert why in errors, errors

    make_private()
    assert driven(os.getpid()) == (0, "hi\n", "")
    assert not copy.exists()
    # Anyone else on the access list makes it public, like mode 644.
    make_private()
    icacls(copy, "/grant", "*S-1-1-0:R")
    refused(os.getpid(), "cannot read")
    assert copy.exists()
    copy.unlink()
    # The pid must be the one of the parent.
    make_private()
    refused(os.getpid() + 1, "does not match the parent process")
    assert copy.exists()
    link = tmp_path / "driver-link.agcb"
    os.symlink(copy, link)
    refused(os.getpid(), "cannot read", link)
    assert copy.exists()
    link.unlink()
    other_name = tmp_path / "driver-other-name.agcb"
    os.link(copy, other_name)
    refused(os.getpid(), "cannot read")
    assert copy.exists() and other_name.exists()
    # Without the second name the same file loads: the link count was the reason for the refusal.
    other_name.unlink()
    assert driven(os.getpid()) == (0, "hi\n", "")
    assert not copy.exists()


# The POSIX case makes the temporary folder read-only with chmod 0500. Windows has no mode bits: an entry that denies
# the right to add files and folders does the same. It names the user and Everyone, so no group of an elevated token
# lets the write through, and the test process gives up the backup and restore privileges that the runner enables:
# with them, NTFS lets a process create entries in a folder whatever its access list says (the privileges are
# inherited by the children, the VM among them). The probes show which side failed if the folder is still writable.
def test_a_temporary_directory_that_cannot_be_written_is_an_infrastructure_error_that_names_it(bdd, request):
    scratch = bdd.make_suite({"nothing.txt": ""}, "agentica-bdd-readonly-")
    temporary = scratch / "tmp"
    temporary.mkdir()
    denied = ["*" + current_user_sid(), "*S-1-1-0"]
    request.addfinalizer(lambda: [icacls(temporary, "/remove:d", who) for who in denied])
    with without_backup_restore_privileges():
        for who in denied:
            icacls(temporary, "/deny", who + ":(WD,AD)")
        with pytest.raises(PermissionError):
            (temporary / "probe-folder").mkdir()
        with pytest.raises(PermissionError):
            (temporary / "probe-file").write_text("x")
        # libuv maps ERROR_ACCESS_DENIED to EPERM, so the text is not "Permission denied" as it is for chmod.
        assert_unwritable_temporary_is_an_infrastructure_error(bdd, scratch, temporary, "Operation not permitted")
