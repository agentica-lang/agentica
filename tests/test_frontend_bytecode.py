"""The Agentica bytecode writer (compiler/bytecode.agc) against the frozen output of the Racket writer.

tests/frontend-bytecode-test.rkt compares the two live. This module compares the Agentica writer with what the Racket
writer made once for the same programs (`make frontend-freeze`, tests/frontend-bytecode-freeze.rkt): the .agcb bytes of
the lowering fixtures, examples/, tests/fixtures/vm/, every std/ module, the compiler, trees at the nesting limit and a
generated program (as SHA-256 of the file, since the bytes of the big ones are megabytes), the lines of the limit
scenarios, the opcode table, and what the VM prints for the Agentica file of two programs. Inputs that are a formula are
rebuilt here; the manifests hold their hashes.
"""
import json
import re

from tests.agentica_test import FIXTURES, ROOT, compile_agc, run_vm, scaled, slow, timeout, vm_environment
from tests.frontend_cases import lower_deep_cases, lower_generated_program, wide_span_programs
from tests.frontend_support import FROZEN, StageTestCase, load_corpus, sections, sha256, write_files
from tests.test_frontend_check import direct_files

LIMITS_FIXTURE = FIXTURES / "frontend" / "limits" / "limits.agc"
TABLES = ROOT / "compiler" / "bytecode_tables.agc"

# The format version of the .agcb file and its header: the magic and the version as a 32-bit little-endian number.
FORMAT_VERSION = 5

# The Agentica version of the header is an input of the writer (the front end gets it from its caller, 35.3), so the
# runs below pass it with --version=V. The released version still lives in src/version.rkt; step 8a moves it to a plain
# file. The frozen manifests hash the file without it.
VERSION = re.search(r'\(define version "([^"]+)"\)',
                    (ROOT / "src" / "version.rkt").read_text(encoding="utf-8")).group(1)


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


