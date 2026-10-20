"""The Agentica checker (compiler/check/check.agc) against the frozen output of the original checker.

This module compares the Agentica checker with what the original checker printed once for the same inputs (frozen in
tests/fixtures/frontend/frozen/; tools/refreeze.py rewrites them from the Agentica stages): the programs of the cases
of the old checker test (now also in tests/test_spec_checker_rest.py), 1,500 mutants of them, the corpus (examples/ and
tests/fixtures/vm/ as they were at the freeze), every std/ module, the compiler, trees around the nesting limit and a
program of 1,000 functions. Inputs that are a formula are rebuilt here; the manifests hold their hashes.
"""
import re
import time

import pytest

from tests.agentica_test import ROOT, scaled, timeout
from tests.frontend_cases import check_deep_cases, check_generated_program
from tests.frontend_support import (FROZEN, PytestStageCase, direct_files, fixture_roots, load_corpus, load_json,
                                    pytest_stage_fixtures, write_files)

FIXTURES = ROOT / "tests" / "fixtures" / "frontend" / "check"

# The codes the original checker has and no program can reach: CHECK-INTERNAL guards an impossible node,
# CHECK-MODULE-CONTEXT a program that still has imports (the linker removes them) and CHECK-BLOCK-TYPE a block with no
# expected type (a block is only parsed after a call, whose parameter gives the type).
UNREACHABLE_CODES = ("CHECK-INTERNAL", "CHECK-MODULE-CONTEXT", "CHECK-BLOCK-TYPE")


class CheckStage(PytestStageCase):
    ENTRY = "check/check.agc"
    STDLIB = True

    def check_files(self, files, directory):
        """Check the files {path: text} written into `directory`; gives {path: output}."""
        write_files(directory, files)
        return self.run_sections(sorted(files), "--stdlib=%s" % self.stdlib, cwd=directory)

    def golden_texts(self):
        roots = fixture_roots(FIXTURES)
        goldens = self.fixture_goldens(FIXTURES, list(roots), ".checked")
        return {name: path.read_bytes().decode("utf-8") for name, path in goldens.items()}


_check_stage_class, check_stage = pytest_stage_fixtures(CheckStage, pytest, "check_stage")


def test_every_fixture_has_a_golden_and_no_golden_is_left_over(check_stage):
    check_stage.fixture_goldens(FIXTURES, list(fixture_roots(FIXTURES)), ".checked")


def test_the_checker_matches_the_goldens_of_the_fixtures_types_resolutions_and_diagnostics(check_stage):
    roots = fixture_roots(FIXTURES)
    goldens = check_stage.fixture_goldens(FIXTURES, list(roots), ".checked")
    outputs = check_stage.run_sections(list(roots.values()), "--stdlib=%s" % (ROOT / "stdlib"), cwd=ROOT)
    check_stage.assert_goldens({name: outputs[path] for name, path in roots.items()}, goldens, "checker fixtures")


def test_the_method_tables_are_the_ones_of_the_freeze(check_stage):
    # compiler/check/check_tables.agc was generated once from the tables of the original checker; it is edited by hand.
    source = (ROOT / "compiler" / "check" / "check_tables.agc").read_bytes().decode("utf-8")
    check_stage.assert_golden(source, FROZEN / "check" / "tables.expected")


def test_the_fixtures_end_in_every_check_diagnostic_the_checker_can_give(check_stage):
    codes = (FROZEN / "check" / "codes.expected").read_text(encoding="utf-8").split()
    seen = "".join(check_stage.golden_texts().values())
    missing = [code for code in codes if code not in UNREACHABLE_CODES and "ERROR %s " % code not in seen]
    assert missing == []


def test_the_fixtures_check_a_call_of_a_builtin_of_every_rule_of_the_builtin_table(check_stage):
    listing = (FROZEN / "check" / "builtin-rules.expected").read_text(encoding="utf-8")
    rules = dict(line.split(" ") for line in listing.splitlines())
    seen = "".join(check_stage.golden_texts().values())
    used = re.findall(r'name="([^"]+)" piped', seen) + re.findall(r'resolved=call\("([^"]+)"', seen)
    covered = {rules[name] for name in used if name in rules}
    assert sorted(set(rules.values()) - covered) == []


