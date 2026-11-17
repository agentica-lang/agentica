"""Prebuilt native modules (`[native.NAME] prebuilt`, `[native_policy]`, docs/grammar/05b-modules.md), through the CLI.

The manifest is checked by `--json check` on a file of the project: a bad table is PKG-MANIFEST-INVALID at its key
path. `agentica native source NAME` prints the source key of a module, which a Python model of the source text
computes again here, the native API of the binary, which must be the one of vm/agentica_native.h, and the URL of each
target of the prebuilt table. Cases assert codes, key paths and the printed values, never message text (AGENTS.md).
"""
import hashlib
import json
import re

import pytest

from tests.agentica_test import ROOT, cli, run, vm_environment
from tests.package_support import assert_at_key, ws  # noqa: F401

ADDER_C = "int adder_value(void) { return 42; }\n"
MAIN = "def main() -> Void\n  puts(1)\nend\n"
SHA = "a" * 64
URL = "https://github.com/o/r/releases/download/native-{source}/lib{name}-{api}-{target}{ext}"
TARGETS = ["linux-x86_64", "linux-arm64", "macos-x86_64", "macos-arm64", "windows-x86_64"]
EXTENSIONS = {"linux": ".so", "macos": ".dylib", "windows": ".dll"}


def prebuilt(url=URL, source="0123456789abcdef", api="1.3", sha256=None):
    digests = sha256 if sha256 is not None else '{ linux-x86_64 = "%s" }' % SHA
    return '{ url = "%s", source = "%s", api = "%s", sha256 = %s }' % (url, source, api, digests)


def project(ws, table):
    """The project: a manifest with the adder module and `table` after it, native/adder.c and main.agc."""
    (ws.project / "native").mkdir(exist_ok=True)
    (ws.project / "native" / "adder.c").write_text(ADDER_C, encoding="utf-8")
    (ws.project / "agentica.toml").write_text('name = "adder"\n\n' + table, encoding="utf-8")
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")


def agentica(ws, *words):
    env = vm_environment({"AGENTICA_PATH": "", **ws.cache_variables})
    return run(cli() + list(words), cwd=ws.project, env=env)


def check_problem(ws):
    result = agentica(ws, "--json", "check", "main.agc")
    assert result.code == 1, (result.stdout, result.stderr)
    return json.loads(result.stderr)


def native_source(ws, name="adder"):
    result = agentica(ws, "--json", "native", "source", name)
    assert (result.code, result.stderr) == (0, ""), result.stderr
    return json.loads(result.stdout)


BUILD = '[native.adder]\nbuild = { sources = ["native/adder.c"], defines = ["N=1"] }\n'


@pytest.mark.parametrize("table, key", [
    ('[native.adder]\nlinux = { system = "libadder.so" }\nprebuilt = %s\n' % prebuilt(), "native.adder.prebuilt"),
    (BUILD + 'prebuilt = "https://example.com/x"\n', "native.adder.prebuilt"),
    (BUILD + 'prebuilt = { url = "%s", api = "1.3", sha256 = { linux-x86_64 = "%s" } }\n' % (URL, SHA),
     "native.adder.prebuilt"),
    (BUILD + 'prebuilt = { url = "%s", source = "0123456789abcdef", api = "1.3", sha256 = {}, mirror = "x" }\n' % URL,
     "native.adder.prebuilt.mirror"),
    (BUILD + "prebuilt = %s\n" % prebuilt(url=URL.replace("https:", "http:")), "native.adder.prebuilt.url"),
    (BUILD + "prebuilt = %s\n" % prebuilt(url="https://example.com/lib{name}{ext}"), "native.adder.prebuilt.url"),
    (BUILD + "prebuilt = %s\n" % prebuilt(url="https://example.com/{version}/{target}"), "native.adder.prebuilt.url"),
    (BUILD + "prebuilt = %s\n" % prebuilt(url="https://example.com/{target"), "native.adder.prebuilt.url"),
    (BUILD + "prebuilt = %s\n" % prebuilt(url="https://example.com/target}/{target}"), "native.adder.prebuilt.url"),
    (BUILD + "prebuilt = %s\n" % prebuilt(url="https://user@example.com/{target}"), "native.adder.prebuilt.url"),
    (BUILD + "prebuilt = %s\n" % prebuilt(url="https://example.com/{}/{target}"), "native.adder.prebuilt.url"),
    (BUILD + "prebuilt = %s\n" % prebuilt(source="0123456789ABCDEF"), "native.adder.prebuilt.source"),
    (BUILD + "prebuilt = %s\n" % prebuilt(source="0123"), "native.adder.prebuilt.source"),
    (BUILD + "prebuilt = %s\n" % prebuilt(api="1"), "native.adder.prebuilt.api"),
    (BUILD + "prebuilt = %s\n" % prebuilt(api="1.x"), "native.adder.prebuilt.api"),
    (BUILD + "prebuilt = %s\n" % prebuilt(api="01.4"), "native.adder.prebuilt.api"),
    (BUILD + "prebuilt = %s\n" % prebuilt(api="1.04"), "native.adder.prebuilt.api"),
    (BUILD + "prebuilt = %s\n" % prebuilt(api="1.2.3"), "native.adder.prebuilt.api"),
    (BUILD + "prebuilt = %s\n" % prebuilt(sha256="{}"), "native.adder.prebuilt.sha256"),
    (BUILD + "prebuilt = %s\n" % prebuilt(sha256='{ linux = "%s" }' % SHA), "native.adder.prebuilt.sha256.linux"),
    (BUILD + "prebuilt = %s\n" % prebuilt(sha256='{ freebsd-x86_64 = "%s" }' % SHA),
     "native.adder.prebuilt.sha256.freebsd-x86_64"),
    (BUILD + "prebuilt = %s\n" % prebuilt(sha256='{ macos-arm64 = "%s" }' % SHA.upper()),
     "native.adder.prebuilt.sha256.macos-arm64"),
    (BUILD + "prebuilt = %s\n" % prebuilt(sha256='{ windows-x86_64 = "abc" }'),
     "native.adder.prebuilt.sha256.windows-x86_64"),
], ids=["no build", "not a table", "no source", "an unknown key", "http", "no target in the url",
        "an unknown placeholder", "an open brace", "a close brace", "user info", "an empty placeholder",
        "an uppercase source", "a short source", "an api with no minor", "an api that is no number",
        "a leading zero in the major", "a leading zero in the minor", "three numbers", "no target",
        "a system for a target", "an unknown target", "an uppercase sha", "a short sha"])
