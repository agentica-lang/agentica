"""tools/provision_duckdb.py against small local archives.

No network, no C loads: each case builds a tiny .tar.gz in a tmp dir and calls
`stage()` on its bytes, so only the hash check and the member selection run.
"""
import hashlib
import importlib.util
import io
import tarfile
from pathlib import Path

import pytest

from tests.agentica_test import ROOT


def load_provisioner():
    spec = importlib.util.spec_from_file_location(
        "provision_duckdb_tool", ROOT / "tools" / "provision_duckdb.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


provision = load_provisioner()

LIB = b"\x7fELF fake shared library"
MEMBER = "libduckdb.so"


def archive(*entries):
    """A .tar.gz holding ENTRIES: (name, kind, data); kind is file, dir or link."""
    body = io.BytesIO()
    with tarfile.open(fileobj=body, mode="w:gz") as picked:
        for name, kind, data in entries:
            info = tarfile.TarInfo(name)
            if kind == "file":
                info.size = len(data)
                picked.addfile(info, io.BytesIO(data))
            elif kind == "dir":
                info.type = tarfile.DIRTYPE
                picked.addfile(info)
            else:
                info.type = tarfile.SYMTYPE
                info.linkname = "elsewhere"
                picked.addfile(info)
    return body.getvalue()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def test_stage_extracts_only_the_pinned_member_to_its_fixed_path(tmp_path):
    data = archive((MEMBER, "file", LIB), ("other.txt", "file", b"noise"),
                   ("sub", "dir", b""), ("sub/nested.txt", "file", b"noise"))
    target = provision.stage(data, digest(data), MEMBER, tmp_path / "native" / "linux")
    assert target.read_bytes() == LIB
    assert target.parent.name == "linux" and target.name == MEMBER
    assert [path for path in target.parent.parent.rglob("*") if path.is_file()] == [target]


def test_stage_rejects_a_hash_mismatch(tmp_path):
    data = archive((MEMBER, "file", LIB))
    with pytest.raises(SystemExit):
        provision.stage(data, digest(b"something else"), MEMBER, tmp_path)


def test_stage_rejects_a_missing_member(tmp_path):
    data = archive(("other.txt", "file", b"noise"))
    with pytest.raises(SystemExit):
        provision.stage(data, digest(data), MEMBER, tmp_path)


def test_stage_rejects_a_duplicate_member(tmp_path):
    data = archive((MEMBER, "file", LIB), (MEMBER, "file", LIB))
    with pytest.raises(SystemExit):
        provision.stage(data, digest(data), MEMBER, tmp_path)


@pytest.mark.parametrize("kind", ["dir", "link"])
def test_stage_rejects_a_nonregular_member(tmp_path, kind):
    data = archive((MEMBER, kind, LIB))
    with pytest.raises(SystemExit):
        provision.stage(data, digest(data), MEMBER, tmp_path)


def test_stage_rejects_an_oversized_member(tmp_path, monkeypatch):
    monkeypatch.setattr(provision, "MAX_MEMBER", 16)
    data = archive((MEMBER, "file", b"x" * 17))
    with pytest.raises(SystemExit):
        provision.stage(data, digest(data), MEMBER, tmp_path)


def test_stage_refuses_to_overwrite_an_existing_library(tmp_path):
    out = tmp_path / "native" / "linux"
    out.mkdir(parents=True)
    (out / MEMBER).write_bytes(b"already staged")
    data = archive((MEMBER, "file", LIB))
    with pytest.raises(SystemExit):
        provision.stage(data, digest(data), MEMBER, out)
    assert (out / MEMBER).read_bytes() == b"already staged"


def test_stage_refuses_a_create_that_lost_the_race(tmp_path, monkeypatch):
    """The exclusive create, not the friendly check, owns the guarantee."""
    out = tmp_path / "native" / "linux"
    out.mkdir(parents=True)
    (out / MEMBER).write_bytes(b"already staged")
    monkeypatch.setattr(Path, "exists", lambda self: False)
    data = archive((MEMBER, "file", LIB))
    with pytest.raises(SystemExit):
        provision.stage(data, digest(data), MEMBER, out)
    assert (out / MEMBER).read_bytes() == b"already staged"
