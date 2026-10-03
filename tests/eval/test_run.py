import os
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import run


class ChildEnvironmentTests(unittest.TestCase):
    def test_only_allowlisted_environment_is_passed(self) -> None:
        with patch.dict(os.environ, {"PROVIDER_TOKEN": "secret", "OTHER_SECRET": "hidden"}, clear=True):
            env = run.child_environment(["PROVIDER_TOKEN"], in_chroot=True, workspace=Path("/tmp/work"))

        self.assertEqual(env["PROVIDER_TOKEN"], "secret")
        self.assertNotIn("OTHER_SECRET", env)
        self.assertEqual(env["PATH"], run.ROOTFS_PATH)
        self.assertEqual(env["HOME"], "/home/agent")

    def test_rejects_invalid_reserved_and_unset_names(self) -> None:
        for name, variables in (
            ("BAD-NAME", {}),
            ("HOME", {"HOME": "/host/home"}),
            ("MISSING_TOKEN", {}),
        ):
            with self.subTest(name=name), patch.dict(os.environ, variables, clear=True):
                with self.assertRaises(SystemExit):
                    run.child_environment([name], in_chroot=True, workspace=Path("/tmp/work"))

    def test_redacts_allowlisted_values(self) -> None:
        with patch.dict(os.environ, {"PROVIDER_TOKEN": "secret-value"}, clear=True):
            output = run.redact_secrets("logged secret-value", ["PROVIDER_TOKEN"])

        self.assertEqual(output, "logged [REDACTED]")


class JailCommandTests(unittest.TestCase):
    def test_agent_has_chroot_and_network_access(self) -> None:
        command = run.jail_prefix(Path("/tmp/rootfs"), network=True)

        self.assertIn("--chroot=/tmp/rootfs", command)
        self.assertIn("--private-tmp", command)
        self.assertIn("--nonewprivs", command)
        self.assertIn("--caps.drop=all", command)
        self.assertIn("--seccomp", command)
        self.assertNotIn("--net=none", command)

    def test_grader_has_no_network(self) -> None:
        command = run.jail_prefix(Path("/tmp/rootfs"), network=False)

        self.assertIn("--net=none", command)


class CandidateBoundaryTests(unittest.TestCase):
    def test_copies_regular_candidate_and_rejects_symlink(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "solution.py"
            destination = root / "copy.py"
            source.write_text("print('ok')\n")
            self.assertTrue(run.copy_candidate(source, destination))
            self.assertEqual(destination.read_text(), "print('ok')\n")

            link = root / "linked.py"
            link.symlink_to(source)
            self.assertFalse(run.copy_candidate(link, root / "linked-copy.py"))

    def test_rootfs_clone_clears_agent_writable_and_home_directories(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            template = root / "template"
            (template / "workspace").mkdir(parents=True)
            (template / "workspace" / "leftover.txt").write_text("old workspace")
            outside_home = root / "outside-home"
            (outside_home / "agent").mkdir(parents=True)
            (outside_home / "agent" / "credentials").write_text("old credentials")
            (template / "home").symlink_to(outside_home, target_is_directory=True)
            clone = run.clone_rootfs(template, root / "clone")

            self.assertFalse((clone / "workspace").exists())
            self.assertFalse((clone / "home" / "agent").exists())
            self.assertEqual((outside_home / "agent" / "credentials").read_text(), "old credentials")


if __name__ == "__main__":
    unittest.main()
