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
import shutil

import pytest

from tests.agentica_test import FIXTURES, ROOT, compile_agc, run_vm
from tests.frontend_support import (
    FROZEN, HERMETIC_ENVIRONMENT, PytestStageCase, assert_golden, pytest_stage_fixtures)

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
    # JSON.codec has no VM builtin: the lowering writes it as the type name (CODEC_BUILTINS).
    codec = tables.index("CODEC_BUILTINS = Set.new([")
    lowered = set(re.findall(r'"([^"]+)"', tables[codec:tables.index("])", codec)]))
    assert sorted(names - vm_builtins - lowered) == []


def test_no_builtin_has_a_default_problem():
    golden = GOLDEN.read_bytes().decode("utf-8")
    assert "default-problem" not in golden
    assert "seed: Int = 0" in golden


DEFAULTS_FIXTURES = FIXTURES / "frontend" / "builtin-defaults"

# A row with a default of every kind, appended to a copy of the catalog: no real row has most of them yet, and the
# lowering of each must be proven. It reuses the VM key of Zlib.crc32, so the call lowers.
PROBE_ROW = """  Model.Builtin(
    name: "Zlib.probe",
    parameters: [
      Model.Named(name: "n", type: Types.Type.Int, default: Model.Default.Whole(7)),
      Model.Named(name: "r", type: Types.Type.Float, default: Model.Default.Real(0.5)),
      Model.Named(name: "t", type: Types.Type.String, default: Model.Default.Text("x")),
      Model.Named(name: "f", type: Types.Type.Bool, default: Model.Default.Flag(true)),
      Model.Named(name: "z", type: Types.Type.Nil, default: Model.Default.Nothing),
      Model.Named(name: "l", type: Types.Type.List(Types.Type.Int), default: Model.Default.EmptyList),
      Model.Named(name: "m", type: Types.Type.Map(Types.Type.String, Types.Type.Int),
                  default: Model.Default.EmptyMap),
      Model.Named(name: "level", type: Types.Type.Enum("LogLevel", []),
                  default: Model.Default.Variant("LogLevel.Info")),
    ],
    result: Types.Type.Result(Types.Type.Int),
    rule: Model.Rule.Plain,
    implementation: "Zlib.crc32.bytes",
    effects: [],
    description: "Probe.",
    alternatives: [],
  ),
"""

PROBE_PROGRAM = """def main() -> Void
  puts(Zlib.probe())
  puts(Zlib.probe(1, 2.5, "y"))
end
"""


def test_default_rules_hold_for_rows_no_real_builtin_has_yet(tmp_path):
    bytecode = compile_agc(DEFAULTS_FIXTURES / "rows.agc", tmp_path / "rows.agcb")
    result = run_vm(bytecode, env=HERMETIC_ENVIRONMENT)
    assert result.code == 0, result.stderr
    assert_golden(result.stdout, DEFAULTS_FIXTURES / "rows.expected")


def test_the_lowering_fills_a_default_of_every_kind(tmp_path):
    shutil.copytree(ROOT / "compiler", tmp_path / "compiler")
    data = tmp_path / "compiler" / "catalog" / "builtins_data.agc"
    text = data.read_bytes().decode("utf-8")
    assert text.endswith("  ),\n]\n")
    data.write_bytes((text[:-len("]\n")] + PROBE_ROW + "]\n").encode("utf-8"))
    (tmp_path / "probe.agc").write_text(PROBE_PROGRAM, encoding="utf-8")
    bytecode = compile_agc(tmp_path / "compiler" / "lower" / "lower.agc", tmp_path / "lower.agcb")
    result = run_vm(bytecode, args=["--stdlib=%s" % (ROOT / "stdlib"), "probe.agc"], cwd=tmp_path,
                    env=HERMETIC_ENVIRONMENT)
    assert result.code == 0, result.stderr
    assert_golden(result.stdout, DEFAULTS_FIXTURES / "lower.expected")
