"""DNS.lookup against a stand-in resolver (fixtures/dns_shim.c), so no DNS server is needed.

The shim is an LD_PRELOAD library, so this module runs on Linux only (tools/conformance.py lists it). The case that
needs only the system resolver, `localhost`, is in test_vm_tcp.py and runs on every system.
"""
import os
import subprocess

import pytest

from tests.agentica_test import FIXTURES, TARGET_OS, compile_text, run_vm, tool, vm_environment

# The shim's "slow" lookups sleep DNS_SHIM_MS on a pool thread: the first one is still running when its deadline
# passes, the second when its task is cancelled. The program then stays alive past the end of both, when libuv calls
# back into the given-up lookups (a use after free before the fix: a crash, or an ASan report).
PROGRAM = """\
def slow() -> Void
  IO.inspect(DNS.lookup("slow.cancelled", 10000))
end

def main() -> Void
  IO.inspect(DNS.lookup("dup.test"))
  IO.inspect(DNS.lookup("missing.test"))
  IO.inspect(DNS.lookup("slow.expires", 200))
  task = Task.spawn(&slow)
  Task.sleep(100)
  Task.cancel(task)
  Task.sleep(1500)
  IO.inspect(DNS.lookup("127.0.0.1"))
  puts("end")
end
"""


@pytest.mark.skipif(TARGET_OS != "linux", reason="host-only: the stand-in resolver is an LD_PRELOAD library of glibc's "
                    "getaddrinfo, which macOS and Windows do not load")
def test_dns_lookup_removes_duplicates_reports_not_found_and_survives_a_lookup_given_up_while_it_runs(tmp_path):
    shim = tmp_path / "dns_shim.so"
    subprocess.run([tool("cc"), "-shared", "-fPIC", "-O1", "-o", str(shim), str(FIXTURES / "dns_shim.c"), "-ldl"],
                   check=True)
    # An ASan VM checks that its runtime comes first among the loaded libraries; the shim only wraps getaddrinfo.
    asan = ":".join(filter(None, [os.environ.get("ASAN_OPTIONS"), "verify_asan_link_order=0"]))
    preload = ":".join(filter(None, [str(shim), os.environ.get("LD_PRELOAD")]))
    env = vm_environment({"LD_PRELOAD": preload, "DNS_SHIM_MS": "1000", "ASAN_OPTIONS": asan})
    result = run_vm(compile_text(PROGRAM, "dns_shim", tmp_path), env=env)
    assert (result.code, result.stderr) == (0, ""), result
    assert result.stdout.splitlines() == [
        'ok(["127.0.0.2", "127.0.0.1"])',
        'error("network: host not found\\n  host: missing.test\\n  system error: unknown node or service")',
        'error("network: operation timed out")',
        'ok(["127.0.0.1"])',
        "end",
    ]
