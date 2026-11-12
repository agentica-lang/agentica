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
import json
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


def test_the_highlighter_needs_no_list_of_reserved_type_names():
    # The site grammar scopes a type by its shape, so a new reserved name needs no docs-theme PR: a list of names in
    # the grammar would have to be kept equal to RESERVED_TYPE_NAMES again.
    data = (ROOT / "compiler" / "catalog" / "builtins_data.agc").read_text(encoding="utf-8")
    reserved_text = re.search(r"^export RESERVED_TYPE_NAMES: List\[String\] = \[(.*?)^\]", data, flags=re.M | re.S).group(1)
    reserved = re.findall(r'"([^"]+)"', reserved_text)
    grammar_file = ROOT / "site" / "themes" / "docs-theme" / "highlight" / "agentica.tmLanguage.json"
    grammar_text = grammar_file.read_text(encoding="utf-8")
    grammar = json.loads(grammar_text)
    assert "builtin-types" not in grammar["repository"]
    names = "|".join(re.escape(name) for name in reserved)
    assert not re.search(r"(?:%s)\|(?:%s)" % (names, names), grammar_text)
    # Each reserved name still gets a scope, from the type rules (a capitalized name is a type, ALL_CAPS a constant).
    shapes = [re.compile(pattern["match"]) for pattern in grammar["repository"]["types"]["patterns"]]
    assert [name for name in reserved if not any(shape.fullmatch(name) for shape in shapes)] == []


def test_every_builtin_type_a_std_module_re_exports_has_its_written_name():
    # REEXPORTED_TYPES (compiler/syntax/types.agc) is the one table of the written names: it holds each
    # `export Family.Type` of stdlib/, written as the alias of STD_ONLY_IMPORTS and the member, and each MOVED_TYPES target.
    def table(path, name):
        text = (ROOT / "compiler" / path).read_text(encoding="utf-8")
        return re.search(r"^export %s: Map\[.*?\] = \{(.*?)^\}" % name, text, flags=re.M | re.S).group(1)

    written = dict(re.findall(r'"([^"]+)": "([^"]+)"', table("syntax/types.agc", "REEXPORTED_TYPES")))
    families = {family: (path, alias) for family, path, alias in
                re.findall(r'"(\w+)": \["([^"]+)", "(\w+)"\]', table("catalog/builtins_data.agc", "STD_ONLY_IMPORTS"))}
    exported = {}
    for path in sorted((ROOT / "stdlib").rglob("*.agc")):
        std_path = "std/" + path.relative_to(ROOT / "stdlib").with_suffix("").as_posix()
        for family, member in re.findall(r"^export (\w+)\.(\w+)$", path.read_text(encoding="utf-8"), flags=re.M):
            if family in families:
                assert families[family][0] == std_path, (family, path)
                exported["%s.%s" % (family, member)] = "%s.%s" % (families[family][1], member)
    assert written == exported
    # A printed value shows the written name too: vm/text.c maps each record and enum (written_names) and prints
    # each handle as <WRITTEN>.
    text_c = (ROOT / "vm" / "text.c").read_text(encoding="utf-8")
    printed = dict(re.findall(r'WRITTEN\("([^"]+)", "([^"]+)"\)', text_c[text_c.index("} written_names[] = {"):]
                              .split("};", 1)[0]))
    handles = {name: shown for name, shown in written.items() if '"<%s>"' % shown in text_c}
    assert printed == {name: shown for name, shown in written.items() if name not in handles}
    assert sorted(handles) == ["HttpWire.Client", "HttpWire.Server"]
    moved = re.findall(r'"\w+": "([^"]+)"', table("catalog/builtins_data.agc", "MOVED_TYPES"))
    assert set(moved) <= set(written)


def test_every_builtin_implementation_is_one_the_vm_has():
    names = set(re.findall(r'\bimpl="([^"]+)"', GOLDEN.read_bytes().decode("utf-8")))
    assert len(names) > 150
    tables = (ROOT / "compiler" / "lower" / "lower_tables.agc").read_bytes().decode("utf-8")
    start = tables.index("VM_BUILTINS = Set.new([")
    vm_builtins = set(re.findall(r'"([^"]+)"', tables[start:tables.index("\n])", start)]))
    # The methods of a codec have no VM builtin of their own: the lowering writes them (CODEC_BUILTINS).
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
      Model.Named(name: "level", type: Types.Type.Enum("LogRegistry.Level", []),
                  default: Model.Default.Variant("LogRegistry.Level.Info")),
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
