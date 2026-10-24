"""The internal native artifact download and member-cache engine (compiler/io/native_artifact.agc over
compiler/packages/native_artifact.agc), through the CLI with a driver that imports the tracked engine.

The peer is tests/fixtures/native-artifact-peer.py (plain HTTP and TLS on 127.0.0.1, port 0, only the
standard library); the archives it serves are read back with urllib and hashlib/tarfile as the
independent implementation. A second implementation of the engine in Python is never used: every
case runs the tracked .agc engine through the product CLI. Cases assert the exact PKG- code and the
file and key path, never message text (AGENTS.md), plus the expected bytes (hashlib) where files
land. No external network, no new dependencies.
"""
import concurrent.futures
import glob
import hashlib
import io
import json
import os
import tarfile
import urllib.request

import pytest

from tests.agentica_test import FIXTURES, PYTHON, Child, compile_agc, output_lines, run_vm, vm_environment

PEER = FIXTURES / "native-artifact-peer.py"
DRIVER = FIXTURES / "native-artifact" / "driver.agc"
CA = FIXTURES / "tls" / "ca.pem"

FILE = "project/agentica.toml"
KEY = "native.demo"
TIMEOUT = "20000"
MEMBER = "lib.bin"


def fetch_bytes(url):
    """The served bytes, read with the standard library as the independent peer implementation."""
    with urllib.request.urlopen(url, timeout=30) as response:
        return response.read()


def member_bytes(archive, member):
    """The member of a TAR read with tarfile, the independent archive implementation."""
    with tarfile.open(fileobj=io.BytesIO(archive), mode="r") as tar:
        return tar.extractfile(member).read()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def parse(line):
    """("ok", path) or ("err", code, file, key) for one driver line."""
    assert line.startswith("OK ") or line.startswith("ERR "), line
    if line.startswith("OK "):
        return ("ok", line[3:])
    rest = line[4:].split(" file=", 1)
    code = rest[0]
    file, _, key = rest[1].partition(" key=")
    return ("err", code, file, key)


@pytest.fixture(scope="module")
def setup(tmp_path_factory):
    """The peer, its ports, the served bytes and the compiled driver; the peer stops at the end."""
    directory = tmp_path_factory.mktemp("native-artifact")
    log = directory / "requests.log"
    peer = Child([PYTHON, str(PEER), str(log)], stdin=True)
    try:
        ports = json.loads(peer.next_line())
    except Exception:
        peer.stop()
        raise
    plain = "http://127.0.0.1:%d" % ports["plain"]
    bytecode = compile_agc(str(DRIVER), str(directory / "driver.agcb"))
    yield {
        "peer": peer,
        "log": log,
        "plain": plain,
        "tls": "https://127.0.0.1:%d" % ports["tls"],
        "self": "https://127.0.0.1:%d" % ports["self"],
        "bytecode": bytecode,
        "lib_tar": fetch_bytes(plain + "/t/lib.tar"),
        "lib_tgz": fetch_bytes(plain + "/g/lib.tar.gz"),
    }
    peer.stop()


def log_pos(setup):
    """The current end of the peer request log."""
    with open(setup["log"], encoding="utf-8") as handle:
        handle.seek(0, 2)
        return handle.tell()


def requests_since(setup, mark):
    """The peer request paths since mark (the log length); proves a case used no network."""
    with open(setup["log"], encoding="utf-8") as handle:
        handle.seek(mark)
        return [line.rstrip("\n") for line in handle]


@pytest.fixture()
def mark(setup):
    return log_pos(setup)


def engine(setup, args, env_extra=None, timeout=120):
    """One driver run; the single output line, with the VM's trust store as given."""
    result = run_vm(setup["bytecode"], args=args, env=vm_environment(env_extra), timeout=timeout)
    assert result.code == 0, result.stderr
    lines = output_lines(result.stdout)
    assert len(lines) == 1, lines
    return parse(lines[0])


def tls_env():
    """The test CA as the only trust root, so the engine verifies the peer's TLS chain."""
    return {"SSL_CERT_FILE": str(CA)}


def cache(directory):
    """A fresh cache root at directory (a distinct subfolder per call)."""
    directory.mkdir(parents=True)
    return str(directory)


