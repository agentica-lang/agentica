"""tools/provision_duckdb.py against small local archives.

No network, no C loads: each case builds a tiny .tar.gz in a tmp dir and calls
`stage()` on its bytes, so only the hash check and the member selection run.
"""
import hashlib
import importlib.util
import io
import json
import tarfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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


def already_staged(tmp_path):
    """native/linux/ holding a library from an earlier run."""
    out = tmp_path / "native" / "linux"
    out.mkdir(parents=True)
    (out / MEMBER).write_bytes(b"already staged")
    return out


def assert_stage_refused(out):
    data = archive((MEMBER, "file", LIB))
    with pytest.raises(SystemExit):
        provision.stage(data, digest(data), MEMBER, out)
    assert (out / MEMBER).read_bytes() == b"already staged"


def test_stage_refuses_to_overwrite_an_existing_library(tmp_path):
    assert_stage_refused(already_staged(tmp_path))


def test_read_asset_returns_a_small_local_file(tmp_path):
    path = tmp_path / "pinned.tar.gz"
    path.write_bytes(b"fake archive bytes")
    assert provision.read_asset(str(path), "pinned.tar.gz") == b"fake archive bytes"


def test_read_asset_rejects_an_oversized_local_file(tmp_path, monkeypatch):
    monkeypatch.setattr(provision, "MAX_COMPRESSED", 16)
    path = tmp_path / "big.tar.gz"
    path.write_bytes(b"x" * 17)
    with pytest.raises(SystemExit):
        provision.read_asset(str(path), "big.tar.gz")


def test_read_asset_fails_closed_on_a_missing_file(tmp_path):
    with pytest.raises(SystemExit):
        provision.read_asset(str(tmp_path / "absent.tar.gz"), "absent.tar.gz")


def test_stage_refuses_a_create_that_lost_the_race(tmp_path, monkeypatch):
    """The exclusive create, not the friendly check, owns the guarantee."""
    out = already_staged(tmp_path)
    monkeypatch.setattr(Path, "exists", lambda self: False)
    assert_stage_refused(out)


def test_linux_arm64_takes_its_own_asset_and_stages_under_linux(tmp_path, monkeypatch, capsys):
    monkeypatch.setattr(provision.sys, "platform", "linux")
    monkeypatch.setattr(provision.platform, "machine", lambda: "aarch64")
    assert provision.this_system() == "linux-arm64"
    data = archive((MEMBER, "file", LIB))
    path = tmp_path / "pinned.tar.gz"
    path.write_bytes(data)
    name = provision.ASSETS["linux-arm64"][0]
    monkeypatch.setitem(provision.ASSETS, "linux-arm64", (name, digest(data), MEMBER))
    assert provision.main(["--out", str(tmp_path / "out"), "--asset", str(path)]) == 0
    target = tmp_path / "out" / "native" / "linux" / MEMBER
    assert capsys.readouterr().out.strip() == str(target.resolve())
    assert target.read_bytes() == LIB


class Release:
    """A local stand-in for github.com/duckdb release downloads and the release API, on port 0.

    `script` maps a request path to a list of answers used in turn (the last one repeats): an int is a status with
    no body, bytes are a 200 body. `seen` records (path, Accept, Authorization) per request."""

    def __init__(self, script):
        self.script = script
        self.seen = []
        release = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                release.seen.append((self.path, self.headers.get("Accept"), self.headers.get("Authorization")))
                answers = release.script.get(self.path, [404])
                answer = answers[min(len([s for s in release.seen if s[0] == self.path]) - 1, len(answers) - 1)]
                body = answer if isinstance(answer, bytes) else b""
                self.send_response(200 if isinstance(answer, bytes) else answer)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):
                pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = "http://127.0.0.1:%d" % self.server.server_port
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def count(self, path):
        return len([seen for seen in self.seen if seen[0] == path])


NAME = "duckdb-shared-libs-linux-amd64.tar.gz"
DOWNLOAD = "/dl/" + NAME
RELEASE_PATH = "/repos/duckdb/duckdb/releases/tags/" + provision.VERSION


