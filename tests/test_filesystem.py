"""File, Dir, Path and System.env programs on the VM.

Most cases run a checked Agentica program through the CLI, like the original
test did in process, against temp directories. The FIFO cases run the VM
binary directly with a one-thread pool and a 10 s bound; fixtures/fifo-peer.py
and fixtures/stop-peer.py play the other side of a FIFO or of a pipe, and
fixtures/os-peer.py gives Python's answers for Path.real and System.env.
"""
import errno
import json
import os
import re
import sys
import threading
import time

from tests.agentica_test import (FIXTURES, PYTHON, ROOT, Child, TestCase, cli, compile_agc, output_lines, run, scaled,
                                 vm_command, vm_environment)

EXAMPLES = ROOT / "examples"
STOP_PEER = FIXTURES / "stop-peer.py"
FIFO_PEER = FIXTURES / "fifo-peer.py"
OS_PEER = FIXTURES / "os-peer.py"
VM_WAIT_SECONDS = scaled(10)
FD_ROOT = "/dev/fd" if sys.platform == "darwin" else "/proc/self/fd"

# Path.real or System.env of every argument after the mode, one line each.
OS_PROGRAM = r"""def line(r: Result[String]) -> String
  if r.ok?
    return "ok:" + Result.unwrap!(r)
  end
  return "error"
end

def main() -> Void
  args = System.args()
  for item in args.drop(1)
    if args[0] == "real"
      puts(line(Path.real(item)))
    else
      puts(line(System.env(item)))
    end
  end
end
"""


def literal(text):
    """An Agentica string literal for a path or text (JSON escapes, which the lexer reads back for these inputs)."""
    return json.dumps(str(text), ensure_ascii=False)


def brief(lines):
    return [len(line) if len(line) > 200 else line for line in lines]


