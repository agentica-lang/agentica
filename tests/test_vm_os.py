"""Non-destructive OS builtin tests for private files, metadata, locks and process state.

Mutating Path.remove/Path.rename and private-bytecode-consumption regressions live in
`tests/test_vm_os_remove.py`; local runs require the physical Docker sandbox, while
GitHub Actions runs them in per-job scratch after checking the runner boundary.
"""
import os
import signal
import stat

import pytest

from tests.agentica_test import Child, compile_agc, output_lines, run_vm, start_vm, vm_binary, vm_command, vm_environment
from tests.windows_support import assert_rename_race

MODES_PROGRAM = """\
def main() -> Void
  base = System.args()[0]
  dir = base + "/private"
  IO.inspect(Dir.mkdir_private(dir, 5000).ok?)
  IO.inspect(Dir.mkdir_private(dir, 5000).ok?)
  IO.inspect(Dir.mkdir_private(base + "/no/such/parent", 5000).ok?)
  path = dir + "/secret.bin"
  file = Result.unwrap!(File.open(path, "create_private", 5000))
  IO.inspect(File.write(file, "top secret\\n", 5000).ok?)
  IO.inspect(File.write_bytes(file, [1, 2, 255], 5000).ok?)
  IO.inspect(File.close(file, 5000).ok?)
  IO.inspect(File.open(path, "create_private", 5000).ok?)
  IO.inspect(File.open(base + "/dangling", "create_private", 5000).ok?)
  IO.inspect(File.open(base + "/missing/child", "create_private", 5000).ok?)
  IO.inspect(File.open(path, "readwrite", 5000))
end
"""

LSTAT_PROGRAM = """\
def show(label: String, r: Result[FileInfo]) -> Void
  if r.ok?
    info = Result.unwrap!(r)
    puts("#{label} #{info.kind} #{info.size_bytes} #{info.mode} #{info.user_id} #{info.group_id} #{info.modified_seconds}")
  else
    puts("#{label} error")
  end
end

def main() -> Void
  base = System.args()[0]
  for name in System.args().drop(1)
    show("lstat " + name, File.lstat(base + "/" + name, 5000))
    show("stat " + name, File.stat(base + "/" + name, 5000))
  end
end
"""

LOCK_PROGRAM = """\
def main() -> Void
  path = System.args()[0]
  first = Result.unwrap!(File.open(path, "create_private", 5000))
  second = Result.unwrap!(File.open(path, "read", 5000))
  IO.inspect(File.try_lock(first, 5000))
  IO.inspect(File.try_lock(first, 5000))
  IO.inspect(File.try_lock(second, 5000))
  IO.inspect(File.close(first, 5000).ok?)
  IO.inspect(File.try_lock(second, 5000))
  IO.inspect(File.try_lock(first, 5000).ok?)
  IO.inspect(File.try_lock(second, 0).ok?)
end
"""

DEVICE_LOCK_PROGRAM = """\
def main() -> Void
  device = Result.unwrap!(File.open("/dev/null", "read", 5000))
  IO.inspect(File.try_lock(device, 5000))
  fifo = Result.unwrap!(File.open(System.args()[0] + "/fifo", "read", 5000))
  IO.inspect(File.try_lock(fifo, 5000))
end
"""

# The driver's protocol: make a private directory under a temporary name, lock a file in it, then rename it to its
# final name; the lock follows the file, so a sweep that finds the final name always finds it locked.
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

ENV_PROGRAM = """\
def main() -> Void
  puts("own #{Result.unwrap!(System.env("AGENTICA_VM_METRICS"))} #{Result.unwrap!(System.env("AGENTICA_VM_METRICS_FILE"))}")
  p = Result.unwrap!(Process.spawn_captured("env", [], ".", 5000))
  out = Result.unwrap!(Process.output(p, 10000))
  for line in out.stdout.split("\\n")
    if line.starts_with?("AGENTICA_VM_METRICS") or line.starts_with?("OTHER_VARIABLE=")
      puts(line)
    end
  end
end
"""


@pytest.fixture
def root(tmp_path):
    """A fresh scratch directory for the test (resolved, like make_temp_dir was)."""
    path = (tmp_path / "scratch").resolve()
    path.mkdir()
    return path


