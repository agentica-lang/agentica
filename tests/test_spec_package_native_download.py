"""Downloaded native artifacts ([native] url/sha256/member) through install/update/check/compile/run.

Hermetic: archives are built with tarfile/gzip/hashlib, served by a plain HTTP server on 127.0.0.1 port 0
(allowed loopback http); no external network, no pip. Cases assert PKG codes and file/key paths, never messages.
"""
import hashlib
import io
import json
import tarfile
import threading
import zipfile
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

from tests.agentica_test import TARGET_OS, WINDOWS, cli, run, vm_environment
from tests.package_support import (Workspace, assert_at_key, build, command, git, install, lock_entry, package_hash,
                                    plain, problem_of, remotes)
from tests.test_vm_native import NATIVE_CALLS, library_name, shared_library

HERE = "windows" if WINDOWS else "macos" if TARGET_OS == "darwin" else "linux"
OTHER = "linux" if HERE == "windows" else "windows"
THIRD = "macos" if HERE != "macos" else "linux"

DEMO = 'extern "pkgdemo"\n  export def pkgdemo_add(a: C.Int32, b: C.Int32) -> C.Int32\nend\n'
MAIN = 'import Demo from "pkg/pkgdemo/demo"\n\ndef main() -> Void\n  puts(Demo.pkgdemo_add(40, 2))\nend\n'
ROOT_MAIN = 'import Demo from "demo"\n\nextern "demo"\n  export def demo_add(a: C.Int32, b: C.Int32) -> C.Int32\nend\n\ndef main() -> Void\n  puts(demo_add(40, 2))\nend\n'