@pytest.mark.slow
@timeout(1800)
def test_the_programs_of_the_cases_of_the_original_checker_tests(check_stage, tmp_path):
    programs = load_json("corpus/checker-programs.json")
    assert len(programs) > 400
    cases = {"c%d" % n: text for n, text in enumerate(programs)}
    check_stage.assert_manifest(check_stage.run_cases(cases, directory=tmp_path / "cases"), "check/programs.sha256", cases)


@pytest.mark.slow
@timeout(1800)
def test_1500_mutated_programs(check_stage, tmp_path):
    cases = {"m%d" % n: text for n, text in enumerate(load_json("check/mutated.json"))}
    outputs = check_stage.run_cases(cases, directory=tmp_path / "mutated", folder="mutated")
    check_stage.assert_manifest(outputs, "check/mutated.sha256", cases)
    checked = sum(1 for text in outputs.values() if not re.match(r"ERROR (PARSE|LEX)-", text))
    assert checked > 150, "%d of 1500 mutants reach the checker" % checked


@pytest.mark.slow
@timeout(1800)
def test_examples_and_the_vm_fixtures(check_stage, tmp_path):
    # The programs import files of the subfolders, so the whole corpus is written.
    files = load_corpus("examples", "fixtures")
    paths = direct_files(files, "examples") + direct_files(files, "tests/fixtures/vm")
    assert len(paths) > 200
    corpus = tmp_path / "corpus"
    write_files(corpus, files)
    outputs = check_stage.run_sections(paths, "--stdlib=%s" % check_stage.stdlib, cwd=corpus)
    check_stage.assert_manifest(outputs, "check/corpus.sha256", files)


@pytest.mark.slow
@timeout(1800)
def test_every_std_module_and_the_compiler(check_stage, tmp_path):
    stdlib = load_corpus("stdlib")
    wrappers = {}
    for path in stdlib:
        name = path[len("stdlib/"):-len(".agc")]
        wrappers["std-" + name.replace("/", "_")] = (
            "import Module from \"std/%s\"\n\ndef main() -> Void\nend\n" % name)
    compiler = load_corpus("compiler")
    cases = dict(wrappers)
    cases.update({path: compiler[path] for path in direct_files(compiler, "compiler")})
    outputs = check_stage.run_cases(wrappers, directory=tmp_path / "std", folder="std")
    outputs.update(check_stage.check_files({path: compiler[path] for path in direct_files(compiler, "compiler")},
                                           tmp_path / "compiler"))
    check_stage.assert_manifest(outputs, "check/std-compiler.sha256", cases)


@pytest.mark.slow
@timeout(1800)
def test_trees_around_the_nesting_limit_give_the_same_types_or_the_same_too_deep(check_stage, tmp_path):
    cases = {"deep-" + name: text for name, text in check_deep_cases().items()}
    outputs = check_stage.run_cases(cases, directory=tmp_path / "deep", folder="deep")
    check_stage.assert_manifest(outputs, "check/deep.sha256", cases)
    assert re.match(r"^ERROR CHECK-TOO-DEEP ", outputs["deep-nested-chains"])
    assert re.match(r"^ERROR CHECK-TOO-DEEP ", outputs["deep-ifs-and-chains"])
    assert re.match(r"^ERROR PARSE-TOO-DEEP ", outputs["deep-chain-999"])
    assert not outputs["deep-chain-900"].startswith("ERROR")


@pytest.mark.slow
@timeout(1800)
def test_a_generated_program_of_1000_functions_checks_in_the_same_time_class_as_the_link(check_stage, tmp_path):
    cases = {"generated": check_generated_program(1000)}
    started = time.monotonic()
    outputs = check_stage.run_cases(cases, directory=tmp_path / "generated", folder="generated")
    assert time.monotonic() - started < scaled(120)
    check_stage.assert_manifest(outputs, "check/generated.sha256", cases)
