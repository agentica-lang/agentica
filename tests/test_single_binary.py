"""The single binary dist/agentica (§18.2 and §18.8): the front end it carries compiles in memory and hands the program
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

import pytest

from tests.agentica_test import (FIXTURES, ROOT, STAGE2, TARGET_OS, UNDER_WINE, binary, compile_agc,
                                 require, run, run_vm, scaled, vm_command, vm_environment, write_files)

STDLIB = ROOT / "stdlib"
FRONT = FIXTURES / "single-binary" / "front.agc"
ANOTHER_VERSION = "9.9.9"
STDIN_CAP = 16 * 1024 * 1024

EXIT_THREE = 'def main() -> Void\n  puts("before")\n  System.exit(3)\nend\n'
TYPE_ERROR = 'def main() -> Void\n  x: Int = "a"\n  puts(x)\nend\n'
LOOP = "def main() -> Void\n  i = 0\n  while true\n    i += 1\n  end\nend\n"
RANDOM = "def main() -> Void\n  puts(Random.int(0, 1000000))\nend\n"
STDIN_AND_ARGS = (
    'def main() -> Void\n  puts("args #{System.args()}")\n  puts("line #{IO.gets()}")\n  System.exit(3)\nend\n')
SPAWN_CALL = (
    'Process.spawn_captured("cmd", ["/c", "echo child"], ".", 5000)'
    if TARGET_OS == "windows"
    else 'Process.spawn_captured("sh", ["-c", "echo child"], ".", 5000)'
)
# The start of the error of a Process start under --deny-run, which programs may test.
DENIED = "denied: --deny-run"
# One call of each family that a --deny-* flag turns off (a hermetic one: localhost, port 0), with its flag.
FAMILIES = (
    ("net", 'TCP.listen("127.0.0.1", 0)', "--deny-net"),
    ("fs", 'File.read_text("main.agc", 5000)', "--deny-fs"),
    ("env", 'System.env("PATH")', "--deny-env"),
    ("run", SPAWN_CALL, "--deny-run"),
)
# Prints one line for each family: `NAME allowed`, or `NAME ` and the error.
FAMILY_CALLS = "def main() -> Void\n" + "".join(
    f"  {name} = {call}\n  if {name}.ok?\n    puts(\"{name} allowed\")\n  else\n"
    f"    puts(\"{name} #{{{name}.message}}\")\n  end\n"
    for name, call, _ in FAMILIES) + "end\n"
SPAWN = (
    "def main() -> Void\n"
    f"  r = {SPAWN_CALL}\n"
    "  if r.ok?\n"
    '    puts("spawned")\n'
    "  else\n"
    "    puts(r.message)\n"
    "  end\n"
    "end\n"
)
STD_SOURCE = 'def main() -> Void\n  puts(FrontEnd.std_source("queue.agc").ok?)\nend\n'
STDIN_BYTES = "def main() -> Void\n  puts(FrontEnd.stdin_bytes().ok?)\nend\n"
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


def agentica(*words, **options):
    options.setdefault("env", vm_environment())
    return run([binary(), *words], **options)


def front_end(work):
    """The test front end, compiled once for the case, with the header version of the current build."""
    return compile_agc(FRONT, work / "front.agcb")


def make_suite(directory, files):
    write_files(directory, files)
    return directory


def test_runs_a_program_with_arguments_and_standard_input(tmp_path):
    directory = make_suite(tmp_path, {"main.agc": STDIN_AND_ARGS})
    result = agentica("main.agc", "one", "two words", cwd=directory, stdin="typed\n")
    assert (result.code, result.stdout, result.stderr) == (3, 'args ["one", "two words"]\nline ok("typed")\n', "")


def test_the_exit_status_and_the_problems_of_a_source_file(tmp_path):
    """The shapes of a result: the status of the program, a diagnostic with status 1, a file that is not UTF-8.

    tests/test_cli_forms.py compares every command, option and diagnostic form with a golden."""
    directory = make_suite(tmp_path, {"exit.agc": EXIT_THREE, "type.agc": TYPE_ERROR})
    (directory / "bad.agc").write_bytes(b"\xff\xfe")
    bad_utf8_file(directory / "big_bad.agc")
    assert agentica("exit.agc", cwd=directory)[:3] == (3, "before\n", "")
    typed = agentica("type.agc", cwd=directory)
    assert (typed.code, typed.stdout) == (1, "")
    assert "CHECK-TYPE-MISMATCH" in typed.stderr
    assert agentica("missing.agc", cwd=directory).code == 2
    # The line of a file that is not UTF-8 is shown with U+FFFD, as the front end shows it.
    assert "1 | \ufffd\ufffd\n" in agentica("bad.agc", cwd=directory).stderr
    assert "50001 | \ufffd\ufffd\n" in agentica("big_bad.agc", cwd=directory).stderr


@pytest.mark.skipif(UNDER_WINE, reason="Wine does not show that two descriptors are one pipe")
def test_the_output_and_the_errors_of_a_program_keep_their_order_in_one_stream(tmp_path):
    """With 2>&1 the program writes both streams to one pipe; the binary leaves them as the program wrote them."""
    directory = make_suite(tmp_path, {"mixed.agc": INTERLEAVED})
    merged = ["sh", "-c", 'exec "$@" 2>&1', "sh"]
    got = run(merged + [str(binary()), "mixed.agc"], cwd=directory, env=vm_environment())
    assert (got.code, got.stdout) == (0, "".join("out %d\nerr %d\n" % (i, i) for i in range(6)))


def test_a_front_end_that_stops_with_an_error_ends_with_status_2_not_the_status_of_a_failed_run(tmp_path):
    """The driver of `agentica test` is part of the front end: when it crashes, the status is 2, as for a usage
    error, and it is never the 1 of a test run that failed."""
    front = front_end(tmp_path)
    got = agentica("--front-end", front, "crash")
    assert (got.code, got.stdout) == (2, "")
    assert "RUNTIME-DIVISION-BY-ZERO" in got.stderr


def test_a_front_end_without_the_path_of_the_binary_cannot_test():
    """The front end started as an ordinary program has no --self: `test` says so and exits 2."""
    got = run_vm(STAGE2, args=["--version", version(), "--stdlib", STDLIB, "--", "test", "x"],
                 env=vm_environment())
    assert (got.code, got.stdout) == (2, "")
    assert "the test command needs the path of the binary" in got.stderr


def test_the_version_is_answered_even_when_the_standard_output_is_closed():
    """A closed pipe must end the answer with a status, not with SIGPIPE, for the early --version path too."""
    reader, writer = os.pipe()
    os.close(reader)
    try:
        process = subprocess.run([str(binary()), "--version"], stdout=writer, stderr=subprocess.PIPE,
                                 env=vm_environment(), timeout=scaled(10))
    finally:
        os.close(writer)
    # POSIX reports the failed flush. Windows' CRT reports success for this closed standard handle, including
    # under Wine; either way, the process must not be killed by a broken-pipe signal.
    assert process.returncode == (0 if TARGET_OS == "windows" else 1), process.stderr


def test_compile_writes_what_the_vm_loads(tmp_path):
    """What compile writes is what the VM loads: the same output as running the file in one step. The bytes are the
    bytes of the front end inside the binary."""
    work = tmp_path
    source = ROOT / "examples" / "json-modules.agc"
    assert agentica("compile", source, "-o", work / "next.agcb").code == 0
    data = (work / "next.agcb").read_bytes()
    assert run_vm(work / "next.agcb", env=vm_environment()) == agentica(source)
    assert version().encode() in data[:32]


def test_run_runs_a_compiled_file_with_the_vm_flags_and_no_front_end(tmp_path):
    directory = make_suite(tmp_path, {"loop.agc": LOOP, "random.agc": RANDOM, "spawn.agc": SPAWN,
                                      "args.agc": STDIN_AND_ARGS, "divide.agc": "def main() -> Void\n  puts(1 / 0)\nend\n"})
    compiled = {name: compile_agc(directory / (name + ".agc"), directory / (name + ".agcb"))
                for name in ("loop", "random", "spawn", "args", "divide")}
    limited = agentica("run", "--max-steps", "5000", "--", compiled["loop"])
    assert (limited.code, limited.stdout) == (1, "")
    assert "RUNTIME-STEP-LIMIT" in limited.stderr
    draws = [agentica("run", "--seed", seed, "--", compiled["random"]).stdout for seed in "445"]
    assert draws[0] == draws[1]
    assert draws[0] != draws[2]
    # The check is in the VM, so bytecode cannot skip it; the refusal is an error Result with a stable prefix.
    assert agentica("run", "--", compiled["spawn"]).stdout == "spawned\n"
    denied = agentica("run", "--deny-run", "--", compiled["spawn"])
    assert (denied.code, denied.stdout.startswith(DENIED)) == (0, True), denied
    # The words after the file are the program's, flags included; its input and exit status are the process's.
    got = agentica("run", "--", compiled["args"], "--seed", "x", stdin="typed\n")
    assert (got.code, got.stdout) == (3, 'args ["--seed", "x"]\nline ok("typed")\n')
    failed = agentica("run", "--json", "--", compiled["divide"])
    assert failed.code == 1
    assert re.search(r'^\{"code":"RUNTIME-DIVISION-BY-ZERO"', failed.stderr)


def test_run_checks_its_command_line_and_names_itself_in_its_messages(tmp_path):
    write_files(tmp_path, {"main.agc": EXIT_THREE})
    compiled = compile_agc(tmp_path / "main.agc", tmp_path / "main.agcb")
    for words, message in (
            ([], "usage: agentica run "),
            (["--seed", "x", "--", compiled], "agentica run: --seed needs an integer from 0 to 2147483647\n"),
            (["--bogus", "--", compiled], "agentica run: unknown option --bogus\n"),
            (["--allow-run", "--", compiled], "agentica run: unknown option --allow-run\n")):
        got = agentica("run", *words)
        assert (got.code, got.stdout) == (2, "")
        assert got.stderr.startswith(message.rstrip("\n")), got.stderr
    # The usual mistake, a source file: the loader's reason, then the way to run it.
    source = tmp_path / "main.agc"
    mistaken = agentica("run", "--", source)
    assert (mistaken.code, mistaken.stdout) == (2, "")
    assert "invalid bytecode: bad magic" in mistaken.stderr
    assert "to run a source file, use agentica %s" % source in mistaken.stderr
    # `run` must be the first word: after an option it is a source file name, and the front end says so.
    late = agentica("--json", "run", "x.agcb")
    assert (late.code, late.stdout) == (2, "")
    assert "run must be the first word" in late.stderr
    # The long version line is the VM's (the libraries it links); `agentica --version` is the version alone.
    long = agentica("run", "--version")
    assert long.code == 0
    # The sanitizer build has no libgc: "(sanitizer build, no libgc, yyjson ...)".
    assert re.search(r"^agentica %s \((libgc |sanitizer build, no libgc).*yyjson .*libuv .*OpenSSL "
                     % re.escape(version()), long.stdout)
    assert agentica("--version").stdout == version() + "\n"


def test_run_embedded_starts_a_program_the_binary_carries():
    """`run --embedded NAME` is for `agentica test`: no file, the words after `--` are the program's."""
    # The runner it starts exits 2 for a configuration it cannot open. A usage error of `run` is exit 2 too, but
    # its message begins with `agentica run:` (below): the runner's does not.
    got = agentica("run", "--embedded", "runner", "--", "/nonexistent/config.jsonl")
    assert (got.code, got.stdout) == (2, "")
    assert got.stderr != ""
    assert not got.stderr.startswith("agentica run:"), got.stderr
    for words, message in (
            (["--embedded", "nothing", "--", "x"],
             "agentica run: this binary carries no embedded program nothing\n"),
            (["--embedded"], "agentica run: --embedded needs a program name\n"),
            (["--embedded", "runner", "--embedded", "steps", "--"],
             "agentica run: the --embedded option can only be specified once\n")):
        got = agentica("run", *words)
        assert (got.code, got.stdout, got.stderr) == (2, "", message)


