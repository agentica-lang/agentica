"""Shared scratch fixtures and OS-level helpers for the VM filesystem suites.

tests/test_vm_os.py and tests/test_vm_os_remove.py share the scratch
fixtures, the compile/run helpers and the embedded Agentica programs; the
Windows suites reuse the fixtures and the duck-typed TestCase adapter.
"""
import os
import subprocess

import pytest

from tests.agentica_test import (WINDOWS, Child, compile_agc, output_lines, run_vm, vm_binary, vm_command,
                                 vm_environment)
from tests.remove_sandbox_support import require_remove_sandbox
from tests.windows_support import assert_rename_race

PROTOCOL_PROGRAM = """\
def main() -> Void
  base = System.args()[0]
  fresh = base + "/new-dir"
  Result.unwrap!(Dir.mkdir_private(fresh, 5000))
  lock = Result.unwrap!(File.open(fresh + "/lock", "create_private", 5000))
  puts(Result.unwrap!(File.try_lock(lock, 5000)))
  Result.unwrap!(Path.rename(fresh, base + "/final-dir", 5000))
  puts("renamed")
  IO.flush()
  IO.gets()
end
"""

RENAME_PROGRAM = """\
def main() -> Void
  base = System.args()[0]
  IO.inspect(Path.rename(base + "/a.txt", base + "/b.txt", 5000).ok?)
  IO.inspect(Path.rename(base + "/c.txt", base + "/d.txt", 5000))
  IO.inspect(Path.rename(base + "/missing", base + "/e.txt", 5000).ok?)
  IO.inspect(Path.rename(base + "/dir", base + "/empty", 5000).ok?)
  IO.inspect(Path.rename(base + "/dir", base + "/moved", 5000).ok?)
  IO.inspect(Path.rename(base + "/link", base + "/link2", 5000).ok?)
  IO.inspect(Path.rename(base + "/b.txt", base + "/b.txt", 5000).ok?)
  IO.inspect(Path.rename(base + "/b.txt", base + "/nodir/x", 5000).ok?)
end
"""

# Races for one target name: the argument is the source, the target is shared.
RACE_PROGRAM = """\
def main() -> Void
  args = System.args()
  puts(Path.rename(args[0], args[1], 5000).ok?)
end
"""

# hold: take the lock and keep it until stdin closes, without closing the file; probe: try once;
# spawn: take the lock, start a child that outlives the handle, close the handle, then wait for stdin.
CONTENTION_PROGRAM = """\
def main() -> Void
  args = System.args()
  file = Result.unwrap!(File.open(args[0], "read", 5000))
  if args[1] == "probe"
    puts(Result.unwrap!(File.try_lock(file, 5000)))
    return
  end
  puts(Result.unwrap!(File.try_lock(file, 5000)))
  if args[1] == "spawn"
    child = Result.unwrap!(Process.spawn_captured("sleep", ["60"], ".", 5000))
    Result.unwrap!(File.close(file, 5000))
    puts("closed")
  end
  IO.flush()
  IO.gets()
end
"""

# A VM started with --driver-pid reads only a private bytecode file (owner only, one link) and deletes it, which is
# why the driver writes its files with create_private.
PID_PROGRAM = """\
def copy_private(source: String, target: String) -> Void
  input = Result.unwrap!(File.open(source, "read", 5000))
  out = Result.unwrap!(File.open(target, "create_private", 5000))
  bytes = Result.unwrap!(File.read_bytes(input, 1048576, 5000))
  Result.unwrap!(File.write_bytes(out, bytes, 5000))
  Result.unwrap!(File.close(input, 5000))
  Result.unwrap!(File.close(out, 5000))
end

def run_child(vm: String, driver: Int, source: String, target: String) -> Void
  copy_private(source, target)
  p = Result.unwrap!(Process.spawn_captured(vm, ["run", "--driver-pid", String.from_int(driver), "--", target], ".", 5000))
  out = Result.unwrap!(Process.output(p, 10000))
  code = Result.unwrap!(Process.wait(p, 10000))
  puts("driver-pid #{driver} exit #{code} stdout #{out.stdout.trim} stderr #{out.stderr.trim}")
end

def main() -> Void
  args = System.args()
  me = System.pid()
  puts("pid #{me}")
  puts("stable #{System.pid() == me}")
  sh = Result.unwrap!(Process.spawn_captured("sh", ["-c", "echo $PPID"], ".", 5000))
  out = Result.unwrap!(Process.output(sh, 10000))
  puts("parent seen by sh #{out.stdout.trim}")
  run_child(args[0], me, args[1], args[2] + "/first.agcb")
  run_child(args[0], me + 1, args[1], args[2] + "/second.agcb")
end
"""


def scratch_dir(tmp_path, sandbox=False):
    """A fresh scratch directory; with sandbox, require the Docker or Actions sandbox."""
    path = (tmp_path / "scratch").resolve()
    path.mkdir()
    if sandbox:
        require_remove_sandbox(path)
    return path


@pytest.fixture
def root(tmp_path):
    """A fresh scratch directory for the test (resolved, like make_temp_dir was)."""
    return scratch_dir(tmp_path)


