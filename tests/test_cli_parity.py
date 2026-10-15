"""The command line written in Agentica (compiler/cli_main.agc, run by tests/agentica-agcb) against the Racket one.

Each case runs the same arguments through both and compares the exit code, stdout and stderr, byte for byte. The cases
cover every command and option of src/main.rkt, and the three forms of a diagnostic (plain, --ai, --json) for the
stages that can fail. The differences that are on purpose are listed in DELIBERATE (docs/future/35-self-hosting.md,
35.4, "Step 8a status") and checked on their own.
"""
import os
import tempfile
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from tests.agentica_test import AGCB_CLI, ROOT, TestCase, agentica_version, require, run, slow, tool, vm_environment

CLI_PROGRAM = ROOT / "dist" / "agentica-cli.agcb"
RACKET_CLI = ["racket", str(ROOT / "src" / "main.rkt")]
JOBS = 6

FILES = {
    "ok.agc": 'def main() -> Void\n  puts("ok")\nend\n',
    "args.agc": (
        'def main() -> Void\n  puts(System.args().join("|"))\n  IO.warn("to stderr")\n  name = IO.gets()\n'
        '  if name.ok?\n    puts("hello #{name.unwrap!}")\n  end\n  print("rest=#{IO.read()}")\n  System.exit(3)\nend\n'),
    "loop.agc": "def main() -> Void\n  while true\n  end\nend\n",
    "divide.agc": "def main() -> Void\n  puts(1 / 0)\nend\n",
    "lex.agc": 'def main() -> Void\n  puts("unterminated)\nend\n',
    "parse.agc": 'def main() -> Void\n  puts "hello"\nend\n',
    "tab.agc": 'def main() -> Void\n\tx: Int = "a"\n\tputs(x)\nend\n',
    "crlf.agc": 'def main() -> Void\r\n  x: Int = "a"\r\n  puts(x)\r\nend\r\n',
    "unicode.agc": 'def main() -> Void\n  puts("héllo")\n  x: Int = "éé"\nend\n',
    "multiline.agc": 'def main() -> Void\n  x = [1, 2,\n    3] + "s"\nend\n',
    "labels.agc": (
        "def add(a: Int, b: Int) -> Int\n  return a + b\nend\n\ndef main() -> Void\n  x = add(1, \"two\")\n"
        "  puts(x)\nend\n"),
    "twice.agc": "def main() -> Void\n  puts(\"x\")\nend\n\ndef main() -> Void\nend\n",
    "helped.agc": "def main() -> Void\n  values = []\nend\n",
    "missing_import.agc": 'import Nothing from "nothing"\n\ndef main() -> Void\n  puts("x")\nend\n',
    "std_error.agc": 'import Queue from "std/queue"\n\ndef main() -> Void\n  puts(Queue.nope())\nend\n',
    "lib/util.agc": (
        "export def boom(n: Int) -> Int\n  return n / 0\nend\n\nexport def bad() -> Int\n  return \"s\"\nend\n"),
    "sub/boom.agc": 'import Util from "../lib/util"\n\ndef main() -> Void\n  puts("start")\n  puts(Util.boom(1))\nend\n',
    "sub/bad.agc": 'import Util from "../lib/util"\n\ndef main() -> Void\n  puts(Util.bad())\nend\n',
}

# Written as bytes: a file that is not UTF-8.
BINARY_FILES = {"invalid.agc": b'def main() -> Void\n  puts("a\xff\xe2\x82b")\nend\n'}

# What the stages and the runtime can say about a program, run in the three forms of a diagnostic.
PROGRAMS = ["ok.agc", "lex.agc", "parse.agc", "tab.agc", "crlf.agc", "unicode.agc", "multiline.agc", "labels.agc",
            "twice.agc", "helped.agc", "missing_import.agc", "std_error.agc", "sub/bad.agc", "sub/boom.agc",
            "invalid.agc", "divide.agc", "absent.agc"]

BUILTINS = ["String.split", "ok", "Task.await", "Map.get", "File.open", "Process.spawn_captured", "JSON.decode"]
ALSO_BUILTINS = ["print", "puts", "error", "gets", "gets!", "Set.new", "List.map", "Channel.new", "Test.eq", "TCP.connect",
                 "TLS.connect", "Time.now_ms", "Random.int", "Path.real", "Dir.list", "System.args", "IO.read_bytes"]

