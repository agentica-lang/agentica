"""The Agentica builtin catalog (compiler/catalog/catalog.agc) against the frozen output of the original catalog.

This module compares the Agentica catalog with the golden the original catalog printed
(tests/fixtures/frontend/catalog/catalog.text, `make goldens`): the tables, the signatures, the lookups and the
did-you-mean suggestions. The probes are the lookup lines at the end of the golden, so the golden holds the input of
the run too. The Rule enum of compiler/catalog/builtin_model.agc is compared with the variants frozen in
catalog/rules.expected.

An accepted loss: compiler/catalog/builtins_data.agc was generated from the tables of the original front end, whose test
compared it with a fresh generation. That file is 106 KB; the golden above prints the same data, so it is not frozen
a second time. The data file is edited by hand now and this golden is refreshed with tools/refreeze.py.
"""
import re

import pytest

from tests.agentica_test import FIXTURES, ROOT
from tests.frontend_support import FROZEN, PytestStageCase, assert_golden, pytest_stage_fixtures

GOLDEN = FIXTURES / "frontend" / "catalog" / "catalog.text"
PROBE = re.compile(r"^((?:near|ref|std|type|sig|disp):.*?) -> ", flags=re.MULTILINE)


class CatalogStage(PytestStageCase):
    ENTRY = "catalog/catalog.agc"


_catalog_stage_class, catalog_stage = pytest_stage_fixtures(CatalogStage, pytest, "catalog_stage")


def test_the_catalog_prints_the_golden_tables_signatures_lookups_and_did_you_mean(catalog_stage):
    golden = GOLDEN.read_bytes().decode("utf-8")
    probes = PROBE.findall(golden)
    assert len(probes) > 50
    assert_golden(catalog_stage.run_stage(*probes, cwd=ROOT), GOLDEN)


def test_the_rule_enum_has_the_rules_of_the_builtin_table():
    text = (ROOT / "compiler" / "catalog" / "builtin_model.agc").read_bytes().decode("utf-8")
    declared = re.search(r"^export enum Rule\n(.*?)\nend", text, flags=re.MULTILINE | re.DOTALL).group(1)
    names = sorted(line.strip() for line in declared.split("\n"))
    assert_golden("".join(name + "\n" for name in names), FROZEN / "catalog" / "rules.expected")


def test_every_builtin_implementation_is_one_the_vm_has():
    names = set(re.findall(r'\bimpl="([^"]+)"', GOLDEN.read_bytes().decode("utf-8")))
    assert len(names) > 150
    tables = (ROOT / "compiler" / "lower" / "lower_tables.agc").read_bytes().decode("utf-8")
    start = tables.index("VM_BUILTINS = Set.new([")
    vm_builtins = set(re.findall(r'"([^"]+)"', tables[start:tables.index("\n])", start)]))
    assert sorted(names - vm_builtins) == []


def test_no_builtin_has_a_default_problem():
    golden = GOLDEN.read_bytes().decode("utf-8")
    assert "default-problem" not in golden
    assert "seed: Int = 0" in golden
