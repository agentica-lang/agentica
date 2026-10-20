"""The Agentica lowering (compiler/lower/lower.agc) against the frozen output of the original lowering.

This module compares the Agentica lowering with what the original lowering printed once for the same inputs (frozen in
tests/fixtures/frontend/frozen/; tools/refreeze.py rewrites them from the Agentica stages): the corpus
(examples/ and tests/fixtures/vm/ as they were at the freeze), the programs of the cases of the old checker test, every
std/ module, the compiler, trees at the nesting limit and a program of 300 functions. Inputs that are a formula are
rebuilt here; the manifests hold their hashes.
"""
import re

import pytest

from tests.agentica_test import ROOT, run_vm, scaled, timeout
from tests.frontend_cases import lower_deep_cases, lower_generated_program
from tests.frontend_support import (
    FROZEN, HERMETIC_ENVIRONMENT, PytestStageCase, assert_golden, assert_goldens, assert_manifest, fixture_goldens,
    direct_files, fixture_roots, load_corpus, load_json, pytest_stage_fixtures, stdlib_compiler_sources, write_files)

FIXTURES = ROOT / "tests" / "fixtures" / "frontend" / "lower"

def golden_text():
    """The text of every golden of the fixtures, in name order."""
    return "".join(path.read_bytes().decode("utf-8") for path in sorted(FIXTURES.glob("*.ir")))


class LowerStage(PytestStageCase):
    ENTRY = "lower/lower.agc"
    STDLIB = True

    def lower_files(self, files):
        directory = self.temp_dir()
        write_files(directory, files)
        return self.run_sections(sorted(files), "--stdlib=%s" % self.stdlib, cwd=directory)

    def lower_corpus(self, corpus, folder, manifest, minimum):
        files = load_corpus(corpus)
        paths = direct_files(files, folder)
        assert len(paths) > minimum
        outputs = self.run_sections(paths, "--stdlib=%s" % self.stdlib, cwd=self.corpus_dir(corpus))
        assert_manifest(outputs, manifest, files)


_lower_stage_class, stage = pytest_stage_fixtures(LowerStage, pytest)


def test_every_fixture_has_a_golden_and_no_golden_is_left_over():
    fixture_goldens(FIXTURES, list(fixture_roots(FIXTURES)), ".ir")


def test_the_lowering_matches_the_goldens_of_the_fixtures(stage):
    roots = fixture_roots(FIXTURES)
    goldens = fixture_goldens(FIXTURES, list(roots), ".ir")
    outputs = stage.run_sections(list(roots.values()), "--stdlib=%s" % (ROOT / "stdlib"), cwd=ROOT)
    assert_goldens({name: outputs[path] for name, path in roots.items()}, goldens, "lowering fixtures")


def test_vm_builtins_of_the_lowering_tables_are_the_ones_of_the_freeze():
    # VM_BUILTINS of compiler/lower/lower_tables.agc is the table of the original lowering, frozen in
    # lower/vm-builtins.expected.
    text = (ROOT / "compiler" / "lower" / "lower_tables.agc").read_bytes().decode("utf-8")
    start = text.index("VM_BUILTINS = Set.new([")
    names = sorted(re.findall(r'"([^"]+)"', text[start:text.index("\n])", start)]))
    assert_golden("".join(name + "\n" for name in names), FROZEN / "lower" / "vm-builtins.expected")


def test_the_fixtures_lower_an_instruction_of_every_opcode_of_the_bytecode():
    seen = golden_text()
    listing = (FROZEN / "bytecode" / "opcodes.expected").read_text(encoding="utf-8")
    opcodes = [line.split(" ")[0] for line in listing.splitlines()]
    missing = [op for op in opcodes if not re.search(r"^    %s( |$)" % re.escape(op), seen, flags=re.MULTILINE)]
    assert missing == []


def test_the_fixtures_cover_chunked_literals_decodable_structs_constants_and_the_start_function():
    seen = golden_text()
    needles = ['"List.concat"', '"Map.put"', " types=[", '"<start>"', '"Task.await_result"', "tail-call", "struct-with",
               "global-set", "call-value", "range-bounds"]
    assert [needle for needle in needles if needle not in seen] == []


def test_the_examples(stage):
    stage.lower_corpus("examples", "examples", "lower/examples.sha256", 20)


@pytest.mark.slow
@timeout(1800)
def test_the_vm_fixtures(stage):
    stage.lower_corpus("fixtures", "tests/fixtures/vm", "lower/vm.sha256", 200)


@pytest.mark.slow
@timeout(1800)
def test_the_programs_of_the_cases_of_the_original_checker_tests(stage):
    programs = load_json("corpus/checker-programs.json")
    assert len(programs) > 400
    cases = {"c%d" % n: text for n, text in enumerate(programs)}
    assert_manifest(stage.run_cases(cases), "lower/programs.sha256", cases)


@pytest.mark.slow
@timeout(1800)
def test_every_std_module_and_the_compiler(stage):
    wrappers, files = stdlib_compiler_sources()
    outputs = stage.run_cases(wrappers, folder="std")
    outputs.update(stage.lower_files(files))
    assert_manifest(outputs, "lower/std-compiler.sha256", dict(wrappers, **files))


@pytest.mark.slow
@timeout(1800)
def test_trees_at_the_nesting_limit_lower_to_the_same_ir_with_a_margin_of_vm_frames(stage):
    cases = {"deep-" + name: text for name, text in lower_deep_cases().items()}
    outputs = stage.run_cases(cases, folder="deep")
    assert_manifest(outputs, "lower/deep.sha256", cases)
    for key, text in outputs.items():
        assert re.search(r"^program ", text), key
    # Lowering takes up to 3 frames for each level of the tree, about 3,000 of the 10,000 at 1,000 levels. With
    # 5,000 frames used up before it starts, every case still lowers.
    burned = stage.run_cases(cases, "--burn=5000", folder="deep")
    assert burned == outputs
    # The control: with 8,000 frames used up the deepest cases must overflow, so the flag measures something.
    directory = stage.temp_dir()
    deepest = list(cases)[-3:]
    write_files(directory, {"deep/%s.agc" % key: cases[key] for key in deepest})
    result = run_vm(stage.bytecode, args=["--stdlib=%s" % stage.stdlib, "--burn=8000"]
                    + ["deep/%s.agc" % key for key in deepest],
                    cwd=directory, env=HERMETIC_ENVIRONMENT, timeout=scaled(600))
    assert "RUNTIME-STACK-OVERFLOW" in result.stdout + result.stderr


@pytest.mark.slow
@timeout(1800)
def test_a_generated_program_of_300_functions_lowers_to_the_same_ir(stage):
    cases = {"generated": lower_generated_program(300)}
    assert_manifest(stage.run_cases(cases, folder="generated"), "lower/generated.sha256", cases)