@pytest.fixture
def served(monkeypatch):
    """A Release factory that points the tool at it and records the pauses instead of sleeping."""
    pauses = []
    made = []
    monkeypatch.setattr(provision, "pause", pauses.append)
    monkeypatch.delenv("GITHUB_TOKEN", raising=False)

    def serve(script, data):
        release = Release(script)
        made.append(release)
        monkeypatch.setattr(provision, "BASE", release.url + "/dl")
        monkeypatch.setattr(provision, "API", release.url)
        monkeypatch.setitem(provision.ASSETS, "linux", (NAME, digest(data), MEMBER))
        return release

    yield serve, pauses
    for release in made:
        release.close()


def provision_linux(tmp_path):
    return provision.main(["--out", str(tmp_path / "out"), "--os", "linux"])


def test_a_download_that_fails_twice_is_retried_with_a_growing_pause(tmp_path, served):
    serve, pauses = served
    data = archive((MEMBER, "file", LIB))
    release = serve({DOWNLOAD: [503, 429, data]}, data)
    assert provision_linux(tmp_path) == 0
    assert (tmp_path / "out" / "native" / "linux" / MEMBER).read_bytes() == LIB
    assert release.count(DOWNLOAD) == 3 and pauses == [5, 10]


def test_a_download_that_keeps_failing_stops_after_five_tries(tmp_path, served):
    serve, pauses = served
    release = serve({DOWNLOAD: [503]}, b"")
    with pytest.raises(SystemExit, match="cannot download"):
        provision_linux(tmp_path)
    assert release.count(DOWNLOAD) == 5 and pauses == [5, 10, 20, 40]


def test_a_404_is_not_retried(tmp_path, served):
    serve, pauses = served
    release = serve({DOWNLOAD: [404]}, b"")
    with pytest.raises(SystemExit, match="cannot download"):
        provision_linux(tmp_path)
    assert release.count(DOWNLOAD) == 1 and pauses == []


def test_a_checksum_mismatch_is_not_retried(tmp_path, served):
    serve, pauses = served
    data = archive((MEMBER, "file", LIB))
    release = serve({DOWNLOAD: [archive((MEMBER, "file", b"tampered"))]}, data)
    with pytest.raises(SystemExit, match="is not the pinned"):
        provision_linux(tmp_path)
    assert release.count(DOWNLOAD) == 1 and pauses == []
    assert not list((tmp_path / "out").rglob(MEMBER))


def test_the_release_api_is_tried_first_with_the_token_and_octet_stream(tmp_path, served, monkeypatch):
    serve, pauses = served
    data = archive((MEMBER, "file", LIB))
    listing = json.dumps({"assets": [{"id": 7, "name": "other.zip"}, {"id": 42, "name": NAME}]}).encode()
    release = serve({RELEASE_PATH: [listing], "/repos/duckdb/duckdb/releases/assets/42": [data]}, data)
    monkeypatch.setenv("GITHUB_TOKEN", "secret")
    assert provision_linux(tmp_path) == 0
    assert release.count(DOWNLOAD) == 0
    assert release.seen[-1] == ("/repos/duckdb/duckdb/releases/assets/42", "application/octet-stream",
                                "Bearer secret")


def test_a_cached_archive_is_used_only_when_it_has_the_pinned_hash(tmp_path, served):
    serve, pauses = served
    data = archive((MEMBER, "file", LIB))
    release = serve({DOWNLOAD: [data]}, data)
    cache = tmp_path / "cache"
    cache.mkdir()
    (cache / NAME).write_bytes(b"stale")
    args = ["--out", str(tmp_path / "out"), "--os", "linux", "--cache", str(cache)]
    assert provision.main(args) == 0
    assert release.count(DOWNLOAD) == 1 and (cache / NAME).read_bytes() == data
    assert provision.main(args[:1] + [str(tmp_path / "out2")] + args[2:]) == 0
    assert release.count(DOWNLOAD) == 1
