"""Windows filesystem mutation regressions in disposable Docker or Actions scratch."""

from __future__ import annotations

import csv
import ctypes
import os
import re
import stat
import struct
import subprocess
import threading
import time
import uuid
from pathlib import Path

import pytest

from tests.agentica_test import compile_agc, run_vm, start_vm, vm_environment
from tests.remove_sandbox_support import require_remove_sandbox
# sandbox_root as root: these isolated tests require the Docker or Actions sandbox,
# unlike the plain root fixture shared by the non-destructive suites.
from tests.vm_os_support import _RaceCase, compile_work_text, sandbox_root as root, work
from tests.windows_support import assert_rename_race, kernel32_file_api, without_backup_restore_privileges

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

NATIVE_WINDOWS_SCRATCH = (
    os.environ.get("AGENTICA_TEST_TARGET_OS") == "windows" and os.environ.get("AGENTICA_TEST_WINE") != "1"
)
WINDOWS = os.environ.get("AGENTICA_TEST_TARGET_OS") == "windows"

# On a native Windows runner of GitHub Actions the scratch must exist (tools/run_remove_actions.py makes it): a missing
# one is an error of the run, not a reason to skip these cases and still pass.
if os.environ.get("GITHUB_ACTIONS") == "true" and os.name == "nt" and not NATIVE_WINDOWS_SCRATCH:
    raise RuntimeError("the native Windows scratch is missing: run this module through make test-remove-actions")

REQUIRES_NATIVE_WINDOWS = pytest.mark.skipif(not NATIVE_WINDOWS_SCRATCH, reason="requires the native Windows VM and scratch")
REQUIRES_WINDOWS = pytest.mark.skipif(not WINDOWS, reason="host-only: Windows path rules exist on Windows only")


def run_with_stdout(bytecode, arguments, root, expected_stdout):
    """Run one VM program in `root` and assert its successful stdout."""
    result = run_vm(bytecode, args=arguments, env=vm_environment(), cwd=root)
    assert (result.code, result.stdout) == (0, expected_stdout)
    return result


@REQUIRES_NATIVE_WINDOWS
def test_remove_recurses_without_following_junctions_and_refuses_unsafe_paths(root, work):
    victim = root / "victim"
    nested = victim / "nested"
    outside = root / "outside"
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
    assert link.returncode == 0, link.stdout + link.stderr

    bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-tree")
    result = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=root)
    assert (result.code, result.stdout, result.stderr) == (0, "true\n", ""), result.stderr
    assert not victim.exists()
    assert sentinel.read_text(encoding="utf-8") == "outside sentinel"

    parent_result = run_vm(bytecode, args=[str(root / "..")], env=vm_environment(), cwd=root)
    device_result = run_vm(bytecode, args=[str(root / "NUL")], env=vm_environment(), cwd=root)
    assert (parent_result.code, parent_result.stdout) == (0, "false\n")
    assert (device_result.code, device_result.stdout) == (0, "false\n")
    assert root.is_dir()
    assert sentinel.read_text(encoding="utf-8") == "outside sentinel"


@REQUIRES_NATIVE_WINDOWS
def test_remove_fails_closed_when_an_existing_handle_allows_rename(root, work):
    victim = root / "busy-directory"
    victim.mkdir()
    (victim / "keep").write_text("keep until handle closes", encoding="utf-8")
    kernel32 = kernel32_file_api()
    handle = kernel32.CreateFileW(str(victim), 0x00010000, 0x00000007, None, 3, 0x02000000, None)
    assert handle != ctypes.c_void_p(-1).value, ctypes.WinError(ctypes.get_last_error())
    try:
        bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-busy-directory")
        blocked = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=root)
        assert (blocked.code, blocked.stdout) == (0, "false\n")
        assert (victim / "keep").exists()
    finally:
        assert kernel32.CloseHandle(handle)

    removed = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=root)
    assert (removed.code, removed.stdout) == (0, "true\n"), removed.stderr
    assert not victim.exists()


@REQUIRES_NATIVE_WINDOWS
def test_remove_refuses_a_reparse_ancestor(root, work):
    outside = root / "outside"
    ancestor = root / "ancestor"
    target = outside / "target"
    outside.mkdir()
    target.write_text("outside sentinel", encoding="utf-8")
    link = subprocess.run(
        ["cmd.exe", "/d", "/c", "mklink", "/J", str(ancestor), str(outside)],
        capture_output=True, text=True, check=False,
    )
    assert link.returncode == 0, link.stdout + link.stderr

    bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-reparse-ancestor")
    result = run_vm(bytecode, args=[str(ancestor / "target")], env=vm_environment(), cwd=root)
    assert (result.code, result.stdout) == (0, "false\n"), result.stderr
    assert target.read_text(encoding="utf-8") == "outside sentinel"