def test_a_prebuilt_table_is_checked_where_it_is_written(ws, table, key):
    project(ws, table)
    assert_at_key(check_problem(ws), "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", key)


def test_a_prebuilt_table_beside_a_build_and_a_native_policy_check_clean(ws):
    digests = "{ %s }" % ", ".join('%s = "%s"' % (target, SHA) for target in TARGETS)
    project(ws, BUILD + "optional = true\nprebuilt = %s\n\n[native_policy]\nbuild = [\"adder\"]\n"
                        'prebuilt_only = ["other"]\n' % prebuilt(sha256=digests))
    result = agentica(ws, "--json", "check", "main.agc")
    assert (result.code, result.stdout, result.stderr) == (0, '{"ok":true}\n', "")


@pytest.mark.parametrize("policy, key", [
    ('build = "some"\n', "native_policy.build"),
    ("build = [1]\n", "native_policy.build[0]"),
    ('prebuilt_only = ["a b"]\n', "native_policy.prebuilt_only[0]"),
    ('colour = "red"\n', "native_policy.colour"),
    ('build = ["adder", "x"]\nprebuilt_only = ["y", "x"]\n', "native_policy.prebuilt_only[1]"),
    ('build = "all"\nprebuilt_only = ["x"]\n', "native_policy.prebuilt_only"),
    ('build = ["x"]\nprebuilt_only = "all"\n', "native_policy.prebuilt_only"),
    ('build = ["x", "x"]\nprebuilt_only = ["y", "y", "x"]\n', "native_policy.prebuilt_only[2]"),
], ids=["a word", "a number", "not a name", "an unknown key", "a module in both", "all and a name",
        "a name and all", "a module in both after repeats"])
def test_a_native_policy_names_modules_or_all_and_no_module_twice(ws, policy, key):
    project(ws, BUILD + "\n[native_policy]\n" + policy)
    assert_at_key(check_problem(ws), "PKG-MANIFEST-INVALID", ws.project / "agentica.toml", key)


def model_source_key(folder, library, sources, defines, libs):
    """The source key as the grammar defines it: the SHA-256 of the format line, the library, its build table and the
    digest and path of each file of native/ the package hash covers (no dotfile, Thumbs.db or desktop.ini), in
    bytewise order of the path; the first 16 hex digits."""
    files = []
    for path in (folder / "native").rglob("*"):
        parts = path.relative_to(folder).parts
        if path.is_file() and not any(part.startswith(".") or part in ("Thumbs.db", "desktop.ini") for part in parts):
            files.append("/".join(parts))
    lines = ["agentica native source 1", "library " + library]
    lines += ["source " + source for source in sources]
    lines += ["define " + define for define in defines]
    lines += ["lib " + lib for lib in libs]
    for path in sorted(files, key=lambda text: text.encode("utf-8")):
        lines.append("file %s %s" % (hashlib.sha256((folder / path).read_bytes()).hexdigest(), path))
    return hashlib.sha256("\n".join(lines).encode("utf-8")).hexdigest()[:16]


