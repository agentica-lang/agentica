"""tools/layout_check.py: what the layout guard of the `--jit off` loop ignores and what it reports.

The build of a base commit and the real binaries run in `make layout-check` (ci.yml). These tests feed the comparison
the disassembly of one function laid out at two addresses, and prepare a base from a temporary Git repository, so they
need no binary and no objdump.
"""
import importlib.util
import subprocess
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


def disassembly(text):
    return layout.normalized(text, "plain_turn")


def test_a_move_of_the_function_does_not_change_its_instructions():
    assert disassembly(BASE) == disassembly(MOVED)


@pytest.mark.parametrize(
    "old, new",
    [
        ("cmp    %rax,%rbx", "cmp    %rax,%rcx"),
        ("jne    1001 <plain_turn+0x1>", "jne    1006 <plain_turn+0x6>"),
        ("call   2000 <step_slow>", "call   2000 <apply_cost>"),
    ],
)
def test_a_changed_instruction_shows(old, new):
    assert disassembly(BASE) != disassembly(BASE.replace(old, new))


def test_a_field_added_to_a_struct_does_not_show():
    before = BASE.replace("push   %rbx", "mov    0x8(%rdi),%rax\n    1001:\tmov    -0x10(%rsp,%rcx,8),%rdx")
    after = before.replace("0x8(%rdi)", "0x10(%rdi)").replace("-0x10(%rsp,%rcx,8)", "-0x20(%rsp,%rcx,8)")
    assert disassembly(before) == disassembly(after)
    assert disassembly(before) != disassembly(before.replace("0x8(%rdi)", "0x8(%rsi)"))
    # A field that was at offset 0 has no displacement in the machine code.
    assert disassembly(before) == disassembly(before.replace("0x8(%rdi)", "(%rdi)"))


def test_a_longer_encoding_does_not_move_the_branches():
    short = """
0000000000001000 <plain_turn>:
    1000:\tmov    0x8(%rdi),%rax
    1004:\tcmp    %rax,%rbx
    1007:\tjne    1004 <plain_turn+0x4>
    1009:\tret
"""
    long = """
0000000000001000 <plain_turn>:
    1000:\tmov    0x108(%rdi),%rax
    1007:\tcmp    %rax,%rbx
    100a:\tjne    1007 <plain_turn+0x7>
    100c:\tret
"""
    assert disassembly(short) == disassembly(long)
    assert disassembly(short) != disassembly(long.replace("<plain_turn+0x7>", "<plain_turn+0x0>").replace("jne    1007", "jne    1000"))


def function(address, local, code):
    return layout.Function(address=address, size=0x2000, local=local, code=code)


def test_compare_fails_with_exit_4_when_the_hot_loop_changes(capsys):
    code = disassembly(BASE)
    base = {"plain_turn": function(0x59860, 0x69A0, code)}
    assert layout.compare(base, {"plain_turn": function(0x59860, 0x69A0, code + ["ret"])}) == layout.EXIT_CHANGED
    # The same code 128 bytes later in interp.o is a change too; 64 bytes later from the objects before it is a note.
    assert layout.compare(base, {"plain_turn": function(0x598E0, 0x6A20, code)}) == layout.EXIT_CHANGED
    assert layout.compare(base, {"plain_turn": function(0x598A0, 0x69A0, code)}) == layout.EXIT_OK
    assert "note: plain_turn moved +64" in capsys.readouterr().out


def git(repo, *args):
    subprocess.run(
        ["git", "-c", "user.name=t", "-c", "user.email=t@example.com", *args], cwd=repo, check=True, capture_output=True
    )


def test_prepare_builds_a_base_only_when_a_vm_input_changed(tmp_path):
    repo = tmp_path / "repo"
    (repo / "vm" / "third_party" / "lib").mkdir(parents=True)
    (repo / "vm" / "third_party" / "lib" / "lib.c").write_text("int lib;\n")
    (repo / "vm" / "interp.c").write_text("int loop;\n")
    (repo / "tests.txt").write_text("a\n")
    git(repo, "init", "-q")
    git(repo, "add", ".")
    git(repo, "commit", "-q", "-m", "base")
    tree = tmp_path / "base"

    (repo / "tests.txt").write_text("b\n")
    assert layout.prepare(repo, "HEAD", tree) == layout.EXIT_NOTHING_TO_COMPARE
    assert not tree.exists()

    (repo / "vm" / "interp.c").write_text("int loop, more;\n")
    assert layout.prepare(repo, "HEAD", tree) == layout.EXIT_OK
    assert (tree / "vm" / "interp.c").read_text() == "int loop;\n"
    assert (tree / "vm" / "third_party").is_symlink()
    assert (tree / "vm" / "third_party" / "lib" / "lib.c").exists()
    layout.clean(repo, tree)
    assert not tree.exists()