@REQUIRES_NATIVE_WINDOWS
def test_remove_deletes_files_and_treats_missing_paths_as_success(root, work):
    victim = root / "victim"
    victim.write_text("remove me", encoding="utf-8")
    unicode_victim = root / "café-雪.txt"
    unicode_victim.write_text("unicode", encoding="utf-8")
    long_victim = root / ("n" * 240)
    long_victim.write_text("long name", encoding="utf-8")
    missing = root / "missing"
    traversed_target = root / "traversed"
    traversed_target.write_text("remove through normalized parent", encoding="utf-8")
    bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-file")

    removed = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=root)
    unicode_removed = run_vm(bytecode, args=[str(unicode_victim)], env=vm_environment(), cwd=root)
    long_removed = run_vm(bytecode, args=[str(long_victim)], env=vm_environment(), cwd=root)
    absent = run_vm(bytecode, args=[str(missing)], env=vm_environment(), cwd=root)
    traversed = run_vm(bytecode, args=[str(root / "unused" / ".." / "traversed")], env=vm_environment(), cwd=root)

    assert (removed.code, removed.stdout, removed.stderr) == (0, "true\n", "")
    assert (unicode_removed.code, unicode_removed.stdout, unicode_removed.stderr) == (0, "true\n", "")
    assert (long_removed.code, long_removed.stdout, long_removed.stderr) == (0, "true\n", "")
    assert (absent.code, absent.stdout, absent.stderr) == (0, "true\n", "")
    assert (traversed.code, traversed.stdout, traversed.stderr) == (0, "true\n", "")
    assert not victim.exists()
    assert not unicode_victim.exists()
    assert not long_victim.exists()
    assert not traversed_target.exists()


@REQUIRES_NATIVE_WINDOWS
def test_unsafe_aliases_and_trailing_separators_preserve_the_entry(root, work):
    victim = root / "keep"
    victim.write_text("sentinel", encoding="utf-8")
    bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-aliases")
    paths = (
        str(victim) + ".", str(victim) + " ", str(victim) + ":stream",
        str(victim) + "/", str(victim) + "\\",
        str(root) + "/.", str(root) + "/unused/..",
        rf"\\?\{victim}", rf"\\.\{victim}",
    )
    for path in paths:
        result = run_vm(
            bytecode, args=[path], env=vm_environment(), cwd=root
        )
        assert (result.code, result.stdout) == (0, "false\n")
        assert victim.read_text(encoding="utf-8") == "sentinel"


@REQUIRES_NATIVE_WINDOWS
def test_read_only_entry_failure_preserves_data_and_closes_its_handles(root, work):
    victim = root / "readonly"
    victim.write_text("sentinel", encoding="utf-8")
    bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-readonly")
    os.chmod(victim, stat.S_IREAD)
    try:
        result = run_vm(
            bytecode, args=[str(victim)], env=vm_environment(), cwd=root
        )
        assert (result.code, result.stdout) == (0, "false\n")
        assert victim.read_text(encoding="utf-8") == "sentinel"
    finally:
        os.chmod(victim, stat.S_IWRITE)
    result = run_vm(
        bytecode, args=[str(victim)], env=vm_environment(), cwd=root
    )
    assert (result.code, result.stdout, result.stderr) == (0, "true\n", "")
    assert not victim.exists()


def current_user_sid():
    identity = subprocess.run(
        ["whoami.exe", "/user", "/fo", "csv", "/nh"],
        capture_output=True, text=True, check=False,
    )
    assert identity.returncode == 0, identity.stderr
    sid = next(csv.reader(identity.stdout.splitlines()))[1]
    assert sid.startswith("S-1-"), sid
    return sid


