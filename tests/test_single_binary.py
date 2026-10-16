"""The single binary dist/agentica (35.3 and 35.6): the front end it carries compiles in memory and hands the program
to C, which runs it in a new runtime; `agentica run` runs a compiled file with the VM flags.

The binary is all this module needs, so the sanitizer job can run it on its own build: the command line forms are
frozen in tests/fixtures/cli/forms.json (tests/test_cli_forms.py). The cases use a
front end of their own (tests/fixtures/single-binary/front.agc, loaded with --front-end) to see what the C side does
with the two FrontEnd builtins. The fixed point is not tested here: `make fixed-point` is a step of CI (the test job
and the sanitizer job), where it compiles compiler/ three times next to this module.
"""
import os
import random
import re
import struct
import subprocess

from tests.agentica_test import (FIXTURES, ROOT, STAGE2, TestCase, binary, compile_agc, require, run, run_vm, scaled,
                                 vm_environment)

STDLIB = ROOT / "stdlib"
FRONT = FIXTURES / "single-binary" / "front.agc"
ANOTHER_VERSION = "9.9.9"

EXIT_THREE = 'def main() -> Void\n  puts("before")\n  System.exit(3)\nend\n'
TYPE_ERROR = 'def main() -> Void\n  x: Int = "a"\n  puts(x)\nend\n'
LOOP = "def main() -> Void\n  i = 0\n  while true\n    i += 1\n  end\nend\n"
RANDOM = "def main() -> Void\n  puts(Random.int(0, 1000000))\nend\n"
STDIN_AND_ARGS = (
    'def main() -> Void\n  puts("args #{System.args()}")\n  puts("line #{IO.gets()}")\n  System.exit(3)\nend\n')
SPAWN = (
    "def main() -> Void\n"
    '  r = Process.spawn_captured("sh", ["-c", "echo child"], ".", 5000)\n'
    "  if r.ok?\n"
    '    puts("spawned")\n'
    "  else\n"
    "    puts(r.message)\n"
    "  end\n"
    "end\n")
STD_SOURCE = 'def main() -> Void\n  puts(FrontEnd.std_source("queue.agc").ok?)\nend\n'
HAND_OFF = "def main() -> Void\n  puts(FrontEnd.hand_off([1], [], []).ok?)\nend\n"
BROKEN_STD = '\nexport def broken() -> Int\n  return "text"\nend\n'
INTERLEAVED = (
    'def main() -> Void\n  for i in 0...6\n    puts("out #{i}")\n    IO.warn("err #{i}")\n  end\nend\n')
USES_STD = 'import Queue from "std/queue"\n\ndef main() -> Void\n  puts("unused")\nend\n'


def version():
    return (ROOT / "VERSION").read_text().strip()


def bad_utf8_file(path):
    """A source file of 350 KB: valid lines, then bad bytes on line 50001, then 100 KB of random bytes.

    The bad bytes lie in the second 256 KiB chunk that the front end reads, and the tail has every kind of broken
    sequence; a decoder that copied the rest of the file at each bad byte would need minutes for it.
    """
    path.write_bytes(b"x = 1\n" * 50000 + b"\xff\xfe\n" + random.Random(7).randbytes(100000))


def with_version(data, text):
    """The bytes of an .agcb with the Agentica version of its header replaced (magic, u32 format, str version)."""
    (length,) = struct.unpack_from("<I", data, 8)
    return data[:8] + struct.pack("<I", len(text)) + text.encode() + data[12 + length:]