def fetch(setup, cache_root, url, sha, member=MEMBER, timeout=TIMEOUT, key=KEY):
    return engine(setup, ["fetch", cache_root, FILE, key, url, sha, member, timeout])


def cached(setup, cache_root, sha, member=MEMBER, timeout=TIMEOUT, key=KEY):
    return engine(setup, ["cached", cache_root, FILE, key, sha, member, timeout])


def layout(setup, cache_root, sha, member=MEMBER):
    result = run_vm(setup["bytecode"], args=["layout", cache_root, sha, member], env=vm_environment())
    assert result.code == 0, result.stderr
    lines = output_lines(result.stdout)
    assert len(lines) == 4, lines
    return lines


def pure(setup, *args):
    result = run_vm(setup["bytecode"], args=list(args), env=vm_environment())
    assert result.code == 0, result.stderr
    return output_lines(result.stdout)


# The pure data rules: no network, no cache.

def test_limits_are_the_contract(setup):
    assert pure(setup, "limits") == ["5", "268435456", "268435456", "1024", "64"]


def test_canonical_member_strips_one_dot_slash(setup):
    assert pure(setup, "canonical", "./lib.bin") == ["OK lib.bin"]
    assert pure(setup, "canonical", "lib.bin") == ["OK lib.bin"]
    assert pure(setup, "canonical", "sub/deep.bin") == ["OK sub/deep.bin"]


def test_canonical_member_rejects_unsafe_paths(setup):
    for bad in ["", ".", "./", "/abs.bin", "a/../b.bin", "a/./b.bin", "a//b.bin", "..", "../x",
                "a\\b.bin", "a:b.bin", "C:/x.bin", "a/../../b.bin"]:
        assert pure(setup, "canonical", bad)[0].startswith("ERR "), bad
    assert pure(setup, "nul") == ["ERR rejected"]
    assert pure(setup, "canonical", "a" * 1024) == ["OK " + "a" * 1024]
    assert pure(setup, "canonical", "a" * 1025)[0].startswith("ERR ")


def test_member_digest_is_sha256_of_canonical_bytes(setup):
    assert pure(setup, "digest", "lib.bin") == [digest(b"lib.bin")]
    assert pure(setup, "digest", "lib.bin") != pure(setup, "digest", "sub/deep.bin")


def test_valid_sha_needs_64_lower_hex(setup):
    good = "ab" * 32
    assert pure(setup, "validsha", good) == ["true"]
    assert pure(setup, "validsha", good[:63]) == ["false"]
    assert pure(setup, "validsha", good + "0") == ["false"]
    assert pure(setup, "validsha", good.upper()) == ["false"]
    assert pure(setup, "validsha", "zz" + good[2:]) == ["false"]


def test_allowed_urls_are_https_or_loopback_http(setup):
    assert pure(setup, "allowed", "https://example.com/x.tar.gz") == ["true"]
    assert pure(setup, "allowed", "http://127.0.0.1:9/x") == ["true"]
    assert pure(setup, "allowed", "http://[::1]:9/x") == ["true"]
    assert pure(setup, "allowed", "https://example.com:443/x") == ["true"]
    for bad in ["http://example.com/x", "http://localhost:9/x", "ftp://h/x", "https://u@example.com/x",
                "https://example.com/x#f", "file:///x", "https://", "http://127.0.0.1:0/x@y",
                "https://example.com:/x", "https://[::1]:/x", "http://127.0.0.1:/x"]:
        assert pure(setup, "allowed", bad) == ["false"], bad