def acl(path, *arguments):
    result = subprocess.run(
        ["icacls.exe", str(path), *arguments],
        capture_output=True, text=True, check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def delete_is_denied(path):
    kernel32 = kernel32_file_api()
    handle = kernel32.CreateFileW(str(path), 0x10000, 7, None, 3, 0, None)
    if handle != ctypes.c_void_p(-1).value:
        kernel32.CloseHandle(handle)
        return False
    return ctypes.get_last_error() == 5


@REQUIRES_NATIVE_WINDOWS
def test_acl_denied_delete_preserves_remove_sources(root, work):
    box = root / "acl-box"
    box.mkdir()
    victim = box / "keep"
    victim.write_text("acl sentinel", encoding="utf-8")
    sid = current_user_sid()

    remove = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-acl")
    try:
        # Deny both routes Windows may use: DELETE on the object and
        # DELETE_CHILD on its parent. Reading the sentinel remains allowed.
        acl(box, "/deny", f"*{sid}:(DC)")
        acl(victim, "/deny", f"*{sid}:(D)")
        if not delete_is_denied(victim):
            acl(box, "/inheritance:d")
            acl(victim, "/inheritance:d")
            acl(box, "/deny", f"*{sid}:(DC,D)")
            acl(victim, "/deny", f"*{sid}:(D)")
            if not delete_is_denied(victim):
                details = subprocess.run(
                    ["icacls.exe", str(box)], capture_output=True,
                    text=True, check=False,
                )
                pytest.fail(
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
                bytecode, args=arguments, env=vm_environment(), cwd=root
            )
            expected = "true\n" if removed else "false\n"
            assert (result.code, result.stdout) == (0, expected), \
                f"{arguments}: {result.stderr}"
            if removed:
                assert not victim.exists()
            else:
                # The denied DELETE ACE also blocks some hosted-runner
                # identities from reopening for read; restore before the
                # sentinel check, then reapply it for the next operation.
                acl(victim, "/remove:d", f"*{sid}")
                acl(box, "/remove:d", f"*{sid}")
                assert victim.read_text(encoding="utf-8") == "acl sentinel"
                assert not (box / "moved").exists()
                acl(box, "/deny", f"*{sid}:(DC,D)")
                acl(victim, "/deny", f"*{sid}:(D)")
    finally:
        if victim.exists():
            acl(victim, "/remove:d", f"*{sid}")
        acl(box, "/remove:d", f"*{sid}")
    result = run_vm(
        remove, args=[str(victim)], env=vm_environment(), cwd=root
    )
    assert (result.code, result.stdout) == (0, "true\n"), result.stderr


@REQUIRES_NATIVE_WINDOWS
def test_rename_denied_delete_preserves_source_and_target(root, work):
    box = root / "acl-box"
    box.mkdir()
    source = box / "source"
    source.write_text("rename sentinel", encoding="utf-8")
    target = box / "destination"
    occupied = box / "occupied"
    occupied.write_text("keep destination", encoding="utf-8")
    sid = current_user_sid()

    rename = compile_work_text(work, RACE_PROGRAM, "windows-rename-denied")
    try:
        # Deny DELETE on the source; the non-replacing rename must refuse
        # instead of moving or truncating anything.
        # MoveFile can use a parent's DELETE_CHILD grant even when DELETE
        # on the source is denied. Remove inherited grants (including group
        # grants), then grant the parent read/write rights without deletion.
        acl(box, "/grant:r", f"*{sid}:(RX,W)")
        acl(box, "/inheritance:r")
        acl(box, "/deny", f"*{sid}:(DC)")
        acl(source, "/deny", f"*{sid}:(D)")
        assert delete_is_denied(source), "DELETE was not denied"
        with without_backup_restore_privileges():
            result = run_vm(
                rename, args=[str(source), str(target)], env=vm_environment(), cwd=root
            )
        assert (result.code, result.stdout) == (0, "false\n"), result.stderr
    finally:
        acl(box, "/grant:r", f"*{sid}:(F)")
        acl(box, "/inheritance:e")
        acl(source if source.exists() else target, "/remove:d", f"*{sid}")
        acl(box, "/remove:d", f"*{sid}")
    assert source.read_text(encoding="utf-8") == "rename sentinel"
    assert not target.exists()
    assert occupied.read_text(encoding="utf-8") == "keep destination"
    result = run_vm(
        rename, args=[str(source), str(target)], env=vm_environment(), cwd=root
    )
    assert (result.code, result.stdout) == (0, "true\n"), result.stderr
    assert not source.exists()
    assert target.read_text(encoding="utf-8") == "rename sentinel"


@REQUIRES_NATIVE_WINDOWS
def test_remove_names_the_nested_entry_that_failed_and_stops_there(root, work):
    tree = root / "tree"
    locked = tree / "a" / "locked"
    locked.mkdir(parents=True)
    (locked / "f.txt").write_text("f", encoding="utf-8")
    (tree / "z.txt").write_text("z", encoding="utf-8")
    sid = current_user_sid()

    remove = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-nested-denied")
    try:
        # Deny DELETE on the nested directory: emptying it succeeds, but the
        # directory itself cannot go, so the failure names it.
        acl(locked, "/deny", f"*{sid}:(D)")
        kernel32 = kernel32_file_api()
        handle = kernel32.CreateFileW(
            str(locked), 0x10000, 7, None, 3, 0, None
        )
        try:
            assert handle == ctypes.c_void_p(-1).value, "DELETE was not denied"
            assert ctypes.get_last_error() == 5, ctypes.WinError(ctypes.get_last_error())
        finally:
            if handle != ctypes.c_void_p(-1).value:
                kernel32.CloseHandle(handle)
        result = run_vm(
            remove, args=[str(tree)], env=vm_environment(), cwd=root
        )
        assert (result.code, result.stdout) == (0, "false\n"), result.stderr
        assert str(locked) in result.stderr, result.stderr
    finally:
        acl(locked, "/remove:d", f"*{sid}")
    assert locked.is_dir()


@REQUIRES_NATIVE_WINDOWS
def test_depth_limit_fails_without_leaking_handles(root, work, adopt):
    victim = root / "deep"
    current = victim
    for _ in range(129):
        current.mkdir()
        current = current / "d"
    sentinel = current.parent / "keep"
    sentinel.write_text("deep sentinel", encoding="utf-8")
    bytecode = compile_work_text(work, PAUSED_REMOVE_PROGRAM, "windows-remove-depth")
    child = adopt(start_vm(bytecode, str(victim), stdin=True, cwd=root))
    try:
        assert child.next_line() == "false"
        assert child.next_line() == "ready"
        assert child.process.poll() is None
        assert sentinel.read_text(encoding="utf-8") == "deep sentinel"
        # The process is still alive: exit cannot hide leaked traversal handles.
        moved = root / "deep-moved"
        victim.rename(moved)
        assert moved.is_dir()
    finally:
        child.close_stdin()
    assert child.wait() == 0


@REQUIRES_NATIVE_WINDOWS
def test_depth_boundary_removes_exactly_128_levels(root, work):
    victim = root / "fits"
    current = victim
    for _ in range(128):
        current.mkdir()
        current = current / "d"
    bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-boundary")
    result = run_vm(bytecode, args=[str(victim)], env=vm_environment(), cwd=root)
    assert (result.code, result.stdout) == (0, "true\n"), result.stderr
    assert not victim.exists()


@REQUIRES_NATIVE_WINDOWS
def test_remove_pins_ancestors_during_concurrent_replacement(root, work, adopt):
    anchor = root / "anchor"
    moved = root / "anchor-moved"
    tree = anchor / "tree"
    outside = root / "outside"
    anchor.mkdir()
    tree.mkdir()
    outside.mkdir()
    outside_tree = outside / "tree"
    outside_tree.mkdir()
    sentinel = outside_tree / "keep"
    sentinel.write_text("outside sentinel", encoding="utf-8")
    for number in range(1200):
        (tree / f"item-{number}.dat").write_text("remove", encoding="utf-8")

    bytecode = compile_work_text(work, REMOVE_RACE_PROGRAM, "windows-remove-ancestor-race")
    child = adopt(start_vm(bytecode, str(tree), cwd=root))
    assert child.next_line() == "ready"
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
    assert not racer.is_alive()
    assert blocked.is_set() or swapped.is_set(), "replacement attempt did not reach the filesystem"
    assert answer in ("true", "false")
    assert child.wait() == 0
    assert sentinel.read_text(encoding="utf-8") == "outside sentinel"


@REQUIRES_NATIVE_WINDOWS
def test_rename_is_atomic_non_replacing_and_moves_directories(root, work):
    source = root / "source"
    occupied = root / "occupied"
    moved = root / "moved"
    directory = root / "directory"
    moved_directory = root / "moved-directory"
    source.write_text("source contents", encoding="utf-8")
    occupied.write_text("keep destination", encoding="utf-8")
    directory.mkdir()
    (directory / "inside").write_text("inside contents", encoding="utf-8")
    occupied_identity = occupied.stat().st_dev, occupied.stat().st_ino

    bytecode = compile_work_text(work, RENAME_PROGRAM, "windows-rename")
    result = run_vm(bytecode, args=[str(root)], env=vm_environment(), cwd=root)

    assert (result.code, result.stdout, result.stderr) == (0, "false\ntrue\ntrue\nfalse\n", "")
    assert occupied.read_text(encoding="utf-8") == "keep destination"
    assert (occupied.stat().st_dev, occupied.stat().st_ino) == occupied_identity
    assert not source.exists()
    assert moved.read_text(encoding="utf-8") == "source contents"
    assert not directory.exists()
    assert (moved_directory / "inside").read_text(encoding="utf-8") == "inside contents"


@REQUIRES_NATIVE_WINDOWS
def test_rename_preserves_existing_directory_and_file_targets(root, work):
    bytecode = compile_work_text(work, RACE_PROGRAM, "windows-rename-types")
    for source_directory in (False, True):
        for target_directory in (False, True):
            base = root / f"pair-{int(source_directory)}-{int(target_directory)}"
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
            run_with_stdout(bytecode, [str(source), str(target)], root, "false\n")
            for path, directory, text in entries:
                entry = path / "keep" if directory else path
                assert entry.read_text(encoding="utf-8") == text


@REQUIRES_NATIVE_WINDOWS
def test_rename_moves_a_junction_not_its_target(root, work):
    outside = root / "outside-rename"
    outside.mkdir()
    sentinel = outside / "keep"
    sentinel.write_text("target sentinel", encoding="utf-8")
    source, target = root / "source-link", root / "moved-link"
    link = subprocess.run(
        ["cmd.exe", "/d", "/c", "mklink", "/J", str(source), str(outside)],
        capture_output=True, text=True, check=False,
    )
    assert link.returncode == 0, link.stdout + link.stderr
    bytecode = compile_work_text(work, RACE_PROGRAM, "windows-rename-junction")
    run_with_stdout(bytecode, [str(source), str(target)], root, "true\n")
    assert not source.exists()
    assert target.is_junction()
    assert sentinel.read_text(encoding="utf-8") == "target sentinel"
    assert (target / "keep").read_text(encoding="utf-8") == "target sentinel"


# Third-party reparse tags that the VM and the OS do not implement, one with
# the name-surrogate bit and one without. NTFS needs an empty entry to accept
# them and nothing can resolve them, so the tests prove only that remove does
# not fail on them and that rename moves the entry itself.
UNKNOWN_REPARSE_TAGS = {"name-surrogate": 0x2000C10D, "plain": 0x0000C10E}
FSCTL_SET_REPARSE_POINT = 0x900A4
FILE_FLAG_BACKUP_SEMANTICS = 0x02000000
FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000
FILE_ATTRIBUTE_REPARSE_POINT = 0x400


def tag_as_unknown_reparse_point(path, tag):
    """Stamp an empty entry with a GUID-owned, non-Microsoft reparse tag."""
    kernel32 = kernel32_file_api()
    kernel32.DeviceIoControl.argtypes = [
        ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32,
        ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32), ctypes.c_void_p,
    ]
    kernel32.DeviceIoControl.restype = ctypes.c_int
    payload = b"agentica-test-target\x00"
    # Non-Microsoft tags require REPARSE_GUID_DATA_BUFFER, not the shorter
    # Microsoft-owned REPARSE_DATA_BUFFER. NTFS requires an empty directory.
    owner = uuid.UUID("42543ec1-1467-4fd3-9fd0-c3f95204e613").bytes_le
    buffer = struct.pack("<IHH16s", tag, len(payload), 0, owner) + payload
    handle = kernel32.CreateFileW(
        str(path), 0x40000000, 0x00000007, None, 3,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, None)
    if handle == ctypes.c_void_p(-1).value:
        raise ctypes.WinError(ctypes.get_last_error())
    try:
        written = ctypes.c_uint32(0)
        ok = kernel32.DeviceIoControl(
            handle, FSCTL_SET_REPARSE_POINT, buffer, len(buffer),
            None, 0, ctypes.byref(written), None)
        if not ok:
            raise ctypes.WinError(ctypes.get_last_error())
    finally:
        kernel32.CloseHandle(handle)