class SingleBinary(TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.binary = binary()

    def agentica(self, *words, **options):
        options.setdefault("env", vm_environment())
        return run([self.binary, *words], **options)

    def front_end(self, work):
        """The test front end, compiled once for the case, with the header version of the current build."""
        return compile_agc(FRONT, work / "front.agcb")

    def test_runs_a_program_with_arguments_and_standard_input(self):
        directory = self.make_suite({"main.agc": STDIN_AND_ARGS})
        result = self.agentica("main.agc", "one", "two words", cwd=directory, stdin="typed\n")
        self.assertEqual((result.code, result.stdout, result.stderr),
                         (3, 'args ["one", "two words"]\nline ok("typed")\n', ""))

    def test_the_exit_status_and_the_problems_of_a_source_file(self):
        """The shapes of a result: the status of the program, a diagnostic with status 1, a file that is not UTF-8.

        tests/test_cli_forms.py compares every command, option and diagnostic form with a golden."""
        directory = self.make_suite({"exit.agc": EXIT_THREE, "type.agc": TYPE_ERROR})
        (directory / "bad.agc").write_bytes(b"\xff\xfe")
        bad_utf8_file(directory / "big_bad.agc")
        self.assertEqual(self.agentica("exit.agc", cwd=directory)[:3], (3, "before\n", ""))
        typed = self.agentica("type.agc", cwd=directory)
        self.assertEqual((typed.code, typed.stdout), (1, ""))
        self.assertIn("CHECK-TYPE-MISMATCH", typed.stderr)
        self.assertEqual(self.agentica("missing.agc", cwd=directory).code, 2)
        # The line of a file that is not UTF-8 is shown with U+FFFD, as the front end shows it.
        self.assertIn("1 | \ufffd\ufffd\n", self.agentica("bad.agc", cwd=directory).stderr)
        self.assertIn("50001 | \ufffd\ufffd\n", self.agentica("big_bad.agc", cwd=directory).stderr)

    def test_the_output_and_the_errors_of_a_program_keep_their_order_in_one_stream(self):
        """With 2>&1 the program writes both streams to one pipe; the binary leaves them as the program wrote them."""
        directory = self.make_suite({"mixed.agc": INTERLEAVED})
        merged = ["sh", "-c", 'exec "$@" 2>&1', "sh"]
        got = run(merged + [str(self.binary), "mixed.agc"], cwd=directory, env=vm_environment())
        self.assertEqual((got.code, got.stdout), (0, "".join("out %d\nerr %d\n" % (i, i) for i in range(6))))

    def test_a_front_end_that_stops_with_an_error_ends_with_status_2_not_the_status_of_a_failed_run(self):
        """The driver of `agentica test` is part of the front end: when it crashes, the status is 2, as for a usage
        error, and it is never the 1 of a test run that failed."""
        front = self.front_end(self.make_temp_dir())
        got = self.agentica("--front-end", front, "crash")
        self.assertEqual((got.code, got.stdout), (2, ""))
        self.assertIn("RUNTIME-DIVISION-BY-ZERO", got.stderr)

    def test_a_front_end_without_the_path_of_the_binary_cannot_test(self):
        """The front end started as an ordinary program has no --self: `test` says so and exits 2."""
        got = run_vm(STAGE2, "--allow-run", args=["--version", version(), "--stdlib", STDLIB, "--", "test", "x"],
                     env=vm_environment())
        self.assertEqual((got.code, got.stdout), (2, ""))
        self.assertIn("the test command needs the path of the binary", got.stderr)

    def test_the_version_is_answered_even_when_the_standard_output_is_closed(self):
        """A closed pipe must end the answer with a status, not with SIGPIPE, for the early --version path too."""
        reader, writer = os.pipe()
        os.close(reader)
        try:
            process = subprocess.run([str(self.binary), "--version"], stdout=writer, stderr=subprocess.PIPE,
                                     env=vm_environment(), timeout=scaled(10))
        finally:
            os.close(writer)
        self.assertEqual(process.returncode, 1, process.stderr)

    def test_compile_writes_what_the_vm_loads(self):
        """What compile writes is what the VM loads: the same output as running the file in one step. The bytes are the
        bytes of the front end inside the binary."""
        work = self.make_temp_dir()
        source = ROOT / "examples" / "json-modules.agc"
        self.assertEqual(self.agentica("compile", source, "-o", work / "next.agcb").code, 0)
        data = (work / "next.agcb").read_bytes()
        self.assertEqual(run_vm(work / "next.agcb", env=vm_environment()), self.agentica(source))
        self.assertIn(version().encode(), data[:32])

    def test_run_runs_a_compiled_file_with_the_vm_flags_and_no_front_end(self):
        directory = self.make_suite({"loop.agc": LOOP, "random.agc": RANDOM, "spawn.agc": SPAWN,
                                     "args.agc": STDIN_AND_ARGS, "divide.agc": "def main() -> Void\n  puts(1 / 0)\nend\n"})
        compiled = {name: compile_agc(directory / (name + ".agc"), directory / (name + ".agcb"))
                    for name in ("loop", "random", "spawn", "args", "divide")}
        limited = self.agentica("run", "--max-steps", "5000", "--", compiled["loop"])
        self.assertEqual((limited.code, limited.stdout), (1, ""))
        self.assertIn("RUNTIME-STEP-LIMIT", limited.stderr)
        draws = [self.agentica("run", "--seed", seed, "--", compiled["random"]).stdout for seed in "445"]
        self.assertEqual(draws[0], draws[1])
        self.assertNotEqual(draws[0], draws[2])
        self.assertIn("--allow-run", self.agentica("run", "--", compiled["spawn"]).stdout)
        self.assertEqual(self.agentica("run", "--allow-run", "--", compiled["spawn"]).stdout, "spawned\n")
        # The words after the file are the program's, flags included; its input and exit status are the process's.
        got = self.agentica("run", "--", compiled["args"], "--seed", "x", stdin="typed\n")
        self.assertEqual((got.code, got.stdout), (3, 'args ["--seed", "x"]\nline ok("typed")\n'))
        failed = self.agentica("run", "--json", "--", compiled["divide"])
        self.assertEqual(failed.code, 1)
        self.assertRegex(failed.stderr, r'^\{"code":"RUNTIME-DIVISION-BY-ZERO"')

    def test_run_checks_its_command_line_and_names_itself_in_its_messages(self):
        compiled = compile_agc(self.make_suite({"main.agc": EXIT_THREE}) / "main.agc", self.make_temp_dir() / "main.agcb")
        for words, message in (
                ([], "usage: agentica run "),
                (["--seed", "x", "--", compiled], "agentica run: --seed needs an integer from 0 to 2147483647\n"),
                (["--bogus", "--", compiled], "agentica run: unknown option --bogus\n")):
            with self.subTest(words=words):
                got = self.agentica("run", *words)
                self.assertEqual((got.code, got.stdout), (2, ""))
                self.assertTrue(got.stderr.startswith(message.rstrip("\n")), got.stderr)
        # The usual mistake, a source file: the loader's reason, then the way to run it.
        source = self.make_suite({"main.agc": EXIT_THREE}) / "main.agc"
        mistaken = self.agentica("run", "--", source)
        self.assertEqual((mistaken.code, mistaken.stdout), (2, ""))
        self.assertIn("invalid bytecode: bad magic", mistaken.stderr)
        self.assertIn("to run a source file, use agentica %s" % source, mistaken.stderr)
        # `run` must be the first word: after an option it is a source file name, and the front end says so.
        late = self.agentica("--json", "run", "x.agcb")
        self.assertEqual((late.code, late.stdout), (2, ""))
        self.assertIn("run must be the first word", late.stderr)
        # The long version line is the VM's (the libraries it links); `agentica --version` is the version alone.
        long = self.agentica("run", "--version")
        self.assertEqual(long.code, 0)
        # The sanitizer build has no libgc: "(sanitizer build, no libgc, yyjson ...)".
        self.assertRegex(long.stdout, r"^agentica %s \((libgc |sanitizer build, no libgc).*yyjson .*libuv .*OpenSSL "
                                      % re.escape(version()))
        self.assertEqual(self.agentica("--version").stdout, version() + "\n")

    def test_run_embedded_starts_a_program_the_binary_carries(self):
        """`run --embedded NAME` is for `agentica test`: no file, the words after `--` are the program's."""
        got = self.agentica("run", "--embedded", "runner", "--", "/nonexistent/config.jsonl")
        self.assertEqual((got.code, got.stdout), (2, ""))
        self.assertIn("cannot open the BDD runner configuration", got.stderr)
        for words, message in (
                (["--embedded", "nothing", "--", "x"],
                 "agentica run: this binary carries no embedded program nothing\n"),
                (["--embedded"], "agentica run: --embedded needs a program name\n"),
                (["--embedded", "runner", "--embedded", "steps", "--"],
                 "agentica run: the --embedded option can only be specified once\n")):
            with self.subTest(words=words):
                got = self.agentica("run", *words)
                self.assertEqual((got.code, got.stdout, got.stderr), (2, "", message))

    def test_a_program_cannot_call_the_front_end_builtins(self):
        directory = self.make_suite({"std.agc": STD_SOURCE, "hand_off.agc": HAND_OFF})
        for name in ("std", "hand_off"):
            with self.subTest(name=name):
                got = self.agentica(name + ".agc", cwd=directory)
                self.assertEqual((got.code, got.stdout), (1, ""))
                self.assertIn("RUNTIME-FRONT-END-ONLY", got.stderr)
                # The same program on the VM that runs a compiled file: there is no front end there either.
                self.assertEqual(self.agentica("compile", name + ".agc", "-o", name + ".agcb", cwd=directory).code, 0)
                again = run_vm(directory / (name + ".agcb"), env=vm_environment())
                self.assertEqual((again.code, again.stdout), (1, ""))
                self.assertIn("RUNTIME-FRONT-END-ONLY", again.stderr)

    def test_the_vm_options_apply_to_the_program_only(self):
        directory = self.make_suite({"loop.agc": LOOP, "random.agc": RANDOM, "spawn.agc": SPAWN})
        # The front end needs millions of steps to compile this: the limit does not reach it.
        limited = self.agentica("--max-steps", "5000", "loop.agc", cwd=directory)
        self.assertEqual((limited.code, limited.stdout), (1, ""))
        self.assertIn("RUNTIME-STEP-LIMIT", limited.stderr)
        seeded = [self.agentica("--seed", seed, "random.agc", cwd=directory).stdout for seed in ("4", "4", "5")]
        self.assertEqual(seeded[0], seeded[1])
        self.assertNotEqual(seeded[0], seeded[2])
        denied = self.agentica("spawn.agc", cwd=directory)
        self.assertIn("--allow-run", denied.stdout)
        self.assertEqual(self.agentica("--allow-run", "spawn.agc", cwd=directory).stdout, "spawned\n")

    def test_a_front_end_of_another_version_runs_but_a_program_of_another_version_does_not(self):
        work = self.make_temp_dir()
        data = self.front_end(work).read_bytes()
        other = work / "other.agcb"
        other.write_bytes(with_version(data, ANOTHER_VERSION))
        loaded = self.agentica("--front-end", other, "inputs", "x")
        # The binary names itself with the real path of its file, for the commands that start it again.
        inputs = "--version %s --self %s -- inputs x\n" % (version(), os.path.realpath(self.binary))
        self.assertEqual((loaded.code, loaded.stdout, loaded.stderr), (0, inputs, ""))
        refused = run_vm(other, env=vm_environment())
        self.assertEqual(refused.code, 2)
        self.assertIn("built for another Agentica version", refused.stderr)
        # The program that a front end hands over gets the same check as a file given to the VM.
        got = self.agentica("--front-end", work / "front.agcb", "hand-off", other)
        self.assertEqual((got.code, got.stdout), (2, ""))
        self.assertEqual(got.stderr, "agentica: invalid bytecode: built for another Agentica version\n")

    def test_the_front_end_gets_the_embedded_std_sources(self):
        work = self.make_temp_dir()
        front = self.front_end(work)
        for name in (STDLIB / "MODULES").read_text().split():
            with self.subTest(name=name):
                got = self.agentica("--front-end", front, "std", name)
                self.assertEqual((got.code, got.stdout), (0, (STDLIB / name).read_text()))
        missing = self.agentica("--front-end", front, "std", "nothing.agc")
        self.assertEqual((missing.code, missing.stdout), (0, "error: no such std source\n"))

    def test_the_hand_off_runs_the_program_in_a_new_runtime(self):
        work = self.make_suite({"user.agc": STDIN_AND_ARGS, "random.agc": RANDOM})
        front = self.front_end(work)
        user = compile_agc(work / "user.agc", work / "user.agcb")
        got = self.agentica("--front-end", front, "hand-off", user, "--", "p", "q r", stdin="in\n")
        self.assertEqual((got.code, got.stdout, got.stderr), (3, 'args ["p", "q r"]\nline ok("in")\n', ""))
        # The options the front end passes on apply to the program: the front end itself ran far more than 5000 steps.
        loop = compile_agc(self.make_suite({"loop.agc": LOOP}) / "loop.agc", work / "loop.agcb")
        limited = self.agentica("--front-end", front, "hand-off", loop, "--max-steps", "5000")
        self.assertEqual(limited.code, 1)
        self.assertIn("RUNTIME-STEP-LIMIT", limited.stderr)
        random = compile_agc(work / "random.agc", work / "random.agcb")
        draws = [self.agentica("--front-end", front, "hand-off", random, "--seed", seed).stdout for seed in "445"]
        self.assertEqual(draws[0], draws[1])
        self.assertNotEqual(draws[0], draws[2])

    def test_the_driver_refuses_what_the_front_end_hands_over_wrongly(self):
        work = self.make_temp_dir()
        front = self.front_end(work)
        program = compile_agc(self.make_suite({"user.agc": EXIT_THREE}) / "user.agc", work / "user.agcb")
        for words, error in (
                (["bad-program"], "error: the program is not a list of bytes, or it is too large\n"),
                (["bad-word"], "error: argument 1 has a character 0\n"),
                (["too-many-options"], "error: too many options\n"),
                (["too-many-arguments"], "error: too many arguments\n")):
            with self.subTest(words=words):
                got = self.agentica("--front-end", front, *words)
                self.assertEqual((got.code, got.stdout, got.stderr), (0, error, ""))
        for options, message in (
                (["--bogus"], "agentica: unknown option --bogus\n"),
                (["--max-steps", "0"], "agentica: --max-steps needs a positive integer\n"),
                (["--version"], "agentica: the front end passed --version, which is not an option of a run\n"),
                (["--driver-pid", "1"],
                 "agentica: the front end passed --driver-pid, which only the process that started agentica may name\n"),
                (["--embedded", "runner"], "agentica: the front end passed --embedded, which only agentica run takes\n"),
                (["word"], "agentica: the front end passed word, which is not an option of a run\n")):
            with self.subTest(options=options):
                got = self.agentica("--front-end", front, "hand-off", program, *options)
                self.assertEqual((got.code, got.stdout, got.stderr), (2, "", message))

    def test_a_missing_front_end_is_a_usage_error(self):
        pipe = self.make_temp_dir() / "front.agcb"
        os.mkfifo(pipe)
        for words, message in (
                (["--front-end", "/nonexistent/front.agcb"], "agentica: cannot read /nonexistent/front.agcb\n"),
                # A named pipe is refused at once, not waited for.
                (["--front-end", pipe], "agentica: cannot read %s\n" % pipe),
                (["--front-end"], "agentica: --front-end needs a file\n")):
            got = self.agentica(*words, timeout=scaled(10))
            self.assertEqual((got.code, got.stdout, got.stderr), (2, "", message))

    def test_the_environment_and_the_version_flag_are_read_before_a_front_end_runs(self):
        work = self.make_temp_dir()
        trace = work / "trace"
        env = vm_environment({"AGENTICA_VM_TRACE": "io", "AGENTICA_VM_TRACE_FILE": trace})
        answer = self.agentica("--version", env=env)
        self.assertEqual((answer.code, answer.stdout, answer.stderr), (0, version() + "\n", ""))
        self.assertFalse(trace.exists())
        # The program of a run would not start with this variable, so the front end does not compile for it either.
        refused = self.agentica(ROOT / "examples" / "hello.agc",
                                env=vm_environment({"AGENTICA_FLUSH_TIMEOUT_MS": "soon"}), timeout=scaled(10))
        self.assertEqual((refused.code, refused.stdout), (2, ""))
        self.assertIn("AGENTICA_FLUSH_TIMEOUT_MS needs an integer", refused.stderr)

    def test_a_problem_in_a_std_module_shows_that_module_not_a_file_of_the_working_folder(self):
        """A front end on the VM with --stdlib DIR: DIR/queue.agc is broken, ./std/queue.agc is a decoy."""
        require(STAGE2.is_file(), "the front end is not built (%s): run make stage2" % STAGE2)
        work = self.make_suite({"main.agc": USES_STD})
        (work / "libstd").mkdir()
        (work / "libstd" / "queue.agc").write_text((STDLIB / "queue.agc").read_text() + BROKEN_STD)
        (work / "std").mkdir()
        (work / "std" / "queue.agc").write_text("# a decoy\n" * 100)
        got = run_vm(STAGE2, args=["--version", version(), "--stdlib", "libstd", "--", "compile", "main.agc",
                                   "-o", "out.agcb"], cwd=work, env=vm_environment())
        self.assertEqual((got.code, got.stdout), (1, ""))
        self.assertIn("std/queue.agc:", got.stderr)
        self.assertIn('return "text"', got.stderr)
        self.assertNotIn("decoy", got.stderr)
