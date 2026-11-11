"""`.github/scripts/apt-mirror.sh` rewrites the apt sources of a runner to non-Canonical mirrors.

The script runs on a fake root. The cases are the shapes the runners really have: the `URIs:` of deb822 files with and
without a trailing slash (the arm64 runner has none), one-line `deb` entries, and the mirror list of the amd64 runner.
Running it a second time must change nothing.
"""
import os
import subprocess

import pytest

from tests.agentica_test import ROOT

SCRIPT = ROOT / ".github" / "scripts" / "apt-mirror.sh"
EDGE = "https://mirrors.edge.kernel.org/ubuntu/"
PORTS = "https://mirrors.ocf.berkeley.edu/ubuntu-ports/"


def run_script(root, arch):
    env = {**os.environ, "APT_MIRROR_ARCH": arch}
    return subprocess.run(["bash", str(SCRIPT), str(root)], env=env, capture_output=True, text=True, check=True)


def write_sources(root, name, text):
    path = root / "etc" / "apt" / "sources.list.d" / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


@pytest.mark.parametrize(
    "arch, uri, expected",
    [
        ("arm64", "http://ports.ubuntu.com/ubuntu-ports", PORTS),
        ("arm64", "http://ports.ubuntu.com/ubuntu-ports/", PORTS),
        ("arm64", "http://archive.ubuntu.com/ubuntu", PORTS),
        ("amd64", "http://archive.ubuntu.com/ubuntu", EDGE),
        ("amd64", "http://security.ubuntu.com/ubuntu/", EDGE),
    ],
)
def test_uris_with_and_without_trailing_slash(tmp_path, arch, uri, expected):
    path = write_sources(tmp_path, "ubuntu.sources", f"Types: deb\nURIs: {uri}\nSuites: noble\n")
    run_script(tmp_path, arch)
    assert path.read_text() == f"Types: deb\nURIs: {expected}\nSuites: noble\n"
    first = path.read_text()
    run_script(tmp_path, arch)
    assert path.read_text() == first


def test_one_line_entries_keep_their_separator(tmp_path):
    path = write_sources(
        tmp_path,
        "ubuntu.list",
        "deb http://archive.ubuntu.com/ubuntu noble main\n"
        "deb http://ports.ubuntu.com/ubuntu-ports noble-updates main\n"
        "deb http://example.com/ubuntu noble main\n",
    )
    run_script(tmp_path, "arm64")
    assert path.read_text() == (
        f"deb {PORTS} noble main\n"
        f"deb {PORTS} noble-updates main\n"
        "deb http://example.com/ubuntu noble main\n"
    )


def test_mirror_list_collapses_to_one_line(tmp_path):
    path = tmp_path / "etc" / "apt" / "apt-mirrors.txt"
    path.parent.mkdir(parents=True)
    path.write_text(
        "http://azure.archive.ubuntu.com/ubuntu/\tpriority:1\n"
        "http://archive.ubuntu.com/ubuntu/\tpriority:2\n"
    )
    run_script(tmp_path, "amd64")
    assert path.read_text() == f"{EDGE}\tpriority:1\n"