def has_reparse_point(path):
    kernel32 = kernel32_file_api()
    kernel32.GetFileAttributesW.argtypes = [ctypes.c_wchar_p]
    kernel32.GetFileAttributesW.restype = ctypes.c_uint32
    return bool(kernel32.GetFileAttributesW(str(path)) & FILE_ATTRIBUTE_REPARSE_POINT)


@REQUIRES_NATIVE_WINDOWS
@pytest.mark.parametrize("tag", UNKNOWN_REPARSE_TAGS.values(), ids=UNKNOWN_REPARSE_TAGS.keys())
@pytest.mark.parametrize("directory", [False, True], ids=["file", "directory"])
def test_unknown_reparse_tags_are_deleted_and_moved_as_links(root, work, directory, tag):
    link = root / "unknown-link"
    if directory:
        link.mkdir()
    else:
        link.write_bytes(b"")
    sentinel = root / "outside-sentinel"
    sentinel.write_text("preserve", encoding="utf-8")
    identity = sentinel.stat().st_ino
    tag_as_unknown_reparse_point(link, tag)
    assert has_reparse_point(link)
    moved = root / "unknown-moved"
    bytecode = compile_work_text(work, RACE_PROGRAM, "windows-rename-unknown-tag")
    run_with_stdout(bytecode, [str(link), str(moved)], root, "true\n")
    assert not link.exists()
    assert has_reparse_point(moved)
    assert sentinel.read_text(encoding="utf-8") == "preserve"
    remove = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-unknown-tag")
    result = run_vm(remove, args=[str(moved)], env=vm_environment(), cwd=root)
    assert (result.code, result.stdout) == (0, "true\n"), result.stderr
    assert not moved.exists()
    assert sentinel.stat().st_ino == identity
    assert sentinel.read_text(encoding="utf-8") == "preserve"