@pytest.mark.parametrize("name", ("std", "stdin", "hand_off"))
def test_a_program_cannot_call_the_front_end_builtins(tmp_path, name):
    directory = make_suite(tmp_path, {"std.agc": STD_SOURCE, "stdin.agc": STDIN_BYTES, "hand_off.agc": HAND_OFF})
    got = agentica(name + ".agc", cwd=directory)
    assert (got.code, got.stdout) == (1, "")
    assert "RUNTIME-FRONT-END-ONLY" in got.stderr
    # The same program on the VM that runs a compiled file: there is no front end there either.
    assert agentica("compile", name + ".agc", "-o", name + ".agcb", cwd=directory).code == 0
    again = run_vm(directory / (name + ".agcb"), env=vm_environment())
    assert (again.code, again.stdout) == (1, "")
    assert "RUNTIME-FRONT-END-ONLY" in again.stderr


def test_the_vm_options_apply_to_the_program_only(tmp_path):
    directory = make_suite(tmp_path, {"loop.agc": LOOP, "random.agc": RANDOM, "spawn.agc": SPAWN})
    # The front end needs millions of steps to compile this: the limit does not reach it.
    limited = agentica("--max-steps", "5000", "loop.agc", cwd=directory)
    assert (limited.code, limited.stdout) == (1, "")
    assert "RUNTIME-STEP-LIMIT" in limited.stderr
    seeded = [agentica("--seed", seed, "random.agc", cwd=directory).stdout for seed in ("4", "4", "5")]
    assert seeded[0] == seeded[1]
    assert seeded[0] != seeded[2]
    assert agentica("spawn.agc", cwd=directory).stdout == "spawned\n"
    denied = agentica("--deny-run", "spawn.agc", cwd=directory)
    assert (denied.code, denied.stdout.startswith(DENIED)) == (0, True), denied