# Arguments with no file: the options, their mistakes and the help.
OPTIONS = [
    ["--version"], ["-h"], ["--help"], ["-hx"], ["-xh"], ["-ab", "c"], ["--foo"], ["+x"], ["-"], ["+"], [],
    ["check"], ["compile"], ["help"], ["--json", "help"], ["help", "--json"], ["help", "Nope"], ["help", "Strin.split"],
    ["help", "a", "b", "c"], ["help", "HttpWire.client"],
    ["--max-steps"], ["--max-steps", "x", "ok.agc"], ["--max-steps", "0", "ok.agc"], ["--max-steps", "007", "ok.agc"],
    ["--max-steps=5", "ok.agc"], ["--seed", "2147483648", "ok.agc"], ["--seed", "007", "ok.agc"],
    ["--seed", "--json", "ok.agc"], ["--seed", "1", "--seed"], ["--seed", "5", "--seed", "6", "ok.agc"],
    ["--ai", "--ai", "check", "ok.agc"], ["--allow-run", "--allow-run", "ok.agc"], ["--steps"],
    ["--flush-timeout"], ["--flush-timeout", "x", "ok.agc"], ["--flush-timeout", "100", "ok.agc"],
    ["--version", "--foo"], ["--foo", "--version"], ["--", "ok.agc"], ["ok.agc", "--version"],
    ["check", "--json", "ok.agc"], ["compile", "ok.agc"], ["--dump", "compile", "ok.agc", "-o", "out.agcb"],
    ["--max-steps", "1", "check", "ok.agc"], ["--json", "check", "ok.agc"], ["--ai", "check", "ok.agc"],
    ["check", "nope.agc"], ["nope.agc"], ["check", "."],
    ["--max-steps", "5", "--seed", "1", "--json", "--allow-run", "--flush-timeout", "10", "ok.agc"],
]


