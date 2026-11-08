#!/usr/bin/env python3
"""Stage the pinned DuckDB shared library for examples/ffi/duckdb.

Downloads (or takes with --asset) exactly one pinned v2.0.0 archive for this
system (and, on Linux, this architecture), checks its SHA-256 before unpacking
anything, extracts only the shared library to OUT/native/<os>/<name> (the
layout agentica.toml points at), and prints the absolute path of the staged
library. Python's standard library only; used by the README and by CI, never by
the ordinary test run (tests read DUCKDB_LIB and never fetch anything
themselves).
"""
from __future__ import annotations

import argparse
import hashlib
import http.client
import io
import json
import os
import platform
import sys
import tarfile
import time
import urllib.error
import urllib.request
from pathlib import Path

VERSION = "v2.0.0"
BASE = f"https://github.com/duckdb/duckdb/releases/download/{VERSION}"
# The GitHub API route to the same asset (the one agentica-lang/setup-agentica takes): it is rate-limited apart from
# the release CDN and takes GITHUB_TOKEN. Tried first; the plain URL above is the fallback.
API = "https://api.github.com"
REPOSITORY = "duckdb/duckdb"

# asset key -> (asset name, archive sha256, shared library: the member in the
# archive and the name staged under native/<os>/, one and the same). The key is
# the os-key, with "-arm64" for Linux on ARM64; both Linux keys stage under
# native/linux/.
ASSETS = {
    "linux": (
        "duckdb-shared-libs-linux-amd64.tar.gz",
        "993ad89e7dfca66cd6da994c2cad090c2fc160ddf9f550498a098ab4bb13cfb1",
        "libduckdb.so",
    ),
    "linux-arm64": (
        "duckdb-shared-libs-linux-arm64.tar.gz",
        "c60eecf91143ca6bbac55c4f4d40dc22520488b0ac257c86e0fe9a2b451cf2b7",
        "libduckdb.so",
    ),
    "macos": (
        "duckdb-shared-libs-osx-universal.tar.gz",
        "14cd63180614cfd961f7959146ecd9087527ff20b67311efdc3fa1c29c18204d",
        "libduckdb.dylib",
    ),
    "windows": (
        "duckdb-shared-libs-windows-amd64.tar.gz",
        "2b83169128239de5f45fe21de80f99bf436e53aa4bb24020dd951a1ba8d4b95f",
        "duckdb.dll",
    ),
}

MAX_COMPRESSED = 128 * 1024 * 1024
MAX_MEMBER = 1024 * 1024 * 1024
REQUEST_TIMEOUT = 30
DEADLINE = 600
# A failed download is tried again after these pauses (5 tries): GitHub's release hosts answer 5xx now and then.
BACKOFF = (5, 10, 20, 40)
pause = time.sleep


def this_system() -> str:
    """The asset key of this machine (the macOS asset is universal)."""
    if sys.platform.startswith("linux"):
        return "linux-arm64" if platform.machine().lower() in ("aarch64", "arm64") else "linux"
    if sys.platform == "darwin":
        return "macos"
    if sys.platform in ("win32", "cygwin", "msys"):
        return "windows"
    raise SystemExit(f"provision_duckdb.py: unsupported system {sys.platform}")


def retryable(error: BaseException) -> bool:
    """Whether a failed request may succeed when repeated: 5xx, 429, a timeout, a dropped or refused connection. A
    404 or any other 4xx is an answer, not a fault, and is never repeated."""
    if isinstance(error, urllib.error.HTTPError):
        return error.code >= 500 or error.code == 429
    return isinstance(error, (OSError, http.client.HTTPException))