@pytest.mark.parametrize("flag", [None, "--deny-net", "--deny-fs", "--deny-env", "--deny-run", "--sandbox"])
def test_each_deny_flag_turns_its_family_into_an_error_result(tmp_path, flag):
    """The check is in the VM builtins, so a source file and compiled bytecode get the same error Result, with a stable
    prefix the program can test; the program goes on and exits 0. --sandbox is every --deny-* flag."""
    directory = make_suite(tmp_path, {"main.agc": FAMILY_CALLS})
    compiled = compile_agc(directory / "main.agc", directory / "main.agcb")
    flags = [flag] if flag else []
    for got in (agentica(*flags, "main.agc", cwd=directory), agentica("run", *flags, "--", compiled, cwd=directory)):
        assert got.code == 0, got
        lines = got.stdout.splitlines()
        assert [line.split(" ")[0] for line in lines] == [name for name, _, _ in FAMILIES], got
        for (name, _, family), line in zip(FAMILIES, lines):
            if flag in (family, "--sandbox"):
                assert line.startswith(f"{name} denied: {family}"), line
            else:
                assert "denied:" not in line, line


def test_a_front_end_of_another_version_runs_but_a_program_of_another_version_does_not(tmp_path):
    work = tmp_path
    data = front_end(work).read_bytes()
    other = work / "other.agcb"
    other.write_bytes(with_version(data, ANOTHER_VERSION))
    loaded = agentica("--front-end", other, "inputs", "x")
    # The binary names itself with the real path of its file, for the commands that start it again.
    self_path = os.path.realpath(binary())
    if os.environ.get("AGENTICA_TEST_WINE"):
        self_path = "Z:" + str(ROOT / "dist" / "agentica.exe").replace("/", "\\")
    inputs = "--version %s --self %s -- inputs x\n" % (version(), self_path)
    assert (loaded.code, loaded.stdout, loaded.stderr) == (0, inputs, "")
    refused = run_vm(other, env=vm_environment())
    assert refused.code == 2
    assert "built for another Agentica version" in refused.stderr
    # The program that a front end hands over gets the same check as a file given to the VM.
    got = agentica("--front-end", work / "front.agcb", "hand-off", other)
    assert (got.code, got.stdout) == (2, "")
    assert got.stderr == "agentica: invalid bytecode: built for another Agentica version\n"


