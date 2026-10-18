"""Windows filesystem mutation regressions in disposable Docker or Actions scratch."""

from __future__ import annotations

import csv
import ctypes
import os
import re
import stat
import subprocess
import threading
import time
import unittest
import uuid
from pathlib import Path

from tests.agentica_test import TestCase, run_vm, start_vm, vm_environment
from tests.remove_sandbox_support import require_remove_sandbox

REMOVE_PROGRAM = """\
def main() -> Void
  case Path.remove(System.args()[0], 5000)
    ok(_) -> puts("true")
    error(message) ->
      IO.warn(message)
      puts("false")
  end
end
"""

PAUSED_REMOVE_PROGRAM = """\
def main() -> Void
  outcome = Path.remove(System.args()[0], 5000)
  puts(outcome.ok?)
  puts("ready")
  IO.flush()
  IO.gets()
end
"""

RENAME_PROGRAM = """\
def main() -> Void
  base = System.args()[0]
  puts(Path.rename(base + "/source", base + "/occupied", 5000).ok?)
  puts(Path.rename(base + "/source", base + "/moved", 5000).ok?)
  puts(Path.rename(base + "/directory", base + "/moved-directory", 5000).ok?)
  puts(Path.rename(base + "/missing", base + "/missing-target", 5000).ok?)
end
"""

RACE_PROGRAM = """\
def main() -> Void
  args = System.args()
  puts(Path.rename(args[0], args[1], 5000).ok?)
end
"""

REMOVE_RACE_PROGRAM = """\
def main() -> Void
  puts("ready")
  IO.flush()
  puts(Path.remove(System.args()[0], 30000).ok?)
end
"""


