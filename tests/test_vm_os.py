"""The OS builtins the BDD driver port needs (35.5): owner-only creates, File.lstat, File.try_lock, Path.remove,
Path.rename, System.pid and the child environment.

Each case runs a small Agentica program on the VM against a temp directory and compares the disk, or Python's
os module, with what the program printed. The lock cases start separate VM processes: the contention is real.

Every VM here runs with its working directory inside the case's own scratch directory, and every path that is
removed is inside it. The names Path.remove must refuse are asked as "scratch/guarded/sub/..", "." and "..", never
as "/": a regression of the refusal then removes part of the scratch directory, not a real tree.
"""
import os
import signal
import stat
import unittest

from tests.agentica_test import Child, TestCase, output_lines, run_vm, start_vm, vm_binary, vm_environment

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

REMOVE_PROGRAM = """\
def main() -> Void
  base = System.args()[0]
  IO.inspect(Path.remove(base + "/tree", 5000))
  IO.inspect(Path.remove(base + "/root-link", 5000))
  IO.inspect(Path.remove(base + "/root-link", 5000))
  IO.inspect(Path.remove(base + "/other-link/", 5000).ok?)
  IO.inspect(Path.remove(base + "/missing", 5000))
  IO.inspect(Path.remove(base + "/plain.txt/x", 5000).ok?)
  IO.inspect(Path.remove(base + "/guarded/sub/..", 5000))
  IO.inspect(Path.remove(base + "/guarded/sub/../", 5000))
  IO.inspect(Path.remove(".", 5000))
  IO.inspect(Path.remove("..", 5000))
  IO.inspect(Path.remove("../.", 5000))
  IO.inspect(Path.remove(base + "/deep", 5000))
  IO.inspect(Path.remove(base + "/file-link", 5000))
  IO.inspect(Path.remove(base + "/plain.txt", 5000))
  IO.inspect(Path.remove(base + "/real-dir", 5000))
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
  p = Result.unwrap!(Process.spawn_captured(vm, ["--driver-pid", String.from_int(driver), "--", target], ".", 5000))
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

TREE_DEPTH = 130


class OsBuiltins(TestCase):
    def setUp(self):
        self.root = self.make_temp_dir("agentica-os-").resolve()

    def program(self, text, name):
        return self.compile_text(text, name)

    def run_program(self, text, name, *args, flags=(), env=None, cwd=None):
        """Run a program on the VM in `cwd` (default: the scratch directory); asserts exit 0 and no stderr, and
        returns the stdout lines."""
        result = run_vm(self.program(text, name), *flags, args=[str(arg) for arg in args],
                        env=vm_environment(env), cwd=cwd or self.root)
        self.assertEqual((result.code, result.stderr), (0, ""), result.stdout)
        return output_lines(result.stdout)

    def test_private_create_and_mkdir_set_owner_only_modes_and_never_reuse_a_path(self):
        # With umask 0 only the mode the VM asks for can explain 0600 and 0700.
        self.addCleanup(os.umask, os.umask(0))
        os.symlink(self.root / "dangling-target", self.root / "dangling")
        lines = self.run_program(MODES_PROGRAM, "modes", self.root)
        self.assertEqual(lines[:9], ["true", "false", "false", "true", "true", "true", "false", "false", "false"])
        self.assertEqual(lines[9], 'error("filesystem: mode must be read, write, append, or create_private")')
        self.assertEqual(stat.S_IMODE((self.root / "private").stat().st_mode), 0o700)
        secret = self.root / "private" / "secret.bin"
        self.assertEqual(stat.S_IMODE(secret.stat().st_mode), 0o600)
        self.assertEqual(secret.read_bytes(), b"top secret\n\x01\x02\xff")
        # O_EXCL does not follow the dangling link, so the target was not created through it.
        self.assertFalse((self.root / "dangling-target").exists())
        self.assertTrue((self.root / "dangling").is_symlink())
        self.assertFalse((self.root / "no").exists())

    def test_lstat_describes_links_themselves_and_reports_mode_and_owner_like_python(self):
        (self.root / "file").write_text("hello")
        os.chmod(self.root / "file", 0o640)
        (self.root / "dir").mkdir()
        (self.root / "sticky").mkdir()
        os.chmod(self.root / "sticky", 0o1777)
        os.symlink("file", self.root / "link-file")
        os.symlink("dir", self.root / "link-dir")
        os.symlink("nowhere", self.root / "dangling")
        names = ["file", "dir", "sticky", "link-file", "link-dir", "dangling", "missing"]
        lines = self.run_program(LSTAT_PROGRAM, "lstat", self.root, *names)

        def expected(label, info):
            if info is None:
                return "%s error" % label
            kind = "directory" if stat.S_ISDIR(info.st_mode) else "link" if stat.S_ISLNK(info.st_mode) else "file"
            size = 0 if kind == "directory" else info.st_size
            return "%s %s %d %d %d %d %d" % (label, kind, size, stat.S_IMODE(info.st_mode), info.st_uid, info.st_gid,
                                              info.st_mtime_ns // 10**9)

        def seen(call, name):
            try:
                return call(self.root / name)
            except OSError:
                return None

        want = []
        for name in names:
            want.append(expected("lstat " + name, seen(os.lstat, name)))
            want.append(expected("stat " + name, seen(os.stat, name)))
        self.assertEqual(lines, want)
        # The spot checks the TMPDIR check and the sweep depend on: a link is itself, the sticky bit is in the mode.
        self.assertTrue(lines[0].startswith("lstat file file 5 416 "), lines[0])
        self.assertTrue(lines[4].startswith("lstat sticky directory 0 1023 "), lines[4])
        self.assertTrue(lines[6].startswith("lstat link-file link 4 "), lines[6])
        self.assertTrue(lines[7].startswith("stat link-file file 5 "), lines[7])
        self.assertTrue(lines[8].startswith("lstat link-dir link 3 "), lines[8])
        self.assertTrue(lines[9].startswith("stat link-dir directory 0 "), lines[9])
        self.assertTrue(lines[10].startswith("lstat dangling link 7 "), lines[10])
        self.assertEqual(lines[11:], ["stat dangling error", "lstat missing error", "stat missing error"])

    def test_try_lock_on_two_handles_of_one_file_is_released_by_close(self):
        lines = self.run_program(LOCK_PROGRAM, "lock", self.root / "lock")
        self.assertEqual(lines, ["ok(true)", "ok(true)", "ok(false)", "true", "ok(true)", "false", "false"])
        self.assertEqual(stat.S_IMODE((self.root / "lock").stat().st_mode), 0o600)

    def test_try_lock_contends_across_processes_and_dies_with_its_holder(self):
        path = self.root / "lock"
        path.write_text("")
        bytecode = self.program(CONTENTION_PROGRAM, "contention")

        def probe():
            result = run_vm(bytecode, args=[str(path), "probe"], env=vm_environment(), cwd=self.root)
            self.assertEqual((result.code, result.stderr), (0, ""))
            return result.stdout.strip()

        self.assertEqual(probe(), "true")
        # The holder never closes the file: ending the process releases the lock.
        holder = self.adopt(start_vm(bytecode, str(path), "hold", stdin=True, cwd=self.root))
        self.assertEqual(holder.next_line(), "true")
        self.assertEqual(probe(), "false")
        holder.close_stdin()
        self.assertEqual(holder.wait(), 0)
        self.assertEqual(probe(), "true")
        # A killed holder releases it too.
        killed = self.adopt(start_vm(bytecode, str(path), "hold", stdin=True, cwd=self.root))
        self.assertEqual(killed.next_line(), "true")
        self.assertEqual(probe(), "false")
        os.killpg(killed.process.pid, signal.SIGKILL)
        killed.wait()
        self.assertEqual(probe(), "true")

    def test_a_child_does_not_keep_the_lock_after_the_handle_closes(self):
        path = self.root / "lock"
        path.write_text("")
        bytecode = self.program(CONTENTION_PROGRAM, "contention")
        holder = self.adopt(start_vm(bytecode, str(path), "spawn", flags=("--allow-run",), stdin=True, cwd=self.root))
        self.assertEqual(holder.next_line(), "true")
        self.assertEqual(holder.next_line(), "closed")
        # The `sleep` child is alive and was started after the lock was taken, yet the lock is free.
        result = run_vm(bytecode, args=[str(path), "probe"], env=vm_environment(), cwd=self.root)
        self.assertEqual(result.stdout.strip(), "true")
        holder.close_stdin()
        self.assertEqual(holder.wait(), 0)

    def test_try_lock_refuses_what_is_not_a_regular_file(self):
        os.mkfifo(self.root / "fifo")
        lines = self.run_program(DEVICE_LOCK_PROGRAM, "devicelock", self.root)
        self.assertEqual(lines, ['error("filesystem: only a regular file can be locked")'] * 2)

    def test_a_locked_directory_keeps_its_lock_when_it_is_renamed_to_its_final_name(self):
        bytecode = self.program(CONTENTION_PROGRAM, "contention")

        def probe(name):
            result = run_vm(bytecode, args=[str(self.root / name / "lock"), "probe"], env=vm_environment(),
                            cwd=self.root)
            self.assertEqual((result.code, result.stderr), (0, ""))
            return result.stdout.strip()

        holder = self.adopt(start_vm(self.program(PROTOCOL_PROGRAM, "protocol"), str(self.root), stdin=True,
                                     cwd=self.root))
        self.assertEqual(holder.next_line(), "true")
        self.assertEqual(holder.next_line(), "renamed")
        self.assertFalse((self.root / "new-dir").exists())
        self.assertEqual(stat.S_IMODE((self.root / "final-dir").stat().st_mode), 0o700)
        self.assertEqual(probe("final-dir"), "false")
        holder.close_stdin()
        self.assertEqual(holder.wait(), 0)
        self.assertEqual(probe("final-dir"), "true")

    def test_rename_never_replaces_and_moves_a_link_as_a_link(self):
        (self.root / "a.txt").write_text("a")
        (self.root / "c.txt").write_text("c")
        (self.root / "d.txt").write_text("d")
        (self.root / "dir").mkdir()
        (self.root / "dir" / "inside.txt").write_text("inside")
        (self.root / "empty").mkdir()
        (self.root / "target.txt").write_text("target")
        os.symlink("target.txt", self.root / "link")
        lines = self.run_program(RENAME_PROGRAM, "rename", self.root)
        exists = 'error("filesystem: cannot rename path\\n  from: %s/c.txt\\n  to: %s/d.txt\\n  system error: ' \
                 'File exists; errno=17")' % (self.root, self.root)
        self.assertEqual(lines, ["true", exists, "false", "false", "true", "true", "false", "false"])
        self.assertEqual((self.root / "b.txt").read_text(), "a")
        self.assertFalse((self.root / "a.txt").exists())
        # The target of a name that exists is never replaced, an empty directory included.
        self.assertEqual((self.root / "c.txt").read_text(), "c")
        self.assertEqual((self.root / "d.txt").read_text(), "d")
        self.assertEqual(list((self.root / "empty").iterdir()), [])
        self.assertEqual((self.root / "moved" / "inside.txt").read_text(), "inside")
        self.assertFalse((self.root / "dir").exists())
        # A link moves as a link; what it names stays.
        self.assertTrue((self.root / "link2").is_symlink())
        self.assertEqual(os.readlink(self.root / "link2"), "target.txt")
        self.assertFalse(os.path.lexists(self.root / "link"))
        self.assertEqual((self.root / "target.txt").read_text(), "target")

    def test_rename_has_exactly_one_winner_when_processes_race_for_a_name(self):
        bytecode = self.program(RACE_PROGRAM, "race")
        target = self.root / "target"
        sources = []
        for k in range(6):
            source = self.root / ("source%d" % k)
            source.write_text(str(k))
            sources.append(source)
        racers = [self.adopt(start_vm(bytecode, str(source), str(target), cwd=self.root)) for source in sources]
        answers = [racer.next_line() for racer in racers]
        for racer in racers:
            self.assertEqual(racer.wait(), 0)
        self.assertEqual(sorted(answers), ["false"] * 5 + ["true"])
        winner = answers.index("true")
        self.assertEqual(target.read_text(), str(winner))
        self.assertFalse(sources[winner].exists())
        for k, source in enumerate(sources):
            self.assertEqual(source.exists(), k != winner)

    def prepare_trees(self):
        outside = self.root / "outside"
        (outside / "keep-dir").mkdir(parents=True)
        (outside / "keep.txt").write_text("keep")
        tree = self.root / "tree"
        (tree / "sub" / "deeper").mkdir(parents=True)
        (tree / "sub" / "deeper" / "f.txt").write_text("f")
        (tree / "top.txt").write_text("top")
        os.symlink(outside, tree / "to-dir")
        os.symlink("../../outside/keep.txt", tree / "sub" / "to-file")
        os.symlink("/does/not/exist", tree / "dangling")
        os.mkfifo(tree / "pipe")
        os.symlink(outside, self.root / "root-link")
        os.symlink(outside, self.root / "other-link")
        os.symlink(outside / "keep.txt", self.root / "file-link")
        (self.root / "plain.txt").write_text("plain")
        (self.root / "real-dir" / "sub").mkdir(parents=True)
        (self.root / "real-dir" / "sub" / "b.txt").write_text("b")
        (self.root / "guarded" / "sub").mkdir(parents=True)
        (self.root / "guarded" / "sub" / "keep.txt").write_text("keep")
        deep = self.root / "deep"
        deep.mkdir()
        path = str(deep)
        for _ in range(TREE_DEPTH):
            path += "/d"
            os.mkdir(path)

    def test_remove_deletes_links_as_links_never_follows_them_and_refuses_unsafe_roots(self):
        self.prepare_trees()
        # The VM runs in guarded/sub: "." and ".." name the scratch directories guarded/sub and guarded.
        lines = self.run_program(REMOVE_PROGRAM, "remove", self.root, cwd=self.root / "guarded" / "sub")
        refused = 'error("filesystem: refusing to remove /, . or ..")'
        self.assertEqual(lines, [
            "ok()", "ok()", "ok()", "false", "ok()", "false", refused, refused, refused, refused, refused,
            'error("filesystem: directory tree is deeper than 128 levels")', "ok()", "ok()", "ok()"])
        self.assertEqual((self.root / "guarded" / "sub" / "keep.txt").read_text(), "keep")
        self.assertFalse((self.root / "tree").exists())
        # What the links inside the tree and the root link named is untouched.
        self.assertEqual((self.root / "outside" / "keep.txt").read_text(), "keep")
        self.assertTrue((self.root / "outside" / "keep-dir").is_dir())
        # A link given as the path goes itself; with a trailing slash it is an error and stays.
        self.assertFalse((self.root / "root-link").is_symlink())
        self.assertTrue((self.root / "other-link").is_symlink())
        self.assertFalse((self.root / "file-link").is_symlink())
        self.assertFalse((self.root / "plain.txt").exists())
        self.assertFalse((self.root / "real-dir").exists())
        self.assertTrue((self.root / "deep").is_dir())

    @unittest.skipIf(os.geteuid() == 0, "root ignores the permission bits")
    def test_remove_names_the_entry_that_failed_and_leaves_the_rest(self):
        tree = self.root / "tree"
        (tree / "a" / "locked").mkdir(parents=True)
        (tree / "a" / "locked" / "f.txt").write_text("f")
        (tree / "z.txt").write_text("z")
        os.chmod(tree / "a" / "locked", 0o500)
        self.addCleanup(os.chmod, tree / "a" / "locked", 0o700)
        text = """\
