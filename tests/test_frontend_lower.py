"""The Agentica lowering (compiler/lower.agc) against the frozen output of the Racket lowering.

tests/frontend-lower-test.rkt compares the two live. This module compares the Agentica lowering with what the Racket
lowering printed once for the same inputs (`make frontend-freeze`, tests/frontend-lower-freeze.rkt): the corpus
(examples/ and tests/fixtures/vm/ as they were at the freeze), the programs of the cases of tests/checker-test.rkt, every
std/ module, the compiler, trees at the nesting limit and a program of 300 functions. Inputs that are a formula are
rebuilt here; the manifests hold their hashes.
"""
from tests.agentica_test import run_vm, slow
from tests.frontend_cases import lower_deep_cases, lower_generated_program
from tests.frontend_support import HERMETIC_ENVIRONMENT, StageTestCase, load_corpus, load_json, write_files
from tests.test_frontend_check import direct_files


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
