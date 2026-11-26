"""A List[Float32] is stored packed, 4 bytes per item (docs/vm/17-lists.md 17.12).

The values and operations are in the golden list-float32-vectors against a Python peer (tests/fixtures/
list-float32-vectors.py), which this module checks is what the peer writes. Ten million items must take about 40 MB
of data, half of what a List[Float] takes. The peak resident memory comes from /proc, so only Linux checks it.
"""
import importlib.util
import re
import sys
from pathlib import Path

import pytest

from tests.agentica_test import compile_agc, run, run_vm, vm_command, vm_environment

LINUX = sys.platform.startswith("linux")
ITEMS = 10000000
PACKED_KIB = 4 * ITEMS // 1024

# The list is built by joining a million items ten times: a join shares the leaves of its left side, and a builder
# writes the right side, so the peak is the list and little else.
LIST_PROGRAM = """\
def hwm() -> Void
  status = Result.unwrap!(File.read_text("/proc/self/status", 10000))
  for entry in status.split("\\n")
    if entry.start_with?("VmHWM")
      puts(entry)
    end
  end
end

def main() -> Void
  chunk: List[ITEM] = (0...1000000).to_a.map do |i| i.CONVERT end
  xs: List[ITEM] = chunk
  for _k in 0...9
    xs = xs.concat(chunk)
  end
  puts(xs.size)
  puts(xs[9999999])
  hwm()
end
"""

BASELINE_PROGRAM = LIST_PROGRAM[:LIST_PROGRAM.index("def main")] + "def main() -> Void\n  hwm()\nend\n"


def hwm_kib(text):
    return int(re.search(r"VmHWM:\s+([0-9]+) kB", text).group(1))


def peak(tmp_path, name, program):
    source = tmp_path / (name + ".agc")
    source.write_text(program, encoding="utf-8")
    bytecode = compile_agc(source, tmp_path / (name + ".agcb"))
    # Without the heap floor of the VM, which would hide the growth of a small list.
    result = run_vm(bytecode, env=vm_environment({"AGENTICA_GC_HEAP": "0"}))
    assert result.code == 0, result.stderr
    return hwm_kib(result.stdout), result.stdout


def collected():
    """False for a VM built without libgc, whose memory use no collector bounds."""
    return "no libgc" not in run([*vm_command(), "--version"]).stdout


@pytest.mark.skipif(not LINUX, reason="the peak memory is read from /proc/self/status")
def test_ten_million_float32_items_take_about_40_mb_of_data_and_half_of_a_float_list(tmp_path):
    if not collected():
        pytest.skip("a VM without libgc keeps every list it makes")
    base, _ = peak(tmp_path, "baseline", BASELINE_PROGRAM)
    narrow, text = peak(tmp_path, "float32", LIST_PROGRAM.replace("ITEM", "Float32").replace("CONVERT", "to_float32"))
    assert text.startswith("10000000\n999999.0\n")
    wide, _ = peak(tmp_path, "float", LIST_PROGRAM.replace("ITEM", "Float").replace("CONVERT", "to_f"))
    assert narrow - base < PACKED_KIB * 1.5, "%d kB of growth for %d packed Float32s" % (narrow - base, ITEMS)
    assert narrow - base < (wide - base) * 0.75, "%d kB of Float32 against %d kB of Float" % (narrow - base, wide - base)


def test_the_list_float32_vectors_are_what_the_peer_writes():
    path = Path(__file__).resolve().parent / "fixtures" / "list-float32-vectors.py"
    spec = importlib.util.spec_from_file_location("list_float32_vectors", path)
    peer = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(peer)
    assert (peer.HERE / "list-float32-vectors.stdin").read_text() == peer.stdin_text()