@pytest.mark.parametrize("name", (STDLIB / "MODULES").read_text().split())
def test_the_front_end_gets_the_embedded_std_sources(tmp_path, name):
    work = tmp_path
    front = front_end(work)
    got = agentica("--front-end", front, "std", name)
    assert (got.code, got.stdout) == (0, (STDLIB / name).read_text())


def test_the_front_end_reports_a_missing_std_source(tmp_path):
    work = tmp_path
    front = front_end(work)
    missing = agentica("--front-end", front, "std", "nothing.agc")
    assert (missing.code, missing.stdout) == (0, "error: no such std source\n")


def test_std_source_gives_the_bytes_of_the_std_files(tmp_path):
    """A program sees the embedded std/ sources byte for byte as they are in stdlib/; puts adds one newline to each."""
    names = ["queue.agc", "prelude/list.agc", "internal/compiler/syntax/ast.agc"]
    # The files of stdlib/CORE are the files of compiler/ that std/analysis compiles into a program.
    files = [ROOT / "compiler/syntax/ast.agc" if name.startswith("internal/") else STDLIB / name for name in names]
    program = "def main() -> Void\n" + "".join(
        '  puts(Std.source("%s").unwrap_or("missing"))\n' % name for name in names) + "end\n"
    directory = make_suite(tmp_path, {"main.agc": program})
    out = tmp_path / "out"
    got = agentica("main.agc", cwd=directory, stdout_to=out)
    assert (got.code, got.stderr) == (0, "")
    assert out.read_bytes() == b"".join(path.read_bytes() + b"\n" for path in files)


