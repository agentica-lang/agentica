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


# With one pool thread, "slow.running" takes it and "slow.queued" waits behind it; both tasks are cancelled then. The
# queued lookup must leave the queue (uv_cancel) and never reach getaddrinfo; the running one ends on its thread.
QUEUED_PROGRAM = """\
def running() -> Void
  IO.inspect(DNS.lookup("slow.running", 10000))
end

def queued() -> Void
  IO.inspect(DNS.lookup("slow.queued", 10000))
end

def main() -> Void
  a = Task.spawn(&running)
  Task.sleep(50)
  b = Task.spawn(&queued)
  Task.sleep(100)
  Task.cancel(b)
  Task.cancel(a)
  Task.sleep(1500)
  IO.inspect(DNS.lookup("127.0.0.1"))
  puts("end")
end
"""

LINUX_ONLY = pytest.mark.skipif(TARGET_OS != "linux", reason="host-only: the stand-in resolver is an LD_PRELOAD library "
                                "of glibc's getaddrinfo, which macOS and Windows do not load")


def run_with_shim(tmp_path, name, program, env=None):
    """Runs `program` with the stand-in resolver in front of the system's; its slow lookups take 1000 ms."""
    shim = tmp_path / "dns_shim.so"
    subprocess.run([tool("cc"), "-shared", "-fPIC", "-O1", "-o", str(shim), str(FIXTURES / "dns_shim.c"), "-ldl"],
                   check=True)
    # An ASan VM checks that its runtime comes first among the loaded libraries; the shim only wraps getaddrinfo.
    asan = ":".join(filter(None, [os.environ.get("ASAN_OPTIONS"), "verify_asan_link_order=0"]))
    preload = ":".join(filter(None, [str(shim), os.environ.get("LD_PRELOAD")]))
    full = {"LD_PRELOAD": preload, "DNS_SHIM_MS": "1000", "ASAN_OPTIONS": asan, **(env or {})}
    return run_vm(compile_text(program, name, tmp_path), env=vm_environment(full))


@LINUX_ONLY
def test_dns_lookup_removes_duplicates_reports_not_found_and_survives_a_lookup_given_up_while_it_runs(tmp_path):
    result = run_with_shim(tmp_path, "dns_shim", PROGRAM)
    assert (result.code, result.stderr) == (0, ""), result
    assert result.stdout.splitlines() == [
        'ok(["127.0.0.2", "127.0.0.1"])',
        'error("network: host not found\\n  host: missing.test\\n  system error: unknown node or service")',
        'error("network: operation timed out")',
        'ok(["127.0.0.1"])',
        "end",
    ]


@LINUX_ONLY
def test_dns_lookup_cancelled_while_queued_for_a_pool_thread_never_runs(tmp_path):
    log = tmp_path / "started.txt"
    result = run_with_shim(tmp_path, "dns_queued", QUEUED_PROGRAM,
                           env={"UV_THREADPOOL_SIZE": "1", "DNS_SHIM_LOG": str(log)})
    assert (result.code, result.stderr) == (0, ""), result
    assert result.stdout.splitlines() == ['ok(["127.0.0.1"])', "end"]
    assert log.read_text().splitlines() == ["slow.running"]