def fetch(url: str, headers: dict[str, str], unredirected: dict[str, str] | None = None) -> bytes:
    """One URL, with the caps and the deadline of a single try per attempt and BACKOFF between the attempts.
    `unredirected` headers (the token) are sent to URL only, never to the host it redirects to."""
    for attempt in range(len(BACKOFF) + 1):
        try:
            return fetch_once(url, headers, unredirected or {})
        except (OSError, http.client.HTTPException) as error:
            if attempt == len(BACKOFF) or not retryable(error):
                raise
            print(f"provision_duckdb.py: {url}: {error}; retrying in {BACKOFF[attempt]}s", file=sys.stderr)
            pause(BACKOFF[attempt])
    raise AssertionError("unreachable")


def fetch_once(url: str, headers: dict[str, str], unredirected: dict[str, str]) -> bytes:
    body = io.BytesIO()
    started = time.monotonic()
    request = urllib.request.Request(url, headers={"User-Agent": "agentica-duckdb-example", **headers})
    for name, value in unredirected.items():
        request.add_unredirected_header(name, value)
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


def read_via_api(name: str) -> bytes:
    """The archive through the release API: tag -> asset id -> the bytes (`Accept: application/octet-stream`)."""
    token = os.environ.get("GITHUB_TOKEN")
    auth = {"Authorization": f"Bearer {token}"} if token else {}
    release = json.loads(fetch(f"{API}/repos/{REPOSITORY}/releases/tags/{VERSION}",
                               {"Accept": "application/vnd.github+json"}, auth))
    ids = [asset["id"] for asset in release["assets"] if asset["name"] == name]
    if len(ids) != 1:
        raise ValueError(f"the release lists {len(ids)} assets named {name}")
    return fetch(f"{API}/repos/{REPOSITORY}/releases/assets/{ids[0]}", {"Accept": "application/octet-stream"}, auth)


def read_asset(asset: str | None, name: str) -> bytes:
    """The bytes of the pinned archive: a local file with --asset, else a download (API route, then the plain URL)."""
    if asset is not None:
        return read_file_capped(asset)
    try:
        return read_via_api(name)
    except (OSError, http.client.HTTPException, ValueError, KeyError) as error:
        print(f"provision_duckdb.py: the release API did not give {name} ({error}); trying the plain URL",
              file=sys.stderr)
    url = f"{BASE}/{name}"
    try:
        return fetch(url, {})
    except (OSError, http.client.HTTPException) as error:
        raise SystemExit(f"provision_duckdb.py: cannot download {url}: {error}")


def read_file_capped(path: str) -> bytes:
    """A local archive, streamed with the same 128MiB cap as a download."""
    body = io.BytesIO()
    try:
        with open(path, "rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    return body.getvalue()
                body.write(chunk)
                if body.tell() > MAX_COMPRESSED:
                    raise SystemExit(f"provision_duckdb.py: --asset {path} is larger than 128MiB")
    except OSError as error:
        raise SystemExit(f"provision_duckdb.py: cannot read --asset {path}: {error}")


def read_cached(cache: str, name: str, digest: str) -> bytes | None:
    """The archive kept in CACHE, or None when there is none or it is not the pinned one."""
    path = Path(cache) / name
    if not path.is_file():
        return None
    data = read_file_capped(str(path))
    return data if hashlib.sha256(data).hexdigest() == digest else None


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
    parser.add_argument("--cache", default=None,
                        help="folder that keeps the downloaded archive between runs (CI caches it); the archive is "
                             "used only when it has the pinned hash")
    parser.add_argument("--os", default=None, choices=sorted(ASSETS),
                        help="provision for this system instead of this machine's (testing only)")
    args = parser.parse_args(argv)
    system = args.os or this_system()
    name, digest, member = ASSETS[system]
    data = read_cached(args.cache, name, digest) if args.cache and args.asset is None else None
    if data is None:
        data = read_asset(args.asset, name)
        if args.cache and hashlib.sha256(data).hexdigest() == digest:
            keep = Path(args.cache)
            keep.mkdir(parents=True, exist_ok=True)
            (keep / name).write_bytes(data)
    target = stage(data, digest, member, Path(args.out) / "native" / system.split("-")[0])
    print(str(target.resolve()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
