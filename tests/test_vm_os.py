"""Non-destructive OS builtin tests for private files, metadata, locks and process state.

Mutating Path.remove/Path.rename and private-bytecode-consumption regressions live in
`tests/test_vm_os_remove.py`; local runs require the physical Docker sandbox, while
GitHub Actions runs them in per-job scratch after checking the runner boundary.
"""
import os
import signal
import stat

import pytest

from tests.agentica_test import run_vm, start_vm, vm_environment
from tests.vm_os_support import CONTENTION_PROGRAM, compile_work_text, root, run_program, work

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
# Races for one target name: the argument is the source, the target is shared.
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
    bytecode = compile_work_text(work, CONTENTION_PROGRAM, "contention")

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
    bytecode = compile_work_text(work, CONTENTION_PROGRAM, "contention")
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
