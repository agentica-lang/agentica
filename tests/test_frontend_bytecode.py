"""The Agentica bytecode writer (compiler/bytecode/bytecode.agc) against the frozen output of the original writer.

This module compares the Agentica writer with what the original writer made once for the same programs (frozen in
tests/fixtures/frontend/frozen/; tools/refreeze.py rewrites them from the Agentica stages): the .agcb bytes of
the lowering fixtures, examples/, tests/fixtures/vm/, every std/ module, the compiler, trees at the nesting limit and a
generated program (as SHA-256 of the file, since the bytes of the big ones are megabytes), the lines of the limit
scenarios, the opcode table, and what the VM prints for the Agentica file of two programs. Inputs that are a formula are
rebuilt here; the manifests hold their hashes.
"""
import json
import re

import pytest

from tests.agentica_test import FIXTURES, ROOT, compile_agc, run_vm, scaled, timeout, vm_environment
from tests.frontend_cases import lower_deep_cases, lower_generated_program, wide_span_programs
from tests.frontend_support import (
    FROZEN, PytestStageCase, assert_golden, assert_manifest, load_corpus, pytest_stage_fixtures, sections, sha256,
    direct_files, stdlib_compiler_sources, write_files)

LIMITS_FIXTURE = FIXTURES / "frontend" / "limits" / "limits.agc"
TABLES = ROOT / "compiler" / "bytecode" / "bytecode_tables.agc"

# The format version of the .agcb file and its header: the magic and the version as a 32-bit little-endian number.
FORMAT_VERSION = 6

# The Agentica version of the header is an input of the writer (the front end gets it from its caller, §18.2), so the
# runs below pass it with --version=V. It is the one line of the VERSION file. The frozen manifests hash the file
# without it.
VERSION = (ROOT / "VERSION").read_text(encoding="utf-8").strip()

def lower_fixture_paths(files):
    """The lowering fixtures: a NAME.agc file or a folder NAME with a root.agc."""
    prefix = "tests/fixtures/frontend/lower/"
    found = []
    for path in files:
        if path.startswith(prefix):
            rest = path[len(prefix):]
            if "/" not in rest or re.fullmatch(r"[^/]*/root\.agc", rest):
                found.append(path)
    return sorted(found)


def scenario_names(constant):
    """The strings of a list constant of the limits fixture (SCENARIOS or SLOW_SCENARIOS)."""
    text = LIMITS_FIXTURE.read_text(encoding="utf-8")
    start = re.search(r"^%s = \[" % constant, text, flags=re.MULTILINE).end()
    return re.findall(r'"([^"]+)"', text[start:text.index("]", start)])


def without_version(data):
    """The file without the length and the text of the Agentica version, which a release changes (magic and format
    version, then the length of the version and its bytes)."""
    length = int.from_bytes(data[8:12], "little")
    return data[:8] + data[12 + length:]


def fast_paths():
    """The programs of the fast tier: the lowering fixtures, the bytecode fixtures and examples/."""
    files = load_corpus("examples", "fixtures")
    paths = (lower_fixture_paths(files) + direct_files(files, "tests/fixtures/frontend/bytecode")
             + direct_files(files, "examples"))
    return files, paths


class BytecodeStage(PytestStageCase):
    ENTRY = "bytecode/bytecode.agc"
    STDLIB = True

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.files = {}

    def compile_paths(self, paths, directory, timeout=scaled(1800)):
        """Compile each path (relative to `directory`) to a file of its own.

        Gives {path: what the original writer froze for it}: the size and the hash of the file it wrote without the
        version (`wrote N bytes`, then the hash), or the line the runner printed for a failure and `no file`. Each call
        writes into a fresh folder, so a file of an earlier call is never taken for the output of a failure.
        """
        outputs = self.temp_dir()
        arguments = ["--stdlib=%s" % self.stdlib, "--version=%s" % VERSION]
        targets = {}
        for n, path in enumerate(paths):
            targets[path] = outputs / ("%d.agcb" % n)
            arguments += [path, "-o", str(targets[path])]
        found = sections(self.run_stage(*arguments, cwd=directory, timeout=timeout))
        results = {}
        for path, target in targets.items():
            if not target.exists():
                results[path] = found[path] + "no file\n"
                continue
            data = target.read_bytes()
            assert found[path] == "wrote %d bytes\n" % len(data), path
            body = without_version(data)
            results[path] = "wrote %d bytes\n%s\n" % (len(body), sha256(body))
        self.files = targets
        return results

    def compile_cases(self, cases, folder):
        """Write the programs {key: text} as <folder>/<key>.agc and compile them; gives {key: result}."""
        directory = self.temp_dir()
        write_files(directory, {"%s/%s.agc" % (folder, key): text for key, text in cases.items()})
        results = self.compile_paths(["%s/%s.agc" % (folder, key) for key in cases], directory)
        return {key: results["%s/%s.agc" % (folder, key)] for key in cases}