def test_the_front_end_reads_standard_input_to_its_end(tmp_path):
    front = front_end(tmp_path)
    # The second call reads on from the end, so it gets nothing.
    got = agentica("--front-end", front, "stdin", stdin=b"a\r\nb\xff\x00")
    assert (got.code, got.stdout) == (0, "6 bytes, sum 473\n0 bytes, sum 0\n")
    empty = agentica("--front-end", front, "stdin", stdin=b"")
    assert (empty.code, empty.stdout) == (0, "0 bytes, sum 0\n" * 2)


@pytest.mark.slow
def test_the_front_end_takes_standard_input_of_exactly_the_cap(tmp_path):
    front = front_end(tmp_path)
    at_cap = agentica("--front-end", front, "stdin", stdin=b"a" * STDIN_CAP)
    assert (at_cap.code, at_cap.stdout) == (0, f"{STDIN_CAP} bytes, sum {97 * STDIN_CAP}\n0 bytes, sum 0\n")


def test_the_hand_off_runs_the_program_in_a_new_runtime(tmp_path):
    work = make_suite(tmp_path, {"user.agc": STDIN_AND_ARGS, "random.agc": RANDOM})
    front = front_end(work)
    user = compile_agc(work / "user.agc", work / "user.agcb")
    got = agentica("--front-end", front, "hand-off", user, "--", "p", "q r", stdin="in\n")
    assert (got.code, got.stdout, got.stderr) == (3, 'args ["p", "q r"]\nline ok("in")\n', "")
    # The options the front end passes on apply to the program: the front end itself ran far more than 5000 steps.
    write_files(work, {"loop.agc": LOOP})
    loop = compile_agc(work / "loop.agc", work / "loop.agcb")
    limited = agentica("--front-end", front, "hand-off", loop, "--max-steps", "5000")
    assert limited.code == 1
    assert "RUNTIME-STEP-LIMIT" in limited.stderr
    random = compile_agc(work / "random.agc", work / "random.agcb")
    draws = [agentica("--front-end", front, "hand-off", random, "--seed", seed).stdout for seed in "445"]
    assert draws[0] == draws[1]
    assert draws[0] != draws[2]


