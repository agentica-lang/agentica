"""JSON.node and the JSON.Node enum (docs/grammar/06b-builtins.md) through the product CLI: `--json check FILE`,
asserting the code and the source text the range covers, never the message. The run-time forms are in the VM goldens
json-node and json-kind-vectors.
"""
import pytest

from tests.spec_support import check_diagnostic, covered

WALK = """def walk(value: JSON.Value) -> Int
  case JSON.node(value)
    JSON.Node.Null -> 0
    JSON.Node.Bool(_) -> 1
    JSON.Node.Int(n) -> n
    JSON.Node.BigInt(text) -> text.length
    JSON.Node.Float(x) -> x.round
    JSON.Node.String(s) -> s.length
    JSON.Node.Array(items) -> items.map { |item| walk(item) }.sum
    JSON.Node.Object(members) -> members.values.map { |item| walk(item) }.sum
  end
end

"""

# (name, program, code, covered text or None). A program that checks clean has the code None.
CASES = [
    (
        "a case over every variant checks, and the method form j.node works",
        WALK + "def main() -> Void\n  puts(walk(JSON.null()))\n  puts(JSON.null().node)\nend\n",
        None,
        None,
    ),
    (
        "a case that misses a variant",
        "def main() -> Void\n  case JSON.node(JSON.null())\n    JSON.Node.Null -> puts(0)\n  end\nend\n",
        "CHECK-NON-EXHAUSTIVE-CASE",
        None,
    ),
    (
        "the argument is a JSON.Value",
        "def main() -> Void\n  puts(JSON.node(5))\nend\n",
        "CHECK-TYPE-MISMATCH",
        "5",
    ),
    (
        "a JSON.Node does not encode",
        "def main() -> Void\n  puts(JSON.encode(JSON.node(JSON.null())))\nend\n",
        "CHECK-NOT-ENCODABLE",
        "JSON.node(JSON.null())",
    ),
    (
        "a JSON.Node does not decode",
        "def main() -> Void\n  puts(JSON.decode(\"null\", JSON.Node))\nend\n",
        "CHECK-NOT-DECODABLE",
        "JSON.Node",
    ),
]


@pytest.mark.parametrize("name, program, code, covers", CASES, ids=[case[0] for case in CASES])
def test_json_node_rules(name, program, code, covers, tmp_path):
    found = check_diagnostic(program, tmp_path)
    assert (found and found["code"]) == code, program
    if covers is not None:
        assert covered(program, found["range"]) == covers, program