class CliParity(TestCase):
    @classmethod
    def setUpClass(cls):
        super().setUpClass()
        tool("racket")
        require(CLI_PROGRAM.is_file(), "the Agentica command line is not built (%s): run make cli" % CLI_PROGRAM)
        require((ROOT / "dist" / "agentica-vm").is_file(), "the VM is not built: run make vm")
        cls.directory = tempfile.TemporaryDirectory(prefix="agentica-parity-")
        cls.addClassCleanup(cls.directory.cleanup)
        cls.work = Path(cls.directory.name).resolve()
        for name, text in FILES.items():
            path = cls.work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        for name, data in BINARY_FILES.items():
            (cls.work / name).write_bytes(data)

    def both(self, arguments, stdin=b"", cwd=None, outputs=()):
        """The results of the Racket and the Agentica command line for the same arguments, run side by side.

        `outputs` are files the command writes (relative to cwd); their bytes are returned too, and removed after each
        run so the second command does not find the first one's file."""
        cwd = cwd or self.work
        results = []
        for command in (RACKET_CLI, [str(AGCB_CLI)]):
            result = run(command + [str(argument) for argument in arguments], stdin=stdin, cwd=cwd,
                         env=vm_environment())
            files = []
            for name in outputs:
                path = Path(cwd) / name
                files.append(path.read_bytes() if path.exists() else None)
                if path.exists():
                    path.unlink()
            results.append(((result.code, result.stdout, result.stderr), files))
        return results

    def assertSame(self, arguments, **options):
        racket, agentica = self.both(arguments, **options)
        self.assertEqual(agentica, racket, "arguments: %s" % (arguments,))

    def parallel(self, cases):
        """Compares every (arguments, options) case, JOBS at a time; gives the differences as a message, or ''."""
        def compare(case):
            arguments, options = case
            racket, agentica = self.both(arguments, **options)
            return None if racket == agentica else "%s\n  racket:  %r\n  agentica: %r" % (arguments, racket, agentica)

        with ThreadPoolExecutor(JOBS) as pool:
            return "\n".join(line for line in pool.map(compare, cases) if line)

    def test_options_commands_and_their_mistakes(self):
        self.assertEqual(self.parallel([(arguments, {}) for arguments in OPTIONS]), "")

    def test_every_diagnostic_form_of_every_stage(self):
        cases = [(style + ["check", program], {}) for style in ([], ["--ai"], ["--json"]) for program in PROGRAMS]
        # A runtime problem is the VM's; a path typed in full names the root file as typed.
        cases += [(["--max-steps", "100000", program], {}) for program in ("ok.agc", "divide.agc", "sub/boom.agc")]
        cases += [(["--json", "check", str(self.work / program)], {}) for program in ("tab.agc", "sub/bad.agc")]
        self.assertEqual(self.parallel(cases), "")

    @slow
    def test_the_whole_matrix_of_programs_and_diagnostic_forms(self):
        cases = []
        for style in ([], ["--ai"], ["--json"]):
            for program in PROGRAMS:
                cases.append((style + ["--max-steps", "100000", program], {}))
                cases.append((style + ["check", str(self.work / program)], {}))
        self.assertEqual(self.parallel(cases), "")

    def test_running_a_program_passes_arguments_standard_streams_and_the_exit_status(self):
        cases = [
            (["args.agc", "a", "b c", "--json", ""], {"stdin": b"World\nline2\nline3"}),
            (["args.agc"], {}),
            (["--seed", "3", "args.agc", "x"], {"stdin": b"Zed"}),
            (["--max-steps", "1000", "--json", "loop.agc"], {}),
            (["--ai", "--max-steps", "1000", "loop.agc"], {}),
            (["sub/boom.agc"], {}),
            (["--json", "sub/boom.agc"], {}),
            (["main.agc"], {"cwd": self.work / "sub"}),
            ([str(self.work / "sub" / "boom.agc")], {"cwd": "/"}),
        ]
        self.assertEqual(self.parallel(cases), "")

    def test_compile_writes_the_same_bytes_or_the_same_problem(self):
        cases = [
            (["compile", "args.agc", "-o", "out.agcb"], {"outputs": ["out.agcb"]}),
            (["compile", "sub/boom.agc", "-o", "out.agcb"], {"outputs": ["out.agcb"]}),
            (["compile", "tab.agc", "-o", "out.agcb"], {"outputs": ["out.agcb"]}),
            (["--json", "compile", "labels.agc", "-o", "out.agcb"], {"outputs": ["out.agcb"]}),
            (["compile", "ok.agc", "-o", "/nonexistent/folder/out.agcb"], {}),
        ]
        # The cases write the same name one after the other: run them one at a time.
        for arguments, options in cases:
            self.assertSame(arguments, **options)

    def test_help_for_a_few_builtins_in_both_forms(self):
        cases = [(["help", name] + flag, {}) for name in BUILTINS[:4] for flag in ([], ["--json"])]
        self.assertEqual(self.parallel(cases), "")

    @slow
    def test_help_for_every_builtin_in_both_forms(self):
        cases = [(["help", name] + flag, {}) for name in BUILTINS + ALSO_BUILTINS for flag in ([], ["--json"])]
        self.assertEqual(self.parallel(cases), "")

    def test_the_dump_flags_print_the_program_in_the_text_forms_of_compiler(self):
        # Racket prints its own structures (pretty-print and format-ir); Agentica prints the text forms of
        # compiler/check_text.agc and lower_text.agc. Only the exit code and that something is printed are the same.
        for flag in ("--dump", "--dump-ir"):
            racket, agentica = self.both([flag, "ok.agc"])
            self.assertEqual((agentica[0][0], agentica[0][2]), (racket[0][0], racket[0][2]))
            self.assertIn("main", agentica[0][1])
            self.assertNotEqual(agentica[0][1], "")
            # A program that does not check never reaches the dump: its diagnostic is the same.
            self.assertSame([flag, "tab.agc"])

    def test_the_version_is_the_version_file(self):
        result = run([str(AGCB_CLI), "--version"], env=vm_environment())
        self.assertEqual(result, (0, agentica_version() + "\n", ""))
        self.assertTrue(os.access(AGCB_CLI, os.X_OK))
