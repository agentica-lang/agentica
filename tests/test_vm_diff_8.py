"""Shard 8 of the VM golden tests: the VM command line, the product CLI and the cases that need more than a fixture.

(Ported from run-extras of vm-diff-common.rkt.) The programs are compiled with the product CLI and run on the VM
directly, or through the CLI where the test is about the CLI. The VM runs have the scratch folder of the test as working
directory.
"""
import json
import os
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import unittest

from tests.agentica_test import (RUN_TIMEOUT, TESTS, Child, cli, process_alive, scaled, vm_binary, vm_environment,
                                 wait_until)
from tests.vm_diff_support import (
    EXTRAS_SHARD, FIXTURE_DIR, HEAVY_FIXTURES, LIGHT_SHARD_ROTATION, SHARD_COUNT, Fixture, VmCase, check_text_format,
    decode, exit_status, execute, fixture_programs, last_limit, outcome, read_expected, read_expected_steps,
    run_fixture_vm, run_vm, run_vm_process, runaway_programs, step_limited, total_steps, style_options,
    shard_assignment)

LINUX = sys.platform.startswith("linux")
PLAIN = Fixture()
ALLOWED = Fixture(allow_run=True)


def words(text):
    """The non-empty lines of a text, as Racket's string-split with "\\n" gives them at the ends."""
    return text.strip("\n").split("\n") if text.strip("\n") else []


def gone(pid):
    return wait_until(lambda: not process_alive(pid), scaled(5))


def kill_alive(pids):
    for pid in pids:
        if process_alive(pid):
            try:
                os.kill(int(pid), signal.SIGKILL)
            except ProcessLookupError:
                pass


