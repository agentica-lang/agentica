"""The use of prebuilt native modules at first use (docs/grammar/05b-modules.md): the prebuilt file before a build,
`--native-build`, `--native-prebuilt-only`, their environment variables and `[native_policy]`, through the CLI.

The prebuilt file is the library that the system C compiler builds for the same sources in another project, served by
the peer of tests/test_spec_package_native_fetch.py and downloaded by `install`. A compiler that a case must not start
is a missing CC; one that it may start is a shell script that notes each start in a file before it runs `cc`, so a
case tells a build from the use of the prebuilt file. Cases assert codes and key paths, never message text.
"""
import hashlib
import json
import os
import shutil
import stat

import pytest

from tests.agentica_test import WINDOWS, cli, host_only, run, vm_environment
from tests.package_support import ws  # noqa: F401
from tests.test_spec_package_native_build import ADDER_AGC, ADDER_C, GUARDED_MAIN, MAIN
from tests.test_spec_package_native_fetch import Peer, prebuilt
from tests.test_vm_native import NATIVE_CALLS

pytestmark = [NATIVE_CALLS, host_only(WINDOWS, "the cases start the compiler through a POSIX shell script")]

BUILD = '[native.adder]\nbuild = { sources = ["native/adder.c"], defines = ["SCALE=1"] }\n'
KEY = "native.adder"


@pytest.fixture()
def peer():
    served = Peer()
    yield served
    served.stop()


def environment(ws, **extra):
    """No compiler unless the case gives one (CC names no program), and the bytecode cache in a folder of the case."""
    base = {"AGENTICA_PATH": "", "AGENTICA_BUILD_DIR": str(ws.base / "build"), "CC": str(ws.base / "no-cc"),
            "AGENTICA_NATIVE_BUILD": None, "AGENTICA_NATIVE_PREBUILT_ONLY": None, **ws.cache_variables}
    base.update(extra)
    return vm_environment({key: value for key, value in base.items() if value is not None})


def agentica(ws, *words, folder=None, **extra):
    return run(cli() + list(words), cwd=folder or ws.project, env=environment(ws, **extra))


def counting_cc(ws):
    """A CC that notes each start in ws.base/cc-starts, then runs cc."""
    script = ws.base / "cc.sh"
    script.write_text('#!/bin/sh\necho start >> "%s"\nexec cc "$@"\n' % (ws.base / "cc-starts"), encoding="utf-8")
    script.chmod(script.stat().st_mode | stat.S_IXUSR)
    return {"CC": str(script)}


def starts(ws):
    path = ws.base / "cc-starts"
    return len(path.read_text(encoding="utf-8").splitlines()) if path.exists() else 0


def module(folder, table):
    (folder / "native").mkdir(parents=True, exist_ok=True)
    (folder / "native" / "adder.c").write_text(ADDER_C, encoding="utf-8")
    (folder / "native" / "offset.h").write_text("#define OFFSET 0\n", encoding="utf-8")
    (folder / "adder.agc").write_text(ADDER_AGC, encoding="utf-8")
    (folder / "agentica.toml").write_text('name = "app"\n\n' + table, encoding="utf-8")


def library_bytes(ws):
    """The library that cc builds from the adder's sources, as a package author's release would upload it."""
    author = ws.base / "author"
    module(author, BUILD)
    built = agentica(ws, "install", folder=author, **counting_cc(ws))
    assert built.code == 0, built.stderr
    found = list((ws.pkg_root / "native-build").glob("*/lib*"))
    assert len(found) == 1, found
    data = found[0].read_bytes()
    shutil.rmtree(ws.pkg_root / "native-build")
    return data