def _hand_off_program(work):
    front = front_end(work)
    write_files(work, {"user.agc": EXIT_THREE})
    return front, compile_agc(work / "user.agc", work / "user.agcb")


@pytest.mark.parametrize("words,error", (
    (["bad-program"], "error: the program is not a list of bytes, or it is too large\n"),
    (["bad-word"], "error: argument 1 has a character 0\n"),
    (["too-many-options"], "error: too many options\n"),
    (["too-many-arguments"], "error: too many arguments\n"),
), ids=("bad-program", "bad-word", "too-many-options", "too-many-arguments"))
def test_the_driver_refuses_malformed_handoff_words(tmp_path, words, error):
    front, _program = _hand_off_program(tmp_path)
    got = agentica("--front-end", front, *words)
    assert (got.code, got.stdout, got.stderr) == (0, error, "")


@pytest.mark.parametrize("options,message", (
    (["--bogus"], "agentica: unknown option --bogus\n"),
    (["--max-steps", "0"], "agentica: --max-steps needs a positive integer\n"),
    (["--version"], "agentica: the front end passed --version, which is not an option of a run\n"),
    (["--driver-pid", "1"],
     "agentica: the front end passed --driver-pid, which only the process that started agentica may name\n"),
    (["--embedded", "runner"],
     "agentica: the front end passed --embedded, which only agentica run takes\n"),
    (["word"], "agentica: the front end passed word, which is not an option of a run\n"),
), ids=("bogus", "max-steps-0", "version", "driver-pid", "embedded", "word"))
def test_the_driver_refuses_misplaced_run_options(tmp_path, options, message):
    front, program = _hand_off_program(tmp_path)
    got = agentica("--front-end", front, "hand-off", program, *options)
    assert (got.code, got.stdout, got.stderr) == (2, "", message)


@pytest.mark.parametrize("words,message", (
    (["--front-end", "/nonexistent/front.agcb"], "agentica: cannot read /nonexistent/front.agcb\n"),
    (["--front-end"], "agentica: --front-end needs a file\n"),
), ids=("missing-file", "missing-argument"))
def test_a_missing_front_end_is_a_usage_error(tmp_path, words, message):
    got = agentica(*words, timeout=scaled(10))
    assert (got.code, got.stdout, got.stderr) == (2, "", message)


def test_a_missing_front_end_refuses_a_non_file_at_once(tmp_path):
    if TARGET_OS == "windows":
        # A directory is a portable non-file that the loader must refuse before reading.
        non_file = tmp_path / "front.agcb"
        non_file.mkdir()
    else:
        non_file = tmp_path / "front.agcb"
        os.mkfifo(non_file)
        # A named pipe is refused at once, not waited for.
    got = agentica("--front-end", non_file, timeout=scaled(10))
    assert (got.code, got.stdout, got.stderr) == (2, "", "agentica: cannot read %s\n" % non_file)


def test_the_environment_and_the_version_flag_are_read_before_a_front_end_runs(tmp_path):
    work = tmp_path
    trace = work / "trace"
    env = vm_environment({"AGENTICA_VM_TRACE": "io", "AGENTICA_VM_TRACE_FILE": trace})
    answer = agentica("--version", env=env)
    assert (answer.code, answer.stdout, answer.stderr) == (0, version() + "\n", "")
    assert not trace.exists()
    # The program of a run would not start with this variable, so the front end does not compile for it either.
    refused = agentica(ROOT / "examples" / "hello.agc",
                       env=vm_environment({"AGENTICA_FLUSH_TIMEOUT_MS": "soon"}), timeout=scaled(10))
    assert (refused.code, refused.stdout) == (2, "")
    assert "AGENTICA_FLUSH_TIMEOUT_MS needs an integer" in refused.stderr


