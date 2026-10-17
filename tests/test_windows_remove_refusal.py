"""Windows Path.remove refusal regression, gated to the Docker/Wine sandbox."""

from __future__ import annotations

import os

from tests.agentica_test import TestCase, run_vm, vm_environment
from tests.remove_sandbox_support import require_remove_sandbox

PROGRAM = """\
def main() -> Void
  result = Path.remove(System.args()[0] + "/victim", 5000)
  puts(result.ok?)
end
"""


class WindowsRemoveRefusalTests(TestCase):
    """Ensure unsupported Windows removal refuses without altering its scratch victim."""

    def setUp(self) -> None:
        require_remove_sandbox()
        if os.environ.get("AGENTICA_TEST_TARGET_OS") != "windows":
            self.fail("this regression requires the Windows binary running under the Docker/Wine sandbox")
        self.root = self.make_temp_dir("agentica-windows-remove-").resolve()

    def test_refusal_preserves_victim_and_sibling_sentinel(self) -> None:
        victim = self.root / "victim"
        sentinel = self.root / "sibling-sentinel"
        victim.write_text("keep victim", encoding="utf-8")
        sentinel.write_text("keep sibling", encoding="utf-8")
        victim_identity = victim.stat().st_dev, victim.stat().st_ino
        sentinel_identity = sentinel.stat().st_dev, sentinel.stat().st_ino

        bytecode = self.compile_text(PROGRAM, "windows-remove-refusal")
        result = run_vm(bytecode, args=[str(self.root)], env=vm_environment(), cwd=self.root)

        self.assertEqual((result.code, result.stdout, result.stderr), (0, "false\n", ""))
        self.assertEqual(victim.read_text(encoding="utf-8"), "keep victim")
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "keep sibling")
        self.assertEqual((victim.stat().st_dev, victim.stat().st_ino), victim_identity)
        self.assertEqual((sentinel.stat().st_dev, sentinel.stat().st_ino), sentinel_identity)