@unittest.skipUnless(
    os.environ.get("AGENTICA_TEST_TARGET_OS") == "windows" and os.environ.get("AGENTICA_TEST_WINE") != "1",
    "requires the native Windows VM and scratch",
)
class WindowsFilesystemMutationTests(TestCase):
    """Check Windows filesystem mutations in runner-owned scratch."""

    def setUp(self) -> None:
        self.root = self.make_temp_dir("agentica-windows-remove-").resolve()
        require_remove_sandbox(self.root)

    def test_remove_recurses_without_following_junctions_and_refuses_unsafe_paths(self) -> None:
        victim = self.root / "victim"
        nested = victim / "nested"
        outside = self.root / "outside"
        junction = victim / "junction"
        victim.mkdir()
        nested.mkdir()
        outside.mkdir()
        (nested / "file").write_text("remove me", encoding="utf-8")
        sentinel = outside / "keep"
        sentinel.write_text("outside sentinel", encoding="utf-8")
        link = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(junction), str(outside)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(link.returncode, 0, link.stdout + link.stderr)

        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-tree")
        result = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stdout, result.stderr), (0, "true\n", ""), result.stderr)
        self.assertFalse(victim.exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside sentinel")

        root_result = run_vm(bytecode, args=[str(self.root.anchor)], env=vm_environment(), cwd=self.root)
        parent_result = run_vm(bytecode, args=[str(self.root / "..")], env=vm_environment(), cwd=self.root)
        device_result = run_vm(bytecode, args=[str(self.root / "NUL")], env=vm_environment(), cwd=self.root)
        self.assertEqual((root_result.code, root_result.stdout), (0, "false\n"))
        self.assertEqual((parent_result.code, parent_result.stdout), (0, "false\n"))
        self.assertEqual((device_result.code, device_result.stdout), (0, "false\n"))
        self.assertTrue(self.root.is_dir())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside sentinel")

    def test_remove_fails_closed_when_an_existing_handle_allows_rename(self) -> None:
        victim = self.root / "busy-directory"
        victim.mkdir()
        (victim / "keep").write_text("keep until handle closes", encoding="utf-8")
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.CreateFileW.argtypes = [ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
                                         ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p]
        kernel32.CreateFileW.restype = ctypes.c_void_p
        kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
        kernel32.CloseHandle.restype = ctypes.c_int
        handle = kernel32.CreateFileW(str(victim), 0x00010000, 0x00000007, None, 3, 0x02000000, None)
        self.assertNotEqual(handle, ctypes.c_void_p(-1).value, ctypes.WinError(ctypes.get_last_error()))
        try:
            bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-busy-directory")
            blocked = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
            self.assertEqual((blocked.code, blocked.stdout), (0, "false\n"))
            self.assertTrue((victim / "keep").exists())
        finally:
            self.assertTrue(kernel32.CloseHandle(handle))

        removed = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
        self.assertEqual((removed.code, removed.stdout), (0, "true\n"), removed.stderr)
        self.assertFalse(victim.exists())

    def test_remove_refuses_a_reparse_ancestor(self) -> None:
        outside = self.root / "outside"
        ancestor = self.root / "ancestor"
        target = outside / "target"
        outside.mkdir()
        target.write_text("outside sentinel", encoding="utf-8")
        link = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(ancestor), str(outside)],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(link.returncode, 0, link.stdout + link.stderr)

        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-reparse-ancestor")
        result = run_vm(bytecode, args=[str(ancestor / "target")], env=vm_environment(), cwd=self.root)
        self.assertEqual((result.code, result.stdout), (0, "false\n"), result.stderr)
        self.assertEqual(target.read_text(encoding="utf-8"), "outside sentinel")

    def test_remove_deletes_files_and_treats_missing_paths_as_success(self) -> None:
        victim = self.root / "victim"
        victim.write_text("remove me", encoding="utf-8")
        unicode_victim = self.root / "café-雪.txt"
        unicode_victim.write_text("unicode", encoding="utf-8")
        long_victim = self.root / ("n" * 240)
        long_victim.write_text("long name", encoding="utf-8")
        missing = self.root / "missing"
        traversed_target = self.root / "traversed"
        traversed_target.write_text("remove through normalized parent", encoding="utf-8")
        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-file")

        removed = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root)
        unicode_removed = run_vm(bytecode, args=[str(unicode_victim)], env=vm_environment(), cwd=self.root)
        long_removed = run_vm(bytecode, args=[str(long_victim)], env=vm_environment(), cwd=self.root)
        absent = run_vm(bytecode, args=[str(missing)], env=vm_environment(), cwd=self.root)
        traversed = run_vm(bytecode, args=[str(self.root / "unused" / ".." / "traversed")], env=vm_environment(), cwd=self.root)

        self.assertEqual((removed.code, removed.stdout, removed.stderr), (0, "true\n", ""))
        self.assertEqual((unicode_removed.code, unicode_removed.stdout, unicode_removed.stderr), (0, "true\n", ""))
        self.assertEqual((long_removed.code, long_removed.stdout, long_removed.stderr), (0, "true\n", ""))
        self.assertEqual((absent.code, absent.stdout, absent.stderr), (0, "true\n", ""))
        self.assertEqual((traversed.code, traversed.stdout, traversed.stderr), (0, "true\n", ""))
        self.assertFalse(victim.exists())
        self.assertFalse(unicode_victim.exists())
        self.assertFalse(long_victim.exists())
        self.assertFalse(traversed_target.exists())

    def test_unsafe_aliases_and_trailing_separators_preserve_the_entry(self) -> None:
        victim = self.root / "keep"
        victim.write_text("sentinel", encoding="utf-8")
        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-aliases")
        paths = (
            str(victim) + ".", str(victim) + " ", str(victim) + ":stream",
            str(victim) + "/", str(victim) + "\\",
            str(self.root) + "/.", str(self.root) + "/unused/..",
            rf"\\?\{victim}", rf"\\.\{victim}",
        )
        for path in paths:
            with self.subTest(path=path):
                result = run_vm(
                    bytecode, args=[path], env=vm_environment(), cwd=self.root
                )
                self.assertEqual((result.code, result.stdout), (0, "false\n"))
                self.assertEqual(victim.read_text(encoding="utf-8"), "sentinel")

    def test_read_only_entry_failure_preserves_data_and_closes_its_handles(self) -> None:
        victim = self.root / "readonly"
        victim.write_text("sentinel", encoding="utf-8")
        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-readonly")
        os.chmod(victim, stat.S_IREAD)
        try:
            result = run_vm(
                bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root
            )
            self.assertEqual((result.code, result.stdout), (0, "false\n"))
            self.assertEqual(victim.read_text(encoding="utf-8"), "sentinel")
        finally:
            os.chmod(victim, stat.S_IWRITE)
        result = run_vm(
            bytecode, args=[str(victim)], env=vm_environment(), cwd=self.root
        )
        self.assertEqual((result.code, result.stdout, result.stderr), (0, "true\n", ""))
        self.assertFalse(victim.exists())

    def test_acl_denied_delete_preserves_remove_and_rename_sources(self) -> None:
        box = self.root / "acl-box"
        box.mkdir()
        victim = box / "keep"
        victim.write_text("acl sentinel", encoding="utf-8")
        identity = subprocess.run(
            ["whoami.exe", "/user", "/fo", "csv", "/nh"],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(identity.returncode, 0, identity.stderr)
        sid = next(csv.reader(identity.stdout.splitlines()))[1]
        self.assertTrue(sid.startswith("S-1-"), sid)

        def acl(path, *arguments):
            result = subprocess.run(
                ["icacls.exe", str(path), *arguments],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        remove = self.compile_text(REMOVE_PROGRAM, "windows-remove-acl")
        rename = self.compile_text(RACE_PROGRAM, "windows-rename-acl")
        try:
            # Deny both routes Windows may use: DELETE on the object and
            # DELETE_CHILD on its parent. Reading the sentinel remains allowed.
            acl(box, "/deny", f"*{sid}:(DC)")
            acl(victim, "/deny", f"*{sid}:(D)")
            kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel32.CreateFileW.argtypes = [
                ctypes.c_wchar_p, ctypes.c_uint32, ctypes.c_uint32,
                ctypes.c_void_p, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p,
            ]
            kernel32.CreateFileW.restype = ctypes.c_void_p
            kernel32.CloseHandle.argtypes = [ctypes.c_void_p]
            # Establish actual denial with an independent Win32 open before
            # invoking either mutation; a hosted runner may have backup rights.
            def delete_is_denied() -> bool:
                handle = kernel32.CreateFileW(
                    str(victim), 0x10000, 7, None, 3, 0, None
                )
                if handle != ctypes.c_void_p(-1).value:
                    kernel32.CloseHandle(handle)
                    return False
                return ctypes.get_last_error() == 5

            if not delete_is_denied():
                acl(box, "/inheritance:d")
                acl(victim, "/inheritance:d")
                acl(box, "/deny", f"*{sid}:(DC,D)")
                acl(victim, "/deny", f"*{sid}:(D)")
                if not delete_is_denied():
                    details = subprocess.run(
                        ["icacls.exe", str(box)], capture_output=True,
                        text=True, check=False,
                    )
                    self.fail(
                        "could not establish independent DELETE denial: "
                        + details.stdout
                    )

            for bytecode, arguments, removed in (
                (remove, [str(victim)], False),
                (remove, [str(victim)], True),
            ):
                if removed:
                    acl(victim, "/remove:d", f"*{sid}")
                    acl(box, "/remove:d", f"*{sid}")
                result = run_vm(
                    bytecode, args=arguments, env=vm_environment(), cwd=self.root
                )
                expected = "true\n" if removed else "false\n"
                self.assertEqual(
                    (result.code, result.stdout), (0, expected),
                    f"{arguments}: {result.stderr}",
                )
                if removed:
                    self.assertFalse(victim.exists())
                else:
                    # Rename needs DELETE on the source as well; the denied
                    # object must stay in place with its sentinel.
                    renamed = run_vm(
                        rename,
                        args=[str(victim), str(box / "moved")],
                        env=vm_environment(), cwd=self.root,
                    )
                    self.assertEqual(
                        (renamed.code, renamed.stdout), (0, "false\n"),
                        renamed.stderr,
                    )
                    # The denied DELETE ACE also blocks some hosted-runner
                    # identities from reopening for read; restore before the
                    # sentinel check, then reapply it for the next operation.
                    acl(victim, "/remove:d", f"*{sid}")
                    acl(box, "/remove:d", f"*{sid}")
                    self.assertEqual(
                        victim.read_text(encoding="utf-8"), "acl sentinel"
                    )
                    self.assertFalse((box / "moved").exists())
                    acl(box, "/deny", f"*{sid}:(DC,D)")
                    acl(victim, "/deny", f"*{sid}:(D)")
        finally:
            if victim.exists():
                acl(victim, "/remove:d", f"*{sid}")
            acl(box, "/remove:d", f"*{sid}")
        result = run_vm(
            remove, args=[str(victim)], env=vm_environment(), cwd=self.root
        )
        self.assertEqual((result.code, result.stdout), (0, "true\n"), result.stderr)

    def test_depth_limit_fails_without_leaking_handles(self) -> None:
        victim = self.root / "deep"
        current = victim
        for _ in range(129):
            current.mkdir()
            current = current / "d"
        sentinel = current.parent / "keep"
        sentinel.write_text("deep sentinel", encoding="utf-8")
        bytecode = self.compile_text(PAUSED_REMOVE_PROGRAM, "windows-remove-depth")
        child = self.adopt(start_vm(bytecode, str(victim), stdin=True, cwd=self.root))
        try:
            self.assertEqual(child.next_line(), "false")
            self.assertEqual(child.next_line(), "ready")
            self.assertIsNone(child.process.poll())
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "deep sentinel")
            # The process is still alive: exit cannot hide leaked traversal handles.
            moved = self.root / "deep-moved"
            victim.rename(moved)
            self.assertTrue(moved.is_dir())
        finally:
            child.close_stdin()
        self.assertEqual(child.wait(), 0)

    def test_remove_pins_ancestors_during_concurrent_replacement(self) -> None:
        anchor = self.root / "anchor"
        moved = self.root / "anchor-moved"
        tree = anchor / "tree"
        outside = self.root / "outside"
        anchor.mkdir()
        tree.mkdir()
        outside.mkdir()
        outside_tree = outside / "tree"
        outside_tree.mkdir()
        sentinel = outside_tree / "keep"
        sentinel.write_text("outside sentinel", encoding="utf-8")
        for number in range(1200):
            (tree / f"item-{number}.dat").write_text("remove", encoding="utf-8")

        bytecode = self.compile_text(REMOVE_RACE_PROGRAM, "windows-remove-ancestor-race")
        child = self.adopt(start_vm(bytecode, str(tree), cwd=self.root))
        self.assertEqual(child.next_line(), "ready")
        stop = threading.Event()
        blocked = threading.Event()
        swapped = threading.Event()

        def replace_ancestor() -> None:
            while not stop.is_set() and child.process.poll() is None:
                try:
                    anchor.rename(moved)
                except OSError as error:
                    if getattr(error, "winerror", None) in (5, 32, 33):
                        blocked.set()
                        return
                    time.sleep(0.001)
                    continue
                swapped.set()
                subprocess.run(
                    ["cmd.exe", "/d", "/c", "mklink", "/J", str(anchor), str(outside)],
                    capture_output=True,
                    text=True,
                    check=False,
                )
                return

        racer = threading.Thread(target=replace_ancestor)
        racer.start()
        answer = child.next_line()
        stop.set()
        racer.join(5)
        self.assertFalse(racer.is_alive())
        self.assertTrue(blocked.is_set() or swapped.is_set(), "replacement attempt did not reach the filesystem")
        self.assertIn(answer, ("true", "false"))
        self.assertEqual(child.wait(), 0)
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "outside sentinel")

    def test_rename_is_atomic_non_replacing_and_moves_directories(self) -> None:
        source = self.root / "source"
        occupied = self.root / "occupied"
        moved = self.root / "moved"
        directory = self.root / "directory"
        moved_directory = self.root / "moved-directory"
        source.write_text("source contents", encoding="utf-8")
        occupied.write_text("keep destination", encoding="utf-8")
        directory.mkdir()
        (directory / "inside").write_text("inside contents", encoding="utf-8")
        occupied_identity = occupied.stat().st_dev, occupied.stat().st_ino

        bytecode = self.compile_text(RENAME_PROGRAM, "windows-rename")
        result = run_vm(bytecode, args=[str(self.root)], env=vm_environment(), cwd=self.root)

        self.assertEqual((result.code, result.stdout, result.stderr), (0, "false\ntrue\ntrue\nfalse\n", ""))
        self.assertEqual(occupied.read_text(encoding="utf-8"), "keep destination")
        self.assertEqual((occupied.stat().st_dev, occupied.stat().st_ino), occupied_identity)
        self.assertFalse(source.exists())
        self.assertEqual(moved.read_text(encoding="utf-8"), "source contents")
        self.assertFalse(directory.exists())
        self.assertEqual((moved_directory / "inside").read_text(encoding="utf-8"), "inside contents")

    def test_rename_preserves_existing_directory_and_file_targets(self) -> None:
        bytecode = self.compile_text(RACE_PROGRAM, "windows-rename-types")
        for source_directory in (False, True):
            for target_directory in (False, True):
                with self.subTest(source=source_directory, target=target_directory):
                    base = self.root / f"pair-{int(source_directory)}-{int(target_directory)}"
                    base.mkdir()
                    source, target = base / "source", base / "target"
                    entries = (
                        (source, source_directory, "source sentinel"),
                        (target, target_directory, "target sentinel"),
                    )
                    for path, directory, text in entries:
                        if directory:
                            path.mkdir()
                            (path / "keep").write_text(text, encoding="utf-8")
                        else:
                            path.write_text(text, encoding="utf-8")
                    result = run_vm(
                        bytecode, args=[str(source), str(target)],
                        env=vm_environment(), cwd=self.root,
                    )
                    self.assertEqual((result.code, result.stdout), (0, "false\n"))
                    for path, directory, text in entries:
                        entry = path / "keep" if directory else path
                        self.assertEqual(entry.read_text(encoding="utf-8"), text)

    def test_rename_moves_a_junction_not_its_target(self) -> None:
        outside = self.root / "outside-rename"
        outside.mkdir()
        sentinel = outside / "keep"
        sentinel.write_text("target sentinel", encoding="utf-8")
        source, target = self.root / "source-link", self.root / "moved-link"
        link = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", "/J", str(source), str(outside)],
            capture_output=True, text=True, check=False,
        )
        self.assertEqual(link.returncode, 0, link.stdout + link.stderr)
        bytecode = self.compile_text(RACE_PROGRAM, "windows-rename-junction")
        result = run_vm(
            bytecode, args=[str(source), str(target)],
            env=vm_environment(), cwd=self.root,
        )
        self.assertEqual((result.code, result.stdout), (0, "true\n"))
        self.assertFalse(source.exists())
        self.assertTrue(target.is_junction())
        self.assertEqual(sentinel.read_text(encoding="utf-8"), "target sentinel")
        self.assertEqual((target / "keep").read_text(encoding="utf-8"), "target sentinel")

    def test_cross_volume_rename_fails_without_losing_the_source(self) -> None:
        root = self.root / "cross-volume"
        root.mkdir()
        script = Path(__file__).parent / "fixtures" / "windows-cross-volume.ps1"
        name = "agentica-test-" + uuid.uuid4().hex

        def manage(action: str) -> str:
            result = subprocess.run(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                 str(script), action, name, str(root)],
                capture_output=True, text=True, check=False, timeout=90,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result.stdout

        source = root / "source.txt"
        source.write_text("cross-volume sentinel", encoding="utf-8")
        bytecode = self.compile_text(RACE_PROGRAM, "windows-cross-volume-rename")
        kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel32.GetVolumePathNameW.argtypes = [
            ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32,
        ]
        kernel32.GetVolumePathNameW.restype = ctypes.c_int
        kernel32.GetVolumeInformationW.argtypes = [
            ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32,
            ctypes.POINTER(ctypes.c_uint32), ctypes.POINTER(ctypes.c_uint32),
            ctypes.POINTER(ctypes.c_uint32), ctypes.c_wchar_p, ctypes.c_uint32,
        ]
        kernel32.GetVolumeInformationW.restype = ctypes.c_int

        def volume_serial(path: str) -> tuple[str, int]:
            root_path = ctypes.create_unicode_buffer(32768)
            self.assertTrue(kernel32.GetVolumePathNameW(path, root_path, len(root_path)))
            serial = ctypes.c_uint32()
            self.assertTrue(kernel32.GetVolumeInformationW(
                root_path.value, None, 0, ctypes.byref(serial), None, None, None, 0
            ))
            return root_path.value, serial.value

        mounted = False
        try:
            output = manage("create")
            mounted = True
            match = re.search(r"^AGENTICA_DRIVE=([A-Z]:\\)$", output, re.MULTILINE)
            self.assertIsNotNone(match, output)
            target = match.group(1) + name + ".txt"
            source_volume = volume_serial(str(source))
            target_volume = volume_serial(target)
            self.assertNotEqual(
                source_volume[1], target_volume[1],
                f"VHD must be a distinct volume: {source_volume} vs {target_volume}",
            )
            result = run_vm(
                bytecode, args=[str(source), target],
                env=vm_environment(), cwd=self.root,
            )
            self.assertEqual((result.code, result.stdout), (0, "false\n"), result.stderr)
            self.assertEqual(source.read_text(encoding="utf-8"), "cross-volume sentinel")
            self.assertFalse(Path(target).exists())
        finally:
            if mounted or (root / (name + ".vhdx")).exists():
                manage("remove")

    def test_local_unc_share_removes_and_renames_only_its_confined_entries(self) -> None:
        share_root = self.root / "shared"
        share_root.mkdir()
        sentinel = share_root / "keep"
        sentinel.write_text("share sentinel", encoding="utf-8")
        victim = share_root / "victim"
        victim.mkdir()
        (victim / "data").write_text("remove", encoding="utf-8")
        source = share_root / "source"
        source.write_text("rename", encoding="utf-8")
        name = "agentica-test-" + uuid.uuid4().hex
        script = Path(__file__).parent / "fixtures" / "windows-filesystem-share.ps1"

        def manage(action: str) -> None:
            result = subprocess.run(
                ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
                 str(script), action, name, str(share_root)],
                capture_output=True, text=True, check=False, timeout=60,
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        remove = self.compile_text(REMOVE_PROGRAM, "windows-unc-remove")
        rename = self.compile_text(RACE_PROGRAM, "windows-unc-rename")
        unc = rf"\\localhost\{name}"
        try:
            manage("create")
            self.assertEqual((Path(unc) / "keep").read_text(), "share sentinel")
            removed = run_vm(
                remove, args=[unc + r"\victim"], env=vm_environment(), cwd=self.root
            )
            self.assertEqual(
                (removed.code, removed.stdout), (0, "true\n"), removed.stderr
            )
            renamed = run_vm(
                rename, args=[unc + r"\source", unc + r"\moved"],
                env=vm_environment(), cwd=self.root,
            )
            self.assertEqual(
                (renamed.code, renamed.stdout), (0, "true\n"), renamed.stderr
            )
            self.assertFalse(victim.exists())
            self.assertFalse(source.exists())
            self.assertEqual((share_root / "moved").read_text(), "rename")
            self.assertEqual(sentinel.read_text(), "share sentinel")
        finally:
            manage("remove")

    def test_rename_race_has_one_winner_and_preserves_losing_sources(self) -> None:
        bytecode = self.compile_text(RACE_PROGRAM, "windows-rename-race")
        target = self.root / "target"
        sources = []
        for number in range(6):
            source = self.root / f"source-{number}"
            source.write_text(str(number), encoding="utf-8")
            sources.append(source)

        racers = [self.adopt(start_vm(bytecode, str(source), str(target), cwd=self.root)) for source in sources]
        answers = [racer.next_line() for racer in racers]
        for racer in racers:
            self.assertEqual(racer.wait(), 0)

        self.assertEqual(sorted(answers), ["false"] * 5 + ["true"])
        winner = answers.index("true")
        self.assertEqual(target.read_text(encoding="utf-8"), str(winner))
        for number, source in enumerate(sources):
            self.assertEqual(source.exists(), number != winner)