def test_resolve_location_forms(setup):
    base = "http://127.0.0.1:9/r-rel"
    assert pure(setup, "resolve", base, "t/lib.tar") == ["OK http://127.0.0.1:9/t/lib.tar"]
    assert pure(setup, "resolve", base, "/t/lib.tar") == ["OK http://127.0.0.1:9/t/lib.tar"]
    full = "http://127.0.0.1:9/t/lib.tar"
    assert pure(setup, "resolve", base, full) == ["OK " + full]
    assert pure(setup, "resolve", base, "/t/lib.tar?token=s") == ["OK http://127.0.0.1:9/t/lib.tar?token=s"]
    assert pure(setup, "resolve", base, "./sub/../t/lib.tar") == ["OK http://127.0.0.1:9/t/lib.tar"]
    assert pure(setup, "resolve", base, "/t/lib.tar#frag") == ["OK http://127.0.0.1:9/t/lib.tar"]
    assert pure(setup, "resolve", base, "//127.0.0.1:9/t/lib.tar") == ["OK http://127.0.0.1:9/t/lib.tar"]
    assert pure(setup, "resolve", base, "//example.com/t/lib.tar") == ["OK http://example.com/t/lib.tar"]
    assert pure(setup, "resolve", base, "//127.0.0.1:9/t?token=s") == ["OK http://127.0.0.1:9/t?token=s"]
    assert pure(setup, "resolve", "https://h:9/a", "//h2:8/b") == ["OK https://h2:8/b"]
    assert pure(setup, "resolve", base, "../../t") == ["ERR rejected"]
    assert pure(setup, "resolve", base, "") == ["ERR rejected"]
    assert pure(setup, "resolve", base, "ftp://h/x") == ["ERR rejected"]


def test_downgrade_is_https_to_http_only(setup):
    assert pure(setup, "downgrade", "https://h/a", "http://127.0.0.1:9/b") == ["true"]
    assert pure(setup, "downgrade", "http://127.0.0.1:9/a", "http://127.0.0.1:9/b") == ["false"]
    assert pure(setup, "downgrade", "https://h/a", "https://h/b") == ["false"]
    assert pure(setup, "downgrade", "http://127.0.0.1:9/a", "https://h/b") == ["false"]
    for status in ["301", "302", "303", "307", "308"]:
        assert pure(setup, "redirect", status) == ["true"], status
    for status in ["200", "300", "304", "404", "500"]:
        assert pure(setup, "redirect", status) == ["false"], status


def test_hop_budget_counts_every_byte(setup):
    assert pure(setup, "budget", "9", "10") == ["OK 1"]
    assert pure(setup, "budget", "0", "10") == ["OK 10"]
    assert pure(setup, "budget", "10", "10") == ["ERR spent"]
    assert pure(setup, "budget", "11", "10") == ["ERR spent"]
    assert pure(setup, "budget", "-1", "10") == ["ERR spent"]
    assert pure(setup, "budget", "0", "0") == ["ERR spent"]


def test_layout_is_sha_then_member_digest(setup, tmp_path):
    sha = digest(setup["lib_tar"])
    archive, member, payload, receipt = layout(setup, str(tmp_path), sha, MEMBER)
    assert archive == "%s/native/%s/archive" % (tmp_path, sha)
    want = digest(MEMBER.encode())
    assert member == "%s/native/%s/m/%s" % (tmp_path, sha, want)
    assert payload == "%s/payload/%s" % (member, MEMBER)
    assert receipt == "%s/receipt" % member


# Validation before any network use: the peer sees nothing.

def test_bad_sha_fails_before_network(setup, tmp_path, mark):
    root = cache(tmp_path / "c0")
    url = setup["plain"] + "/t/lib.tar"
    assert fetch(setup, root, url, "AB" * 32) == ("err", "PKG-HASH-MISMATCH", FILE, KEY + ".sha256")
    assert fetch(setup, root, url, "ab" * 31) == ("err", "PKG-HASH-MISMATCH", FILE, KEY + ".sha256")
    assert requests_since(setup, mark) == []


def test_bad_member_fails_before_network(setup, tmp_path, mark):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    url = setup["plain"] + "/t/lib.tar"
    assert fetch(setup, root, url, sha, "../evil") == ("err", "PKG-FETCH", FILE, KEY + ".member")
    assert fetch(setup, root, url, sha, "/abs.bin") == ("err", "PKG-FETCH", FILE, KEY + ".member")
    assert requests_since(setup, mark) == []


def test_bad_url_fails_before_network(setup, tmp_path, mark):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    for bad in ["ftp://example.com/x.tar", "http://example.com/x.tar", "https://u@h/x", "https://h/x#f"]:
        assert fetch(setup, root, bad, sha) == ("err", "PKG-FETCH", FILE, KEY + ".url"), bad
    assert fetch(setup, root, setup["plain"] + "/t/lib.tar", sha, timeout="0") == (
        "err", "PKG-FETCH", FILE, KEY)
    assert fetch(setup, "", setup["plain"] + "/t/lib.tar", sha) == ("err", "PKG-FETCH", FILE, KEY)
    assert requests_since(setup, mark) == []


