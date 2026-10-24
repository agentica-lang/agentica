#!/usr/bin/env python3
"""Stage the pinned DuckDB shared library for examples/ffi/duckdb.

Downloads (or takes with --asset) exactly one pinned v2.0.0 archive for this
system, checks its SHA-256 before unpacking anything, extracts only the shared
library to OUT/native/<os>/<name> (the layout agentica.toml points at), and
prints the absolute path of the staged library. Python's standard library
only; used by the README and by CI, never by the ordinary test run (tests read
DUCKDB_LIB and never fetch anything themselves).
"""
from __future__ import annotations

import argparse
import hashlib
import io
import sys
import tarfile
import time
import urllib.request
from pathlib import Path

VERSION = "v2.0.0"
BASE = f"https://github.com/duckdb/duckdb/releases/download/{VERSION}"

# os-key -> (asset name, archive sha256, member in the archive, staged name).
ASSETS = {
    "linux": (
        "duckdb-shared-libs-linux-amd64.tar.gz",
        "993ad89e7dfca66cd6da994c2cad090c2fc160ddf9f550498a098ab4bb13cfb1",
        "libduckdb.so",
        "libduckdb.so",
    ),
    "macos": (
        "duckdb-shared-libs-osx-universal.tar.gz",
        "14cd63180614cfd961f7959146ecd9087527ff20b67311efdc3fa1c29c18204d",
        "libduckdb.dylib",
        "libduckdb.dylib",
    ),
    "windows": (
        "duckdb-shared-libs-windows-amd64.tar.gz",
        "2b83169128239de5f45fe21de80f99bf436e53aa4bb24020dd951a1ba8d4b95f",
        "duckdb.dll",
        "duckdb.dll",
    ),
}

MAX_COMPRESSED = 128 * 1024 * 1024
MAX_MEMBER = 1024 * 1024 * 1024
REQUEST_TIMEOUT = 30
DEADLINE = 600


def this_system() -> str:
    """The os-key of this machine (the macOS asset is universal)."""
    if sys.platform.startswith("linux"):
        return "linux"
    if sys.platform == "darwin":
        return "macos"
    if sys.platform in ("win32", "cygwin", "msys"):
        return "windows"
    raise SystemExit(f"provision_duckdb.py: unsupported system {sys.platform}")


def read_asset(asset: str | None, name: str) -> bytes:
    """The bytes of the pinned archive: a local file with --asset, else one download."""
    if asset is not None:
        data = Path(asset).read_bytes()
        if len(data) > MAX_COMPRESSED:
            raise SystemExit(f"provision_duckdb.py: --asset {asset} is larger than 128MiB")
        return data
    url = f"{BASE}/{name}"
    body = io.BytesIO()
    started = time.monotonic()
    request = urllib.request.Request(url, headers={"User-Agent": "agentica-duckdb-example"})
    try:
        with urllib.request.urlopen(request, timeout=REQUEST_TIMEOUT) as response:
            while True:
                if time.monotonic() - started > DEADLINE:
                    raise SystemExit("provision_duckdb.py: download past its deadline")
                chunk = response.read(1024 * 1024)
                if not chunk:
                    return body.getvalue()
                body.write(chunk)
                if body.tell() > MAX_COMPRESSED:
                    raise SystemExit(f"provision_duckdb.py: {url} is larger than 128MiB")
    except OSError as error:
        raise SystemExit(f"provision_duckdb.py: cannot download {url}: {error}")


def stage(data: bytes, digest: str, member: str, out: Path) -> Path:
    """Check the archive hash, then extract only MEMBER to its fixed path."""
    actual = hashlib.sha256(data).hexdigest()
    if actual != digest:
        raise SystemExit(f"provision_duckdb.py: archive hash {actual} is not the pinned {digest}")
    out.mkdir(parents=True, exist_ok=True)
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        names = [info.name for info in archive.getmembers()]
        if names.count(member) != 1:
            raise SystemExit(f"provision_duckdb.py: archive holds {names.count(member)} {member} members")
        info = archive.getmember(member)
        if not info.isfile() or info.size <= 0 or info.size > MAX_MEMBER:
            raise SystemExit(f"provision_duckdb.py: refusing member {member} of size {info.size}")
        target = out / member
        if target.exists():
            raise SystemExit(f"provision_duckdb.py: refusing to overwrite {target}")
        source = archive.extractfile(info)
        if source is None:
            raise SystemExit(f"provision_duckdb.py: cannot read member {member}")
        try:
            handle = open(target, "xb")
        except FileExistsError:
            raise SystemExit(f"provision_duckdb.py: refusing to overwrite {target}")
        with handle, source:
            while True:
                chunk = source.read(1024 * 1024)
                if not chunk:
                    break
                handle.write(chunk)
    return target


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, help="directory holding native/<os>/... (created)")
    parser.add_argument("--asset", default=None, help="local pinned archive instead of downloading")
    parser.add_argument("--os", default=None, choices=sorted(ASSETS),
                        help="provision for this system instead of this machine's (testing only)")
    args = parser.parse_args(argv)
    system = args.os or this_system()
    name, digest, member, staged = ASSETS[system]
    data = read_asset(args.asset, name)
    target = stage(data, digest, member, Path(args.out) / "native" / system)
    if target.name != staged:
        target.rename(target.with_name(staged))
        target = target.with_name(staged)
    print(str(target.resolve()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
