"""tools/layout_check.py: what the layout guard of the `--jit off` loop ignores and what it reports.

The build of a base commit and the real binaries run in `make layout-check` (ci.yml). This test feeds the comparison the
disassembly of one function laid out at two addresses, so it needs no binary and no objdump.
"""
import importlib.util
import sys

import pytest

from tests.agentica_test import ROOT


def load_tool():
    spec = importlib.util.spec_from_file_location("agentica_layout_check", ROOT / "tools" / "layout_check.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses looks its module up here
    spec.loader.exec_module(module)
    return module


layout = load_tool()

# plain_turn at 0x1000: a call, a rip-relative jump table, a padding nop and a branch inside the function.
BASE = """
0000000000001000 <plain_turn>:
    1000:\tpush   %rbx
    1001:\tcall   2000 <step_slow>
    1006:\tlea    0x64b38(%rip),%r11        # be434 <agc_front_end_builtin_count+0x2a4>
    100d:\tnopl   0x0(%rax)
    1010:\tcmp    %rax,%rbx
    1013:\tjne    1001 <plain_turn+0x1>
    1015:\tret
"""
# The same function 0x80 bytes later, its callee and the table moved, the nop longer.
MOVED = """
0000000000001080 <plain_turn>:
    1080:\tpush   %rbx
    1081:\tcall   20a0 <step_slow+0x0>
    1086:\tlea    0x64ab8(%rip),%r11        # be4b4 <agc_other_symbol+0x30>
    108d:\tnopw   0x0(%rax,%rax,1)
    1090:\tcmp    %rax,%rbx
    1093:\tjne    1081 <plain_turn+0x1>
    1095:\tret
"""


def disassembly(monkeypatch, text):
    monkeypatch.setattr(layout, "run", lambda command, **_: text)
    return layout.normalized(layout.Path("binary"), "plain_turn")


def test_a_move_of_the_function_does_not_change_its_instructions(monkeypatch):
    assert disassembly(monkeypatch, BASE) == disassembly(monkeypatch, MOVED)


@pytest.mark.parametrize(
    "old, new",
    [
        ("cmp    %rax,%rbx", "cmp    %rax,%rcx"),
        ("jne    1001 <plain_turn+0x1>", "jne    1006 <plain_turn+0x6>"),
        ("call   2000 <step_slow>", "call   2000 <apply_cost>"),
    ],
)
def test_a_changed_instruction_shows(monkeypatch, old, new):
    assert disassembly(monkeypatch, BASE) != disassembly(monkeypatch, BASE.replace(old, new))
