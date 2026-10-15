"""The Agentica checker (compiler/check.agc) against the frozen output of the Racket checker.

tests/frontend-check-test.rkt compares the two live. This module compares the Agentica checker with what the Racket
checker printed once for the same inputs (`make frontend-freeze`, tests/frontend-check-freeze.rkt): the programs of the
cases of tests/checker-test.rkt, 1,500 mutants of them, the corpus (examples/ and tests/fixtures/vm/ as they were at the
freeze), every std/ module, the compiler, trees around the nesting limit and a program of 1,000 functions. Inputs that
are a formula are rebuilt here; the manifests hold their hashes.
"""
import re
import time

from tests.agentica_test import ROOT, slow
from tests.frontend_cases import check_deep_cases, check_generated_program
from tests.frontend_support import FROZEN, StageTestCase, load_corpus, load_json, write_files

FIXTURES = ROOT / "tests" / "fixtures" / "frontend" / "check"

# The codes the Racket checker has and no program can reach: CHECK-INTERNAL guards an impossible node,
# CHECK-MODULE-CONTEXT a program that still has imports (the linker removes them) and CHECK-BLOCK-TYPE a block with no
# expected type (a block is only parsed after a call, whose parameter gives the type).
UNREACHABLE_CODES = ("CHECK-INTERNAL", "CHECK-MODULE-CONTEXT", "CHECK-BLOCK-TYPE")


def direct_files(files, folder):
    """The paths of a folder that are not in a subfolder, sorted."""
    return sorted(path for path in files
                  if path.startswith(folder + "/") and "/" not in path[len(folder) + 1:])