def project(ws, peer, extra="", main=MAIN, table=BUILD):
    """The project with the adder and its prebuilt table, whose file the peer serves; returns the manifest."""
    data = library_bytes(ws)
    peer.body = data
    module(ws.project, table)
    (ws.project / "main.agc").write_text(main, encoding="utf-8")
    source = json.loads(agentica(ws, "--json", "native", "source", "adder").stdout)
    manifest = ws.project / "agentica.toml"
    manifest.write_text(manifest.read_text(encoding="utf-8")
                        + prebuilt("ok", peer, source["source"], source["api"], hashlib.sha256(data).hexdigest())
                        + extra, encoding="utf-8")
    os.remove(ws.base / "cc-starts")
    return manifest


def problem(result):
    found = [json.loads(line) for line in result.stderr.splitlines() if line.strip()]
    found = [item for item in found if not item.get("warning")]
    assert result.code == 1 and len(found) == 1, result.stderr
    return found[0]


def warnings(result):
    found = [json.loads(line) for line in result.stderr.splitlines() if line.strip()]
    return [item for item in found if item.get("warning")]


def test_a_run_with_no_compiler_uses_the_downloaded_file(ws, peer):
    project(ws, peer)
    installed = agentica(ws, "--json", "install", PATH=str(ws.base))
    assert (installed.code, installed.stderr) == (0, ""), installed.stderr
    assert not (ws.pkg_root / "native-build").exists()
    ran = agentica(ws, "main.agc", PATH=str(ws.base))
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr


def test_install_uses_the_prebuilt_file_and_starts_no_compiler(ws, peer):
    project(ws, peer)
    installed = agentica(ws, "--json", "install", **counting_cc(ws))
    assert (installed.code, installed.stderr) == (0, ""), installed.stderr
    ran = agentica(ws, "main.agc", **counting_cc(ws))
    assert (ran.code, ran.stdout, starts(ws)) == (0, "42\n", 0), ran.stderr


@pytest.mark.parametrize("way", ["flag", "variable", "manifest"])
def test_a_forced_build_starts_the_compiler(ws, peer, way):
    extra = '\n[native_policy]\nbuild = ["adder"]\n' if way == "manifest" else ""
    project(ws, peer, extra)
    assert agentica(ws, "--json", "install", **counting_cc(ws)).code == 0
    words = ["--native-build=adder"] if way == "flag" else []
    env = {"AGENTICA_NATIVE_BUILD": "adder"} if way == "variable" else {}
    ran = agentica(ws, *words, "main.agc", **counting_cc(ws), **env)
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    assert starts(ws) > 0


@pytest.mark.parametrize("way", ["flag", "variable", "manifest"])
def test_prebuilt_only_with_nothing_fetched_never_starts_the_compiler(ws, peer, way):
    extra = '\n[native_policy]\nprebuilt_only = "all"\n' if way == "manifest" else ""
    manifest = project(ws, peer, extra)
    words = ["--native-prebuilt-only"] if way == "flag" else []
    env = {"AGENTICA_NATIVE_PREBUILT_ONLY": "all"} if way == "variable" else {}
    ran = agentica(ws, "--json", *words, "main.agc", **counting_cc(ws), **env)
    found = problem(ran)
    assert (found["code"], found["file"], found["key_path"]) == ("PKG-NATIVE-BUILD", str(manifest), KEY + ".build")
    assert "agentica install" in found["help"]
    assert starts(ws) == 0


def test_an_optional_prebuilt_only_module_with_nothing_fetched_is_a_warning(ws, peer):
    project(ws, peer, main=GUARDED_MAIN, table=BUILD + "optional = true\n")
    ran = agentica(ws, "--json", "--native-prebuilt-only", "main.agc", **counting_cc(ws))
    assert (ran.code, ran.stdout, starts(ws)) == (0, "without adder\n", 0), ran.stderr
    assert [item["code"] for item in warnings(ran)] == ["PKG-NATIVE-UNBUILT"]