@pytest.fixture
def sandbox_root(tmp_path):
    """A fresh scratch directory for the test, inside the Docker or Actions sandbox."""
    return scratch_dir(tmp_path, sandbox=True)


@pytest.fixture
def work(tmp_path):
    """A fresh directory for compiled programs, separate from the scratch files."""
    path = tmp_path / "work"
    path.mkdir()
    return path.resolve()


def symlink(target, link, directory=False):
    """Make the symbolic link `link` to `target`, arguments in the order of `os.symlink` (a name relative to the
    link's folder is kept as it is). Windows uses mklink: a file link, or a folder link with `directory`."""
    if not WINDOWS:
        os.symlink(target, link)
        return
    made = subprocess.run(["cmd.exe", "/d", "/c", "mklink", *(["/D"] if directory else []), str(link), str(target)],
                          capture_output=True, text=True, check=False)
    assert made.returncode == 0, made.stdout + made.stderr


def compile_work_text(work, text, name="program"):
    """Compile Agentica source text into the work directory; return the bytecode path.

    Unlike tests.agentica_test.compile_text, which compiles under tmp_path, this one
    keeps programs in work, separate from the scratch files the tests mutate.
    """
    source = work / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, work / (name + ".agcb"))


def run_program(root, work, text, name, *args, flags=(), env=None, cwd=None):
    """Run a program in the scratch directory and return its output lines."""
    result = run_vm(compile_work_text(work, text, name), *flags, args=[str(arg) for arg in args],
                    env=vm_environment(env), cwd=cwd or root)
    assert (result.code, result.stderr) == (0, ""), result.stdout
    return output_lines(result.stdout)


class _RaceCase:
    """Duck-typed TestCase for tests.windows_support helpers (they only use adopt and asserts)."""

    def __init__(self, adopt):
        self._adopt = adopt

    def adopt(self, child):
        return self._adopt(child)

    def assertEqual(self, first, second, message=None):
        assert first == second, message or "%r != %r" % (first, second)

    def assertFalse(self, value, message=None):
        assert not value, message or "%r is not false" % (value,)


def rename_never_replaces_and_moves_a_link_as_a_link(root, work):
    """Rename never replaces, and moves a link as a link."""
    (root / "a.txt").write_text("a")
    (root / "c.txt").write_text("c")
    (root / "d.txt").write_text("d")
    (root / "dir").mkdir()
    (root / "dir" / "inside.txt").write_text("inside")
    (root / "empty").mkdir()
    (root / "target.txt").write_text("target")
    os.symlink("target.txt", root / "link")
    lines = run_program(root, work, RENAME_PROGRAM, "rename", root)
    exists = 'error("filesystem: cannot rename path\\n  from: %s/c.txt\\n  to: %s/d.txt\\n  system error: ' \
             'File exists; errno=17")' % (root, root)
    assert lines == ["true", exists, "false", "false", "true", "true", "false", "false"]
    assert (root / "b.txt").read_text() == "a"
    assert not (root / "a.txt").exists()
    # The target of a name that exists is never replaced, an empty directory included.
    assert (root / "c.txt").read_text() == "c"
    assert (root / "d.txt").read_text() == "d"
    assert list((root / "empty").iterdir()) == []
    assert (root / "moved" / "inside.txt").read_text() == "inside"
    assert not (root / "dir").exists()
    # A link moves as a link; what it names stays.
    assert (root / "link2").is_symlink()
    assert os.readlink(root / "link2") == "target.txt"
    assert not os.path.lexists(root / "link")
    assert (root / "target.txt").read_text() == "target"


def rename_race_has_exactly_one_winner(root, work, adopt):
    """The rename race has exactly one winner (previously dead code on OsBuiltins)."""
    bytecode = compile_work_text(work, RACE_PROGRAM, "race")
    assert_rename_race(_RaceCase(adopt), bytecode, root, lambda number: "source%d" % number)


def system_pid_is_the_vm_process_and_the_parent_a_child_sees(root, work, adopt):
    """The driver-pid handoff only accepts the real parent."""
    child = compile_work_text(work, 'def main() -> Void\n  puts("child ran")\nend\n', "child")
    bytecode = compile_work_text(work, PID_PROGRAM, "pid")
    vm = adopt(Child([*vm_command(), "--", bytecode, str(vm_binary()), str(child), str(root)],
                     env=vm_environment(), cwd=root, capture_stderr=True))
    lines = [vm.next_line() for _ in range(5)]
    assert vm.wait() == 0
    pid = vm.process.pid
    assert lines[0] == "pid %d" % pid
    assert lines[1] == "stable true"
    assert lines[2] == "parent seen by sh %d" % pid
    # --driver-pid is checked against the parent of the child VM: this is how the driver starts the runner.
    assert lines[3] == "driver-pid %d exit 0 stdout child ran stderr " % pid
    assert lines[4].startswith("driver-pid %d exit 2 stdout  stderr agentica run: --driver-pid does not "
                               "match the parent process" % (pid + 1)), lines[4]