# Download, verify, publish.

def test_fetch_downloads_hashes_and_extracts(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    status, path = fetch(setup, root, setup["plain"] + "/t/lib.tar", sha)
    assert status == "ok"
    assert open(path, "rb").read() == member_bytes(setup["lib_tar"], MEMBER)
    assert path == layout(setup, root, sha, MEMBER)[2]
    archive = layout(setup, root, sha, MEMBER)[0]
    assert open(archive, "rb").read() == setup["lib_tar"]
    receipt = layout(setup, root, sha, MEMBER)[3]
    expected = member_bytes(setup["lib_tar"], MEMBER)
    assert open(receipt, encoding="utf-8").read().strip() == digest(expected)
    assert b"\x00" in expected


def test_gzip_archive_and_dot_member_alias(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tgz"])
    first = fetch(setup, root, setup["plain"] + "/g/lib.tar.gz", sha, "./lib.bin")
    second = fetch(setup, root, setup["plain"] + "/g/lib.tar.gz", sha, "lib.bin")
    assert first[0] == "ok" and second[0] == "ok"
    assert first[1] == second[1]
    assert open(first[1], "rb").read() == member_bytes(setup["lib_tar"], MEMBER)


def test_zip_bytes_dispatch_by_magic_not_suffix(setup, tmp_path, mark):
    root = cache(tmp_path / "c0")
    served = fetch_bytes(setup["plain"] + "/t/sneaky.tar.gz")
    assert served[:4] == b"PK\x03\x04"
    # The .tar.gz suffix never decides: the ZIP magic routes to the ZIP extractor.
    status, path = fetch(setup, root, setup["plain"] + "/t/sneaky.tar.gz", digest(served), "zipped.bin")
    assert status == "ok"
    assert open(path, "rb").read() == b"zip-bytes"
    assert path == layout(setup, root, digest(served), "zipped.bin")[2]
    # A member the ZIP lacks is missing, not a corrupt TAR: the bytes parsed as ZIP.
    assert fetch(setup, root, setup["plain"] + "/t/sneaky.tar.gz", digest(served)) == (
        "err", "PKG-NATIVE-MISSING", FILE, KEY + ".member")
    assert requests_since(setup, mark) != []


def test_zip_member_reuses_cache_offline_and_corruption_is_a_hash_error(setup, tmp_path):
    root = cache(tmp_path / "c0")
    served = fetch_bytes(setup["plain"] + "/t/sneaky.tar.gz")
    sha = digest(served)
    path = warm(setup, root, setup["plain"] + "/t/sneaky.tar.gz", sha, "zipped.bin")
    assert open(path, "rb").read() == b"zip-bytes"
    pos = log_pos(setup)
    assert cached(setup, root, sha, "zipped.bin") == ("ok", layout(setup, root, sha, "zipped.bin")[2])
    assert requests_since(setup, pos) == []
    archive = layout(setup, root, sha, "zipped.bin")[0]
    with open(archive, "r+b") as handle:
        handle.seek(20)
        handle.write(b"\xff")
    assert cached(setup, root, sha, "absent.bin") == ("err", "PKG-HASH-MISMATCH", FILE, KEY + ".sha256")
    assert fetch(setup, root, closed_url(sha), sha, "absent.bin") == (
        "err", "PKG-HASH-MISMATCH", FILE, KEY + ".sha256")


def test_tar_under_zip_suffix_downloads(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tgz"])
    status, path = fetch(setup, root, setup["plain"] + "/g/lib.tar.gz?format=zip", sha)
    assert status == "ok"
    assert open(path, "rb").read() == member_bytes(setup["lib_tar"], MEMBER)


def test_plain_text_gzip_trailing_and_empty_are_archive_errors(setup, tmp_path):
    root = cache(tmp_path / "c0")
    for name in ["text", "empty.tar"]:
        served = fetch_bytes(setup["plain"] + "/t/" + name)
        assert fetch(setup, root, setup["plain"] + "/t/" + name, digest(served)) == (
            "err", "PKG-NATIVE-ARCHIVE", FILE, KEY + ".member"), name
    served = fetch_bytes(setup["plain"] + "/t/trailing.tar.gz")
    assert fetch(setup, root, setup["plain"] + "/t/trailing.tar.gz", digest(served)) == (
        "err", "PKG-NATIVE-ARCHIVE", FILE, KEY + ".member")


def test_wrong_sha_never_extracts(setup, tmp_path):
    root = cache(tmp_path / "c0")
    url = setup["plain"] + "/t/lib.tar"
    wrong = digest(b"something else entirely")
    assert fetch(setup, root, url, wrong) == ("err", "PKG-HASH-MISMATCH", FILE, KEY + ".sha256")
    assert not (tmp_path / "cache" / "native" / wrong).exists()


def test_corrupt_bytes_with_wrong_sha_are_a_hash_error(setup, tmp_path):
    root = cache(tmp_path / "c0")
    assert fetch(setup, root, setup["plain"] + "/t/text", digest(b"other")) == (
        "err", "PKG-HASH-MISMATCH", FILE, KEY + ".sha256")


def test_traversal_member_of_evil_archive_is_safe(setup, tmp_path):
    root = cache(tmp_path / "c0")
    served = fetch_bytes(setup["plain"] + "/t/evil.tar")
    sha = digest(served)
    status, path = fetch(setup, root, setup["plain"] + "/t/evil.tar", sha, "good.bin")
    assert status == "ok"
    assert open(path, "rb").read() == b"good-bytes"
    assert not (tmp_path / "evil").exists()
    assert not (tmp_path / "cache" / "evil").exists()


def test_selected_link_duplicate_late_and_missing_members(setup, tmp_path):
    root = cache(tmp_path / "c0")
    link = fetch_bytes(setup["plain"] + "/t/link.tar")
    assert fetch(setup, root, setup["plain"] + "/t/link.tar", digest(link), "link") == (
        "err", "PKG-NATIVE-ARCHIVE", FILE, KEY + ".member")
    status, path = fetch(setup, root, setup["plain"] + "/t/link.tar", digest(link), "lib.bin")
    assert status == "ok" and open(path, "rb").read() == b"real"
    dup = fetch_bytes(setup["plain"] + "/t/dup.tar")
    assert fetch(setup, root, setup["plain"] + "/t/dup.tar", digest(dup), "dup.bin") == (
        "err", "PKG-NATIVE-ARCHIVE", FILE, KEY + ".member")
    late = fetch_bytes(setup["plain"] + "/t/late.tar")
    assert fetch(setup, root, setup["plain"] + "/t/late.tar", digest(late), "late.bin") == (
        "err", "PKG-NATIVE-ARCHIVE", FILE, KEY + ".member")
    lib = setup["lib_tar"]
    assert fetch(setup, root, setup["plain"] + "/t/lib.tar", digest(lib), "absent.bin") == (
        "err", "PKG-NATIVE-MISSING", FILE, KEY + ".member")


# Redirects: the exact policy, then offline reuse.

def redirected_fetch(setup, root, route, sha, member=MEMBER, timeout=TIMEOUT, base=None):
    return fetch(setup, root, (base or setup["plain"]) + route, sha, member, timeout)


def test_redirect_forms_land_on_the_file(setup, tmp_path):
    sha = digest(setup["lib_tar"])
    for route in ["/r-rel", "/r-abs", "/r-full", "/r-query", "/r-dot"]:
        root = cache(tmp_path / ("hop%d" % abs(hash(route))))
        status, path = redirected_fetch(setup, root, route, sha)
        assert status == "ok", route
        assert open(path, "rb").read() == member_bytes(setup["lib_tar"], MEMBER), route


def test_signed_query_never_persists(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    assert redirected_fetch(setup, root, "/r-query", sha)[0] == "ok"
    for directory, _, files in os.walk(root):
        for name in files:
            data = open(os.path.join(directory, name), "rb").read()
            assert b"s3cr3t" not in data, name


def test_scheme_relative_redirect_keeps_current_scheme(setup, tmp_path):
    sha = digest(setup["lib_tar"])
    status, path = redirected_fetch(setup, cache(tmp_path / "scheme"), "/r-scheme", sha)
    assert status == "ok"
    assert open(path, "rb").read() == member_bytes(setup["lib_tar"], MEMBER)
    status, path = redirected_fetch(setup, cache(tmp_path / "schemeq"), "/r-schemeq", sha)
    assert status == "ok"
    assert open(path, "rb").read() == member_bytes(setup["lib_tar"], MEMBER)


def test_scheme_relative_external_redirect_fails_before_network(setup, tmp_path, mark):
    sha = digest(setup["lib_tar"])
    assert redirected_fetch(setup, cache(tmp_path / "ext"), "/r-ext", sha) == (
        "err", "PKG-FETCH", FILE, KEY + ".url")
    assert requests_since(setup, mark) == ["/r-ext"]


def test_redirect_loops_and_counts_fail(setup, tmp_path):
    sha = digest(setup["lib_tar"])
    assert redirected_fetch(setup, cache(tmp_path / "loop"), "/r-loop", sha) == (
        "err", "PKG-FETCH", FILE, KEY + ".url")
    assert redirected_fetch(setup, cache(tmp_path / "pair"), "/r-pair-a", sha) == (
        "err", "PKG-FETCH", FILE, KEY + ".url")
    root = cache(tmp_path / "chain5")
    assert redirected_fetch(setup, root, "/r-chain/5", sha)[0] == "ok"
    assert redirected_fetch(setup, cache(tmp_path / "chain6"), "/r-chain/6", sha) == (
        "err", "PKG-FETCH", FILE, KEY + ".url")


def test_redirect_without_exactly_one_location_fails(setup, tmp_path):
    sha = digest(setup["lib_tar"])
    assert redirected_fetch(setup, cache(tmp_path / "multi"), "/r-multi", sha) == (
        "err", "PKG-FETCH", FILE, KEY + ".url")
    assert redirected_fetch(setup, cache(tmp_path / "noloc"), "/r-noloc", sha) == (
        "err", "PKG-FETCH", FILE, KEY + ".url")
    assert redirected_fetch(setup, cache(tmp_path / "gone"), "/gone", sha) == (
        "err", "PKG-FETCH", FILE, KEY + ".url")


def test_https_download_verifies_and_redirects(setup, tmp_path):
    sha = digest(setup["lib_tgz"])
    root = cache(tmp_path / "direct")
    result = engine(setup, ["fetch", root, FILE, KEY, setup["tls"] + "/g/lib.tar.gz", sha, MEMBER, TIMEOUT],
                    env_extra=tls_env())
    assert result[0] == "ok"
    assert open(result[1], "rb").read() == member_bytes(setup["lib_tar"], MEMBER)
    plain_sha = digest(setup["lib_tar"])
    up = engine(setup, ["fetch", cache(tmp_path / "up"), FILE, KEY, setup["plain"] + "/r-up", plain_sha,
                        MEMBER, TIMEOUT], env_extra=tls_env())
    assert up[0] == "ok"
    assert open(up[1], "rb").read() == member_bytes(setup["lib_tar"], MEMBER)


def test_downgrade_and_untrusted_tls_fail(setup, tmp_path):
    sha = digest(setup["lib_tar"])
    down = engine(setup, ["fetch", cache(tmp_path / "down"), FILE, KEY,
                               setup["tls"] + "/r-down", sha, MEMBER, TIMEOUT], env_extra=tls_env())
    assert down == ("err", "PKG-FETCH", FILE, KEY + ".url")
    self_signed = fetch_bytes(setup["plain"] + "/t/lib.tar")
    untrusted = engine(setup, ["fetch", cache(tmp_path / "untrusted"), FILE, KEY,
                               setup["self"] + "/t/lib.tar", digest(self_signed), MEMBER, TIMEOUT],
                       env_extra=tls_env())
    assert untrusted == ("err", "PKG-FETCH", FILE, KEY + ".url")


# The cache: hits need no network, corruption is stable, races keep the winner.

def warm(setup, root, url, sha, member=MEMBER):
    result = fetch(setup, root, url, sha, member)
    assert result[0] == "ok", result
    return result[1]


def closed_url(sha):
    return "http://127.0.0.1:9/nothing-%s.tar" % sha[:8]


def test_hit_avoids_network_and_member2_reuses_archive(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    first = warm(setup, root, setup["plain"] + "/t/lib.tar", sha)
    pos = log_pos(setup)
    again = fetch(setup, root, closed_url(sha), sha)
    assert again == ("ok", first)
    second = fetch(setup, root, closed_url(sha), sha, "sub/deep.bin")
    assert second[0] == "ok"
    assert second[1] != first
    assert open(second[1], "rb").read() == b"deep-bytes"
    assert requests_since(setup, pos) == []


def test_cached_answers_offline_and_reports_missing(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    warm(setup, root, setup["plain"] + "/t/lib.tar", sha)
    pos = log_pos(setup)
    assert cached(setup, root, sha) == ("ok", layout(setup, root, sha, MEMBER)[2])
    assert cached(setup, root, sha, "sub/deep.bin")[0] == "ok"
    assert requests_since(setup, pos) == []
    other = cache(tmp_path / "c1")
    assert cached(setup, other, sha) == ("err", "PKG-NATIVE-MISSING", FILE, KEY + ".member")
    assert fetch(setup, other, closed_url(sha), sha) == ("err", "PKG-FETCH", FILE, KEY + ".url")


def test_corrupt_receipt_or_member_is_a_hash_error(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    path = warm(setup, root, setup["plain"] + "/t/lib.tar", sha)
    lines = layout(setup, root, sha, MEMBER)
    receipt, payload = lines[3], lines[2]
    assert payload == path
    with open(receipt, "w", encoding="utf-8") as handle:
        handle.write("00" * 32)
    assert fetch(setup, root, closed_url(sha), sha) == ("err", "PKG-HASH-MISMATCH", FILE, KEY + ".member")
    assert cached(setup, root, sha) == ("err", "PKG-HASH-MISMATCH", FILE, KEY + ".member")
    with open(receipt, "w", encoding="utf-8") as handle:
        handle.write(digest(member_bytes(setup["lib_tar"], MEMBER)))
    with open(payload, "ab") as handle:
        handle.write(b"\x00")
    assert fetch(setup, root, closed_url(sha), sha) == ("err", "PKG-HASH-MISMATCH", FILE, KEY + ".member")


def test_unused_archive_is_not_reverified_but_new_use_is(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    path = warm(setup, root, setup["plain"] + "/t/lib.tar", sha)
    archive = layout(setup, root, sha, MEMBER)[0]
    with open(archive, "r+b") as handle:
        handle.seek(100)
        handle.write(b"\xff")
    pos = log_pos(setup)
    assert fetch(setup, root, closed_url(sha), sha) == ("ok", path)
    assert requests_since(setup, pos) == []
    assert fetch(setup, root, closed_url(sha), sha, "sub/deep.bin") == (
        "err", "PKG-HASH-MISMATCH", FILE, KEY + ".sha256")


def test_concurrent_publishers_keep_the_winner(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    url = setup["plain"] + "/t/lib.tar"
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: fetch(setup, root, url, sha), range(8)))
    assert [result[0] for result in results] == ["ok"] * 8
    assert {result[1] for result in results} == {results[0][1]}
    assert open(results[0][1], "rb").read() == member_bytes(setup["lib_tar"], MEMBER)


def test_failed_download_keeps_its_partial(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    assert fetch(setup, root, setup["plain"] + "/trunc", sha) == ("err", "PKG-FETCH", FILE, KEY + ".url")
    partials = glob.glob(os.path.join(root, "native", ".dl-*"))
    assert len(partials) == 1
    assert open(partials[0], "rb").read() == b"0123456789"


def test_success_leaves_no_temporary_download(setup, tmp_path):
    root = cache(tmp_path / "c0")
    assert fetch(setup, root, setup["plain"] + "/t/other.tar", digest(
        fetch_bytes(setup["plain"] + "/t/other.tar")), "other.bin")[0] == "ok"
    assert glob.glob(os.path.join(root, "native", ".dl-*")) == []


def test_deadline_stops_a_slow_server(setup, tmp_path):
    root = cache(tmp_path / "c0")
    sha = digest(setup["lib_tar"])
    assert fetch(setup, root, setup["plain"] + "/slow", sha, MEMBER, "400") == (
        "err", "PKG-FETCH", FILE, KEY + ".url")
