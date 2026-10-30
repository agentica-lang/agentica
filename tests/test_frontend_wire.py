"""The chunks of the bytecode writer (compiler/bytecode/bytecode_bytes.agc).

tests/fixtures/frontend/wire/wire.agc drives them the way the writer does and prints one line for each scenario. The
lines are rebuilt here from the bytes each scenario must give: a non-byte item in the open list, in a long piece or in
chunks that are merged is an error of `join` (the writer reports it as BYTECODE-INTERNAL), the open list is sealed by
the add that makes it longer than 4096 bytes, add_all keeps the order, and a text over 32 bytes is added as bytes.
"""
from tests.agentica_test import FIXTURES, compile_agc, run_vm, vm_environment

WIRE_FIXTURE = FIXTURES / "frontend" / "wire" / "wire.agc"


def ok(name, data):
    return "%s ok %s" % (name, ",".join(str(b) for b in data) or "-")


def sized(text):
    data = text.encode("utf-8")
    return list(len(data).to_bytes(4, "little")) + list(data)


def test_chunks_join_what_was_added_and_refuse_an_item_that_is_not_a_byte(tmp_path):
    bytecode = compile_agc(WIRE_FIXTURE, tmp_path / "wire.agcb")
    result = run_vm(bytecode, env=vm_environment())
    assert result.code == 0, result.stderr
    assert result.stderr == ""
    ones = [i % 256 for i in range(4097)]
    assert result.stdout.split("\n") == [
        "bad-open error",
        "bad-open-negative error",
        "bad-long error",
        "bad-merge-open error",
        "bad-merge-first error",
        "bad-merge-done error",
        "bad-after-ok error",
        ok("empty", []),
        ok("small-pieces", [1, 2, 3]),
        ok("order", [1, 2, 3] + [7] * 40 + [9]),
        "limit-4096 sealed=0 open=4096",
        ok("limit-4096-bytes", ones[:4096]),
        "limit-4097 sealed=1 open=0",
        ok("limit-4097-bytes", ones),
        ok("text-short", sized("hi")),
        ok("text-long", [9] + sized("a" * 40)),
        ok("text-multibyte", sized("é" * 20)),
        "",
    ]