HELLO = ROOT / "examples" / "hello.agc"
SCHEDULERS_RANGE = "needs an integer from 1 to 1024"
RAN_ON = re.compile(r"^agc-trace \S+ sched run schedulers=([0-9]+)$", re.M)


def scheduler_counts(result):
    """The scheduler counts of the runs that a sched trace on stderr shows, in order (the front end's first)."""
    return [int(count) for count in RAN_ON.findall(result.stderr)]


def logical_cores():
    """The CPUs this process may run on, as uv_available_parallelism counts them, at most 1024."""
    count = len(os.sched_getaffinity(0)) if hasattr(os, "sched_getaffinity") else os.cpu_count()
    return min(max(count or 1, 1), 1024)


@pytest.fixture(scope="module")
def sched_trace():
    if "trace off" in run([binary(), "run", "--version"], env=vm_environment(), timeout=scaled(10)).stdout:
        pytest.skip("the VM was built with TRACE=0")
    # AGENTICA_SCHEDULERS is unset even under AGENTICA_VM_TEST_MODULE_SCHEDULERS, so a run without the flag or a value
    # of its own gets the default count.
    return {"AGENTICA_VM_TRACE": "sched", "AGENTICA_SCHEDULERS": None}


def test_the_scheduler_count_is_checked_before_the_program_runs_and_the_flag_wins(tmp_path, sched_trace):
    """`--schedulers N` and AGENTICA_SCHEDULERS take 1 to 1024 and the flag wins over a valid value; anything else is a
    start error (status 2) with nothing on stdout."""
    asked = {}
    for count in ("0", "1025", "x", "-1", ""):
        got = agentica("--schedulers", count, HELLO, timeout=scaled(10))
        asked[count] = (got.code, got.stdout, SCHEDULERS_RANGE in got.stderr)
    assert asked == {count: (2, "", True) for count in asked}
    program = compile_agc(HELLO, tmp_path / "hello.agcb")
    ran = {}
    for words, env in ((("--schedulers", "1"), {}), (("--schedulers", "2"), {}), ((), {"AGENTICA_SCHEDULERS": "3"}),
                       (("--schedulers", "1"), {"AGENTICA_SCHEDULERS": "3"})):
        got = run_vm(program, *words, env=vm_environment({**sched_trace, **env}), timeout=scaled(10))
        ran[words + tuple(env.values())] = (got.code, got.stdout, scheduler_counts(got))
    assert ran == {("--schedulers", "1"): (0, "hello\n", [1]), ("--schedulers", "2"): (0, "hello\n", [2]),
                   ("3",): (0, "hello\n", [3]), ("--schedulers", "1", "3"): (0, "hello\n", [1])}
    # The front end compiles on one scheduler whatever the count, so its output stays the same; the program gets N.
    got = agentica("--schedulers", "2", HELLO, env=vm_environment(sched_trace), timeout=scaled(10))
    assert (got.code, got.stdout, scheduler_counts(got)) == (0, "hello\n", [1, 2])


def test_a_run_that_chooses_no_count_has_one_scheduler_per_logical_core(tmp_path, sched_trace):
    program = compile_agc(HELLO, tmp_path / "hello.agcb")
    got = run_vm(program, env=vm_environment(sched_trace), timeout=scaled(10))
    assert (got.code, got.stdout, scheduler_counts(got)) == (0, "hello\n", [logical_cores()])
    got = run_vm(program, env=vm_environment({**sched_trace, "AGENTICA_SCHEDULERS": ""}), timeout=scaled(10))
    assert (got.code, got.stdout, scheduler_counts(got)) == (0, "hello\n", [logical_cores()])


@pytest.mark.skipif(not hasattr(os, "sched_setaffinity"), reason="host-only: sched_setaffinity sets the CPUs of a process on Linux only")
def test_the_default_count_follows_the_cpus_the_process_may_use(tmp_path, sched_trace):
    """The default is the CPUs of the process (its affinity), not the CPUs of the machine."""
    program = compile_agc(HELLO, tmp_path / "hello.agcb")
    first = sorted(os.sched_getaffinity(0))[0]
    got = subprocess.run([*vm_command(), "--", program], env=vm_environment(sched_trace), capture_output=True,
                         text=True, timeout=scaled(10), preexec_fn=lambda: os.sched_setaffinity(0, {first}))
    assert (got.returncode, got.stdout, scheduler_counts(got)) == (0, "hello\n", [1])