_bytecode_stage_class, stage = pytest_stage_fixtures(BytecodeStage, pytest)


def test_the_opcode_table_is_the_one_of_the_original_writer():
    text = TABLES.read_text(encoding="utf-8")
    start = re.search(r"OPCODES = \{", text).end()
    pairs = re.findall(r'"([^"]+)": ([0-9]+)', text[start:text.index("\n}", start)])
    assert_golden("".join("%s %s\n" % pair for pair in pairs), FROZEN / "bytecode" / "opcodes.expected")


def test_the_opcode_numbers_are_those_of_agc_opcode_in_vm_value_h():
    # The C loader and the writer must count the opcodes the same way; the order of the enum is the number.
    header = (ROOT / "vm" / "value.h").read_text(encoding="utf-8")
    in_c = [name for name in re.findall(r"\bAGC_OP_([A-Z_]+)\b", header) if name != "COUNT"]
    text = TABLES.read_text(encoding="utf-8")
    start = re.search(r"OPCODES = \{", text).end()
    pairs = re.findall(r'"([^"]+)": ([0-9]+)', text[start:text.index("\n}", start)])
    assert [int(number) for _, number in pairs] == list(range(len(pairs)))
    assert [name.upper().replace("-", "_") for name, _ in pairs] == in_c
    # The profile's opcode rows name each opcode as the writer does.
    profile = (ROOT / "vm" / "profile.c").read_text(encoding="utf-8")
    names = profile[profile.index("opcode_names[] = {"):]
    assert re.findall(r'"([^"]+)"', names[:names.index("};")]) == [name for name, _ in pairs]


def test_the_lowering_fixtures_fill_every_section_of_the_file():
    # The writer turns the lowering of these programs into the file, so the sections that their goldens fill are the
    # sections the byte comparisons below exercise. (The opcodes have their own test in test_frontend_lower.py.) An
    # accepted loss against the original test, which looked at the program value of the writer: the `types` and
    # `decodable` sections are not told apart here (both come with a `types=[` struct line), and the spans and the functions are
    # taken as filled when any instruction has a span or any function is lowered.
    lowered = "".join(path.read_bytes().decode("utf-8")
                      for path in sorted((ROOT / "tests" / "fixtures" / "frontend" / "lower").glob("*.ir")))
    patterns = {
        "sources": r"^source 0 ", "more than one source": r"^source 1 ", "spans": r" @ \d+:\d+:\d+-",
        "structs": r"^struct ", "types and decodable": r" types=\[", "enums": r"^enum ",
        "updates": r"^    struct-with ", "globals": r"globals=[1-9]", "builtins": r"^    call-builtin ",
        "functions": r"^fn0 ",
        "a void constant": r"^    const r\d+ void ", "a nil constant": r"^    const r\d+ nil ",
        "a false constant": r"^    const r\d+ false ", "a true constant": r"^    const r\d+ true ",
        "an int constant": r"^    const r\d+ int:", "a float constant": r"^    const r\d+ float:",
        "a string constant": r'^    const r\d+ "',
    }
    missing = [name for name, pattern in patterns.items() if not re.search(pattern, lowered, flags=re.MULTILINE)]
    assert missing == []
    unicode_fixture = (ROOT / "tests" / "fixtures" / "frontend" / "bytecode" / "unicode.agc").read_text(encoding="utf-8")
    assert any(ord(char) > 127 for char in unicode_fixture), "a string with a multi-byte character"


def test_the_header_constants_are_those_of_the_original_writer(stage):
    text = TABLES.read_text(encoding="utf-8")
    assert re.search(r"^export FORMAT_VERSION = (.+)$", text, flags=re.MULTILINE).group(1) == str(FORMAT_VERSION)
    # There is no VERSION constant: the header carries the version that the caller passed in.
    assert re.search(r"^export VERSION\b", text, flags=re.MULTILINE) is None
    stage.compile_paths(["examples/hello.agc"], stage.corpus_dir("examples", "fixtures"))
    data = stage.files["examples/hello.agc"].read_bytes()
    assert data[:8] == b"AGCB" + FORMAT_VERSION.to_bytes(4, "little")
    length = int.from_bytes(data[8:12], "little")
    assert data[12:12 + length].decode("utf-8") == VERSION