class Filesystem(TestCase):
    def new_dir(self):
        return self.make_temp_dir("agentica-filesystem-")

    def run_program(self, text, args=(), cwd=None, env=None):
        """Run an Agentica program through the CLI; asserts exit 0 and returns its stdout."""
        directory = self.new_dir()
        source = directory / "program.agc"
        source.write_text(text.replace("@FD_ROOT@", FD_ROOT), encoding="utf-8")
        result = run(cli() + [source, *args], cwd=cwd, env=env or vm_environment())
        self.assertEqual(result.code, 0, result.stderr)
        return result.stdout

    def stuck_fifo(self):
        """A temp dir with a FIFO that is full and has a reader that never reads; returns (root, fifo).

        A watchdog closes the reader after 20 s, so a flush that nothing bounds cannot hang the run for ever.
        """
        root = self.new_dir()
        fifo = root / "fifo"
        os.mkfifo(fifo)
        reader = [os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)]
        lock = threading.Lock()

        def close_reader():
            with lock:
                if reader:
                    os.close(reader.pop())

        watchdog = threading.Timer(20, close_reader)
        watchdog.daemon = True
        watchdog.start()
        # Cleanups run last in, first out: stop the timer, then close the reader, then remove the directory.
        self.addCleanup(close_reader)
        self.addCleanup(watchdog.cancel)
        writer = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
        try:
            while True:
                os.write(writer, b"a" * 4096)
        except OSError as problem:
            if problem.errno not in (errno.EAGAIN, errno.EPIPE):
                raise
        finally:
            os.close(writer)
        return root, fifo

    def run_vm_bounded(self, root, text, *arguments, peer=None, stdin_text=None, one_pool_thread=False,
                       keep_stdin=False):
        """Compile `text`, run the VM on it with --allow-run, and return (exit code, stdout, stderr).

        The VM must end within 10 s. `peer` runs it under fixtures/stop-peer.py in that mode;
        `keep_stdin` leaves stdin open until the VM has ended. stdout stays a pipe, which a reader thread drains,
        so the cases with one pool thread still cover a pipe on the loop.
        """
        source = root / "program.agc"
        source.write_text(text.replace("@FD_ROOT@", FD_ROOT), encoding="utf-8")
        bytecode = compile_agc(source, root / "program.agcb")
        command = [*vm_command(), "--allow-run", "--", bytecode, *arguments]
        if peer:
            command = [PYTHON, STOP_PEER, peer, *command]
        env = vm_environment({"UV_THREADPOOL_SIZE": "1"} if one_pool_thread else None)
        child = self.adopt(Child(command, env=env, stdin=True, capture_stderr=True))
        if stdin_text:
            child.process.stdin.write(stdin_text.encode())
            child.process.stdin.flush()
        if not keep_stdin:
            child.close_stdin()
        try:
            code = child.wait(VM_WAIT_SECONDS)
        except AssertionError:
            child.stop()
            self.fail("the VM ends within %s s\nstderr: %s" % (VM_WAIT_SECONDS, child.stderr_text()))
        return code, child.stdout_text(), child.stderr_text()

    def os_lines(self, mode, items, cwd=None, env=None):
        """The lines Agentica prints for Path.real (mode "real") or System.env (mode "env") of each item."""
        stdout = self.run_program(OS_PROGRAM, [mode, *items], cwd=cwd, env=env)
        return output_lines(stdout)

    def os_peer_lines(self, mode, items, cwd=None, env=None):
        result = run([PYTHON, "-I", OS_PEER, mode, *items], cwd=cwd, env=env or vm_environment())
        self.assertEqual(result.code, 0, result.stderr)
        return output_lines(result.stdout)

    def test_the_run_waits_for_the_close_of_a_crashed_tasks_file_so_its_buffered_write_reaches_the_disk(self):
        path = self.new_dir() / "crash.txt"
        output = self.run_program(r"""def writer(path: String) -> Result[Int]
  f = try File.open(path, "write", 1000)
  try File.write(f, "hello world\n", 1000)
  n = 0
  return ok(1 / n)
end

def main() -> Void
  t = Task.spawn(&writer, System.args()[0])
  puts(Task.await(t).ok?)
end
""", [path])
        self.assertEqual(output, "false\n")
        self.assertEqual(path.read_text(), "hello world\n")

    def test_flush_timeout_and_agentica_flush_timeout_ms_need_a_non_negative_integer(self):
        hello = EXAMPLES / "hello.agc"

        def code_of(*arguments, variable=None):
            env = vm_environment({"AGENTICA_FLUSH_TIMEOUT_MS": variable})
            return run(cli() + [*arguments, hello], env=env)

        self.assertEqual(code_of("--flush-timeout", "-1").code, 2)
        self.assertEqual(code_of("--flush-timeout", "soon").code, 2)
        self.assertEqual(code_of("--flush-timeout", "86400001").code, 2)
        self.assertEqual(code_of("--flush-timeout", "0").code, 0)
        for bad in ("soon", "-1", "", "86400001"):
            result = code_of(variable=bad)
            self.assertEqual(result.code, 2, bad)
            self.assertIn("AGENTICA_FLUSH_TIMEOUT_MS", result.stderr)
        self.assertEqual(code_of(variable="0").code, 0)

    def test_the_file_flush_limit_comes_from_the_flag_then_the_variable_and_ends_a_stuck_flush(self):
        root, fifo = self.stuck_fifo()
        source = root / "stuck.agc"
        source.write_text(r"""def main() -> Void
  f = File.open(System.args()[0], "write", 1000).unwrap!
  File.write(f, "x", 1000).unwrap!
  IO.print("main done\n")
end
""", encoding="utf-8")

        def start(*arguments, variable=None):
            # Each run ends in well under a second when the limit works; 6 s fails a broken limit before the watchdog.
            return run(cli() + [*arguments], timeout=scaled(6), env=vm_environment({"AGENTICA_FLUSH_TIMEOUT_MS": variable}))

        began = time.monotonic()
        by_flag = start("--json", "--flush-timeout", "200", source, fifo)
        by_variable = start("--json", source, fifo, variable="300")
        flag_wins = start("--json", "--flush-timeout", "250", source, fifo, variable="60000")
        self.assertLess(time.monotonic() - began, scaled(20))
        for result, expected in zip((by_flag, by_variable, flag_wins), (200, 300, 250)):
            self.assertEqual((result.code, result.stdout), (0, "main done\n"), result.stderr)
            self.assertEqual(json.loads(result.stderr)["flush_timeout_ms"], expected)

    def test_an_await_does_not_wait_for_a_flush_that_a_fifo_reader_holds_up(self):
        root, fifo = self.stuck_fifo()
        source = root / "awaited.agc"
        source.write_text(r"""def write_one(path: String) -> Result[Void]
  f = File.open(path, "write", 1000).unwrap!
  return File.write(f, "x", 1000)
end

def main() -> Void
  IO.inspect(Task.await(Task.spawn(&write_one, System.args()[0])))
  IO.print("awaited\n")
end
""", encoding="utf-8")
        began = time.monotonic()
        result = run(cli() + ["--flush-timeout", "200", source, fifo], timeout=scaled(10), env=vm_environment())
        self.assertLess(time.monotonic() - began, scaled(10))
        self.assertEqual((result.code, result.stdout), (0, "ok()\nawaited\n"), result.stderr)

    def test_fifo_calls_wait_on_the_loop_timed_out_reads_and_parked_tasks_hold_no_pool_thread_at_exit(self):
        root = self.new_dir()
        fifo = root / "fifo"
        out = root / "out.txt"
        os.mkfifo(fifo)
        code, output, errors = self.run_vm_bounded(root, r"""def stuck(path: String) -> Result[String]
  return File.read_text(path, 60000)
end

def main() -> Void
  fifo = System.args()[0]
  reader = File.open(fifo, "read", 1000).unwrap!
  writer = File.open(fifo, "append", 1000).unwrap!
  out = File.open(System.args()[1], "write", 1000).unwrap!
  File.write(out, "flushed", 1000).unwrap!
  IO.inspect(File.read_line(reader, 100))
  IO.inspect(File.read_text(fifo, 100))
  for i in [1, 2, 3, 4]
    Task.spawn(&stuck, fifo)
  end
  Task.sleep(50)
  IO.print("main done\n")
end
""", fifo, out, one_pool_thread=True)
        self.assertEqual((code, output), (0, 'error("filesystem: operation timed out")\n'
                                              'error("filesystem: operation timed out")\nmain done\n'), errors)
        self.assertEqual(out.read_text(), "flushed")

    def test_fifos_stream_on_the_loop_read_line_waits_for_a_writer_task_read_text_reads_to_eof(self):
        root = self.new_dir()
        first, second = root / "first", root / "second"
        os.mkfifo(first)
        os.mkfifo(second)
        code, output, errors = self.run_vm_bounded(root, r"""struct Pair
  first: FileHandle
  second: FileHandle
end

def feed(p: Pair) -> Result[Void]
  Task.sleep(100)
  try File.write(p.first, "hello\n", 5000)
  try File.close(p.first, 5000)
  big = "line\n"
  for i in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14]
    big = big + big
  end
  try File.write(p.second, big, 5000)
  return File.close(p.second, 5000)
end

def main() -> Void
  a = System.args()[0]
  b = System.args()[1]
  r = File.open(a, "read", 1000).unwrap!
  w = File.open(a, "append", 1000).unwrap!
  holder = File.open(b, "read", 1000).unwrap!
  w2 = File.open(b, "append", 1000).unwrap!
  t = Task.spawn(&feed, Pair(first: w, second: w2))
  IO.inspect(File.read_line(r, 5000))
  IO.inspect(File.read_line(r, 5000))
  text = File.read_text(b, 5000).unwrap!
  IO.inspect(Task.await(t))
  IO.inspect(String.length(text))
end
""", first, second, one_pool_thread=True)
        self.assertEqual((code, output), (0, 'ok("hello")\nerror("filesystem: end of file")\nok()\n81920\n'),
                         errors)

    def test_a_fifo_write_waits_on_the_loop_for_a_slow_reader_and_a_reader_that_leaves_gives_epipe(self):
        for mode in ("slow", "close"):
            with self.subTest(mode=mode):
                root = self.new_dir()
                fifo = root / "fifo"
                peer = self.adopt(Child([PYTHON, FIFO_PEER, fifo, mode, "65536"]))
                self.assertEqual(peer.next_line(VM_WAIT_SECONDS), "ready", mode)
                code, output, errors = self.run_vm_bounded(root, r"""def main() -> Void
  big = "0123456789"
  for i in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
    big = big + big
  end
  IO.inspect(File.write_text(System.args()[0], big, 10000))
end
""", fifo, one_pool_thread=True)
                try:
                    got = peer.next_line(VM_WAIT_SECONDS)
                except AssertionError:
                    got = None
                self.assertEqual(code, 0, mode + "\n" + errors)
                if mode == "slow":
                    self.assertEqual(output, "ok()\n", errors)
                    self.assertEqual(got, "327680")
                else:
                    self.assertRegex(output, re.compile(r'^error\("error writing to stream port.*Broken pipe', re.S))

    def test_a_crash_cancels_a_task_parked_on_a_fifo_read_and_frees_its_descriptor(self):
        root = self.new_dir()
        fifo = root / "fifo"
        path = root / "plain.txt"
        os.mkfifo(fifo)
        code, output, errors = self.run_vm_bounded(root, r"""def reader(path: String) -> Result[String]
  text = File.read_text(path, 60000)
  puts("the read returned")
  return text
end

def parent(path: String) -> Int
  Task.spawn(&reader, path)
  Task.sleep(300)
  zero = String.length("")
  return 1 / zero
end

def count() -> Int
  return Dir.list("@FD_ROOT@", 1000).unwrap!.length
end

def main() -> Void
  fifo = System.args()[0]
  keep = File.open(fifo, "read", 1000).unwrap!
  holder = File.open(fifo, "append", 1000).unwrap!
  before = count()
  Task.spawn(&parent, fifo)
  Task.sleep(150)
  IO.inspect(count() - before)
  Task.sleep(450)
  IO.inspect(count() - before)
  IO.inspect(File.write_text(System.args()[1], "x", 1000))
end
""", fifo, path, one_pool_thread=True)
        self.assertEqual(code, 1, errors)
        self.assertEqual(output, "1\n0\nok()\n", "the read parks with one descriptor, and the cancel closes it")

    def test_stdin_waits_on_the_loop_so_file_calls_run_while_a_task_waits_for_input(self):
        root = self.new_dir()
        path = root / "plain.txt"
        code, output, errors = self.run_vm_bounded(root, r"""def reader(n: Int) -> Int
  IO.inspect(IO.gets())
  return n
end

def main() -> Void
  Task.spawn(&reader, 1)
  Task.sleep(50)
  IO.inspect(File.write_text(System.args()[0], "x", 1000))
  IO.inspect(File.read_text(System.args()[0], 1000))
end
""", path, one_pool_thread=True, keep_stdin=True)
        self.assertEqual((code, output), (0, 'ok()\nok("x")\n'), errors)

    def test_file_calls_cannot_reopen_the_vms_own_pipes_so_a_later_spawn_does_not_deadlock(self):
        root = self.new_dir()
        code, output, errors = self.run_vm_bounded(root, r"""def main() -> Void
  for name in Dir.list("@FD_ROOT@", 1000).unwrap!
    if name != "0" and name != "1" and name != "2"
      path = "@FD_ROOT@/" + name
      IO.inspect([File.read_text(path, 100).ok?, File.open(path, "append", 100).ok?])
    end
  end
  p = Process.spawn("true", [], 1000).unwrap!
  IO.inspect(Process.wait(p, 1000))
end
""", peer="clean")
        lines = output_lines(output)
        self.assertEqual(code, 0, errors)
        self.assertEqual(lines[-1], "ok(0)")
        self.assertEqual(list(dict.fromkeys(lines[:-1])), ["[false, false]"])

    def test_pipes_the_vm_got_at_start_stay_readable_an_inherited_descriptor_and_a_piped_stdin(self):
        root = self.new_dir()
        program = r"""def main() -> Void
  f = File.open(System.args()[0], "read", 1000).unwrap!
  IO.inspect(File.read_line(f, 1000))
end
"""
        code, output, errors = self.run_vm_bounded(root, program, peer="inherit")
        self.assertEqual((code, output), (0, 'ok("inherited")\n'), errors)
        code, output, errors = self.run_vm_bounded(root, program, "/dev/stdin", stdin_text="piped\n")
        self.assertEqual((code, output), (0, 'ok("piped")\n'), errors)

    def test_file_summary_example_reads_a_command_line_path(self):
        input_path = EXAMPLES / "hello.agc"
        output = self.run_program((EXAMPLES / "file-summary.agc").read_text(encoding="utf-8"), [input_path])
        self.assertEqual(output, "%d\n" % len(input_path.read_text(encoding="utf-8")))

    def test_file_streams_whole_text_helpers_directories_metadata_and_paths_work_together(self):
        root = self.new_dir()
        directory = root / "nested" / "data"
        path = directory / "notes.txt"
        unnormalized = "%s/nested/../nested/data" % root
        output = self.run_program(r"""def main() -> Void
  made: Result[Void] = Dir.mkdir(%s, 1000)
  made_again: Result[Void] = Dir.mkdir(%s, 1000)
  opened: Result[FileHandle] = File.open(%s, "write", 1000)
  handle: FileHandle = Result.unwrap!(opened)
  wrote: Result[Void] = File.write(handle, "alpha\n", 1000)
  wrote_bytes: Result[Void] = File.write_bytes(handle, [98, 101, 116, 97], 1000)
  closed: Result[Void] = File.close(handle, 1000)
  closed_again: Result[Void] = File.close(handle, 1000)
  appended: Result[Void] = File.append_text(%s, "\nend", 1000)
  text: Result[String] = File.read_text(%s, 1000)
  info: Result[FileInfo] = File.stat(%s, 1000)
  entries: Result[List[String]] = Dir.list(%s, 1000)
  joined: Result[String] = Path.join([%s, "notes.txt"])
  resolved: Result[String] = Path.resolve(%s)
  IO.inspect(Result.ok?(made) and Result.ok?(made_again) and Result.ok?(wrote) and Result.ok?(wrote_bytes) and Result.ok?(closed) and Result.ok?(closed_again) and Result.ok?(appended))
  IO.inspect(text)
  IO.inspect(info)
  IO.inspect(entries)
  IO.inspect(joined)
  IO.inspect(resolved)
end

""" % tuple(literal(item) for item in (directory, directory, path, path, path, path, unnormalized, directory,
                                         unnormalized)))
        self.assertIn("true\n", output)
        self.assertIn('ok("alpha\\nbeta\\nend")', output)
        self.assertIn('FileInfo(kind: "file", size_bytes: 14', output)
        self.assertIn('ok(["notes.txt"])', output)
        self.assertIn("ok(%s)" % literal(path), output)
        self.assertIn("ok(%s)" % literal(directory), output)

    def test_invalid_modes_closed_handles_invalid_utf8_and_whole_file_bounds_return_errors(self):
        root = self.new_dir()
        path = root / "bad.txt"
        large = root / "large.txt"
        large.write_bytes(b"x" * 1048577)
        output = self.run_program(r"""def main() -> Void
  invalid_mode: Result[FileHandle] = File.open(%s, "readwrite", 1000)
  opened: Result[FileHandle] = File.open(%s, "write", 1000)
  handle: FileHandle = Result.unwrap!(opened)
  wrote: Result[Void] = File.write_bytes(handle, [255], 1000)
  closed: Result[Void] = File.close(handle, 1000)
  closed_read: Result[List[Int]] = File.read_bytes(handle, 1, 1000)
  invalid_utf8: Result[String] = File.read_text(%s, 1000)
  oversized: Result[String] = File.read_text(%s, 1000)
  IO.inspect(invalid_mode)
  IO.inspect(closed_read)
  IO.inspect(invalid_utf8)
  IO.inspect(oversized)
end

""" % (literal(path), literal(path), literal(path), literal(large)))
        self.assertIn("error(", output)
        self.assertIn("file handle is closed", output)
        self.assertIn("UTF-8", output)
        self.assertIn("1048576", output)

    def test_bounded_stream_reads_and_line_decoding_preserve_eof_semantics(self):
        path = self.new_dir() / "lines.txt"
        path.write_bytes(b"one\r\ntwo\nlast")
        output = self.run_program(r"""def main() -> Void
  opened: Result[FileHandle] = File.open(%s, "read", 1000)
  handle: FileHandle = Result.unwrap!(opened)
  first: Result[String] = File.read_line(handle, 1000)
  second: Result[String] = File.read_line(handle, 1000)
  rest: Result[List[Int]] = File.read_bytes(handle, 100, 1000)
  eof: Result[List[Int]] = File.read_bytes(handle, 100, 1000)
  closed: Result[Void] = File.close(handle, 1000)
  IO.inspect(first)
  IO.inspect(second)
  IO.inspect(rest)
  IO.inspect(eof)
end

""" % literal(path))
        self.assertIn('ok("one")', output)
        self.assertIn('ok("two")', output)
        self.assertIn("ok([108, 97, 115, 116])", output)
        self.assertIn("ok([])", output)

    def test_file_operations_follow_symlinks_to_regular_files(self):
        root = self.new_dir()
        target = root / "target.txt"
        alias = root / "alias.txt"
        target.write_text("linked")
        os.symlink(target, alias)
        output = self.run_program(r"""def main() -> Void
  contents: Result[String] = File.read_text(%s, 1000)
  info: Result[FileInfo] = File.stat(%s, 1000)
  IO.inspect(contents)
  IO.inspect(info)
end

""" % (literal(alias), literal(alias)))
        self.assertIn('ok("linked")', output)
        self.assertIn('FileInfo(kind: "file", size_bytes: 6', output)

    def test_empty_files_read_as_empty_text_and_relative_symlinks_resolve_from_the_link_directory(self):
        root = self.new_dir()
        nested = root / "nested"
        empty = root / "empty.txt"
        target = nested / "target.txt"
        alias = nested / "alias.txt"
        nested.mkdir()
        empty.write_text("")
        target.write_text("linked")
        os.symlink("target.txt", alias)
        output = self.run_program(r"""def main() -> Void
  empty: Result[String] = File.read_text(%s, 1000)
  linked: Result[String] = File.read_text(%s, 1000)
  IO.inspect(empty)
  IO.inspect(linked)
end

""" % (literal(empty), literal(alias)))
        self.assertIn('ok("")', output)
        self.assertIn('ok("linked")', output)

    def test_path_real_gives_what_pythons_os_path_realpath_gives_through_link_chains_loops_and_long_paths(self):
        root = self.new_dir()
        directory = str(root)
        (root / "real" / "dir").mkdir(parents=True)
        (root / "real" / "dir" / "file.txt").write_text("data")
        links = [("../real/dir/file.txt", "real", "rel"), ("../..", "real", "dir", "up"), ("real/dir", "link2"),
                 ("link2", "link1"), ("loop2", "loop1"), ("loop1", "loop2"), ("nowhere", "dangling"), (".", "self"),
                 ("/", "slash"), ("link1/file.txt", "file-link")]
        for target, *parts in links:
            os.symlink(target, root.joinpath(*parts))
        os.symlink(str(root / "real" / "dir"), root / "abs")

        def repeat(part):
            return part * 1500

        items = [".", "./", "..", "../", "real", "real/", "real/dir/file.txt", "real/dir/../dir/./file.txt",
                 "real/rel", "real/dir/up", "real/dir/up/real", "link1", "link1/", "link1/file.txt", "link1/..",
                 "link2/../rel", "abs", "abs/file.txt", "abs/../rel", "file-link", "loop1", "loop1/x", "dangling",
                 "dangling/x", "self", "self/self/self/real", "slash", "slash/", "slash/.", "missing",
                 "real/missing", "real/dir/file.txt/x",
                 directory + "/link1/file.txt", directory + "/link1/../rel",
                 "real" + repeat("/dir/.."), "real/dir" + repeat("/../dir")]
        seen = self.os_lines("real", items, cwd=root)
        self.assertEqual(seen, self.os_peer_lines("real", items, cwd=root))
        table = dict(zip(items, seen))
        real_root = table["."][3:]

        def ok_at(suffix):
            return "ok:" + real_root + suffix

        self.assertEqual(table["link1"], ok_at("/real/dir"))
        self.assertEqual(table["link1/file.txt"], ok_at("/real/dir/file.txt"))
        self.assertEqual(table["link1/.."], ok_at("/real"))
        self.assertEqual(table["abs/../rel"], ok_at("/real/dir/file.txt"))
        self.assertEqual(table["real/dir/up"], ok_at(""))
        self.assertEqual(table["slash"], "ok:/")
        self.assertEqual(table["loop1"], "error")
        self.assertEqual(table["dangling"], "error")
        self.assertEqual(table["real/dir/file.txt/x"], "error")
        self.assertEqual(seen[len(items) - 2], ok_at("/real"))
        self.assertEqual(seen[-1], ok_at("/real/dir"))

    def test_system_env_gives_what_pythons_os_environ_gives_decoding_bytes_that_are_not_utf_8_with_u_fffd(self):
        env = vm_environment()
        # Not vm_environment(extra): it turns values into str, so bytes would become "b'..'" and lose the non-UTF-8 cases.
        env.update({
            "AGC_PEER_SET": b"plain", "AGC_PEER_EMPTY": b"", "AGC_PEER_EQ": b"x=y=", "AGC_PEER_SPACE": b"  padded  ",
            "AGC_PEER_UNI": "h\u00e9llo \u2713 \u65e5\u672c".encode("utf-8"),
            "AGC_PEER_BAD": b"a\xffb", "AGC_PEER_BAD2": b"\xc3(", "AGC_PEER_BAD3": b"x\xe2\x82",
            "AGC_PEER_LONG": b"v" * 100000})
        items = ["AGC_PEER_SET", "AGC_PEER_EMPTY", "AGC_PEER_EQ", "AGC_PEER_SPACE", "AGC_PEER_UNI", "AGC_PEER_BAD",
                 "AGC_PEER_BAD2", "AGC_PEER_BAD3", "AGC_PEER_LONG", "AGC_PEER_UNSET", "agc_peer_set", "AGC_PEER",
                 "AGC_PEER_SET_", "", "=", "AGC_PEER_SET=plain"]
        seen = self.os_lines("env", items, env=env)
        self.assertEqual(brief(seen), brief(self.os_peer_lines("env", items, env=env)))
        self.assertEqual(seen[:3], ["ok:plain", "ok:", "ok:x=y="])
        self.assertEqual(seen[5], "ok:a\ufffdb")
        self.assertEqual(seen[9:], ["error"] * 7)

    def test_system_env_does_not_show_the_variables_the_vm_keeps_for_itself(self):
        def seen(name, env):
            return self.os_lines("env", [name], env=env)[0]

        self.assertEqual(seen("UV_USE_IO_URING", vm_environment({"UV_USE_IO_URING": None})), "error")
        self.assertEqual(seen("UV_USE_IO_URING", vm_environment({"UV_USE_IO_URING": "1"})), "ok:1")
        self.assertEqual(seen("AGENTICA_CHANNEL", vm_environment({"AGENTICA_CHANNEL": "3"})), "error")

    def test_the_end_of_a_run_flushes_and_closes_an_unclosed_file_handle(self):
        path = self.new_dir() / "cleanup.txt"
        self.run_program(r"""def main() -> Void
  opened: Result[FileHandle] = File.open(%s, "write", 1000)
  handle: FileHandle = Result.unwrap!(opened)
  wrote: Result[Void] = File.write(handle, "cleanup", 1000)
end

""" % literal(path))
        self.assertEqual(path.read_text(), "cleanup")
