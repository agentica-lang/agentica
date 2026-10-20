"""The release archives: tools/release.py packs, verifies and collects exactly the four expected packages.

The real binaries and the extracted-package smoke run in release.yml (they need each system's tools). This test covers
what runs anywhere: a package holds the expected files once each, and `collect` refuses a missing, an extra or a
duplicated archive.
"""
import importlib.util
import tarfile
import zipfile

import pytest

from tests.agentica_test import ROOT


def load_release():
    spec = importlib.util.spec_from_file_location("agentica_release_tool", ROOT / "tools" / "release.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


release = load_release()


@pytest.fixture
def archives(tmp_path):
    """One archive per platform, packed from a fake binary into its own folder."""
    binary = tmp_path / "agentica"
    binary.write_bytes(b"not a program")
    packed = {}
    for platform in release.PLATFORMS:
        folder = tmp_path / platform
        packed[platform] = release.package(platform, binary, folder)
    return tmp_path, packed


def test_each_package_holds_the_expected_files_once(archives):
    _, packed = archives
    assert sorted(release.PLATFORMS) == ["linux-x86_64", "macos-arm64", "macos-x86_64", "windows-x86_64"]
    for platform, path in packed.items():
        assert path.name == f"agentica-{release.version()}-{platform}." + ("zip" if "windows" in platform else "tar.gz")
        top = release.package_name(platform)
        names = sorted(name for name, kind in release.list_archive(path) if kind == "file")
        assert names == sorted(f"{top}/{member}" for member in release.expected_members(platform))
    assert "bin/agentica.exe" in release.expected_members("windows-x86_64")
    assert "bin/agentica" in release.expected_members("macos-arm64")


def with_member(source, target, info):
    """Copy a tar archive and add one more member."""
    with tarfile.open(source) as old, tarfile.open(target, "w:gz") as new:
        for member in old.getmembers():
            new.addfile(member, old.extractfile(member))
        new.addfile(info)


def test_a_package_with_an_extra_file_in_bin_is_refused(archives):
    tmp_path, packed = archives
    top = release.package_name("linux-x86_64")
    extra = tmp_path / "extra.tar.gz"
    with_member(packed["linux-x86_64"], extra, tarfile.TarInfo(f"{top}/bin/other"))
    with pytest.raises(SystemExit):
        release.verify_archive(extra, "linux-x86_64")


def test_a_package_with_a_link_or_a_device_is_refused(archives):
    tmp_path, packed = archives
    top = release.package_name("linux-x86_64")
    for kind in (tarfile.SYMTYPE, tarfile.LNKTYPE, tarfile.CHRTYPE):
        info = tarfile.TarInfo(f"{top}/bin/other")
        info.type, info.linkname = kind, "agentica"
        odd = tmp_path / "odd.tar.gz"
        with_member(packed["linux-x86_64"], odd, info)
        with pytest.raises(SystemExit):
            release.verify_archive(odd, "linux-x86_64")
    link = tmp_path / "link.zip"
    with zipfile.ZipFile(link, "w") as z:
        info = zipfile.ZipInfo(f"{release.package_name('windows-x86_64')}/bin/agentica.exe")
        info.external_attr = 0o120777 << 16
        z.writestr(info, "agentica")
    with pytest.raises(SystemExit):
        release.verify_archive(link, "windows-x86_64")


def test_the_same_binary_packs_to_the_same_bytes(tmp_path, monkeypatch):
    monkeypatch.setenv("SOURCE_DATE_EPOCH", "1700000000")
    binary = tmp_path / "agentica"
    binary.write_bytes(b"not a program")
    for platform in release.PLATFORMS:
        first = release.package(platform, binary, tmp_path / "one" / platform)
        second = release.package(platform, binary, tmp_path / "two" / platform)
        assert first.read_bytes() == second.read_bytes()


def test_collect_needs_exactly_the_four_archives(archives):
    tmp_path, packed = archives
    gathered = tmp_path / "gathered"
    for platform, path in packed.items():
        (gathered / f"agentica-{platform}").mkdir(parents=True)
        (gathered / f"agentica-{platform}" / path.name).write_bytes(path.read_bytes())
    out = tmp_path / "release"
    release.collect(gathered, out)
    sums = (out / "SHA256SUMS").read_text(encoding="utf-8").splitlines()
    assert sorted(line.split("  ")[1] for line in sums) == sorted(p.name for p in packed.values())

    missing = gathered / "agentica-macos-arm64" / packed["macos-arm64"].name
    missing.unlink()
    with pytest.raises(SystemExit):
        release.collect(gathered, out)

    # The same archive from two artifacts must not be taken for one.
    (gathered / "agentica-macos-arm64" / packed["macos-arm64"].name).write_bytes(packed["macos-arm64"].read_bytes())
    (gathered / "agentica-other").mkdir()
    (gathered / "agentica-other" / packed["macos-arm64"].name).write_bytes(packed["macos-arm64"].read_bytes())
    with pytest.raises(SystemExit):
        release.collect(gathered, out)
    (gathered / "agentica-other" / packed["macos-arm64"].name).unlink()

    (gathered / "agentica-other" / "surprise.zip").write_bytes(b"x")
    with pytest.raises(SystemExit):
        release.collect(gathered, out)


def test_zip_members_keep_the_executable_bit(archives):
    _, packed = archives
    with zipfile.ZipFile(packed["windows-x86_64"]) as z:
        info = z.getinfo(f"{release.package_name('windows-x86_64')}/bin/agentica.exe")
    assert (info.external_attr >> 16) & 0o111