class Extras(VmCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        vm_binary()

    def program(self, name, text):
        """Write a program into the scratch folder and compile it; returns the bytecode path."""
        source = self.work_dir() / (name + ".agc")
        source.write_text(text, encoding="utf-8")
        return self.bytecode_of(source)

    def fixture_bytecode(self, name):
        return self.bytecode_of(FIXTURE_DIR / (name + ".agc"))

    def vm(self, *argv, timeout=RUN_TIMEOUT):
        """The VM with the given words (options, "--", file, arguments) and nothing else."""
        return execute([vm_binary(), *argv], cwd=self.work_dir(), env=vm_environment(), timeout=timeout)

    def test_shard_tables_name_real_fixtures_and_shards(self):
        names = [program.name for program, _shard in shard_assignment(fixture_programs())]
        for heavy, shard in HEAVY_FIXTURES.items():
            self.assertIn(heavy, names)
            self.assertTrue(1 <= shard <= SHARD_COUNT, heavy)
        for shard in LIGHT_SHARD_ROTATION:
            self.assertTrue(1 <= shard <= SHARD_COUNT, "light shard %d" % shard)
        for shard in range(1, SHARD_COUNT + 1):
            module = TESTS / ("test_vm_diff_%d.py" % shard)
            self.assertTrue(module.is_file(), str(module))
            if shard != EXTRAS_SHARD:
                self.assertIn("shard_case(%d)" % shard, module.read_text(encoding="utf-8"), str(module))

    def test_compile_gives_the_same_bytes_every_time(self):
        for name in ["imports", "io-gets", "enums-case"]:
            program = FIXTURE_DIR / (name + ".agc")
            first = self.bytecode_of(program, name + "-one")
            second = self.bytecode_of(program, name + "-two")
            self.assertEqual(first.read_bytes(), second.read_bytes(), name)

    def test_the_vm_reads_piped_stdin_like_the_file_redirect(self):
        for name in ["io-read", "io-rest"]:
            program = FIXTURE_DIR / (name + ".agc")
            fixture = Fixture(input=(FIXTURE_DIR / (name + ".stdin")).read_bytes())
            bytecode = self.bytecode_of(program, name + "-pipe")
            self.assertEqual(outcome(run_vm(fixture, bytecode, None, cwd=self.work_dir())), read_expected(program), name)

    def test_runaway_loops_stop_at_max_steps_with_a_prefix_of_their_expected_output(self):
        for program in runaway_programs():
            with self.subTest(program.name):
                self.check_runaway(program)

    def test_the_vm_command_line_checks_options_and_stops_parsing_at_the_file(self):
        bytecode = str(self.fixture_bytecode("calls"))
        self.assertEqual(run_vm(PLAIN, bytecode, None, extra=["--max-steps", "1"], cwd=self.work_dir())[0], 0)
        for options in [["--max-steps", "0"], ["--bogus"], ["--ai", "--ai"], ["--max-steps", "5", "--max-steps", "5"],
                        ["--seed", "1", "--seed", "1"]]:
            self.assertEqual(self.vm(*options, "--", bytecode)[0], 2, options)
        for seed in ["-1", "2147483648", "1x", "", "99999999999999999999"]:
            rejected = self.vm("--seed", seed, "--", bytecode)
            self.assertEqual(rejected[0], 2, seed)
            self.assertEqual(rejected[2], "agentica-vm: --seed needs an integer from 0 to 2147483647\n", seed)
        draws = self.program(
            "random-draws", "def main() -> Void\n  puts(Random.int(0, 1000000000))\n  puts(Random.float)\nend\n")

        def seeded(seed):
            return self.vm("--seed", seed, "--", str(draws))

        self.assertEqual(seeded("0002147483647")[0], 0)
        self.assertEqual(seeded("7"), seeded("7"))
        self.assertNotEqual(seeded("7")[1], seeded("8")[1])

    def test_tests_draw_the_same_values_alone_or_with_others(self):
        tests = self.program(
            "seeded-tests",
            "def main() -> Void\n  Test.run([\n"
            "    Test.test(\"a\") do\n      puts(Random.int(0, 1000000000))\n      ok()\n    end,\n"
            "    Test.test(\"b\") do\n      puts(Random.int(0, 1000000000))\n      ok()\n    end\n"
            "  ])\nend\n")

        def test_draws(seed, order, label):
            feed = self.work_dir() / ("seeded-%s.channel" % label)
            feed.write_bytes(order)
            run = run_vm_process(Fixture(channel=feed), ["--seed", seed], tests, ["--agentica-test", "run"],
                                 cwd=self.work_dir())
            self.assertEqual(run[0], 0, run[2])
            return [line for line in words(run[1]) if not line.startswith("channel> ")]

        alone = test_draws("7", b"1\n", "alone")
        mixed = test_draws("7", b"0\n1\n1\n", "mixed")
        self.assertEqual([mixed[1], mixed[2]], [alone[0], alone[0]])
        self.assertNotEqual(mixed[0], mixed[1])
        self.assertNotEqual(test_draws("8", b"1\n", "other"), alone)

    def test_a_duplicate_test_name_is_reported_at_its_source(self):
        duplicate = self.fixture_bytecode("test-name-duplicate")
        named = self.vm("--json", "--", str(duplicate), "--agentica-test", "run")
        start = json.loads(named[2])["range"]["start"]
        self.assertEqual((named[0], start["line"], start["column"]), (1, 9, 5))

    def test_the_vm_options_after_the_file_belong_to_the_program(self):
        bytecode = str(self.fixture_bytecode("calls"))
        limited = self.vm("--max-steps", "1", "--ai", "--json", "--", bytecode)
        self.assertEqual(limited[0], 1)
        self.assertEqual(json.loads(limited[2])["code"], "RUNTIME-STEP-LIMIT")
        self.assertEqual(self.vm("--json", "--", bytecode, "--ai")[2], "")

    def test_a_bytecode_file_may_have_a_non_ascii_name_and_a_bad_one_is_rejected(self):
        bytecode = self.fixture_bytecode("calls")
        unicode_name = self.work_dir() / "cálculo-λ-日本-𝔸.agcb"
        shutil.copy(bytecode, unicode_name)
        self.assertEqual(run_vm(PLAIN, unicode_name, None, cwd=self.work_dir()),
                         run_vm(PLAIN, bytecode, None, cwd=self.work_dir()))
        self.assertEqual(self.vm("--", str(self.work_dir()))[0], 2)
        bad = self.work_dir() / "bad.agcb"
        bad.write_bytes(b"AGCB")
        rejected = self.vm("--", str(bad))
        self.assertEqual(rejected[0], 2)
        self.assertTrue(rejected[2].startswith("agentica-vm: invalid bytecode: "), rejected[2])

    @unittest.skipUnless(LINUX, "Linux only")
    def test_the_hidden_driver_pid_flag_loads_only_a_private_input_and_then_deletes_it(self):
        bytecode = self.fixture_bytecode("calls")
        copy = self.work_dir() / "driver-copy.agcb"

        def driven(pid, path=copy):
            return self.vm("--driver-pid", str(pid), "--", str(path))

        shutil.copy(bytecode, copy)
        copy.chmod(0o600)
        self.assertEqual(driven(os.getpid()), run_vm(PLAIN, bytecode, None, cwd=self.work_dir()))
        self.assertFalse(copy.exists())
        shutil.copy(bytecode, copy)
        copy.chmod(0o644)
        self.assertEqual(driven(os.getpid())[0], 2)
        self.assertTrue(copy.exists())
        copy.chmod(0o600)
        self.assertEqual(driven(os.getpid() + 1)[0], 2)
        self.assertTrue(copy.exists())
        link = self.work_dir() / "driver-link.agcb"
        os.symlink(copy, link)
        self.assertEqual(driven(os.getpid(), link)[0], 2)
        self.assertTrue(copy.exists())

    @unittest.skipUnless(LINUX, "Linux only")
    def test_a_read_stuck_on_a_fifo_times_out_closes_the_handle_and_does_not_hold_the_vm_at_exit(self):
        bytecode = self.program(
            "fifo-stuck",
            "def main() -> Void\n  input = Result.unwrap!(File.open(System.args()[0], \"read\", 60000))\n"
            "  IO.inspect(File.read_bytes(input, 4, 300))\n  IO.inspect(File.read_line(input, 300))\n"
            "  IO.inspect(File.close(input, 300))\n  puts(\"done\")\nend\n")
        fifo = self.work_dir() / "stuck-fifo"
        os.mkfifo(fifo)
        # Held open for reading and writing, so the VM's read blocks instead of ending at once.
        held = os.open(fifo, os.O_RDWR)
        self.addCleanup(os.close, held)
        started = time.monotonic()
        result = run_vm(Fixture(args=(str(fifo),)), bytecode, None, cwd=self.work_dir())
        self.assertEqual(outcome(result)[:3], (
            0, "error(\"filesystem: operation timed out\")\nerror(\"filesystem: file handle is closed\")\nok()\ndone\n",
            ""))
        self.assertLess(time.monotonic() - started, scaled(20))

    @unittest.skipUnless(LINUX, "Linux only")
    def test_process_spawn_searches_path_only_and_resolves_a_name_with_a_slash_against_the_working_directory(self):
        bytecode = self.program(
            "path-lookup",
            "def show(name: String) -> Void\n  case Process.spawn(name, [\"x\"], 60000)\n"
            "    ok(p) ->\n      puts(\"#{name}: #{Process.read_line(p, 60000)} #{Process.wait(p, 60000)}\")\n"
            "      Process.close(p)\n    error(message) -> puts(\"#{name}: #{message}\")\n  end\nend\n\n"
            "def main() -> Void\n  show(\"agc-tool\")\n  show(\"./agc-tool\")\n  show(\"bin/agc-tool\")\n  show(\"bin\")\nend\n")
        folder = self.work_dir() / "lookup"
        (folder / "bin").mkdir(parents=True)
        for file in [folder / "agc-tool", folder / "bin" / "agc-tool"]:
            file.write_text("#!/bin/sh\necho \"ran $1\"\n", encoding="utf-8")
            file.chmod(0o755)

        def expected(found):
            return (0, "agc-tool: " + ("ok(\"ran x\") ok(0)" if found else "process: executable is unavailable")
                    + "\n./agc-tool: ok(\"ran x\") ok(0)\nbin/agc-tool: ok(\"ran x\") ok(0)\n"
                    + "bin: process: executable is unavailable\n", "")

        none = str(folder / "none")
        for search in [none, ":" + none, "bin:" + none, ".:" + none]:
            want = expected(search.startswith("bin:") or search.startswith(".:"))
            self.assertEqual(run_vm(ALLOWED, bytecode, None, cwd=folder, env={"PATH": search}), want, search)

    @unittest.skipUnless(LINUX, "Linux only")
    def test_a_program_that_is_stopped_by_sigterm_kills_the_vms_running_children(self):
        program = self.work_dir() / "signal-children.agc"
        program.write_text(
            "def main() -> Void\n  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"echo $$; exec sleep 30\"], 60000))\n"
            "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n  Task.sleep(20000)\nend\n",
            encoding="utf-8")
        driver = self.adopt(Child(
            cli() + ["--allow-run", program], env=vm_environment({"TMPDIR": self.work_dir(), "AGENTICA_VM": vm_binary()}),
            cwd=self.work_dir(), capture_stderr=True))
        pid = driver.next_line(RUN_TIMEOUT)
        self.addCleanup(kill_alive, [pid])
        self.assertTrue(process_alive(pid))
        os.kill(driver.process.pid, signal.SIGTERM)
        driver.wait(RUN_TIMEOUT)
        self.assertTrue(gone(pid), pid)

    @unittest.skipUnless(LINUX, "Linux only")
    def test_closing_a_captured_vm_child_sends_sigterm_first_so_the_child_stops_its_own_children(self):
        inner = self.program(
            "captured-inner",
            "def main() -> Void\n"
            "  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"echo $PPID $$; exec sleep 30\"], 60000))\n"
            "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n  Task.sleep(5000)\nend\n")
        outer = self.program(
            "captured-outer",
            "def main() -> Void\n  args = System.args()\n"
            "  child = Result.unwrap!(Process.spawn_captured(args[0], [\"--allow-run\", \"--\", args[1]], \".\", 60000))\n"
            "  puts(Result.unwrap!(Process.read_line(child, 60000)))\n"
            "  if args[2] == \"close\"\n    Process.close(child)\n  else\n    IO.inspect(Process.read_line(child, 200))\n  end\nend\n")
        for mode in ["close", "timeout"]:
            with self.subTest(mode):
                pids = []
                self.addCleanup(lambda found=pids: kill_alive(found))
                result = run_vm(ALLOWED, outer, None, extra=[str(vm_binary()), str(inner), mode], cwd=self.work_dir())
                lines = words(result[1])
                pids.extend(word for word in (lines[0].split() if lines else []) if word.isdigit())
                self.assertEqual(result[0], 0, mode)
                self.assertEqual(lines[1:], [] if mode == "close" else ['error("network: operation timed out")'], mode)
                self.assertEqual(len(pids), 2, mode)
                for pid in pids:
                    self.assertTrue(gone(pid), "%s: %s" % (mode, pid))

    @unittest.skipUnless(LINUX, "Linux only")
    def test_close_never_waits_for_a_captured_child_and_one_that_ignores_sigterm_gets_sigkill_a_second_later(self):
        bytecode = self.program(
            "captured-grace",
            "def main() -> Void\n  mode = System.args()[0]\n"
            "  script = \"trap '' TERM; echo $$; exec sleep 30\"\n"
            "  if mode == \"quick\"\n    script = \"echo $$; exec sleep 30\"\n  end\n"
            "  p = Result.unwrap!(Process.spawn_captured(\"/bin/sh\", [\"-c\", script], \".\", 60000))\n"
            "  pid = Result.unwrap!(Process.read_line(p, 60000))\n  puts(pid)\n  IO.flush()\n"
            "  start = Time.monotonic_ms()\n  Process.close(p)\n  puts(Time.monotonic_ms() - start)\n"
            "  if mode == \"wait\"\n    Task.sleep(1500)\n"
            "    puts(Result.ok?(File.stat(\"/proc/#{pid}\", 60000)))\n  end\nend\n")
        traced = "trace off" not in self.vm("--version")[1]
        for mode in ["wait", "exit", "quick"]:
            with self.subTest(mode):
                pids = []
                self.addCleanup(lambda found=pids: kill_alive(found))
                result = run_vm(ALLOWED, bytecode, None, extra=[mode], cwd=self.work_dir(), env={"AGENTICA_VM_TRACE": "io"})
                lines = words(result[1])
                if lines and lines[0].isdigit():
                    pids.append(lines[0])
                self.assertEqual(result[0], 0, mode)
                self.assertEqual(len(pids), 1, mode)
                self.assertTrue(len(lines) >= 2 and int(lines[1]) < 500, "%s: %s" % (mode, lines))
                self.assertEqual(lines[2:], ["false"] if mode == "wait" else [], mode)
                self.assertTrue(gone(pids[0]), mode)
                if traced:
                    self.assertRegex(result[2], r" io end code=0 signal=0", mode)

    @unittest.skipUnless(LINUX, "Linux only")
    def test_an_output_timeout_keeps_the_captured_child_and_output_decodes_invalid_utf8_as_ufffd(self):
        bytecode = self.program(
            "captured-output",
            "def main() -> Void\n"
            "  p = Result.unwrap!(Process.spawn_captured(\"/bin/sh\", [\"-c\", \"printf '\\\\377' >&2; sleep 1; echo hi\"], \".\", 60000))\n"
            "  IO.inspect(Process.output(p, 50))\n  out = Result.unwrap!(Process.output(p, 60000))\n"
            "  puts(\"#{out.stdout.inspect} #{out.stderr.length} #{String.code(out.stderr)} #{out.truncated}\")\n"
            "  Process.close(p)\nend\n")
        self.assertEqual(run_vm(ALLOWED, bytecode, None, cwd=self.work_dir()),
                         (0, "error(\"network: operation timed out\")\n\"hi\\n\" 1 65533 false\n", ""))

    @unittest.skipUnless(LINUX, "Linux only")
    def test_a_signal_caught_while_the_vm_is_blocked_is_not_lost_when_the_last_child_exits_first(self):
        bytecode = self.program(
            "signal-pending",
            "def main() -> Void\n  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", \"echo $$; exec sleep 30\"], 60000))\n"
            "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  IO.flush()\n"
            "  puts(String.join(List.repeat(\"x\", 1048576), \"\"))\n  puts(\"survived\")\nend\n")
        # Nothing reads the VM's stdout after the first line, so its 1 MiB write blocks: the state under test.
        vm = self.adopt(Child([vm_binary(), "--allow-run", "--", bytecode], env=vm_environment(),
                              cwd=self.work_dir(), read_stdout=False))
        pid = vm.process.stdout.readline().decode().strip()
        self.addCleanup(kill_alive, [pid])
        self.assertTrue(pid.isdigit(), pid)
        time.sleep(0.5)
        os.kill(int(pid), signal.SIGKILL)
        time.sleep(0.3)
        os.kill(vm.process.pid, signal.SIGTERM)
        threading.Thread(target=vm.process.stdout.read, daemon=True).start()
        self.assertEqual(exit_status(vm.wait(RUN_TIMEOUT)), 128 + signal.SIGTERM)

    @unittest.skipUnless(LINUX, "Linux only")
    def test_a_child_does_not_inherit_descriptors_the_vm_inherited(self):
        bytecode = self.program(
            "private-fds",
            "def main() -> Void\n  p = Result.unwrap!(Process.spawn(\"/bin/sh\", [\"-c\", "
            "\"if [ -e /proc/self/fd/7 ]; then echo leaked; else echo private; fi\"], 60000))\n"
            "  puts(Result.unwrap!(Process.read_line(p, 60000)))\n  Process.close(p)\nend\n")
        result = execute(["/bin/sh", "-c", "exec 7</dev/null; exec \"$0\" --allow-run -- \"$1\"", vm_binary(), bytecode],
                         cwd=self.work_dir(), env=vm_environment())
        self.assertEqual(result, (0, "private\n", ""))

    @unittest.skipUnless(LINUX, "Linux only")
    def test_relative_file_paths_use_the_raw_bytes_of_a_non_utf8_working_directory(self):
        bytecode = self.program(
            "raw-cwd",
            "def main() -> Void\n  IO.inspect(File.write_text(\"a.txt\", \"hi\", 60000))\n"
            "  IO.inspect(File.read_text(\"a.txt\", 60000))\nend\n")
        folder = self.work_dir() / os.fsdecode(b"raw-\xff")
        folder.mkdir()
        self.assertEqual(run_vm(PLAIN, bytecode, None, cwd=folder), (0, "ok()\nok(\"hi\")\n", ""))
        self.assertEqual((folder / "a.txt").read_text(encoding="utf-8"), "hi")

    @unittest.skipUnless(LINUX, "Linux only")
    def test_the_vm_decodes_invalid_utf8_arguments_like_racket_in_a_utf8_locale(self):
        program = FIXTURE_DIR / "system-args.agc"
        bytecode = self.bytecode_of(program)
        arguments = [b"\xff\xfeZ", b"\xe2\x82A", b"\xed\xa0\x80z", b"a\xe2\x82", b"\xf0\x9f\x98", b"\xe0\x80",
                     b"\xf0\x80\x80", b"\xed\xa0", b"\xf4\x90", b"\xc0\xaf", b"\xe2\x82\xe2\x82", b"\xe2\x82\xac"]
        environment = vm_environment({"LC_ALL": "C.UTF-8"})
        on_vm = execute([vm_binary(), "--", bytecode, *arguments], cwd=self.work_dir(), env=environment)
        on_cli = execute(cli() + [program, *arguments], cwd=self.work_dir(), env=environment)
        self.assertEqual(outcome(on_vm), outcome(on_cli))

    def test_deep_tail_calls_run_on_the_vm(self):
        bytecode = self.program(
            "deep-tail",
            "def loop(n: Int, acc: Int) -> Int\n  if n == 0\n    return acc\n  end\n  return loop(n - 1, acc + 1)\nend\n\n"
            "def even(n: Int) -> Bool\n  if n == 0\n    return true\n  end\n  return odd(n - 1)\nend\n\n"
            "def odd(n: Int) -> Bool\n  if n == 0\n    return false\n  end\n  return even(n - 1)\nend\n\n"
            "def main() -> Void\n  puts(loop(1000000, 0))\n  puts(even(1000001))\nend\n")
        self.assertEqual(run_vm(PLAIN, bytecode, None, cwd=self.work_dir()), (0, "1000000\nfalse\n", ""))

    def test_string_at_and_slice_over_a_long_non_ascii_string_on_the_vm(self):
        bytecode = self.program(
            "string-cursor",
            "def main() -> Void\n  s = \"é😀\"\n  i = 0\n  while i < 15\n    s = s + s\n    i += 1\n  end\n"
            "  n = s.length\n  total = 0\n  j = 0\n  while j < n\n    total += s.at(j).code\n    j += 1\n  end\n"
            "  j = n - 1\n  while j >= 0\n    total += s.slice(j, 1).code\n    j -= 1\n  end\n"
            "  puts(\"#{n} #{total}\")\nend\n")
        self.assertEqual(run_vm(PLAIN, bytecode, None, cwd=self.work_dir()),
                         (0, "65536 %d\n" % (2 * 32768 * (233 + 128512)), ""))

    def test_large_generated_input_splits_and_decodes_lines_across_buffer_boundaries(self):
        bytecode = self.program(
            "large-input",
            "def main() -> Void\n  count = 0\n  running = true\n  while running\n    case gets()\n"
            "      ok(line) -> puts(\"#{count}: #{line.inspect}\")\n"
            "      error(message) ->\n        puts(message)\n        running = false\n    end\n"
            "    count = count + 1\n  end\n  puts(count)\nend\n")
        data = (b"a" * 65535 + b"\xe2\x82\xac\n" + b"b" * 65535 + b"\r\n" + b"c" * 65535 + b"\rnext\n"
                + b"d" * 65534 + b"\xf0\x9f\x98\x80\xff\xe2\x82\n"
                + b"".join(b"line %d\r\n" % k for k in range(20000)) + b"tail \xe2\x82")
        lines = re.split(rb"\r\n|\r|\n", data)
        stdout = "".join('%d: "%s"\n' % (k, decode(line)) for k, line in enumerate(lines))
        stdout += "IO.gets reached the end of input\n%d\n" % (len(lines) + 1)
        fixture = Fixture(input=data)
        full = (0, stdout, "", None)
        self.assertEqual(outcome(run_vm(fixture, bytecode, None, cwd=self.work_dir())), full, "large input")
        for limit in [1, 50, 100000, 400000]:
            self.check_limited(run_vm(fixture, bytecode, limit, cwd=self.work_dir()), full, "large input", limit)

    def test_a_crlf_program_under_a_non_ascii_path_gives_the_expected_outcome(self):
        folder = self.work_dir() / "dír-λ-𝔸"
        folder.mkdir()
        program = folder / "división-日本.agc"
        original = FIXTURE_DIR / "division-by-zero.agc"
        program.write_bytes(original.read_text(encoding="utf-8").replace("\n", "\r\n").encode("utf-8"))
        bytecode = self.bytecode_of(program)
        full = read_expected(original)
        self.assertEqual(full[3], "RUNTIME-DIVISION-BY-ZERO")
        for style in ["plain", "ai", "json"]:
            on_vm = run_vm(PLAIN, bytecode, None, style=style, cwd=self.work_dir())
            if style == "json":
                self.assertEqual(outcome(on_vm), full, style)
            else:
                check_text_format(self, on_vm, full, style)
        work = self.work_dir()
        total = total_steps(lambda limit: step_limited(run_fixture_vm(PLAIN, bytecode, limit, work)))
        expected_steps = read_expected_steps(original)
        self.check_steps(total, expected_steps, "CRLF program")
        limits = [1, total - 1, total, last_limit(expected_steps)]
        self.check_sweep([run_vm(PLAIN, bytecode, limit, cwd=work) for limit in limits], limits, full, "CRLF program")


class CliCase(VmCase):
    """Helpers to run the product CLI with a folder that must stay empty as its temporary directory."""

    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        vm_binary()

    def setUp(self):
        self.temp = self.make_temp_dir("agentica-cli-").resolve()

    def agentica(self, *argv, stdin=b"", vm=None):
        """The CLI with TMPDIR set to the folder that must stay empty and the VM it should use."""
        environment = vm_environment({"TMPDIR": self.temp, "AGENTICA_VM": vm or vm_binary()})
        return execute(cli() + list(argv), stdin=stdin, cwd=self.work_dir(), env=environment)

    def fixture(self, name):
        return str(FIXTURE_DIR / name)

    def expected(self, name):
        return read_expected(FIXTURE_DIR / name)

    def no_bytecode(self, arguments):
        self.assertEqual([path.name for path in self.temp.glob("*.agcb")], [], "%s leaves no bytecode" % arguments)


class ProductCli(CliCase):
    """The product CLI runs programs on the VM with their expected exit code, stdout and diagnostic code."""

    @unittest.skipUnless(LINUX, "Linux only")
    def test_the_formats_exit_codes_and_diagnostics_of_a_run(self):
        for name in ["calls.agc", "division-by-zero.agc", "linked.agc"]:
            for style in ["plain", "ai", "json"]:
                arguments = style_options(style) + [self.fixture(name)]
                result = self.agentica(*arguments)
                if style == "json":
                    self.assertEqual(outcome(result), self.expected(name), str(arguments))
                else:
                    check_text_format(self, result, self.expected(name), str(arguments))
                self.no_bytecode(arguments)
                if name == "linked.agc":
                    self.assertEqual(result[0], 1)

    @unittest.skipUnless(LINUX, "Linux only")
    def test_options_arguments_and_removed_flags(self):
        calls = self.fixture("calls.agc")
        limited = self.agentica("--json", "--max-steps", "3", calls)
        self.assertEqual((limited[0], outcome(limited)[3]), (1, "RUNTIME-STEP-LIMIT"))
        self.no_bytecode("--max-steps 3")
        with_args = self.agentica("--json", calls, "first", "--allow-run", "--json")
        self.assertEqual(with_args[:2], self.expected("calls.agc")[:2])
        deep = self.work_dir() / "deep.agc"
        deep.write_text(
            "def loop(n: Int, acc: Int) -> Int\n  if n == 0\n    return acc\n  end\n  return loop(n - 1, acc + 1)\nend\n\n"
            "def main() -> Void\n  puts(loop(100000, 0))\nend\n", encoding="utf-8")
        self.assertEqual(self.agentica(str(deep)), (0, "100000\n", ""))
        for removed in ["--vm", "--legacy-eval"]:
            self.assertEqual(self.agentica(removed, str(deep))[:2], (1, ""), removed)
        denied = self.fixture("spawn-denied.agc")
        self.assertEqual(outcome(self.agentica("--json", denied)), self.expected("spawn-denied.agc"))
        self.assertEqual(self.agentica("--allow-run", "--json", denied)[0], 0)
        random = self.fixture("random.agc")
        seeded = self.agentica("--seed", "77", random)
        self.assertEqual(seeded[0], 0)
        self.assertEqual(self.agentica("--seed", "77", random), seeded)
        self.assertEqual(self.agentica("--seed", "2147483648", random)[0], 2)
        self.assertEqual(self.agentica("--max-steps", "0", calls)[0], 2)

    @unittest.skipUnless(LINUX, "Linux only")
    def test_standard_input_exit_codes_and_arguments_reach_the_program(self):
        gets = self.fixture("io-gets.agc")
        data = (FIXTURE_DIR / "io-gets.stdin").read_bytes()
        self.assertEqual(outcome(self.agentica("--json", gets, stdin=data)), self.expected("io-gets.agc"))
        self.assertEqual(self.agentica(self.fixture("system-exit.agc"))[0], 3)
        self.assertEqual(
            self.agentica("--json", self.fixture("system-args.agc"), "a", "", "λ 𝔸", "--json", "--vm"),
            (0, "0 \"a\"\n1 \"\"\n2 \"λ 𝔸\"\n3 \"--json\"\n4 \"--vm\"\n[\"a\", \"\", \"λ 𝔸\", \"--json\", \"--vm\"]\n", ""))
        self.assertEqual(list(self.temp.iterdir()), [])

    def test_compile_exits_1_on_a_diagnostic_and_2_on_an_unwritable_output(self):
        work = self.work_dir()
        rejected_file = work / "file.agc"
        rejected_file.write_text("def main() -> Void\n  c = HTTP.client_options()\nend\n", encoding="utf-8")
        rejected = self.agentica("compile", rejected_file, "-o", work / "out.agcb")
        self.assertEqual(rejected[0], 1)
        self.assertIn("error[CHECK-UNKNOWN-NAME]", rejected[2])
        self.assertFalse((work / "out.agcb").exists())
        supported = work / "hello.agc"
        supported.write_text("def main() -> Void\n  puts(\"hi\")\nend\n", encoding="utf-8")
        self.assertEqual(self.agentica("compile", supported, "-o", work / "missing" / "out.agcb")[0], 2)


@unittest.skipIf(os.environ.get("AGENTICA_TEST_EXECUTABLE"), "the Racket launcher only: step 8d deletes AGENTICA_VM")
class RacketLauncher(CliCase):
    """What only the launcher of src/main.rkt does: it finds the VM by AGENTICA_VM and feeds the VM its stdin."""

    @unittest.skipUnless(LINUX, "Linux only")
    def test_a_missing_or_non_executable_vm_exits_2(self):
        calls = self.fixture("calls.agc")
        missing = self.agentica(calls, vm=self.temp / "no-vm")
        self.assertEqual(missing[0], 2)
        self.assertTrue(missing[2].startswith("agentica: cannot find the VM at "), missing[2])
        plain = self.work_dir() / "plain-vm"
        shutil.copy(vm_binary(), plain)
        plain.chmod(0o644)
        self.assertEqual(self.agentica(calls, vm=plain)[0], 2)

    def test_a_standard_input_that_cannot_be_read_is_an_internal_error(self):
        gets = self.fixture("io-gets.agc")
        # A directory opens for reading and fails on the first read.
        environment = vm_environment({"TMPDIR": self.temp, "AGENTICA_VM": vm_binary()})
        descriptor = os.open(self.work_dir(), os.O_RDONLY)
        try:
            process = subprocess.run(cli() + ["--json", gets], stdin=descriptor, capture_output=True,
                                     env=environment, cwd=self.work_dir(), timeout=RUN_TIMEOUT)
        finally:
            os.close(descriptor)
        self.assertEqual(process.returncode, 1)
        last = decode(process.stderr).strip().split("\n")[-1]
        self.assertEqual(json.loads(last)["code"], "RUNTIME-INTERNAL")