def main() -> Void
  IO.inspect(Path.remove(System.args()[0] + "/tree", 5000))
end
"""
        lines = self.run_program(text, "named", self.root)
        self.assertEqual(lines, [
            'error("filesystem: cannot remove path\\n  path: %s/tree/a/locked/f.txt\\n  system error: '
            'Permission denied; errno=13")' % self.root])
        self.assertTrue((tree / "a" / "locked" / "f.txt").exists())

    def test_error_texts_carry_the_path_and_the_os_reason(self):
        (self.root / "plain.txt").write_text("plain")
        text = """\
def main() -> Void
  base = System.args()[0]
  IO.inspect(Path.remove(base + "/plain.txt/x", 5000))
  IO.inspect(Dir.mkdir_private(base + "/missing/x", 5000))
end
"""
        lines = self.run_program(text, "texts", self.root)
        root = str(self.root)
        self.assertEqual(lines, [
            'error("filesystem: cannot remove path\\n  path: %s/plain.txt/x\\n  system error: '
            'Not a directory; errno=20")' % root,
            'error("make-directory: cannot make directory\\n  path: %s/missing/x\\n  system error: '
            'No such file or directory; errno=2")' % root])

    def test_system_pid_is_the_vm_process_and_the_parent_a_child_sees(self):
        child = self.compile_text('def main() -> Void\n  puts("child ran")\nend\n', "child")
        bytecode = self.program(PID_PROGRAM, "pid")
        vm = self.adopt(Child([vm_binary(), "--allow-run", "--", bytecode, str(vm_binary()), str(child), str(self.root)],
                              env=vm_environment(), cwd=self.root, capture_stderr=True))
        lines = [vm.next_line() for _ in range(5)]
        self.assertEqual(vm.wait(), 0)
        pid = vm.process.pid
        self.assertEqual(lines[0], "pid %d" % pid)
        self.assertEqual(lines[1], "stable true")
        self.assertEqual(lines[2], "parent seen by sh %d" % pid)
        # --driver-pid is checked against the parent of the child VM: this is how the driver starts the runner.
        self.assertEqual(lines[3], "driver-pid %d exit 0 stdout child ran stderr " % pid)
        self.assertTrue(lines[4].startswith("driver-pid %d exit 2 stdout  stderr agentica-vm: --driver-pid does not "
                                            "match the parent process" % (pid + 1)), lines[4])

    def test_children_never_get_the_metrics_variables_but_the_program_reads_them(self):
        extra = {"AGENTICA_VM_METRICS": "9465", "AGENTICA_VM_METRICS_FILE": "/nowhere/metrics.prom",
                 "AGENTICA_VM_METRICS_KEPT": "kept", "OTHER_VARIABLE": "stays"}
        lines = self.run_program(ENV_PROGRAM, "env", flags=("--allow-run",), env=extra)
        self.assertEqual(lines[0], "own 9465 /nowhere/metrics.prom")
        # Only the exact names go; a longer name that starts with them is an ordinary variable.
        self.assertEqual(sorted(lines[1:]), ["AGENTICA_VM_METRICS_KEPT=kept", "OTHER_VARIABLE=stays"])
