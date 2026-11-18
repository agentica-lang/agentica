"""The download of prebuilt native modules (`[native.NAME] prebuilt`, docs/grammar/05b-modules.md) by `install`, `add`
and `update`, through the CLI.

Hermetic: the peer is a plain HTTP server of the standard library on 127.0.0.1, port 0 (the loopback http the URL rules
allow), which serves the file, a wrong file, a 404, redirects and bodies over the 64 MiB cap; a package comes from a
bare git repository behind a throwaway HOME (tests/package_support.py). The bytes
of a prebuilt file are never loaded here, so any bytes do, and no C compiler runs: the module is optional and CC names
no program, so the build that `install` tries for the project is a PKG-NATIVE-UNBUILT warning, left out of what the
cases read. Cases assert codes and key paths, never message text.
"""
import hashlib
import json
import os
import platform
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from tests.agentica_test import TARGET_OS, WINDOWS, cli, run
from tests.package_support import (assert_at_key, environment, git, inline_table, dependency,  # noqa: F401
                                    remotes, ws)

ADDER_C = "int adder_value(void) { return 42; }\n"
BODY = b"prebuilt adder bytes\n"
SHA = hashlib.sha256(BODY).hexdigest()
TARGETS = ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64", "windows-x86_64"]
LIBRARY = "library.dll" if WINDOWS else "library.dylib" if TARGET_OS == "darwin" else "library.so"
OVER_CAP = 64 * 1024 * 1024 + 1
BUILD = 'build = { sources = ["native/adder.c"] }\noptional = true\n'
KEY = "native.adder.prebuilt"