@pytest.fixture
def work(tmp_path):
    """A fresh directory for compiled programs, separate from the scratch files."""
    path = tmp_path / "work"
    path.mkdir()
    return path.resolve()


@pytest.fixture
def adopt(request):
    """Stop a Child when the test ends (also after a failure); return it."""
    def register(child):
        request.addfinalizer(child.stop)
        return child

    return register


def compile_text(work, text, name="program"):
    """Compile Agentica source text; return the bytecode path."""
    source = work / (name + ".agc")
    source.write_text(text, encoding="utf-8")
    return compile_agc(source, work / (name + ".agcb"))


def run_program(root, work, text, name, *args, flags=(), env=None, cwd=None):
    """Run a program in the scratch directory and return its output lines."""
    result = run_vm(compile_text(work, text, name), *flags, args=[str(arg) for arg in args],
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
    """Shared with tests/test_vm_os_remove.py: rename never replaces, and moves a link as a link."""
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
    """Shared rename-race check (previously dead code on OsBuiltins; kept for the remove tests)."""
    bytecode = compile_text(work, RACE_PROGRAM, "race")
    assert_rename_race(_RaceCase(adopt), bytecode, root, lambda number: "source%d" % number)


def system_pid_is_the_vm_process_and_the_parent_a_child_sees(root, work, adopt):
    """Shared with tests/test_vm_os_remove.py: the driver-pid handoff only accepts the real parent."""
    child = compile_text(work, 'def main() -> Void\n  puts("child ran")\nend\n', "child")
    bytecode = compile_text(work, PID_PROGRAM, "pid")
    vm = adopt(Child([*vm_command(), "--allow-run", "--", bytecode, str(vm_binary()), str(child), str(root)],
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


def test_private_create_and_mkdir_set_owner_only_modes_and_never_reuse_a_path(root, work):
    # With umask 0 only the mode the VM asks for can explain 0600 and 0700.
    old_umask = os.umask(0)
    try:
        os.symlink(root / "dangling-target", root / "dangling")
        lines = run_program(root, work, MODES_PROGRAM, "modes", root)
        assert lines[:9] == ["true", "false", "false", "true", "true", "true", "false", "false", "false"]
        assert lines[9] == 'error("filesystem: mode must be read, write, append, or create_private")'
        assert stat.S_IMODE((root / "private").stat().st_mode) == 0o700
        secret = root / "private" / "secret.bin"
        assert stat.S_IMODE(secret.stat().st_mode) == 0o600
        assert secret.read_bytes() == b"top secret\n\x01\x02\xff"
        # O_EXCL does not follow the dangling link, so the target was not created through it.
        assert not (root / "dangling-target").exists()
        assert (root / "dangling").is_symlink()
        assert not (root / "no").exists()
    finally:
        os.umask(old_umask)


def test_lstat_describes_links_themselves_and_reports_mode_and_owner_like_python(root, work):
    (root / "file").write_text("hello")
    os.chmod(root / "file", 0o640)
    (root / "dir").mkdir()
    (root / "sticky").mkdir()
    os.chmod(root / "sticky", 0o1777)
    os.symlink("file", root / "link-file")
    os.symlink("dir", root / "link-dir")
    os.symlink("nowhere", root / "dangling")
    names = ["file", "dir", "sticky", "link-file", "link-dir", "dangling", "missing"]
    lines = run_program(root, work, LSTAT_PROGRAM, "lstat", root, *names)

    def expected(label, info):
        if info is None:
            return "%s error" % label
        kind = "directory" if stat.S_ISDIR(info.st_mode) else "link" if stat.S_ISLNK(info.st_mode) else "file"
        size = 0 if kind == "directory" else info.st_size
        return "%s %s %d %d %d %d %d" % (label, kind, size, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid,
                                        info.st_mtime_ns // 10**9)

    def seen(call, name):
        try:
            return call(root / name)
        except OSError:
            return None

    want = []
    for name in names:
        want.append(expected("lstat " + name, seen(os.lstat, name)))
        want.append(expected("stat " + name, seen(os.stat, name)))
    assert lines == want
    # The spot checks the TMPDIR check and the sweep depend on: a link is itself, the sticky bit is in the mode.
    assert lines[0].startswith("lstat file file 5 416 "), lines[0]
    assert lines[4].startswith("lstat sticky directory 0 1023 "), lines[4]
    assert lines[6].startswith("lstat link-file link 4 "), lines[6]
    assert lines[7].startswith("stat link-file file 5 "), lines[7]
    assert lines[8].startswith("lstat link-dir link 3 "), lines[8]
    assert lines[9].startswith("stat link-dir directory 0 "), lines[9]
    assert lines[10].startswith("lstat dangling link 7 "), lines[10]
    assert lines[11:] == ["stat dangling error", "lstat missing error", "stat missing error"]


def test_try_lock_on_two_handles_of_one_file_is_released_by_close(root, work):
    lines = run_program(root, work, LOCK_PROGRAM, "lock", root / "lock")
    assert lines == ["ok(true)", "ok(true)", "ok(false)", "true", "ok(true)", "false", "false"]
    assert stat.S_IMODE((root / "lock").stat().st_mode) == 0o600


def test_try_lock_contends_across_processes_and_dies_with_its_holder(root, work, adopt):
    path = root / "lock"
    path.write_text("")
    bytecode = compile_text(work, CONTENTION_PROGRAM, "contention")

    def probe():
        result = run_vm(bytecode, args=[str(path), "probe"], env=vm_environment(), cwd=root)
        assert (result.code, result.stderr) == (0, "")
        return result.stdout.strip()

    assert probe() == "true"
    # The holder never closes the file: ending the process releases the lock.
    holder = adopt(start_vm(bytecode, str(path), "hold", stdin=True, cwd=root))
    assert holder.next_line() == "true"
    assert probe() == "false"
    holder.close_stdin()
    assert holder.wait() == 0
    assert probe() == "true"
    # A killed holder releases it too.
    killed = adopt(start_vm(bytecode, str(path), "hold", stdin=True, cwd=root))
    assert killed.next_line() == "true"
    assert probe() == "false"
    os.killpg(killed.process.pid, signal.SIGKILL)
    killed.wait()
    assert probe() == "true"


def test_a_child_does_not_keep_the_lock_after_the_handle_closes(root, work, adopt):
    path = root / "lock"
    path.write_text("")
    bytecode = compile_text(work, CONTENTION_PROGRAM, "contention")
    holder = adopt(start_vm(bytecode, str(path), "spawn", flags=("--allow-run",), stdin=True, cwd=root))
    assert holder.next_line() == "true"
    assert holder.next_line() == "closed"
    # The `sleep` child is alive and was started after the lock was taken, yet the lock is free.
    result = run_vm(bytecode, args=[str(path), "probe"], env=vm_environment(), cwd=root)
    assert result.stdout.strip() == "true"
    holder.close_stdin()
    assert holder.wait() == 0


def test_try_lock_refuses_what_is_not_a_regular_file(root, work):
    os.mkfifo(root / "fifo")
    lines = run_program(root, work, DEVICE_LOCK_PROGRAM, "devicelock", root)
    assert lines == ['error("filesystem: only a regular file can be locked")'] * 2


def test_make_directory_error_names_the_path_and_os_reason(root, work):
    text = """\
def main() -> Void
  base = System.args()[0]
  IO.inspect(Dir.mkdir_private(base + "/missing/x", 5000))
end
"""
    lines = run_program(root, work, text, "make-directory-error", root)
    assert lines == [
        'error("make-directory: cannot make directory\\n  path: %s/missing/x\\n  system error: '
        'No such file or directory; errno=2")' % root]
    assert not (root / "missing").exists()


def test_children_never_get_the_metrics_variables_but_the_program_reads_them(root, work):
    extra = {"AGENTICA_VM_METRICS": "9465", "AGENTICA_VM_METRICS_FILE": "/nowhere/metrics.prom",
             "AGENTICA_VM_METRICS_KEPT": "kept", "OTHER_VARIABLE": "stays"}
    lines = run_program(root, work, ENV_PROGRAM, "env", flags=("--allow-run",), env=extra)
    assert lines[0] == "own 9465 /nowhere/metrics.prom"
    # Only the exact names go; a longer name that starts with them is an ordinary variable.
    assert sorted(lines[1:]) == ["AGENTICA_VM_METRICS_KEPT=kept", "OTHER_VARIABLE=stays"]
