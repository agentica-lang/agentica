"""The single binary dist/agentica-next (35.3 and 35.6, step 8b): the front end it carries compiles in memory and hands
the program to C, which runs it in a new runtime.

The binary is checked against what `agentica` does today (the Racket front end, or AGENTICA_TEST_EXECUTABLE): the
same stdout, stderr and exit status for a few programs and a few diagnostics, and the same bytes for `compile`.
The other cases use a front end of their own (tests/fixtures/single-binary/front.agc, loaded with --front-end) to
see what the C side does with the two FrontEnd builtins. The fixed point is the make target of the same name; its
test is slow because it compiles compiler/ three times.
"""
import re
import struct
import subprocess

from tests.agentica_test import (FIXTURES, ROOT, TestCase, cli, compile_agc, require, run, run_vm, slow,
                                 vm_environment)

STDLIB = ROOT / "stdlib"
FRONT = FIXTURES / "single-binary" / "front.agc"
ANOTHER_VERSION = "9.9.9"

EXIT_THREE = 'def main() -> Void\n  puts("before")\n  System.exit(3)\nend\n'
INDEX_ERROR = "def main() -> Void\n  xs = [1, 2]\n  puts(xs[5])\nend\n"
TYPE_ERROR = 'def main() -> Void\n  x: Int = "a"\n  puts(x)\nend\n'
SYNTAX_ERROR = "def main() -> Void\n  puts(1\nend\n"
HELPER_ERROR = 'export def f() -> Int\n  return "x"\nend\n'
USES_HELPER = 'import {f} from "./lib/helper"\n\ndef main() -> Void\n  puts(f())\nend\n'
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


def version():
    return re.search(r'\(define version "([^"]+)"\)', (ROOT / "src" / "version.rkt").read_text()).group(1)


def next_binary():
    """dist/agentica-next, built by `make test` for this module; a skip when it is missing, a failure in CI."""
    path = ROOT / "dist" / "agentica-next"
    require(path.is_file(), "the single binary is not built (%s): run make agentica-next" % path)
    return path


def with_version(data, text):
    """The bytes of an .agcb with the Agentica version of its header replaced (magic, u32 format, str version)."""
    (length,) = struct.unpack_from("<I", data, 8)
    return data[:8] + struct.pack("<I", len(text)) + text.encode() + data[12 + length:]


class SingleBinary(TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        cls.binary = next_binary()

    def agentica(self, *words, **options):
        options.setdefault("env", vm_environment())
        return run([self.binary, *words], **options)

    def racket(self, *words, **options):
        options.setdefault("env", vm_environment())
        return run(cli() + list(words), **options)

    def front_end(self, work):
        """The test front end, compiled once for the case, with the header version of the current build."""
        return compile_agc(FRONT, work / "front.agcb")

    def test_runs_a_program_with_arguments_and_standard_input(self):
        directory = self.make_suite({"main.agc": STDIN_AND_ARGS})
        result = self.agentica("main.agc", "one", "two words", cwd=directory, stdin="typed\n")
        self.assertEqual((result.code, result.stdout, result.stderr),
                         (3, 'args ["one", "two words"]\nline ok("typed")\n', ""))

    def test_has_the_results_of_the_racket_front_end(self):
        directory = self.make_suite({
            "exit.agc": EXIT_THREE, "index.agc": INDEX_ERROR, "type.agc": TYPE_ERROR, "syntax.agc": SYNTAX_ERROR,
            "main.agc": USES_HELPER})
        (directory / "lib").mkdir()
        (directory / "lib" / "helper.agc").write_text(HELPER_ERROR)
        cases = [
            ["exit.agc"], ["index.agc"], ["type.agc"], ["./type.agc"], ["syntax.agc"], ["main.agc"], ["missing.agc"],
            ["--max-steps", "0", "exit.agc"], ["--bogus", "exit.agc"], ["compile", "type.agc", "-o", "out.agcb"],
        ]
        for words in cases + [[str(ROOT / "examples" / name)] for name in ("hello.agc", "queue.agc", "json-modules.agc")]:
            with self.subTest(words=words):
                got = self.agentica(*words, cwd=directory)
                self.assertEqual(got, self.racket(*words, cwd=directory))
        self.assertFalse((directory / "out.agcb").exists())

    def test_compile_writes_the_bytes_of_the_racket_front_end(self):
        work = self.make_temp_dir()
        source = ROOT / "examples" / "json-modules.agc"
        self.assertEqual(self.agentica("compile", source, "-o", work / "next.agcb").code, 0)
        self.assertEqual(self.racket("compile", source, "-o", work / "racket.agcb").code, 0)
        data = (work / "next.agcb").read_bytes()
        self.assertEqual(data, (work / "racket.agcb").read_bytes())
        # What compile writes is what the VM loads: the same output as running the file in one step.
        self.assertEqual(run_vm(work / "next.agcb", env=vm_environment()), self.agentica(source))
        self.assertIn(version().encode(), data[:32])

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
        self.assertEqual((loaded.code, loaded.stdout, loaded.stderr), (0, "--version %s -- inputs x\n" % version(), ""))
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
        names = (STDLIB / "MODULES").read_text().split()
        self.assertEqual(sorted(names), sorted(p.relative_to(STDLIB).as_posix() for p in STDLIB.rglob("*.agc")))
        for name in names:
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
                (["bad-word"], "error: argument 1 has a character 0\n")):
            with self.subTest(words=words):
                got = self.agentica("--front-end", front, *words)
                self.assertEqual((got.code, got.stdout, got.stderr), (0, error, ""))
        for options, message in (
                (["--bogus"], "agentica: unknown option --bogus\n"),
                (["--max-steps", "0"], "agentica: --max-steps needs a positive integer\n"),
                (["--version"], "agentica: the front end passed --version, which is not an option of a run\n"),
                (["word"], "agentica: the front end passed word, which is not an option of a run\n")):
            with self.subTest(options=options):
                got = self.agentica("--front-end", front, "hand-off", program, *options)
                self.assertEqual((got.code, got.stdout, got.stderr), (2, "", message))

    def test_a_missing_front_end_is_a_usage_error(self):
        for words, message in (
                (["--front-end", "/nonexistent/front.agcb"], "agentica: cannot read /nonexistent/front.agcb\n"),
                (["--front-end"], "agentica: --front-end needs a file\n")):
            got = self.agentica(*words)
            self.assertEqual((got.code, got.stdout, got.stderr), (2, "", message))

    @slow
    def test_the_fixed_point_holds(self):
        """stage2 == stage3 and Racket's stage1 == stage2, and the binary compiles its own front end to stage2."""
        result = subprocess.run(["make", "fixed-point"], cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                text=True, timeout=1800)
        self.assertEqual(result.returncode, 0, result.stdout[-4000:])
