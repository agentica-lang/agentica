"""The private BDD run-folder cleanup regression; Docker sandbox required."""

from __future__ import annotations

from tests import test_bdd as bdd_tests
from tests.remove_sandbox_support import require_remove_sandbox


class BddCleanup(bdd_tests.BddBase):
    """Run the private handoff deletion regression only inside the sandbox."""

    def setUp(self) -> None:
        self.root = self.make_temp_dir("agentica-bdd-cleanup-").resolve()
        require_remove_sandbox(self.root)
        super().setUp()

    def test_later_run_removes_only_ended_private_folders(self) -> None:
        bdd_tests.Bdd._later_run_removes_private_run_folders(self)