class BytecodeFrozenTest(StageTestCase):
    ENTRY = "bytecode.agc"
    STDLIB = True

    def compile_paths(self, paths, directory, timeout=scaled(1800)):
        """Compile each path (relative to `directory`) to a file of its own.

        Gives {path: what the Racket writer froze for it}: the size and the hash of the file it wrote without the version
        (`wrote N bytes`, then the hash), or the line the runner printed for a failure and `no file`. Each call writes into
        a fresh folder, so a file of an earlier call is never taken for the output of a failure.
        """
        outputs = self.make_temp_dir()
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
            self.assertEqual(found[path], "wrote %d bytes\n" % len(data), path)
            body = without_version(data)
            results[path] = "wrote %d bytes\n%s\n" % (len(body), sha256(body))
        self.files = targets
        return results

    def compile_cases(self, cases, folder):
        """Write the programs {key: text} as <folder>/<key>.agc and compile them; gives {key: result}."""
        directory = self.make_temp_dir()
        write_files(directory, {"%s/%s.agc" % (folder, key): text for key, text in cases.items()})
        results = self.compile_paths(["%s/%s.agc" % (folder, key) for key in cases], directory)
        return {key: results["%s/%s.agc" % (folder, key)] for key in cases}

    def fast_paths(self):
        files = load_corpus("examples", "fixtures")
        paths = (lower_fixture_paths(files) + direct_files(files, "tests/fixtures/frontend/bytecode")
                 + direct_files(files, "examples"))
        return files, paths

    def test_the_opcode_table_is_the_one_of_the_racket_writer(self):
        text = TABLES.read_text(encoding="utf-8")
        start = re.search(r"OPCODES = \{", text).end()
        pairs = re.findall(r'"([^"]+)": ([0-9]+)', text[start:text.index("\n}", start)])
        self.assert_golden("".join("%s %s\n" % pair for pair in pairs), FROZEN / "bytecode" / "opcodes.expected")

    def test_the_lowering_fixtures_fill_every_section_of_the_file(self):
        # The writer turns the lowering of these programs into the file, so the sections that their goldens fill are the
        # sections the byte comparisons below exercise. (The opcodes have their own test in test_frontend_lower.py.) An
        # accepted loss against the rackunit test, which looked at the Racket program value: the `types` and `decodable`
        # sections are not told apart here (both come with a `types=[` struct line), and the spans and the functions are
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
        self.assertEqual(missing, [])
        unicode_fixture = (ROOT / "tests" / "fixtures" / "frontend" / "bytecode" / "unicode.agc").read_text(encoding="utf-8")
        self.assertTrue(any(ord(char) > 127 for char in unicode_fixture), "a string with a multi-byte character")

    def test_the_header_constants_are_those_of_the_racket_writer(self):
        text = TABLES.read_text(encoding="utf-8")
        self.assertEqual(re.search(r"^export FORMAT_VERSION = (.+)$", text, flags=re.MULTILINE).group(1),
                         str(FORMAT_VERSION))
        # There is no VERSION constant: the header carries the version that the caller passed in.
        self.assertIsNone(re.search(r"^export VERSION\b", text, flags=re.MULTILINE))
        self.compile_paths(["examples/hello.agc"], self.corpus_dir("examples", "fixtures"))
        data = self.files["examples/hello.agc"].read_bytes()
        self.assertEqual(data[:8], b"AGCB" + FORMAT_VERSION.to_bytes(4, "little"))
        length = int.from_bytes(data[8:12], "little")
        self.assertEqual(data[12:12 + length].decode("utf-8"), VERSION)

    def test_the_writer_reaches_the_limits_and_the_internal_errors_as_the_racket_writer_does(self):
        bytecode = compile_agc(LIMITS_FIXTURE, self.stage_dir / "limits.agcb")
        result = run_vm(bytecode, args=["--version=%s" % VERSION], cwd=ROOT, env=vm_environment(), timeout=scaled(300))
        self.assertEqual(result.code, 0, result.stderr)
        self.assertGreater(len(scenario_names("SCENARIOS")), 15)
        self.assert_golden(result.stdout, FROZEN / "bytecode" / "limits.expected")

    def test_the_writer_writes_the_bytes_of_the_racket_writer(self):
        files, paths = self.fast_paths()
        results = self.compile_paths(paths, self.corpus_dir("examples", "fixtures"))
        self.assert_manifest(results, "bytecode/fast.sha256", files)
        # A check failure and an import failure print their ERROR line and write no file.
        failures = [results[path] for path in paths if "/error-" in path]
        self.assertEqual(len(failures), 2)
        self.assertTrue(any(re.match(r"ERROR CHECK-[A-Z-]+ ", line) for line in failures))
        self.assertTrue(any(line.startswith("ERROR CHECK-IMPORT-IO ") for line in failures))
        self.assertTrue(all(line.endswith("\nno file\n") for line in failures))

    def test_spans_past_65535_are_written_with_the_bytes_of_the_racket_writer(self):
        # A line or a column of 65536 or more takes the general branch of Bytes.u32 and of span_bytes, which the corpus
        # never reaches. A file index of 65536 or more would need that many sources, which is not worth the time.
        cases = wide_span_programs()
        self.assertTrue(cases["lines"].count("\n") > 65535)
        self.assertTrue(max(len(line) for line in cases["columns"].split("\n")) > 65535)
        self.assert_manifest(self.compile_cases(cases, "wide"), "bytecode/wide-spans.sha256", cases)

    def test_the_vm_runs_the_agentica_file_as_it_runs_the_racket_file(self):
        files, paths = self.fast_paths()
        self.compile_paths(paths, self.corpus_dir("examples", "fixtures"))
        found = ""
        for name, path in (("basics", "tests/fixtures/frontend/lower/basics.agc"),
                           ("unicode", "tests/fixtures/frontend/bytecode/unicode.agc")):
            result = run_vm(self.files[path], cwd=ROOT, env=vm_environment())
            found += ("== %s\nexit %d\nstdout %s\nstderr %s\n"
                      % (name, result.code, json.dumps(result.stdout, ensure_ascii=False),
                         json.dumps(result.stderr, ensure_ascii=False)))
        # The whole file, so that a missing or an extra section fails too (and a refreeze rewrites it).
        self.assert_golden(found, FROZEN / "bytecode" / "runs.expected")

    @slow
    @timeout(3600)
    def test_the_vm_fixtures(self):
        files = load_corpus("fixtures")
        paths = direct_files(files, "tests/fixtures/vm")
        self.assertGreater(len(paths), 200)
        results = self.compile_paths(paths, self.corpus_dir("fixtures"))
        self.assert_manifest(results, "bytecode/vm.sha256", files)

    @slow
    @timeout(3600)
    def test_every_std_module_and_the_compiler(self):
        wrappers = {}
        for path in load_corpus("stdlib"):
            name = path[len("stdlib/"):-len(".agc")]
            wrappers["std-" + name.replace("/", "_")] = "import Module from \"std/%s\"\n\ndef main() -> Void\nend\n" % name
        compiler = load_corpus("compiler")
        files = {path: compiler[path] for path in direct_files(compiler, "compiler")}
        self.assertGreater(len(wrappers) + len(files), 50)
        results = self.compile_cases(wrappers, "std")
        directory = self.make_temp_dir()
        write_files(directory, files)
        results.update(self.compile_paths(sorted(files), directory))
        self.assert_manifest(results, "bytecode/std-compiler.sha256", dict(wrappers, **files))

    @slow
    @timeout(3600)
    def test_trees_at_the_nesting_limit_and_a_generated_program_are_written_with_equal_bytes(self):
        cases = {"generated": lower_generated_program(300)}
        cases.update({"deep-" + name: text for name, text in lower_deep_cases().items()})
        self.assert_manifest(self.compile_cases(cases, "deep"), "bytecode/deep.sha256", cases)

    @slow
    @timeout(3600)
    def test_the_writer_matches_the_racket_writer_on_the_large_limit_scenarios(self):
        bytecode = compile_agc(LIMITS_FIXTURE, self.stage_dir / "limits.agcb")
        result = run_vm(bytecode, args=["slow", "--version=%s" % VERSION], cwd=ROOT, env=vm_environment(),
                        timeout=scaled(1800))
        self.assertEqual(result.code, 0, result.stderr)
        self.assertEqual(len(scenario_names("SLOW_SCENARIOS")), 4)
        self.assert_golden(result.stdout, FROZEN / "bytecode" / "limits-slow.expected")
