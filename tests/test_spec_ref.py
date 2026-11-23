"""Ref (`Ref.new`) through the product CLI: what a Ref may be used for, the rules and their diagnostic codes and spans.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers.
A program that must check clean has no code.
"""

import pytest

from tests.spec_support import assert_rule, check_many


def main(*lines: str) -> str:
    """A `main` function whose body is the lines."""
    return "def main() -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"


REF = "r = Ref.new()"

RULES = {
    "a constant may hold a Ref": (
        "ROOT: Ref = Ref.new()\n\n" + main("puts(ROOT)"), None, None),
    "a Ref is data": (
        "struct Node\n  id: Ref\nend\n\nenum Tag\n  Of(Ref)\nend\n\n"
        + main(REF, "puts(r == Ref.new())", "puts(r)", "puts(r.inspect)", 'puts("#{r}")',
               "IO.inspect(Node(id: r))", "IO.inspect(Tag.Of(r))", "ch: Channel[Ref] = Channel.new(1)",
               "_ = ch.send(r, 10)"), None, None),
    "a Ref is a map key, a set element and a table key": (
        "TABLE: ATS[Ref, Int] = ATS.new()\n\n"
        + main(REF, "m: Map[Ref, Int] = {}", "puts(m.put(r, 1)[r])", "puts(Set.new([r]).include?(r))",
               "TABLE.put(r, 1)", "puts([r].uniq.size + [r].tally.size + [r].group_by { |x| x }.size)"), None, None),
    "Refs sort": (
        "struct Node\n  id: Ref\nend\n\n"
        + main(REF, "puts([r].sort == [r])", "puts([Node(id: r)].sort_by { |n| n.id }.size)"), None, None),
    "a Ref has no <": (main(REF, "puts(r < r)"), "CHECK-TYPE-MISMATCH", "<"),
    "a Ref is no Int": (main("n: Int = Ref.new()"), "CHECK-TYPE-MISMATCH", "Ref.new()"),
    "a Ref has no arithmetic": (main(REF, "puts(r + 1)"), "CHECK-TYPE-MISMATCH", "+"),
    "a Ref cannot be encoded": (main(REF, "puts(JSON.encode([r]))"), "CHECK-NOT-ENCODABLE", "[r]"),
    "Ref.new takes nothing": (main("r = Ref.new(1)"), "CHECK-ARITY", "Ref.new(1)"),
    "Ref is not reserved": (
        "struct Ref\n  n: Int\nend\n\n" + main("puts(Ref(n: 1).n)", "puts(Ref.new())"), None, None),
    "a program's own Ref is its type": (
        "struct Ref\n  n: Int\nend\n\n" + main("r: Ref = Ref.new()"), "CHECK-TYPE-MISMATCH", "Ref.new()"),
}

# A module case is m.agc and a main.agc that imports it, which check clean.
MODULES = {
    "a module that declares no Ref has the builtin": (
        "struct Node\n  id: Ref\nend\n\ndef node() -> Node = Node(id: Ref.new())\n\n"
        "def same?(a: Node, b: Node) -> Bool = a.id == b.id\n",
        'import M from "m"\n\n' + main("puts(M.same?(M.node(), M.node()))")),
    "a module's own Ref is its type": (
        "struct Ref\n  n: Int\nend\n\ndef make() -> Ref = Ref(n: 1)\n",
        'import M from "m"\n\n' + main("puts(M.make().n)", "puts(Ref.new())")),
    "a struct Ref of the root file stays out of a module": (
        "def fresh() -> Ref = Ref.new()\n",
        'import M from "m"\n\nstruct Ref\n  n: Int\nend\n\n' + main("puts(M.fresh())", "puts(Ref(n: 1).n)")),
    "an alias Ref of the root file stays out of a module": (
        "def fresh() -> Ref = Ref.new()\n",
        'import M from "m"\n\ntype Ref = Int\n\n' + main("puts(M.fresh())", "r: Ref = 1", "puts(r)")),
}


@pytest.fixture(scope="module")
def batch(tmp_path_factory):
    """The programs of the tables, checked by one `check` call."""
    programs = [rule[0] for rule in RULES.values()]
    programs += [{"m.agc": lib, "main.agc": program} for lib, program in MODULES.values()]
    return check_many(programs, tmp_path_factory.mktemp("ref"))


@pytest.mark.parametrize("name", list(RULES))
def test_ref_rules(batch, name):
    program, code, text = RULES[name]
    assert_rule(batch(program), program, code, text)


@pytest.mark.parametrize("name", list(MODULES))
def test_ref_across_modules(batch, name):
    lib, program = MODULES[name]
    assert batch({"m.agc": lib, "main.agc": program}) is None