@REQUIRES_NATIVE_WINDOWS
def test_symlinks_are_removed_and_renamed_without_touching_their_targets(root, work):
    target_dir = root / "symlink-target-dir"
    target_dir.mkdir()
    (target_dir / "keep").write_text("dir target", encoding="utf-8")
    target_file = root / "symlink-target.txt"
    target_file.write_text("file target", encoding="utf-8")
    dir_link, file_link = root / "dir-link", root / "file-link"
    for link, target, flags in (
        (dir_link, target_dir, ["/D"]),
        (file_link, target_file, []),
    ):
        made = subprocess.run(
            ["cmd.exe", "/d", "/c", "mklink", *flags, str(link), str(target)],
            capture_output=True, text=True, check=False,
        )
        assert made.returncode == 0, made.stdout + made.stderr

    remove = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-symlink")
    for link in (file_link, dir_link):
        result = run_vm(
            remove, args=[str(link)], env=vm_environment(), cwd=root
        )
        assert (result.code, result.stdout) == (0, "true\n"), result.stderr
        assert not os.path.lexists(link)
    assert target_file.read_text(encoding="utf-8") == "file target"
    assert (target_dir / "keep").read_text(encoding="utf-8") == "dir target"

    # A symlink renames as a link: the target keeps its contents.
    made = subprocess.run(
        ["cmd.exe", "/d", "/c", "mklink", "/D", str(dir_link), str(target_dir)],
        capture_output=True, text=True, check=False,
    )
    assert made.returncode == 0, made.stdout + made.stderr
    moved = root / "moved-dir-link"
    rename = compile_work_text(work, RACE_PROGRAM, "windows-rename-symlink")
    result = run_vm(
        rename, args=[str(dir_link), str(moved)],
        env=vm_environment(), cwd=root,
    )
    assert (result.code, result.stdout) == (0, "true\n"), result.stderr
    assert not os.path.lexists(dir_link)
    assert os.path.islink(moved)
    assert (moved / "keep").read_text(encoding="utf-8") == "dir target"