def header_api():
    header = (ROOT / "vm" / "agentica_native.h").read_text(encoding="utf-8")
    major = re.search(r"#define AN_API_MAJOR (\d+)", header).group(1)
    minor = re.search(r"#define AN_API_MINOR (\d+)", header).group(1)
    return "%s.%s" % (major, minor)


def test_native_source_prints_the_key_of_the_build_the_api_of_the_header_and_the_url_of_each_target(ws):
    project(ws, BUILD + "prebuilt = %s\n" % prebuilt())
    (ws.project / "native" / "sub").mkdir()
    (ws.project / "native" / "sub" / "scale.h").write_text("#define SCALE 2\n", encoding="utf-8")
    (ws.project / "native" / "B.h").write_text("#define B 1\n", encoding="utf-8")
    answer = native_source(ws)
    key = model_source_key(ws.project, "adder", ["native/adder.c"], ["N=1"], [])
    api = header_api()
    assert answer["source"] == key and answer["api"] == api
    expected = {}
    for target in TARGETS:
        extension = EXTENSIONS[target.split("-")[0]]
        expected[target] = "https://github.com/o/r/releases/download/native-%s/libadder-%s-%s%s" % (
            key, api, target, extension)
    assert answer["urls"] == expected
    plain = agentica(ws, "native", "source", "adder")
    assert plain.code == 0
    assert plain.stdout.splitlines() == ["source " + key, "api " + api] + [
        "%s %s" % (target, expected[target]) for target in TARGETS]


def test_the_source_key_follows_the_code_but_not_the_prebuilt_table_or_files_the_hash_leaves_out(ws):
    project(ws, BUILD)
    first = native_source(ws)
    assert first["urls"] == {}
    # The table of the files built from the code, a dotfile and Thumbs.db in native/ leave the key alone.
    project(ws, BUILD + "prebuilt = %s\n" % prebuilt(source=first["source"]))
    (ws.project / "native" / ".clangd").write_text("x\n", encoding="utf-8")
    (ws.project / "native" / "Thumbs.db").write_bytes(b"\x00")
    assert native_source(ws)["source"] == first["source"]
    # A file of native/, a define or a source changes it.
    (ws.project / "native" / "extra.h").write_text("#define E 1\n", encoding="utf-8")
    second = native_source(ws)["source"]
    assert second not in (first["source"],)
    project(ws, BUILD.replace("N=1", "N=2"))
    third = native_source(ws)["source"]
    assert third not in (first["source"], second)
    assert third == model_source_key(ws.project, "adder", ["native/adder.c"], ["N=2"], [])


def test_a_crlf_checkout_of_native_keys_as_its_lf_copy(ws):
    project(ws, BUILD)
    (ws.project / "native" / "adder.h").write_bytes(b"#define A 1\n#define B 2\n")
    lf = native_source(ws)["source"]
    (ws.project / "native" / "adder.c").write_bytes(ADDER_C.replace("\n", "\r\n").encode("utf-8"))
    (ws.project / "native" / "adder.h").write_bytes(b"#define A 1\r\n#define B 2\r\n")
    assert native_source(ws)["source"] == lf
    (ws.project / "native" / "adder.h").write_bytes(b"#define A 1\r\n#define B 3\r\n")
    assert native_source(ws)["source"] != lf


def test_a_native_file_over_the_limit_of_a_fetched_package_is_pkg_native_build(ws):
    project(ws, BUILD)
    (ws.project / "native" / "big.h").write_bytes(b"x" * (1_048_576 + 1))
    result = agentica(ws, "--json", "native", "source", "adder")
    assert result.code == 1, result.stderr
    assert_at_key(json.loads(result.stderr), "PKG-NATIVE-BUILD", ws.project / "agentica.toml", "native.adder.build")


def test_native_source_needs_a_module_that_builds_and_two_words(ws):
    project(ws, BUILD + '\n[native.sys]\nlinux = { system = "libsys.so" }\n')
    manifest = ws.project / "agentica.toml"
    for name in ("nope", "sys"):
        result = agentica(ws, "--json", "native", "source", name)
        assert result.code == 1, result.stderr
        assert_at_key(json.loads(result.stderr), "PKG-NATIVE-MISSING", manifest, "native." + name)
    for words in (["native"], ["native", "source"], ["native", "key", "adder"], ["native", "source", "a", "b"]):
        result = agentica(ws, *words)
        assert (result.code, result.stdout) == (2, ""), words