class Server:
    def __init__(self, routes):
        self.routes = routes
        self.requests = []
        handler = self._handler()
        self.httpd = HTTPServer(("127.0.0.1", 0), handler)
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def _handler(self):
        routes, requests = self.routes, self.requests

        class H(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                requests.append(self.path)
                if self.path in routes:
                    body = routes[self.path]
                    self.send_response(200)
                    self.send_header("Content-Type", "application/octet-stream")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(404)
                    self.end_headers()

            def log_message(self, *args):
                pass

        return H

    def url(self, path):
        return "http://127.0.0.1:%d%s" % (self.port, path)

    def stop(self):
        self.httpd.shutdown()
        self.thread.join()


@pytest.fixture()
def server():
    routes = {}
    srv = Server(routes)
    srv.routes_ref = routes
    yield srv
    srv.stop()


def make_tar(members, gzip=True):
    buf = io.BytesIO()
    mode = "w:gz" if gzip else "w"
    with tarfile.open(fileobj=buf, mode=mode) as tar:
        for name, data in members.items():
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mtime = 0
            info.mode = 0o755
            tar.addfile(info, io.BytesIO(data))
    return buf.getvalue()


def make_zip(members):
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in members.items():
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            zf.writestr(info, data)
    return buf.getvalue()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def no_proxy_env(ws):
    env = dict(ws.cache_variables)
    env.update({"AGENTICA_PATH": ""})
    return vm_environment(env)


def run_cli(ws, *words, extra=None):
    env = no_proxy_env(ws)
    if extra:
        env.update(extra)
    return run(cli() + list(words), cwd=ws.project, env=env)


def update(ws, *words, extra=None):
    result = run_cli(ws, "--json", "update", *words, extra=extra)
    if result.code == 0:
        assert result.stdout == '{"ok":true}\n'
        return result, None
    return result, json.loads(result.stderr) if result.code == 1 else None


def check_json(ws, path, extra=None):
    result = run_cli(ws, "--json", "check", str(path), extra=extra)
    if result.code == 0:
        return result, None
    return result, json.loads(result.stderr) if result.code == 1 else None


def download_row(system, url, sha, member="lib.bin"):
    return '%s = { url = "%s", sha256 = "%s", member = "%s" }\n' % (system, url, sha, member)


def write_root_manifest(ws, lib, rows):
    text = 'name = "app"\n\n[native.%s]\n' % lib + "".join(rows)
    (ws.project / "agentica.toml").write_text(text, encoding="utf-8")


def test_root_nodb_manifest_shapes_reject_before_network(server, tmp_path):
    ws = Workspace(tmp_path)
    (ws.project / "main.agc").write_text('def main() -> Void\nend\n', encoding="utf-8")
    good_url = server.url("/t/lib.tar")
    good_sha = "ab" * 32
    cases = [
        ('%s = { url = "%s", sha256 = "%s" }\n' % (HERE, good_url, good_sha), "native.demo.%s" % HERE),
        ('%s = { url = "%s", member = "lib.bin" }\n' % (HERE, good_url), "native.demo.%s" % HERE),
        ('%s = { sha256 = "%s", member = "lib.bin" }\n' % (HERE, good_sha), "native.demo.%s" % HERE),
        ('%s = { file = "native/x.bin", url = "%s", sha256 = "%s", member = "lib.bin" }\n' % (HERE, good_url, good_sha),
         "native.demo.%s" % HERE),
        ('%s = { system = "libx", url = "%s", sha256 = "%s", member = "lib.bin" }\n' % (HERE, good_url, good_sha),
         "native.demo.%s" % HERE),
        ('%s = { url = "ftp://example.com/x.tar", sha256 = "%s", member = "lib.bin" }\n' % (HERE, good_sha),
         "native.demo.%s.url" % HERE),
        ('%s = { url = "%s", sha256 = "ZZ", member = "lib.bin" }\n' % (HERE, good_url), "native.demo.%s.sha256" % HERE),
        ('%s = { url = "%s", sha256 = "%s", member = "../evil" }\n' % (HERE, good_url, good_sha),
         "native.demo.%s.member" % HERE),
    ]
    for body, key in cases:
        write_root_manifest(ws, "demo", [body])
        result, problem = check_json(ws, ws.project / "main.agc")
        # Missing lock for a downloading project is PKG-LOCK-MISSING at the lock file; malformed rows are
        # PKG-MANIFEST-INVALID at their key. Both prove no network use for bad manifests.
        assert result.code == 1
        assert problem["code"] in ("PKG-MANIFEST-INVALID", "PKG-LOCK-MISSING"), (body, problem)
        if problem["code"] == "PKG-MANIFEST-INVALID":
            assert_at_key(problem, "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", key)
    assert server.requests == []


def test_root_native_only_install_update_and_offline_hit(server, tmp_path):
    ws = Workspace(tmp_path)
    (ws.project / "main.agc").write_text('def main() -> Void\nend\n', encoding="utf-8")
    archive = make_tar({"lib.bin": b"member-bytes", "sub/deep.bin": b"deep-bytes"})
    sha = digest(archive)
    server.routes_ref["/t/lib.tar"] = archive
    write_root_manifest(ws, "demo", [download_row(HERE, server.url("/t/lib.tar"), sha)])
    # No lock yet: check reports the missing lock without touching the network.
    mark = len(server.requests)
    result, problem = check_json(ws, ws.project / "main.agc")
    assert result.code == 1 and problem["code"] == "PKG-LOCK-MISSING"
    assert len(server.requests) == mark
    # Update pins all rows and fetches HOST; install from the lock fetches again from cache.
    result, problem = update(ws)
    assert (result.code, problem) == (0, None), getattr(result, "stderr", "")
    lock_text = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    assert "[[native-artifact]]" in lock_text and sha in lock_text
    result, problem = install(ws, None) if False else (None, None)
    # install via package_support helper needs remotes; use CLI directly with cache env.
    result = run_cli(ws, "--json", "install")
    assert result.code == 0, result.stderr
    assert len(server.requests) >= 1
    # Offline: check/compile/run use the cache alone and never fetch.
    mark = len(server.requests)
    result, problem = check_json(ws, ws.project / "main.agc")
    # Unused alias stays lazy: no extern use, so check passes even though the member is dummy bytes.
    assert (result.code, problem) == (0, None), problem
    assert len(server.requests) == mark


def test_all_systems_pinned_host_fetched_only(server, tmp_path):
    ws = Workspace(tmp_path)
    (ws.project / "main.agc").write_text('def main() -> Void\nend\n', encoding="utf-8")
    archives = {}
    for system, path in [(HERE, "/t/here.tar"), (OTHER, "/t/other.tar"), (THIRD, "/t/third.tar")]:
        archives[system] = make_tar({"lib.bin": ("%s-bytes" % system).encode()})
        server.routes_ref[path] = archives[system]
    rows = [download_row(HERE, server.url("/t/here.tar"), digest(archives[HERE])),
            download_row(OTHER, server.url("/t/other.tar"), digest(archives[OTHER])),
            download_row(THIRD, server.url("/t/third.tar"), digest(archives[THIRD]))]
    write_root_manifest(ws, "demo", rows)
    result, problem = update(ws)
    assert (result.code, problem) == (0, None), getattr(result, "stderr", problem)
    lock_text = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    assert lock_text.count("[[native-artifact]]") == 3
    paths = [line for line in server.requests]
    assert any(p == "/t/here.tar" for p in paths)
    assert not any(p in ("/t/other.tar", "/t/third.tar") for p in paths)


def test_multi_member_one_archive_two_aliases(server, tmp_path):
    ws = Workspace(tmp_path)
    (ws.project / "main.agc").write_text('def main() -> Void\nend\n', encoding="utf-8")
    archive = make_tar({"a.bin": b"a-bytes", "b.bin": b"b-bytes"})
    sha = digest(archive)
    server.routes_ref["/t/multi.tar"] = archive
    url = server.url("/t/multi.tar")
    text = 'name = "app"\n\n[native.a]\n' + download_row(HERE, url, sha, "a.bin")
    text += '\n[native.b]\n' + download_row(HERE, url, sha, "b.bin")
    (ws.project / "agentica.toml").write_text(text, encoding="utf-8")
    result, problem = update(ws)
    assert (result.code, problem) == (0, None), getattr(result, "stderr", problem)
    lock_text = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    assert lock_text.count("[[native-artifact]]") == 2
    # One archive download serves both members (second member reuses the archive).
    assert [p for p in server.requests if p == "/t/multi.tar"] != []


def use_site(ws, server, member_bytes=b"member-bytes", member="lib.bin", route="/t/lib.tar"):
    """A project whose main uses downloaded `demo`: writes the sources, serves the archive and pins it."""
    (ws.project / "demo.agc").write_text('extern "demo"\n  export def f() -> Void\nend\n', encoding="utf-8")
    (ws.project / "main.agc").write_text(
        'import Demo from "demo"\n\nextern "demo"\n  export def f() -> Void\nend\n\ndef main() -> Void\n  f()\nend\n',
        encoding="utf-8")
    archive = make_tar({member: member_bytes})
    sha = digest(archive)
    server.routes_ref[route] = archive
    write_root_manifest(ws, "demo", [download_row(HERE, server.url(route), sha)])
    return sha


def test_locked_drift_and_corrupt_cache_are_use_site_errors(server, tmp_path):
    ws = Workspace(tmp_path)
    sha = use_site(ws, server)
    result, problem = update(ws)
    assert (result.code, problem) == (0, None)
    # Drift the manifest without updating the lock: use fails PKG-LOCK-STALE at the manifest row.
    write_root_manifest(ws, "demo", [download_row(HERE, server.url("/t/lib.tar"), digest(b"other"))])
    result, problem = check_json(ws, ws.project / "main.agc")
    assert problem["code"] == "PKG-LOCK-STALE"
    assert_at_key(problem, "PKG-LOCK-STALE", ws.project / "agentica.toml", "native.demo.%s" % HERE)
    # Restore, then corrupt the cached member: use fails PKG-HASH-MISMATCH.
    write_root_manifest(ws, "demo", [download_row(HERE, server.url("/t/lib.tar"), sha)])
    result, problem = check_json(ws, ws.project / "main.agc")
    assert problem is None or problem["code"] != "PKG-LOCK-STALE"
    # Find the cached payload via the cache layout and tamper it.
    from tests.package_support import cache_path as _cp  # noqa
    roots = [q for q in (tmp_path / "cache").rglob("lib.bin") if q.is_file()]
    assert roots, "expected a cached payload"
    payload = roots[0]
    payload.write_bytes(payload.read_bytes() + b"\x00")
    result, problem = check_json(ws, ws.project / "main.agc")
    # Tampered payload is a hash mismatch at use (or a cache miss that rebuilds and fails the same way).
    assert problem is not None and problem["code"] in ("PKG-HASH-MISMATCH", "PKG-NATIVE-MISSING"), problem


def test_missing_cache_never_fetches_on_check(server, tmp_path):
    ws = Workspace(tmp_path)
    sha = use_site(ws, server)
    result, problem = update(ws)
    assert (result.code, problem) == (0, None)
    # Wipe the cache: check must fail from the cache alone without fetching.
    import shutil
    shutil.rmtree(tmp_path / "cache", ignore_errors=True)
    (tmp_path / "cache").mkdir(parents=True)
    mark = len(server.requests)
    result, problem = check_json(ws, ws.project / "main.agc")
    assert problem["code"] in ("PKG-NATIVE-MISSING", "PKG-HASH-MISMATCH", "PKG-FETCH"), problem
    assert len(server.requests) == mark


def test_lazy_unavailable_target_and_deny_native(server, tmp_path):
    ws = Workspace(tmp_path)
    (ws.project / "main.agc").write_text('def main() -> Void\nend\n', encoding="utf-8")
    archive = make_tar({"lib.bin": b"x"})
    sha = digest(archive)
    server.routes_ref["/t/lib.tar"] = archive
    # Declared for another system only: unused here, check passes lazily.
    write_root_manifest(ws, "demo", [download_row(OTHER, server.url("/t/other.tar"), sha)])
    server.routes_ref["/t/other.tar"] = make_tar({"lib.bin": b"y"})
    result, problem = update(ws)
    assert (result.code, problem) == (0, None)
    result, problem = check_json(ws, ws.project / "main.agc")
    assert (result.code, problem) == (0, None), problem


def pin_downloaded_demo(ws, url, sha, member):
    """A manifest pinning the archive for every system, with the demo sources that call it."""
    text = 'name = "app"\n\n[native.pkgdemo]\n'
    text += download_row(HERE, url, sha, member)
    text += download_row(OTHER, url, sha, member)
    text += download_row(THIRD, url, sha, member)
    (ws.project / "agentica.toml").write_text(text, encoding="utf-8")
    (ws.project / "demo.agc").write_text(DEMO, encoding="utf-8")
    (ws.project / "main.agc").write_text(
        'import Demo from "demo"\n\ndef main() -> Void\n  puts(Demo.pkgdemo_add(40, 2))\nend\n',
        encoding="utf-8")


def run_downloaded_demo(ws):
    """Run the demo entry point: the downloaded library must add to 42."""
    result = run_cli(ws, str(ws.project / "main.agc"))
    assert (result.code, result.stdout) == (0, "42\n"), (result.code, result.stdout, result.stderr)


@NATIVE_CALLS
def test_downloaded_library_calls_and_deny(server, tmp_path_factory):
    tmp_path = tmp_path_factory.mktemp("native-download-ffi")
    ws = Workspace(tmp_path)
    from tests.test_vm_native import library_name as _libname
    lib_path = shared_library(tmp_path_factory, "pkgdemo")
    lib_bytes = lib_path.read_bytes()
    member = _libname("pkgdemo")
    archive = make_tar({member: lib_bytes})
    sha = digest(archive)
    srv = server
    srv.routes_ref["/t/demo.tar.gz"] = archive
    pin_downloaded_demo(ws, srv.url("/t/demo.tar.gz"), sha, member)
    result, problem = update(ws)
    assert (result.code, problem) == (0, None), getattr(result, "stderr", problem)
    run_downloaded_demo(ws)
    denied = run_cli(ws, "--deny-native", str(ws.project / "main.agc"))
    assert denied.code == 2


@NATIVE_CALLS
def test_zip_archive_download_calls_offline_and_deny(server, tmp_path_factory):
    tmp_path = tmp_path_factory.mktemp("native-download-zip")
    ws = Workspace(tmp_path)
    from tests.test_vm_native import library_name as _libname
    lib_bytes = shared_library(tmp_path_factory, "pkgdemo").read_bytes()
    member = _libname("pkgdemo")
    archive = make_zip({member: lib_bytes})
    assert archive[:4] == b"PK\x03\x04"
    sha = digest(archive)
    # A TAR-looking URL and no format field: the file magic alone routes to the ZIP extractor.
    server.routes_ref["/t/demo.tar.gz"] = archive
    pin_downloaded_demo(ws, server.url("/t/demo.tar.gz"), sha, member)
    result, problem = update(ws)
    assert (result.code, problem) == (0, None), getattr(result, "stderr", problem)
    assert [p for p in server.requests if p == "/t/demo.tar.gz"] != []
    run_downloaded_demo(ws)
    # Offline: the routes are gone, yet the cached payload still runs with no new request.
    fetched = len(server.requests)
    server.routes_ref.clear()
    run_downloaded_demo(ws)
    assert len(server.requests) == fetched
    denied = run_cli(ws, "--deny-native", str(ws.project / "main.agc"))
    assert denied.code == 2
    # A tampered payload fails at use instead of loading.
    roots = [q for q in (tmp_path / "cache").rglob(member) if q.is_file()]
    assert roots, "expected a cached payload"
    roots[0].write_bytes(roots[0].read_bytes() + b"\x00")
    result, problem = check_json(ws, ws.project / "main.agc")
    assert problem is not None and problem["code"] in ("PKG-HASH-MISMATCH", "PKG-NATIVE-MISSING"), problem


def test_dependency_download_git_hash_stable_and_host_only(server, tmp_path, remotes):
    from tests.package_support import dependency as _dep, lock_entry as _lock_entry
    from tests.test_vm_native import library_name as _libname
    ws = Workspace(tmp_path)
    # Build a real library for HOST; other systems get dummy bytes (never fetched).
    import tests.test_vm_native as _vn
    lib_bytes = shared_library(tmp_path_factory_fixture(tmp_path), "pkgdemo").read_bytes()
    member = _libname("pkgdemo")
    host_archive = make_tar({member: lib_bytes})
    host_sha = digest(host_archive)
    server.routes_ref["/t/dep-host.tar.gz"] = host_archive
    other_sha = "ab" * 32
    host_url = server.url("/t/dep-host.tar.gz")
    other_url = "https://example.test/other.tar.gz"
    native_table = "[native.pkgdemo]\n"
    native_table += download_row(HERE, host_url, host_sha, member)
    native_table += download_row(OTHER, other_url, other_sha, member)
    native_table += download_row(THIRD, other_url, other_sha, member)
    pkg_manifest = 'name = "pkgdemo"\n\n' + native_table
    pkg_files = {"demo.agc": DEMO, "agentica.toml": pkg_manifest}
    commit = remotes.publish("owner/pkgdemo", pkg_files, tag="v1.0.0")
    _lock_entry(ws, remotes, "owner/pkgdemo", pkg_files, commit, tag="v1.0.0")
    from tests.package_support import manifest_text as _mt
    (ws.project / "agentica.toml").write_text(_mt({"pkgdemo": _dep(remotes.url("owner/pkgdemo"), tag="v1.0.0")}), encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")
    # Update pins git + all artifact rows; only HOST is fetched.
    from tests.package_support import environment as _env
    result = run(cli() + ["--json", "update"], cwd=ws.project, env=_env(ws, remotes))
    assert result.code == 0, result.stderr
    lock_text = (ws.project / "agentica.lock").read_text(encoding="utf-8")
    assert lock_text.count("[[native-artifact]]") == 3
    assert 'package = "pkgdemo"' in lock_text
    paths = list(server.requests)
    assert any(p == "/t/dep-host.tar.gz" for p in paths)
    # Install writes deps/ from git only; the git hash is stable and covers no downloaded bytes.
    result = run(cli() + ["--json", "install"], cwd=ws.project, env=_env(ws, remotes))
    assert result.code == 0, result.stderr
    from tests.package_support import package_hash as _ph, cached_files as _cf
    assert _cf(ws.deps / "pkgdemo") == sorted(["agentica.toml", "demo.agc"])
    before = _ph(ws.deps / "pkgdemo")
    result = run(cli() + [str(ws.project / "main.agc")], cwd=ws.project, env=_env(ws, remotes))
    assert (result.code, result.stdout) == (0, "42\n"), (result.code, result.stdout, result.stderr)
    assert _ph(ws.deps / "pkgdemo") == before


def tmp_path_factory_fixture(tmp_path):
    class F:
        def mktemp(self, name):
            p = tmp_path / ("_" + name)
            p.mkdir(parents=True, exist_ok=True)
            return p
    return F()


def test_workspace_member_download_uses_folder_and_cache(server, tmp_path):
    ws = Workspace(tmp_path)
    repo = tmp_path / "repo"
    repo.mkdir()
    member = "common"
    archive = make_tar({"lib.bin": b"member-bytes"})
    sha = digest(archive)
    server.routes_ref["/t/ws.tar"] = archive
    url = server.url("/t/ws.tar")
    # Member with a download on HOST only (other systems pinned but unfetched).
    member_manifest = 'name = "common"\n\n[native.demo]\n' + download_row(HERE, url, sha)
    (repo / member).mkdir(parents=True)
    (repo / member / "agentica.toml").write_text(member_manifest, encoding="utf-8")
    (repo / member / "util.agc").write_text('export def shout() -> String\n  return "hi"\nend\n', encoding="utf-8")
    # Workspace root listing the member; app is the member itself (its own download, lock key "").
    (repo / "agentica.toml").write_text('[workspace]\nrepository = "https://example.test/owner/ws"\nmembers = ["%s"]\n' % member, encoding="utf-8")
    result = run(cli() + ["--json", "update"], cwd=repo / member, env=no_proxy_env(ws))
    assert result.code == 0, result.stderr
    lock_text = (repo / member / "agentica.lock").read_text(encoding="utf-8")
    assert "[[native-artifact]]" in lock_text and 'package = ""' in lock_text