@REQUIRES_NATIVE_WINDOWS
@pytest.mark.parametrize("directory", [False, True], ids=["file", "directory"])
def test_existing_and_broken_link_targets_are_never_replaced_or_followed(root, work, directory):
    referent = root / "referent"
    if directory:
        referent.mkdir()
    else:
        referent.write_text("referent sentinel", encoding="utf-8")
    link = root / "link"
    made = subprocess.run(
        ["cmd.exe", "/d", "/c", "mklink", *(["/D"] if directory else []), str(link), str(referent)],
        capture_output=True, text=True, check=False,
    )
    assert made.returncode == 0, made.stdout + made.stderr
    source = root / "source"
    source.write_text("source sentinel", encoding="utf-8")
    identity = link.lstat().st_ino
    destination = os.readlink(link)
    rename = compile_work_text(work, RACE_PROGRAM, "windows-rename-existing-link")
    for broken in (False, True):
        if broken:
            if directory:
                referent.rmdir()
            else:
                referent.unlink()
        run_with_stdout(rename, [str(source), str(link)], root, "false\n")
        assert link.lstat().st_ino == identity
        assert os.readlink(link) == destination
        assert source.read_text(encoding="utf-8") == "source sentinel"
        if not broken:
            if directory:
                assert referent.is_dir()
                assert link.is_dir()
            else:
                assert referent.read_text(encoding="utf-8") == "referent sentinel"
    moved = root / "broken-moved"
    run_with_stdout(rename, [str(link), str(moved)], root, "true\n")
    assert not os.path.lexists(link)
    assert moved.lstat().st_ino == identity
    assert os.readlink(moved) == destination
    remove = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-broken-link")
    run_with_stdout(remove, [str(moved)], root, "true\n")
    assert not os.path.lexists(moved)
    assert source.read_text(encoding="utf-8") == "source sentinel"


