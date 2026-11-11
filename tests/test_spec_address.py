"""Addresses (`Address[M]`, `channel.address`) and constant ATS tables through the product CLI: the rules and their
diagnostic codes and spans.

A rule case is `(program, code, covered text)`: the code of the diagnostic and the source text its range covers.
A program that must check clean has no code. A module case is a main file and `m.agc`.
"""

from pathlib import Path

import pytest

from tests.spec_support import assert_rule, check_many


def main(*lines: str) -> str:
    """A `main` function whose body is the lines."""
    return "def main() -> Void\n" + "".join("  %s\n" % line for line in lines) + "end\n\n"


INBOX = "inbox: Channel[Int] = Channel.new(4)"
TABLE = "NAMES: ATS[String, Int] = ATS.new()\n\n"

RULES = {
    "a constant may be a table": (
        TABLE + main('NAMES.put("a", 1)', 'puts(NAMES.get("a").unwrap_or(0))'), None, None),
    "a constant table of addresses": (
        "NAMES: ATS[String, Address[Int]] = ATS.new()\n\n"
        + main(INBOX, 'NAMES.put("inbox", inbox.address)'), None, None),
    "a constant table needs its type": ("NAMES = ATS.new()\n\n" + main("puts(1)"), "CHECK-EXPECTED-TYPE", "ATS.new()"),
    "a table inside a constant": (
        "ALL: List[ATS[String, Int]] = [ATS.new()]\n\n" + main("puts(1)"), "CHECK-CONSTANT-TYPE", "ATS.new()"),
    "a constant that names another table": (
        TABLE + "SAME: ATS[String, Int] = NAMES\n\n" + main("puts(1)"), "CHECK-CONSTANT-TYPE", "NAMES"),
    "a channel is still no constant": (
        "INBOX: Channel[Int] = Channel.new(1)\n\n" + main("puts(1)"), "CHECK-CONSTANT-TYPE", "Channel.new(1)"),
    "a constant table holds data only": (
        "TASKS: ATS[String, Task[Int]] = ATS.new()\n\n" + main("puts(1)"), "CHECK-ATS-VALUE", "Task[Int]"),
    "an address is data": (
        "struct Link\n  to: Address[Int]\nend\n\nenum Note\n  To(Address[Int])\nend\n\n"
        + main(INBOX, "a: Address[Int] = inbox.address", "_ = a.send(1, 10)", "puts(a)",
               "puts(a == inbox.address)", "IO.inspect(Link(to: a))", "IO.inspect(Note.To(a))", "IO.inspect([a])",
               'm: Map[String, Address[Int]] = {"a": a}', "puts(m.size)", "t: ATS[String, Address[Int]] = ATS.new()",
               't.put("a", a)'), None, None),
    "an address sends the item type": (
        main(INBOX, 'r = inbox.address.send("one", 10)'), "CHECK-TYPE-MISMATCH", '"one"'),
    "an address does not receive": (
        main(INBOX, "r = inbox.address.recv(10)"), "CHECK-UNKNOWN-METHOD", "inbox.address.recv(10)"),
    "an address is no channel": (
        "def take(ch: Channel[Int]) -> Void\n  ch.close\nend\n\n" + main(INBOX, "take(inbox.address)"),
        "CHECK-TYPE-MISMATCH", "inbox.address"),
    "an address is no constant": (
        "ALL: List[Address[Int]] = []\n\n" + main("puts(1)"), "CHECK-CONSTANT-TYPE", "[]"),
    "an address cannot be encoded": (
        main(INBOX, "puts(JSON.encode([inbox.address]))"), "CHECK-NOT-ENCODABLE", "[inbox.address]"),
    "an address is no set item": (
        main(INBOX, "s = Set.new([inbox.address])"), "CHECK-SET-ELEMENT-TYPE", "[inbox.address]"),
    "an address is no map key": (
        main(INBOX, "m: Map[Address[Int], Int] = {}"), "CHECK-MAP-KEY-TYPE", "Address[Int]"),
    "an address is no handle to hand over": (
        "def f(a: Address[Int]) -> Result[Int]\n  return ok(1)\nend\n\n"
        + main(INBOX, "t = Task.spawn_owning(&f, inbox.address)"), "CHECK-NOT-A-HANDLE", "inbox.address"),
    "Address is not reserved": (
        "struct Address\n  street: String\nend\n\n" + main('puts(Address(street: "Main").street)'), None, None),
    "a generic struct cannot be named Address": (
        "struct Address[T]\n  v: T\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME",
        "struct Address[T]\n  v: T\nend\n"),
    "a generic enum cannot be named Address": (
        "enum Address[T]\n  One(T)\nend\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME",
        "enum Address[T]\n  One(T)\nend\n"),
    "a generic alias cannot be named Address": (
        "type Address[T] = List[T]\n\n" + main("puts(1)"), "CHECK-REDEFINED-NAME", "Address"),
    "a table in a struct of a constant": (
        "BB: Box = Box(t: ATS.new())\n\nstruct Box\n  t: ATS[String, Int]\nend\n\n" + main("puts(1)"),
        "CHECK-CONSTANT-TYPE", "ATS.new()"),
    "a constant table through a generic alias": (
        "AA: Tab[Int] = ATS.new()\n\ntype Tab[V] = ATS[String, V]\n\n" + main('AA.put("a", 1)'), None, None),
}

LIB = (
    "export NAMES: ATS[String, Address[Int]] = ATS.new()\n\n"
    "struct Address\n  street: String\nend\n\n"
    "export def tell(name: String, n: Int) -> Result[Void]\n"
    "  address: Address[Int] = try NAMES.get(name)\n"
    "  address.send(n, 1000)\n"
    "end\n\n"
    "export def street() -> String = Address(street: \"Main\").street\n"
)

GENERIC_LIB = "export type Address[T] = List[T]\n\nexport def first(a: Address[Int]) -> Int = a[0]\n"

# A module case is (m.agc, main.agc, code, covered text in the file the diagnostic names).
MODULE_RULES = {
    "an exported table and an address in a signature": (
        LIB,
        'import M from "m"\nimport {NAMES} from "m"\n\n'
        + main(INBOX, 'NAMES.put("inbox", inbox.address)', '_ = M.tell("inbox", 1)', "puts(M.street())"), None, None),
    "an imported module cannot declare a generic Address": (
        GENERIC_LIB, 'import M from "m"\n\n' + main("puts(M.first([1]))"), "CHECK-REDEFINED-NAME", "Address"),
}


@pytest.fixture(scope="module")
def batch(tmp_path_factory):
    """The programs of the rule tables, checked by one `check` call."""
    programs = [rule[0] for rule in RULES.values()]
    programs += [{"m.agc": rule[0], "main.agc": rule[1]} for rule in MODULE_RULES.values()]
    return check_many(programs, tmp_path_factory.mktemp("address"))


@pytest.mark.parametrize("name", list(RULES))
def test_address_and_constant_table_rules(batch, name):
    program, code, text = RULES[name]
    assert_rule(batch(program), program, code, text)


@pytest.mark.parametrize("name", list(MODULE_RULES))
def test_addresses_across_modules(batch, name):
    lib, program, code, text = MODULE_RULES[name]
    found = batch({"m.agc": lib, "main.agc": program})
    in_lib = found is not None and Path(found["file"]).name == "m.agc"
    assert_rule(found, lib if in_lib else program, code, text)