@unittest.skipUnless(os.environ.get("AGENTICA_TEST_TARGET_OS") == "windows", "requires the Windows VM")
class WindowsPathRefusalTests(TestCase):
    """Check root and dot-component refusals without mutating the filesystem."""

    def test_empty_nul_and_invalid_timeout_do_not_mutate_the_entry(self) -> None:
        root = self.make_temp_dir("agentica-windows-invalid-path-")
        require_remove_sandbox(root)
        victim = root / "keep"
        victim.write_text("argument sentinel", encoding="utf-8")
        source = """\
def main() -> Void
  path = System.args()[0]
  invalid = path + String.from_code(0) + "suffix"
  puts(Path.remove("", 5000).ok?)
  puts(Path.remove(invalid, 5000).ok?)
  puts(Path.remove(path, 0).ok?)
  puts(Path.rename(path, path + "-moved", 0).ok?)
  puts(Path.rename(invalid, path + "-moved", 5000).ok?)
  puts(Path.rename(path, invalid, 5000).ok?)
end
"""
        bytecode = self.compile_text(source, "windows-invalid-path")
        result = run_vm(
            bytecode, args=[str(victim)], env=vm_environment(), cwd=root
        )
        self.assertEqual((result.code, result.stderr), (0, ""), result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["false"] * 6)
        self.assertEqual(victim.read_text(encoding="utf-8"), "argument sentinel")
        self.assertFalse((root / "keep-moved").exists())

    def test_roots_and_final_dot_components_are_refused(self) -> None:
        bytecode = self.compile_text(REMOVE_PROGRAM, "windows-remove-refusal")
        paths = ("C:\\", "C:", "C:\\parent\\..", "\\\\server\\share")
        for path in paths:
            with self.subTest(path=path):
                result = run_vm(bytecode, args=[path], env=vm_environment(), cwd=os.getcwd())
                self.assertEqual((result.code, result.stdout), (0, "false\n"), result.stderr)