@REQUIRES_NATIVE_WINDOWS
def test_cross_volume_rename_fails_without_losing_the_source(root, work):
    box = root / "cross-volume"
    box.mkdir()
    script = Path(__file__).parent / "fixtures" / "windows-cross-volume.ps1"
    name = "agentica-test-" + uuid.uuid4().hex

    def manage(action: str) -> str:
        result = subprocess.run(
            ["powershell.exe", "-NoProfile", "-NonInteractive", "-File",
             str(script), action, name, str(box)],
            capture_output=True, text=True, check=False, timeout=90,
        )
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout

    source = box / "source.txt"
    source.write_text("cross-volume sentinel", encoding="utf-8")
    bytecode = compile_work_text(work, RACE_PROGRAM, "windows-cross-volume-rename")
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
        assert kernel32.GetVolumePathNameW(path, root_path, len(root_path))
        serial = ctypes.c_uint32()
        assert kernel32.GetVolumeInformationW(
            root_path.value, None, 0, ctypes.byref(serial), None, None, None, 0
        )
        return root_path.value, serial.value

    mounted = False
    try:
        output = manage("create")
        mounted = True
        match = re.search(r"^AGENTICA_DRIVE=([A-Z]:\\)$", output, re.MULTILINE)
        assert match is not None, output
        target = match.group(1) + name + ".txt"
        source_volume = volume_serial(str(source))
        target_volume = volume_serial(target)
        assert source_volume[1] != target_volume[1], \
            f"VHD must be a distinct volume: {source_volume} vs {target_volume}"
        result = run_vm(
            bytecode, args=[str(source), target],
            env=vm_environment(), cwd=root,
        )
        assert (result.code, result.stdout) == (0, "false\n"), result.stderr
        assert source.read_text(encoding="utf-8") == "cross-volume sentinel"
        assert not Path(target).exists()

        # An actual volume mount point shares the junction tag, but its
        # filesystem may refuse unlinking. Either result must preserve the
        # volume's contents; never descend into the mounted filesystem.
        volume_name = ctypes.create_unicode_buffer(1024)
        kernel32.GetVolumeNameForVolumeMountPointW.argtypes = [
            ctypes.c_wchar_p, ctypes.c_wchar_p, ctypes.c_uint32,
        ]
        kernel32.SetVolumeMountPointW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]
        kernel32.DeleteVolumeMountPointW.argtypes = [ctypes.c_wchar_p]
        assert kernel32.GetVolumeNameForVolumeMountPointW(match.group(1), volume_name, len(volume_name))
        mount = box / "mounted-volume"
        mount.mkdir()
        mount_path = str(mount) + "\\"
        assert kernel32.SetVolumeMountPointW(mount_path, volume_name.value)
        volume_sentinel = Path(match.group(1)) / (name + "-keep.txt")
        volume_sentinel.write_text("mounted sentinel", encoding="utf-8")
        identity = volume_sentinel.stat().st_ino
        try:
            # The sentinel is visible through the mount point, so the VM below
            # meets a live mounted volume and not an empty directory.
            assert (mount / volume_sentinel.name).read_text(encoding="utf-8") == "mounted sentinel"
            remove = compile_work_text(work, REMOVE_PROGRAM, "windows-volume-mount-remove")
            result = run_vm(remove, args=[str(mount)], env=vm_environment(), cwd=root)
            assert result.code == 0, result.stderr
            assert result.stdout in ("true\n", "false\n"), result.stdout
            assert volume_sentinel.read_text(encoding="utf-8") == "mounted sentinel"
            assert volume_sentinel.stat().st_ino == identity
        finally:
            if mount.exists():
                assert kernel32.DeleteVolumeMountPointW(mount_path)
                mount.rmdir()
    finally:
        if mounted or (box / (name + ".vhdx")).exists():
            manage("remove")