def test_the_flag_goes_before_the_variable_and_the_variable_before_the_manifest(ws, peer):
    project(ws, peer, '\n[native_policy]\nbuild = ["adder"]\n')
    assert agentica(ws, "--json", "install", AGENTICA_NATIVE_PREBUILT_ONLY="adder", **counting_cc(ws)).code == 0
    assert starts(ws) == 0
    ran = agentica(ws, "main.agc", AGENTICA_NATIVE_PREBUILT_ONLY="adder", **counting_cc(ws))
    assert (ran.code, ran.stdout, starts(ws)) == (0, "42\n", 0), ran.stderr
    ran = agentica(ws, "--native-build=adder", "main.agc", AGENTICA_NATIVE_PREBUILT_ONLY="adder", **counting_cc(ws))
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    assert starts(ws) > 0


@pytest.mark.parametrize("words, env", [
    (["--native-build=adder", "--native-prebuilt-only=adder"], {}),
    (["--native-build", "--native-prebuilt-only=adder"], {}),
    (["--native-build="], {}),
    (["--native-build=a b"], {}),
    (["--native-build", "--native-build"], {}),
    ([], {"AGENTICA_NATIVE_BUILD": "adder", "AGENTICA_NATIVE_PREBUILT_ONLY": "adder"}),
    ([], {"AGENTICA_NATIVE_BUILD": "a b"}),
], ids=["a module in both", "all and a module", "no names", "a bad name", "twice", "both variables",
        "a bad name in a variable"])
def test_a_bad_native_policy_on_the_command_line_is_a_usage_error(ws, words, env):
    module(ws.project, BUILD)
    (ws.project / "main.agc").write_text(MAIN, encoding="utf-8")
    ran = agentica(ws, *words, "main.agc", **env)
    assert (ran.code, ran.stdout) in ((1, ""), (2, "")), ran.stderr
    assert ran.code == (1 if words == ["--native-build", "--native-build"] else 2), ran.stderr


def test_the_bytecode_cache_follows_the_policy_and_checks_the_file(ws, peer):
    manifest = project(ws, peer)
    assert agentica(ws, "--json", "install", **counting_cc(ws)).code == 0
    assert agentica(ws, "main.agc", **counting_cc(ws)).stdout == "42\n"
    ran = agentica(ws, "--native-build", "main.agc", **counting_cc(ws))
    assert (ran.code, ran.stdout) == (0, "42\n") and starts(ws) > 0, ran.stderr
    built = starts(ws)
    ran = agentica(ws, "main.agc", **counting_cc(ws))
    assert (ran.code, ran.stdout, starts(ws)) == (0, "42\n", built), ran.stderr
    libraries = list((ws.pkg_root / "native-prebuilt").glob("*/library*"))
    assert len(libraries) == 1
    libraries[0].write_bytes(b"changed")
    found = problem(agentica(ws, "--json", "main.agc", **counting_cc(ws)))
    assert (found["code"], found["file"], found["key_path"]) == ("PKG-NATIVE-BUILD", str(manifest), KEY + ".prebuilt")


def test_a_native_file_over_the_limit_of_a_fetched_package_still_builds(ws, peer):
    project(ws, peer)
    (ws.project / "native" / "big.h").write_bytes(b"/" * (1_048_576 + 1) + b"\n")
    installed = agentica(ws, "--json", "install", **counting_cc(ws))
    assert installed.code == 0, installed.stderr
    ran = agentica(ws, "main.agc", **counting_cc(ws))
    assert (ran.code, ran.stdout) == (0, "42\n"), ran.stderr
    assert starts(ws) > 0 and peer.requests == []


def test_install_warns_of_a_policy_name_that_is_no_module(ws, peer):
    manifest = project(ws, peer, '\n[native_policy]\nbuild = ["nope"]\n')
    installed = agentica(ws, "--json", "--native-prebuilt-only=other", "install", **counting_cc(ws))
    assert installed.code == 0, installed.stderr
    found = [(item["code"], item.get("key_path", "")) for item in warnings(installed)]
    assert sorted(found) == [("PKG-NATIVE-MISSING", ""), ("PKG-NATIVE-MISSING", "native_policy.build")]
    assert all(item["file"] == str(manifest) for item in warnings(installed))