class CheckFrozenTest(StageTestCase):
    ENTRY = "check.agc"
    STDLIB = True

    def check_files(self, files):
        """Check the files {path: text} written into a fresh folder; gives {path: output}."""
        directory = self.make_temp_dir()
        write_files(directory, files)
        return self.run_sections(sorted(files), "--stdlib=%s" % self.stdlib, cwd=directory)

    def fixture_roots(self):
        """{fixture name: path of its program relative to the repository}: NAME.agc, or NAME/root.agc for a folder."""
        roots = {}
        for path in sorted(FIXTURES.iterdir()):
            if path.is_dir():
                roots[path.name] = "tests/fixtures/frontend/check/%s/root.agc" % path.name
            elif path.suffix == ".agc":
                roots[path.stem] = "tests/fixtures/frontend/check/" + path.name
        return roots

    def golden_texts(self):
        roots = self.fixture_roots()
        goldens = self.fixture_goldens(FIXTURES, list(roots), ".checked")
        return {name: path.read_bytes().decode("utf-8") for name, path in goldens.items()}

    def test_every_fixture_has_a_golden_and_no_golden_is_left_over(self):
        self.fixture_goldens(FIXTURES, list(self.fixture_roots()), ".checked")

    def test_the_checker_matches_the_goldens_of_the_fixtures_types_resolutions_and_diagnostics(self):
        roots = self.fixture_roots()
        goldens = self.fixture_goldens(FIXTURES, list(roots), ".checked")
        outputs = self.run_sections(list(roots.values()), "--stdlib=%s" % (ROOT / "stdlib"), cwd=ROOT)
        self.assert_goldens({name: outputs[path] for name, path in roots.items()}, goldens, "checker fixtures")

    def test_the_method_tables_are_the_ones_of_the_freeze(self):
        # compiler/check_tables.agc is generated from the method tables of src/checker.rkt (tools/gen-check-tables.rkt).
        source = (ROOT / "compiler" / "check_tables.agc").read_bytes().decode("utf-8")
        self.assert_golden(source, FROZEN / "check" / "tables.expected")

    def test_the_fixtures_end_in_every_check_diagnostic_the_checker_can_give(self):
        codes = (FROZEN / "check" / "codes.expected").read_text(encoding="utf-8").split()
        seen = "".join(self.golden_texts().values())
        missing = [code for code in codes if code not in UNREACHABLE_CODES and "ERROR %s " % code not in seen]
        self.assertEqual(missing, [])

    def test_the_fixtures_check_a_call_of_a_builtin_of_every_rule_of_the_builtin_table(self):
        listing = (FROZEN / "check" / "builtin-rules.expected").read_text(encoding="utf-8")
        rules = dict(line.split(" ") for line in listing.splitlines())
        seen = "".join(self.golden_texts().values())
        used = re.findall(r'name="([^"]+)" piped', seen) + re.findall(r'resolved=call\("([^"]+)"', seen)
        covered = {rules[name] for name in used if name in rules}
        self.assertEqual(sorted(set(rules.values()) - covered), [])

    @slow
    def test_the_programs_of_the_cases_of_the_racket_checker_tests(self):
        programs = load_json("corpus/checker-programs.json")
        self.assertGreater(len(programs), 400)
        cases = {"c%d" % n: text for n, text in enumerate(programs)}
        self.assert_manifest(self.run_cases(cases), "check/programs.sha256", cases)

    @slow
    def test_1500_mutated_programs(self):
        cases = {"m%d" % n: text for n, text in enumerate(load_json("check/mutated.json"))}
        outputs = self.run_cases(cases, folder="mutated")
        self.assert_manifest(outputs, "check/mutated.sha256", cases)
        checked = sum(1 for text in outputs.values() if not re.match(r"ERROR (PARSE|LEX)-", text))
        self.assertGreater(checked, 150, "%d of 1500 mutants reach the checker" % checked)

    @slow
    def test_examples_and_the_vm_fixtures(self):
        # The programs import files of the subfolders, so the whole corpus is written.
        files = load_corpus("examples", "fixtures")
        paths = direct_files(files, "examples") + direct_files(files, "tests/fixtures/vm")
        self.assertGreater(len(paths), 200)
        outputs = self.run_sections(paths, "--stdlib=%s" % self.stdlib, cwd=self.corpus_dir("examples", "fixtures"))
        self.assert_manifest(outputs, "check/corpus.sha256", files)

    @slow
    def test_every_std_module_and_the_compiler(self):
        stdlib = load_corpus("stdlib")
        wrappers = {}
        for path in stdlib:
            name = path[len("stdlib/"):-len(".agc")]
            wrappers["std-" + name.replace("/", "_")] = (
                "import Module from \"std/%s\"\n\ndef main() -> Void\nend\n" % name)
        compiler = load_corpus("compiler")
        cases = dict(wrappers)
        cases.update({path: compiler[path] for path in direct_files(compiler, "compiler")})
        outputs = self.run_cases(wrappers, folder="std")
        outputs.update(self.check_files({path: compiler[path] for path in direct_files(compiler, "compiler")}))
        self.assert_manifest(outputs, "check/std-compiler.sha256", cases)

    @slow
    def test_trees_around_the_nesting_limit_give_the_same_types_or_the_same_too_deep(self):
        cases = {"deep-" + name: text for name, text in check_deep_cases().items()}
        outputs = self.run_cases(cases, folder="deep")
        self.assert_manifest(outputs, "check/deep.sha256", cases)
        self.assertRegex(outputs["deep-nested-chains"], r"^ERROR CHECK-TOO-DEEP ")
        self.assertRegex(outputs["deep-ifs-and-chains"], r"^ERROR CHECK-TOO-DEEP ")
        self.assertRegex(outputs["deep-chain-999"], r"^ERROR PARSE-TOO-DEEP ")
        self.assertFalse(outputs["deep-chain-900"].startswith("ERROR"))

    @slow
    def test_a_generated_program_of_1000_functions_checks_in_the_same_time_class_as_the_link(self):
        cases = {"generated": check_generated_program(1000)}
        started = time.monotonic()
        outputs = self.run_cases(cases, folder="generated")
        self.assertLess(time.monotonic() - started, 120)
        self.assert_manifest(outputs, "check/generated.sha256", cases)