class Peer:
    """Answers by the first part of the path: /ok/ the file, /wrong/ other bytes, /missing/ a 404, /hop/ a redirect to
    /ok/ on this host, /away/ a redirect to https://localhost on this port (another host, which the rules of a URL
    allow: only the list of redirect hosts refuses it, and a client that went would open a second connection), /big/
    a body over the cap with its length, /chunked/ one in chunks. `connections` counts the connections the peer
    accepted."""

    def __init__(self):
        self.requests = []
        self.connections = 0
        self.body = BODY
        peer = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):
                peer.requests.append(self.path)
                kind, _, rest = self.path.lstrip("/").partition("/")
                if kind in ("hop", "away"):
                    origin = "http://127.0.0.1" if kind == "hop" else "https://localhost"
                    self.send_response(302)
                    self.send_header("Location", "%s:%d/ok/%s" % (origin, peer.port, rest))
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                elif kind == "chunked":
                    self.send_response(200)
                    self.send_header("Transfer-Encoding", "chunked")
                    self.end_headers()
                    piece = b"x" * 65536
                    try:
                        for _ in range(OVER_CAP // len(piece) + 1):
                            self.wfile.write(b"%x\r\n%s\r\n" % (len(piece), piece))
                        self.wfile.write(b"0\r\n\r\n")
                    except OSError:
                        pass
                elif kind == "big":
                    self.send_response(200)
                    self.send_header("Content-Length", str(OVER_CAP))
                    self.end_headers()
                    try:
                        for _ in range(OVER_CAP // 65536 + 1):
                            self.wfile.write(b"x" * 65536)
                    except OSError:
                        pass
                elif kind in ("ok", "wrong"):
                    body = peer.body if kind == "ok" else b"other bytes\n"
                    self.send_response(200)
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                else:
                    self.send_response(404)
                    self.send_header("Content-Length", "0")
                    self.end_headers()

            def log_message(self, *args):
                pass

        class Server(ThreadingHTTPServer):
            def verify_request(self, request, client_address):
                peer.connections += 1
                return True

        self.httpd = Server(("127.0.0.1", 0), Handler)
        self.httpd.daemon_threads = True
        self.port = self.httpd.server_address[1]
        self.thread = threading.Thread(target=self.httpd.serve_forever, daemon=True)
        self.thread.start()

    def url(self, kind):
        return "http://127.0.0.1:%d/%s/lib{name}-{api}-{target}{ext}" % (self.port, kind)

    def stop(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        self.thread.join()


@pytest.fixture()
def peer():
    served = Peer()
    yield served
    served.stop()


def agentica(ws, remotes, *words):
    return run(cli() + list(words), cwd=ws.project, env=environment(ws, remotes, CC=str(ws.base / "no-cc")))


def native_source(folder, ws, remotes, name="adder"):
    """The source key and native API that `agentica native source NAME` prints in `folder`."""
    result = run(cli() + ["--json", "native", "source", name], cwd=folder, env=environment(ws, remotes))
    assert (result.code, result.stderr) == (0, ""), result.stderr
    answer = json.loads(result.stdout)
    return answer["source"], answer["api"]


def prebuilt(kind, peer, source, api, sha=SHA):
    digests = ", ".join('%s = "%s"' % (target, sha) for target in TARGETS)
    return 'prebuilt = { url = "%s", source = "%s", api = "%s", sha256 = { %s } }\n' % (
        peer.url(kind), source, api, digests)


def project(ws, remotes, peer, kind, extra=""):
    """The project with the module adder, whose prebuilt table names the files of `kind` on the peer."""
    (ws.project / "native").mkdir(exist_ok=True)
    (ws.project / "native" / "adder.c").write_text(ADDER_C, encoding="utf-8")
    manifest = ws.project / "agentica.toml"
    manifest.write_text('name = "adder"\n\n[native.adder]\n' + BUILD, encoding="utf-8")
    source, api = native_source(ws.project, ws, remotes)
    manifest.write_text('name = "adder"\n\n[native.adder]\n%s%s%s' % (BUILD, prebuilt(kind, peer, source, api), extra),
                        encoding="utf-8")
    return manifest


def entry(ws, sha=SHA):
    return ws.pkg_root / "native-prebuilt" / sha


def leftovers(ws):
    """What the prebuilt cache holds besides finished entries (temporary folders of a failed download)."""
    base = ws.pkg_root / "native-prebuilt"
    return [name for name in os.listdir(base) if name.startswith(".")] if base.exists() else []


def target_of(path):
    """The target that the file name of a requested path names."""
    stem = path.rsplit("/", 1)[1].rsplit(".", 1)[0]
    return next(target for target in TARGETS if stem.endswith("-" + target))


def problems(result):
    """The JSON problems on stderr, but the warning of the build that no compiler can make."""
    found = [json.loads(line) for line in result.stderr.splitlines() if line.strip()]
    return [problem for problem in found if problem["code"] != "PKG-NATIVE-UNBUILT"]


def problem(result):
    found = problems(result)
    assert len(found) == 1, result.stderr
    return found[0]


def assert_fetched(ws, peer):
    assert (entry(ws) / LIBRARY).read_bytes() == BODY
    assert (entry(ws) / "receipt").read_text(encoding="utf-8").strip() == SHA
    assert peer.requests and all(path.endswith(LIBRARY[LIBRARY.index("."):]) for path in peer.requests)


def test_install_fetches_the_file_of_this_target_once(ws, remotes, peer):
    project(ws, remotes, peer, "ok")
    result = agentica(ws, remotes, "--json", "install")
    assert (result.code, result.stdout, problems(result)) == (0, '{"ok":true}\n', []), result.stderr
    assert_fetched(ws, peer)
    assert len(peer.requests) == 1
    assert target_of(peer.requests[0]) == python_target()
    plain = agentica(ws, remotes, "install")
    assert plain.code == 0 and len(peer.requests) == 1, plain.stderr
    assert plain.stdout.count("adder") == 1


def python_target():
    """The release target of this machine as Python sees it, which must be the binary's."""
    system = "windows" if WINDOWS else "macos" if sys.platform == "darwin" else "linux"
    arch = {"amd64": "x86_64", "x86_64": "x86_64", "arm64": "arm64", "aarch64": "arm64"}[platform.machine().lower()]
    return system + "-" + arch


def test_two_modules_that_name_one_file_share_its_entry(ws, remotes, peer):
    (ws.project / "native").mkdir()
    (ws.project / "native" / "other.c").write_text("int other_value(void) { return 7; }\n", encoding="utf-8")
    manifest = project(ws, remotes, peer, "ok", '\n[native.other]\n%s' % BUILD.replace("adder", "other"))
    source, api = native_source(ws.project, ws, remotes, "other")
    manifest.write_text(manifest.read_text(encoding="utf-8") + prebuilt("ok", peer, source, api), encoding="utf-8")
    result = agentica(ws, remotes, "--json", "install")
    assert (result.code, problems(result)) == (0, []), result.stderr
    assert_fetched(ws, peer)
    assert len(peer.requests) == 1


def plant(ws, state):
    """A cache that holds the file of SHA, private to the user but for the one defect of `state`."""
    base = ws.pkg_root / "native-prebuilt"
    real = ws.base / "elsewhere"
    real.mkdir(mode=0o700)
    if state == "linked folder":
        base.parent.mkdir(parents=True, exist_ok=True)
        os.symlink(real, base, target_is_directory=True)
        base = real
    else:
        base.mkdir(mode=0o700, parents=True)
    folder = real / SHA if state == "linked entry" else base / SHA
    folder.mkdir(mode=0o700)
    if state == "linked entry":
        os.symlink(folder, base / SHA, target_is_directory=True)
    if state == "incomplete":
        return
    (folder / "receipt").write_text(SHA, encoding="utf-8")
    if state == "linked library":
        (real / "lib").write_bytes(BODY)
        os.symlink(real / "lib", folder / LIBRARY)
    else:
        (folder / LIBRARY).write_bytes(BODY)


PLANTED = ["linked folder", "linked entry", "linked library", "incomplete"]


@pytest.mark.skipif(WINDOWS, reason="host-only: a symbolic link needs a privilege on Windows")
def test_each_planted_cache_state_is_pkg_native_build(tmp_path, remotes, peer):
    from tests.package_support import Workspace
    checked = []
    for state in PLANTED:
        ws = Workspace(tmp_path / state.replace(" ", "-"))
        manifest = project(ws, remotes, peer, "ok")
        plant(ws, state)
        result = agentica(ws, remotes, "--json", "install")
        assert result.code == 1, (state, result.stderr)
        assert_at_key(problem(result), "PKG-NATIVE-BUILD", manifest, KEY)
        checked.append(state)
    assert checked == PLANTED and peer.requests == []


@pytest.mark.parametrize("change", ["no row", "newer api", "changed sources"])
def test_a_prebuilt_only_module_with_no_file_says_its_first_use_fails(ws, remotes, peer, change):
    manifest = project(ws, remotes, peer, "ok", '\n[native_policy]\nprebuilt_only = ["adder"]\n')
    text = manifest.read_text(encoding="utf-8")
    if change == "no row":
        rows = text.split("sha256 = { ")[1].split(" }")[0]
        text = text.replace(rows, ", ".join(row for row in rows.split(", ") if python_target() not in row))
    elif change == "newer api":
        _, api = native_source(ws.project, ws, remotes)
        major, minor = api.split(".")
        text = text.replace('api = "%s"' % api, 'api = "%s.%d"' % (major, int(minor) + 1))
    else:
        (ws.project / "native" / "adder.c").write_text(ADDER_C + "int more(void) { return 1; }\n", encoding="utf-8")
    manifest.write_text(text, encoding="utf-8")
    result = agentica(ws, remotes, "install")
    assert result.code == 0, result.stderr
    assert [line for line in result.stdout.splitlines() if "adder" in line and "prebuilt-only" in line] != []
    assert peer.requests == []


# The outcome of each kind of file on the peer: the code and key path of the failure (an error, or with `warned` a
# warning after which the command succeeds), or None when the file is fetched.
OUTCOMES = [
    ("ok", None, "", False),
    ("hop", None, "", False),
    ("wrong", "PKG-HASH-MISMATCH", KEY + ".sha256.", False),
    ("missing", "PKG-FETCH", KEY + ".url", True),
    ("away", "PKG-FETCH", KEY + ".url", True),
    ("big", "PKG-FETCH", KEY + ".url", True),
    ("chunked", "PKG-FETCH", KEY + ".url", True),
]


def test_each_answer_of_the_peer_fetches_warns_or_fails_at_its_key(tmp_path, remotes, peer):
    from tests.package_support import Workspace
    checked = []
    for kind, code, key, warned in OUTCOMES:
        ws = Workspace(tmp_path / kind)
        manifest = project(ws, remotes, peer, kind)
        before, opened = len(peer.requests), peer.connections
        result = agentica(ws, remotes, "--json", "install")
        asked = peer.requests[before:]
        if code is None:
            assert (result.code, problems(result)) == (0, []), (kind, result.stderr)
            assert (entry(ws) / LIBRARY).read_bytes() == BODY, kind
        else:
            assert result.code == (0 if warned else 1), (kind, result.stderr)
            found = problem(result)
            assert found.get("warning", False) == warned, (kind, result.stderr)
            assert_at_key(found, code, manifest, key + (target_of(asked[-1]) if key.endswith(".") else ""))
            assert not entry(ws).exists(), kind
        assert leftovers(ws) == [], kind
        assert len(asked) == (2 if kind == "hop" else 1), (kind, asked)
        if kind == "away":
            assert peer.connections - opened == 1
        checked.append(kind)
    assert checked == [kind for kind, *_ in OUTCOMES]


def test_a_prebuilt_only_module_fails_where_another_warns(ws, remotes, peer):
    manifest = project(ws, remotes, peer, "missing", '\n[native_policy]\nprebuilt_only = ["adder"]\n')
    result = agentica(ws, remotes, "--json", "install")
    assert result.code == 1, result.stderr
    assert_at_key(problem(result), "PKG-FETCH", manifest, KEY + ".url")


@pytest.mark.parametrize("flag", ["--deny-net", "--sandbox"])
def test_deny_net_and_sandbox_download_nothing(ws, remotes, peer, flag):
    manifest = project(ws, remotes, peer, "ok")
    result = agentica(ws, remotes, "--json", flag, "install")
    assert (result.code, problems(result)) == (0, []), result.stderr
    assert (peer.requests, peer.connections) == ([], 0) and not entry(ws).exists()
    manifest.write_text(manifest.read_text(encoding="utf-8") + '\n[native_policy]\nprebuilt_only = "all"\n',
                        encoding="utf-8")
    result = agentica(ws, remotes, "--json", flag, "install")
    assert result.code == 1, result.stderr
    assert_at_key(problem(result), "PKG-NATIVE-DENIED", manifest, KEY)
    assert (peer.requests, peer.connections) == ([], 0)
    # A file in the cache needs no download, so the flags let it be.
    assert agentica(ws, remotes, "--json", "install").code == 0
    result = agentica(ws, remotes, "--json", flag, "install")
    assert (result.code, problems(result)) == (0, []), result.stderr
    assert len(peer.requests) == 1


def test_a_module_that_builds_is_not_downloaded(ws, remotes, peer):
    manifest = project(ws, remotes, peer, "ok", '\n[native_policy]\nbuild = ["adder"]\n')
    assert agentica(ws, remotes, "--json", "install").code == 0
    assert peer.requests == []
    # Sources that no longer hash to the source key are other code: the files are not for them.
    manifest.write_text(manifest.read_text(encoding="utf-8").split("\n[native_policy]")[0], encoding="utf-8")
    (ws.project / "native" / "adder.c").write_text(ADDER_C + "int more(void) { return 1; }\n", encoding="utf-8")
    assert agentica(ws, remotes, "--json", "install").code == 0
    assert peer.requests == [] and not entry(ws).exists()


def test_files_for_a_newer_native_api_are_not_downloaded(ws, remotes, peer):
    manifest = project(ws, remotes, peer, "ok")
    text = manifest.read_text(encoding="utf-8")
    _, api = native_source(ws.project, ws, remotes)
    major, minor = api.split(".")
    manifest.write_text(text.replace('api = "%s"' % api, 'api = "%s.%d"' % (major, int(minor) + 1)), encoding="utf-8")
    assert agentica(ws, remotes, "--json", "install").code == 0
    assert peer.requests == []


def test_a_cache_entry_that_changed_is_pkg_native_build(ws, remotes, peer):
    manifest = project(ws, remotes, peer, "ok")
    assert agentica(ws, remotes, "--json", "install").code == 0
    (entry(ws) / LIBRARY).write_bytes(b"changed")
    result = agentica(ws, remotes, "--json", "install")
    assert result.code == 1, result.stderr
    assert_at_key(problem(result), "PKG-NATIVE-BUILD", manifest, KEY)
    assert len(peer.requests) == 1


@pytest.mark.skipif(WINDOWS, reason="host-only: Windows has no file modes")
def test_a_cache_entry_others_can_write_is_pkg_native_build(ws, remotes, peer):
    manifest = project(ws, remotes, peer, "ok")
    assert agentica(ws, remotes, "--json", "install").code == 0
    os.chmod(entry(ws), 0o777)
    result = agentica(ws, remotes, "--json", "install")
    assert result.code == 1, result.stderr
    assert_at_key(problem(result), "PKG-NATIVE-BUILD", manifest, KEY)


ADDER = "owner/adder"


def publish_adder(ws, remotes, peer, kind, workspace=False):
    """The package adder with the module adder and its prebuilt table, or, with `workspace`, a workspace repository
    whose one member `adder` is that package."""
    scratch = ws.base / "author"
    (scratch / "native").mkdir(parents=True)
    (scratch / "native" / "adder.c").write_text(ADDER_C, encoding="utf-8")
    (scratch / "agentica.toml").write_text('name = "adder"\n\n[native.adder]\n' + BUILD, encoding="utf-8")
    source, api = native_source(scratch, ws, remotes)
    manifest = 'name = "adder"\n\n[native.adder]\n%s%s' % (BUILD, prebuilt(kind, peer, source, api))
    files = {"agentica.toml": manifest, "native/adder.c": ADDER_C, "adder.agc": "def one() -> Int = 1\n"}
    if workspace:
        table = '[workspace]\nrepository = "%s"\nmembers = ["adder"]\n' % remotes.url(ADDER)
        files = {"agentica.toml": table, **{"adder/" + path: text for path, text in files.items()}}
    remotes.publish(ADDER, files, tag="v1")


def test_add_and_update_fetch_the_files_of_a_fetched_package(ws, remotes, peer):
    publish_adder(ws, remotes, peer, "ok")
    (ws.project / "agentica.toml").write_text('name = "app"\n', encoding="utf-8")
    result = agentica(ws, remotes, "--json", "add", "adder", remotes.url(ADDER), "--tag", "v1")
    assert (result.code, problems(result)) == (0, []), result.stderr
    assert_fetched(ws, peer)
    assert len(peer.requests) == 1
    os.remove(entry(ws) / LIBRARY)
    os.remove(entry(ws) / "receipt")
    os.rmdir(entry(ws))
    result = agentica(ws, remotes, "--json", "update")
    assert (result.code, problems(result)) == (0, []), result.stderr
    assert_fetched(ws, peer)
    assert len(peer.requests) == 2


def test_a_prebuilt_module_of_a_workspace_member_is_fetched_through_the_workspace_dependency(ws, remotes, peer):
    publish_adder(ws, remotes, peer, "ok", workspace=True)
    (ws.project / "agentica.toml").write_text(
        'name = "app"\n\n[dependencies]\nsuite = { git = "%s", tag = "v1", workspace = true }\n' % remotes.url(ADDER),
        encoding="utf-8")
    result = agentica(ws, remotes, "--json", "update")
    assert (result.code, problems(result)) == (0, []), result.stderr
    assert_fetched(ws, peer)
    assert len(peer.requests) == 1
    # The lock names the member `suite/adder`, and install finds the file in the prebuilt cache.
    assert 'name = "suite/adder"' in (ws.project / "agentica.lock").read_text(encoding="utf-8")
    result = agentica(ws, remotes, "--json", "install")
    assert (result.code, problems(result)) == (0, []), result.stderr
    assert len(peer.requests) == 1


def test_a_wrong_file_of_a_package_writes_no_lock(ws, remotes, peer):
    publish_adder(ws, remotes, peer, "wrong")
    manifest = ws.project / "agentica.toml"
    manifest.write_text('name = "app"\n\n[dependencies]\nadder = %s\n'
                        % inline_table(dependency(remotes.url(ADDER), tag="v1")), encoding="utf-8")
    result = agentica(ws, remotes, "--json", "update")
    assert result.code == 1, result.stderr
    found = problem(result)
    assert found["code"] == "PKG-HASH-MISMATCH"
    assert found["key_path"] == KEY + ".sha256." + target_of(peer.requests[-1])
    assert found["file"].endswith("agentica.toml") and not (ws.project / "agentica.lock").exists()