def test_the_writer_reaches_the_limits_and_the_internal_errors_as_the_original_writer_does(stage):
    bytecode = compile_agc(LIMITS_FIXTURE, stage.stage_dir / "limits.agcb")
    result = run_vm(bytecode, args=["--version=%s" % VERSION], cwd=ROOT, env=vm_environment(), timeout=scaled(300))
    assert result.code == 0, result.stderr
    assert len(scenario_names("SCENARIOS")) > 15
    assert_golden(result.stdout, FROZEN / "bytecode" / "limits.expected")


def test_the_writer_writes_the_bytes_of_the_original_writer(stage):
    files, paths = fast_paths()
    results = stage.compile_paths(paths, stage.corpus_dir("examples", "fixtures"))
    assert_manifest(results, "bytecode/fast.sha256", files)
    # A check failure and an import failure print their ERROR line and write no file.
    failures = [results[path] for path in paths if "/error-" in path]
    assert len(failures) == 2
    assert any(re.match(r"ERROR CHECK-[A-Z-]+ ", line) for line in failures)
    assert any(line.startswith("ERROR CHECK-IMPORT-IO ") for line in failures)
    assert all(line.endswith("\nno file\n") for line in failures)


def test_spans_past_65535_are_written_with_the_bytes_of_the_original_writer(stage):
    # A line or a column of 65536 or more takes the general branch of Bytes.u32 and of span_bytes, which the corpus
    # never reaches. A file index of 65536 or more would need that many sources, which is not worth the time.
    cases = wide_span_programs()
    assert cases["lines"].count("\n") > 65535
    assert max(len(line) for line in cases["columns"].split("\n")) > 65535
    assert_manifest(stage.compile_cases(cases, "wide"), "bytecode/wide-spans.sha256", cases)


def test_the_vm_runs_the_agentica_file_as_it_runs_the_original_file(stage):
    _files, paths = fast_paths()
    stage.compile_paths(paths, stage.corpus_dir("examples", "fixtures"))
    found = ""
    for name, path in (("basics", "tests/fixtures/frontend/lower/basics.agc"),
                       ("unicode", "tests/fixtures/frontend/bytecode/unicode.agc")):
        result = run_vm(stage.files[path], cwd=ROOT, env=vm_environment())
        found += ("== %s\nexit %d\nstdout %s\nstderr %s\n"
                  % (name, result.code, json.dumps(result.stdout, ensure_ascii=False),
                     json.dumps(result.stderr, ensure_ascii=False)))
    # The whole file, so that a missing or an extra section fails too (and a refreeze rewrites it).
    assert_golden(found, FROZEN / "bytecode" / "runs.expected")


@pytest.mark.slow
@timeout(3600)
def test_the_vm_fixtures(stage):
    files = load_corpus("fixtures")
    paths = direct_files(files, "tests/fixtures/vm")
    assert len(paths) > 200
    results = stage.compile_paths(paths, stage.corpus_dir("fixtures"))
    assert_manifest(results, "bytecode/vm.sha256", files)


@pytest.mark.slow
@timeout(3600)
def test_every_std_module_and_the_compiler(stage):
    wrappers, files = stdlib_compiler_sources()
    results = stage.compile_cases(wrappers, "std")
    directory = stage.temp_dir()
    write_files(directory, files)
    results.update(stage.compile_paths(sorted(files), directory))
    assert_manifest(results, "bytecode/std-compiler.sha256", dict(wrappers, **files))


@pytest.mark.slow
@timeout(3600)
def test_trees_at_the_nesting_limit_and_a_generated_program_are_written_with_equal_bytes(stage):
    cases = {"generated": lower_generated_program(300)}
    cases.update({"deep-" + name: text for name, text in lower_deep_cases().items()})
    assert_manifest(stage.compile_cases(cases, "deep"), "bytecode/deep.sha256", cases)


@pytest.mark.slow
@timeout(3600)
def test_the_writer_matches_the_original_writer_on_the_large_limit_scenarios(stage):
    bytecode = compile_agc(LIMITS_FIXTURE, stage.stage_dir / "limits.agcb")
    result = run_vm(bytecode, args=["slow", "--version=%s" % VERSION], cwd=ROOT, env=vm_environment(),
                    timeout=scaled(1800))
    assert result.code == 0, result.stderr
    assert len(scenario_names("SLOW_SCENARIOS")) == 4
    assert_golden(result.stdout, FROZEN / "bytecode" / "limits-slow.expected")
