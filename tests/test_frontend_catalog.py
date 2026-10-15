"""The Agentica builtin catalog (compiler/catalog.agc) against the frozen output of the Racket catalog.

tests/frontend-catalog-test.rkt compares the two live. This module compares the Agentica catalog with the golden the Racket
catalog printed (tests/fixtures/frontend/catalog/catalog.text, `make goldens`): the tables, the signatures, the lookups and
the did-you-mean suggestions. The probes are the lookup lines at the end of the golden, so the golden holds the input of
the run too. The Rule enum of compiler/builtin_model.agc is compared with the variants frozen in catalog/rules.expected.

An accepted loss: compiler/builtins_data.agc is generated from src/builtins.rkt (tools/gen-builtins-data.rkt) and the
rackunit test compared it with a fresh generation. That file is 106 KB; the golden above prints the same data, so it is
not frozen a second time. Once the Racket tables are gone, the data file is edited by hand and this golden is refreshed
with tools/refreeze.py.
"""
import re

from tests.agentica_test import FIXTURES, ROOT
from tests.frontend_support import FROZEN, StageTestCase

GOLDEN = FIXTURES / "frontend" / "catalog" / "catalog.text"
PROBE = re.compile(r"^((?:near|ref|std|type|sig|disp):.*?) -> ", flags=re.MULTILINE)


class CatalogFrozenTest(StageTestCase):
    ENTRY = "catalog.agc"

    def test_the_catalog_prints_the_golden_tables_signatures_lookups_and_did_you_mean(self):
        golden = GOLDEN.read_bytes().decode("utf-8")
        probes = PROBE.findall(golden)
        self.assertGreater(len(probes), 50)
        self.assert_golden(self.run_stage(*probes, cwd=ROOT), GOLDEN)

    def test_the_rule_enum_has_the_rules_of_the_builtin_table(self):
        text = (ROOT / "compiler" / "builtin_model.agc").read_bytes().decode("utf-8")
        declared = re.search(r"^export enum Rule\n(.*?)\nend", text, flags=re.MULTILINE | re.DOTALL).group(1)
        names = sorted(line.strip() for line in declared.split("\n"))
        self.assert_golden("".join(name + "\n" for name in names), FROZEN / "catalog" / "rules.expected")