@REQUIRES_NATIVE_WINDOWS
def test_local_unc_share_removes_and_renames_only_its_confined_entries(root, work):
    share_root = root / "shared"
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
        assert result.returncode == 0, result.stdout + result.stderr

    remove = compile_work_text(work, REMOVE_PROGRAM, "windows-unc-remove")
    rename = compile_work_text(work, RACE_PROGRAM, "windows-unc-rename")
    unc = rf"\\localhost\{name}"
    try:
        manage("create")
        assert (Path(unc) / "keep").read_text() == "share sentinel"
        removed = run_vm(
            remove, args=[unc + r"\victim"], env=vm_environment(), cwd=root
        )
        assert (removed.code, removed.stdout) == (0, "true\n"), removed.stderr
        renamed = run_vm(
            rename, args=[unc + r"\source", unc + r"\moved"],
            env=vm_environment(), cwd=root,
        )
        assert (renamed.code, renamed.stdout) == (0, "true\n"), renamed.stderr
        assert not victim.exists()
        assert not source.exists()
        assert (share_root / "moved").read_text() == "rename"
        assert sentinel.read_text() == "share sentinel"
    finally:
        manage("remove")


@REQUIRES_NATIVE_WINDOWS
def test_rename_race_has_one_winner_and_preserves_losing_sources(root, work, adopt):
    bytecode = compile_work_text(work, RACE_PROGRAM, "windows-rename-race")
    assert_rename_race(_RaceCase(adopt), bytecode, root, lambda number: f"source-{number}")


@REQUIRES_WINDOWS
def test_empty_nul_and_invalid_timeout_do_not_mutate_the_entry(tmp_path, work):
    """Refuse empty, NUL and zero-timeout arguments without mutating the filesystem."""
    box = (tmp_path / "scratch").resolve()
    box.mkdir()
    require_remove_sandbox(box)
    victim = box / "keep"
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
    bytecode = compile_work_text(work, source, "windows-invalid-path")
    result = run_vm(
        bytecode, args=[str(victim)], env=vm_environment(), cwd=box
    )
    assert (result.code, result.stderr) == (0, ""), result.stderr
    assert result.stdout.splitlines() == ["false"] * 6
    assert victim.read_text(encoding="utf-8") == "argument sentinel"
    assert not (box / "keep-moved").exists()


@REQUIRES_NATIVE_WINDOWS
@pytest.mark.parametrize("form", ["drive-relative", "device-extension"])
def test_remove_missing_native_names_is_idempotent(root, work, form):
    # Drive-relative names are valid native paths. The handle-relative NT
    # backend treats a device name with an extension as a literal filename,
    # not a DOS device alias. Neither missing entry is a refusal.
    path = root.drive + "agentica-missing-" + uuid.uuid4().hex
    if form == "device-extension":
        path = str(root / "NUL.txt")
    bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-missing-native")
    run_with_stdout(bytecode, [path], root, "true\n")
    assert root.is_dir()


@REQUIRES_NATIVE_WINDOWS
@pytest.mark.parametrize("path", [
    "",
    "C:\\foo\\",
    "C:\\foo\\.",
    "C:\\foo\\..",
    "C:\\foo ",
    "C:\\foo.",
    "C:\\foo:stream",
    "NUL",
    "CON",
    "AUX",
    "COM1",
    "LPT1",
], ids=[
    "empty",
    "trailing-separator", "trailing-dot", "trailing-dotdot", "trailing-space",
    "trailing-dot-component", "ads-stream",
    "nul-device", "con-device", "aux-device", "com1-device", "lpt1-device",
])
def test_remove_refuses_reserved_windows_paths_without_touching_entries(root, work, path):
    sentinel = root / "keep"
    sentinel.write_text("sentinel", encoding="utf-8")
    bytecode = compile_work_text(work, REMOVE_PROGRAM, "windows-remove-reserved")
    result = run_vm(bytecode, args=[path], env=vm_environment(), cwd=root)
    assert (result.code, result.stdout) == (0, "false\n"), (path, result.stderr)
    assert sentinel.read_text(encoding="utf-8") == "sentinel"
    assert root.is_dir()