@pytest.mark.parametrize("value, flag, code", (
    ("0", None, 2), ("1025", None, 2), ("many", None, 2), ("-1", None, 2),
    ("0001", None, 0), ("1", None, 0), ("1024", "1", 0),
    # An empty variable is unset.
    ("", None, 0), ("", "1", 0),
    # A bad variable is an error even next to a valid flag: the flag wins over a valid value only.
    ("many", "1", 2), ("0", "1", 2),
))
def test_the_scheduler_variable_is_checked_for_every_command(value, flag, code):
    """AGENTICA_SCHEDULERS is read before the front end starts, so a bad value stops `check` and a program alike."""
    env = vm_environment({"AGENTICA_SCHEDULERS": value})
    words = ("--schedulers", flag) if flag else ()
    for command in ((HELLO,), ("check", HELLO)):
        got = agentica(*words, *command, env=env, timeout=scaled(10))
        assert got.code == code, (value, flag, command, got.stderr)
        if code == 2:
            assert (got.stdout, "AGENTICA_SCHEDULERS " + SCHEDULERS_RANGE in got.stderr) == ("", True)


def test_the_test_command_refuses_the_flag_and_points_at_the_variable(tmp_path):
    """The test files run in VMs that the driver starts, so the flag is refused up front instead of dropped."""
    for count in ("1", "4"):
        refused = agentica("--schedulers", count, "test", cwd=tmp_path, timeout=scaled(10))
        assert (refused.code, refused.stdout) == (2, "") and "AGENTICA_SCHEDULERS" in refused.stderr


@pytest.mark.skipif(UNDER_WINE, reason="Wine cannot make the owner-only run folder of the test driver")
def test_the_scheduler_variable_reaches_the_vms_that_the_test_driver_starts(tmp_path, sched_trace):
    """The driver cannot see the variable in a flag; the runner and the test files run at its count, the front ends at
    one."""
    (tmp_path / "test").mkdir()
    (tmp_path / "test" / "x_test.agc").write_text('def main() -> Void\n  Test.run([])\nend\n')
    trace = tmp_path / "trace"
    env = vm_environment({**sched_trace, "AGENTICA_SCHEDULERS": "3", "TMPDIR": tmp_path,
                          "AGENTICA_VM_TRACE_FILE": trace})
    ran = agentica("test", cwd=tmp_path, env=env, timeout=scaled(30))
    assert (ran.stderr, ran.stdout.startswith("0 passed, 0 failed")) == ("", True)
    assert set(int(count) for count in RAN_ON.findall(trace.read_text())) == {1, 3}


def test_a_problem_in_a_std_module_shows_that_module_not_a_file_of_the_working_folder(tmp_path):
    """A front end on the VM with --stdlib DIR: DIR/queue.agc is broken, ./std/queue.agc is a decoy."""
    require(STAGE2.is_file(), "the front end is not built (%s): run make stage2" % STAGE2)
    work = make_suite(tmp_path, {"main.agc": USES_STD})
    (work / "libstd").mkdir()
    (work / "libstd" / "queue.agc").write_text((STDLIB / "queue.agc").read_text() + BROKEN_STD)
    (work / "std").mkdir()
    (work / "std" / "queue.agc").write_text("# a decoy\n" * 100)
    got = run_vm(STAGE2, args=["--version", version(), "--stdlib", "libstd", "--", "compile", "main.agc",
                               "-o", "out.agcb"], cwd=work, env=vm_environment())
    assert (got.code, got.stdout) == (1, "")
    assert "std/queue.agc:" in got.stderr
    assert 'return "text"' in got.stderr
    assert "decoy" not in got.stderr
