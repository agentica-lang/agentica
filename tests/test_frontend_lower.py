"""The Agentica lowering (compiler/lower.agc) against the frozen output of the Racket lowering.

tests/frontend-lower-test.rkt compares the two live. This module compares the Agentica lowering with what the Racket
lowering printed once for the same inputs (`make frontend-freeze`, tests/frontend-lower-freeze.rkt): the corpus
(examples/ and tests/fixtures/vm/ as they were at the freeze), the programs of the cases of tests/checker-test.rkt, every
std/ module, the compiler, trees at the nesting limit and a program of 300 functions. Inputs that are a formula are
rebuilt here; the manifests hold their hashes.
"""
import re

from tests.agentica_test import ROOT, run_vm, slow
from tests.frontend_cases import lower_deep_cases, lower_generated_program
from tests.frontend_support import (
    FROZEN, HERMETIC_ENVIRONMENT, StageTestCase, fixture_roots, load_corpus, load_json, write_files)
from tests.test_frontend_check import direct_files

FIXTURES = ROOT / "tests" / "fixtures" / "frontend" / "lower"


def golden_text():
    """The text of every golden of the fixtures, in name order."""
    return "".join(path.read_bytes().decode("utf-8") for path in sorted(FIXTURES.glob("*.ir")))


class LowerFrozenTest(StageTestCase):
    ENTRY = "lower.agc"
    STDLIB = True

    def lower_files(self, files):
        """Lower the files {path: text} written into a fresh folder; gives {path: output}."""
        directory = self.make_temp_dir()
        write_files(directory, files)
        return self.run_sections(sorted(files), "--stdlib=%s" % self.stdlib, cwd=directory)

    def lower_corpus(self, corpus, folder, manifest, minimum):
        """Lower the files of `folder` (not those of its subfolders, which they import) of a corpus."""
        files = load_corpus(corpus)
        paths = direct_files(files, folder)
        self.assertGreater(len(paths), minimum)
        outputs = self.run_sections(paths, "--stdlib=%s" % self.stdlib, cwd=self.corpus_dir(corpus))
        self.assert_manifest(outputs, manifest, files)

    def test_every_fixture_has_a_golden_and_no_golden_is_left_over(self):
        self.fixture_goldens(FIXTURES, list(fixture_roots(FIXTURES)), ".ir")

    def test_the_lowering_matches_the_goldens_of_the_fixtures(self):
        roots = fixture_roots(FIXTURES)
        goldens = self.fixture_goldens(FIXTURES, list(roots), ".ir")
        outputs = self.run_sections(list(roots.values()), "--stdlib=%s" % (ROOT / "stdlib"), cwd=ROOT)
        self.assert_goldens({name: outputs[path] for name, path in roots.items()}, goldens, "lowering fixtures")

    def test_vm_builtins_of_the_lowering_tables_are_the_ones_of_the_freeze(self):
        # VM_BUILTINS of compiler/lower_tables.agc is vm-builtins of src/lower.rkt, frozen in lower/vm-builtins.expected.
        text = (ROOT / "compiler" / "lower_tables.agc").read_bytes().decode("utf-8")
        start = text.index("VM_BUILTINS = Set.new([")
        names = sorted(re.findall(r'"([^"]+)"', text[start:text.index("\n])", start)]))
        self.assert_golden("".join(name + "\n" for name in names), FROZEN / "lower" / "vm-builtins.expected")

    def test_the_fixtures_lower_an_instruction_of_every_opcode_of_the_bytecode(self):
        seen = golden_text()
        listing = (FROZEN / "bytecode" / "opcodes.expected").read_text(encoding="utf-8")
        opcodes = [line.split(" ")[0] for line in listing.splitlines()]
        missing = [op for op in opcodes if not re.search(r"^    %s( |$)" % re.escape(op), seen, flags=re.MULTILINE)]
        self.assertEqual(missing, [])

    def test_the_fixtures_cover_chunked_literals_decodable_structs_constants_and_the_start_function(self):
        seen = golden_text()
        needles = ['"List.concat"', '"Map.put"', " types=[", '"<start>"', '"Task.await_result"', "tail-call", "struct-with",
                   "global-set", "call-value", "range-bounds"]
        self.assertEqual([needle for needle in needles if needle not in seen], [])

    def test_the_examples(self):
        self.lower_corpus("examples", "examples", "lower/examples.sha256", 20)

    @slow
    def test_the_vm_fixtures(self):
        self.lower_corpus("fixtures", "tests/fixtures/vm", "lower/vm.sha256", 200)

    @slow
    def test_the_programs_of_the_cases_of_the_racket_checker_tests(self):
        programs = load_json("corpus/checker-programs.json")
        self.assertGreater(len(programs), 400)
        cases = {"c%d" % n: text for n, text in enumerate(programs)}
        self.assert_manifest(self.run_cases(cases), "lower/programs.sha256", cases)

    @slow
    def test_every_std_module_and_the_compiler(self):
        wrappers = {}
        for path in load_corpus("stdlib"):
            name = path[len("stdlib/"):-len(".agc")]
            wrappers["std-" + name.replace("/", "_")] = "import Module from \"std/%s\"\n\ndef main() -> Void\nend\n" % name
        compiler = load_corpus("compiler")
        files = {path: compiler[path] for path in direct_files(compiler, "compiler")}
        self.assertGreater(len(wrappers) + len(files), 50)
        outputs = self.run_cases(wrappers, folder="std")
        outputs.update(self.lower_files(files))
        self.assert_manifest(outputs, "lower/std-compiler.sha256", dict(wrappers, **files))

    @slow
    def test_trees_at_the_nesting_limit_lower_to_the_same_ir_with_a_margin_of_vm_frames(self):
        cases = {"deep-" + name: text for name, text in lower_deep_cases().items()}
        outputs = self.run_cases(cases, folder="deep")
        self.assert_manifest(outputs, "lower/deep.sha256", cases)
        for key, text in outputs.items():
            self.assertRegex(text, r"^program ", key)
        # Lowering takes up to 3 frames for each level of the tree, about 3,000 of the 10,000 at 1,000 levels. With
        # 5,000 frames used up before it starts, every case still lowers.
        burned = self.run_cases(cases, "--burn=5000", folder="deep")
        self.assertEqual(burned, outputs)
        # The control: with 8,000 frames used up the deepest cases must overflow, so the flag measures something.
        directory = self.make_temp_dir()
        deepest = list(cases)[-3:]
        write_files(directory, {"deep/%s.agc" % key: cases[key] for key in deepest})
        result = run_vm(self.bytecode, args=["--stdlib=%s" % self.stdlib, "--burn=8000"]
                        + ["deep/%s.agc" % key for key in deepest],
                        cwd=directory, env=HERMETIC_ENVIRONMENT, timeout=600)
        self.assertIn("RUNTIME-STACK-OVERFLOW", result.stdout + result.stderr)

    @slow
    def test_a_generated_program_of_300_functions_lowers_to_the_same_ir(self):
        cases = {"generated": lower_generated_program(300)}
        self.assert_manifest(self.run_cases(cases, folder="generated"), "lower/generated.sha256", cases)
