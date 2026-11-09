"""`agentica --coverage FILE`: the line coverage of a run as LCOV. The fixture program has a branch that never runs, a
function that is never called, a block, a file it imports and a std/ module; the golden is its report. The report is
also read back by a small LCOV reader here, which checks the totals of each record against its lines."""
import os
import shutil

from tests.agentica_test import ROOT, cli, run, vm_environment
from tests.package_support import (dependency, environment, git, inline_table, install, lock_entry,  # noqa: F401
                                    remotes, ws)

FIXTURE = ROOT / "tests" / "fixtures" / "coverage"
GOLDEN = (FIXTURE / "main.info").read_text()


def program(tmp_path):
    """A copy of the fixture program in tmp_path, so that the run writes no cache or report into the repository."""
    for name in ("main.agc", "helper.agc"):
        shutil.copy(FIXTURE / name, tmp_path / name)
    return tmp_path


def agentica(cwd, *words):
    return run(cli() + list(words), env=vm_environment(), cwd=cwd)


def records(text):
    """The records of an LCOV report, by source: {"lines": {line: count}, "functions": {name: (line, calls)}}. Each
    total (FNF, FNH, LF, LH) must match the lines of its record."""
    found = {}
    for block in text.split("end_of_record\n")[:-1]:
        fields = [line.split(":", 1) for line in block.splitlines()]
        assert fields[0][0] == "SF", block
        lines, starts, calls, totals = {}, {}, {}, {}
        for key, value in fields[1:]:
            if key == "DA":
                line, count = value.split(",")
                lines[int(line)] = int(count)
            elif key == "FN":
                line, name = value.split(",", 1)
                starts[name] = int(line)
            elif key == "FNDA":
                count, name = value.split(",", 1)
                calls[name] = int(count)
            else:
                totals[key] = int(value)
        assert set(starts) == set(calls), block
        assert totals == {"FNF": len(calls), "FNH": sum(1 for n in calls.values() if n),
                          "LF": len(lines), "LH": sum(1 for n in lines.values() if n)}, block
        found[fields[0][1]] = {"lines": lines, "functions": {name: (starts[name], calls[name]) for name in starts}}
    assert text.endswith("end_of_record\n")
    return found


def test_a_run_writes_the_coverage_of_the_program_and_its_imports_but_not_of_std(tmp_path):
    cwd = program(tmp_path)
    result = agentica(cwd, "--coverage", "out.info", "main.agc")
    assert result.code == 0, result.stderr
    report = (cwd / "out.info").read_text()
    assert report == GOLDEN
    sources = records(report)
    assert list(sources) == ["main.agc", "helper.agc"]
    main = sources["main.agc"]
    # classify runs three times and takes its n < 0 branch never; unused is never called.
    assert main["functions"]["classify"] == (6, 3)
    assert main["functions"]["unused"] == (14, 0)
    assert main["lines"][8] == 0 and main["lines"][15] == 0
    # The blocks that times, a range's each and map call run once per item, each line of them too.
    assert [main["functions"][name] for name in main["functions"] if name.startswith("block@main.agc:")] == [
        (23, 2), (28, 3), (33, 3), (38, 4)]
    assert [main["lines"][line] for line in (29, 30, 34, 35, 39, 40)] == [3, 3, 3, 3, 4, 4]
    assert sources["helper.agc"]["functions"] == {"size_of": (4, 3)}
    # The report is written beside its target and renamed over it: no temporary file is left, and a new report has the
    # mode of a new file, 0666 less the umask.
    assert sorted(path.name for path in cwd.iterdir()) == ["helper.agc", "main.agc", "out.info"]
    if os.name != "nt":
        umask = os.umask(0)
        os.umask(umask)
        assert (cwd / "out.info").stat().st_mode & 0o777 == 0o666 & ~umask


def test_a_path_dependency_is_counted_under_its_package_name(tmp_path):
    (tmp_path / "tools").mkdir()
    (tmp_path / "app").mkdir()
    (tmp_path / "tools" / "agentica.toml").write_text('name = "tools"\n')
    (tmp_path / "tools" / "tools.agc").write_text("export def twice(n: Int) -> Int\n  return n * 2\nend\n")
    (tmp_path / "app" / "agentica.toml").write_text('name = "app"\n\n[dependencies]\ntools = { path = "../tools" }\n')
    (tmp_path / "app" / "agentica.lock").write_text('version = 1\n\n[[package]]\nname = "tools"\npath = "../tools"\n')
    (tmp_path / "app" / "main.agc").write_text(
        'import Tools from "pkg/tools/tools"\n\ndef main() -> Void\n  puts(Tools.twice(2))\nend\n')
    result = agentica(tmp_path / "app", "--coverage", "out.info", "main.agc")
    assert result.code == 0, result.stderr
    sources = records((tmp_path / "app" / "out.info").read_text())
    assert sources["pkg/tools@path/tools.agc"] == {"lines": {2: 1}, "functions": {"twice": (1, 1)}}
    assert list(sources) == ["main.agc", "pkg/tools@path/tools.agc"]


def test_a_workspace_member_is_counted_as_a_path_dependency_is(ws, remotes, tmp_path):
    """A member that another member of the repository depends on is read from its folder (`pkg/NAME@workspace/`): the
    project's own code, so it is counted."""
    url = remotes.url("owner/packages")
    files = {
        "agentica.toml": '[workspace]\nrepository = "%s"\nmembers = ["app", "common"]\n' % url,
        "common/agentica.toml": 'name = "common"\n',
        "common/util.agc": "export def twice(n: Int) -> Int\n  return n * 2\nend\n",
        "app/agentica.toml": 'name = "app"\n\n[dependencies]\ncommon = %s\n'
                             % inline_table(dependency(url, tag="common-1", subdir="common")),
        "app/main.agc": 'import Util from "pkg/common/util"\n\ndef main() -> Void\n  puts(Util.twice(2))\nend\n',
    }
    for relative, text in files.items():
        (tmp_path / "repo" / relative).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / "repo" / relative).write_text(text)
    app = tmp_path / "repo" / "app"
    updated = run(cli() + ["update"], cwd=app, env=environment(ws, remotes))
    assert updated.code == 0, updated.stderr
    result = run(cli() + ["--coverage", "out.info", "main.agc"], cwd=app, env=environment(ws, remotes))
    assert result.code == 0, result.stderr
    sources = records((app / "out.info").read_text())
    assert list(sources) == ["main.agc", "pkg/common@workspace/util.agc"]
    assert sources["pkg/common@workspace/util.agc"]["functions"] == {"twice": (1, 1)}


def test_a_fetched_package_is_left_out_when_the_entry_is_in_another_folder(ws, remotes):
    """Run from the folder above the project, so the loader joins that folder to every name (--source-root): the
    package is still told apart by the name it was stored with."""
    files = {"agentica.toml": 'name = "x"\n', "x.agc": "export def twice(n: Int) -> Int\n  return n * 2\nend\n"}
    commit = remotes.publish("owner/x", files, tag="v1.0.0")
    lock_entry(ws, remotes, "owner/x", files, commit, tag="v1.0.0")
    ws.write_manifest({"x": dependency(remotes.url("owner/x"), tag="v1.0.0")})
    ws.write_lock()
    assert install(ws, remotes)[1] is None
    (ws.project / "main.agc").write_text('import X from "pkg/x/x"\n\ndef main() -> Void\n  puts(X.twice(2))\nend\n')
    entry = os.path.relpath(ws.project / "main.agc", ws.base)
    result = run(cli() + ["--coverage", "lcov.info", entry], cwd=ws.base, env=environment(ws, remotes))
    assert result.code == 0, result.stderr
    sources = records((ws.base / "lcov.info").read_text())
    assert list(sources) == [entry.replace(os.sep, "/")]


def test_the_counts_of_tasks_that_run_at_once_are_the_same_on_four_schedulers(tmp_path):
    shutil.copy(FIXTURE / "tasks.agc", tmp_path / "tasks.agc")
    reports = []
    for schedulers in ("1", "4"):
        result = agentica(tmp_path, "--schedulers", schedulers, "--coverage", "out.info", "tasks.agc")
        assert result.code == 0, result.stderr
        reports.append((tmp_path / "out.info").read_text())
    assert reports[0] == reports[1]
    lines = records(reports[1])["tasks.agc"]["lines"]
    assert (lines[5], lines[7], lines[8]) == (4, 120000, 40000)


def test_the_counts_are_the_same_with_the_jit_and_from_bytecode(tmp_path):
    cwd = program(tmp_path)
    assert agentica(cwd, "compile", "main.agc", "-o", "main.agcb").code == 0
    for name, words in {
        "jit": ["--jit", "always", "--coverage", "j.info", "main.agc"],
        "bytecode": ["run", "--coverage", "b.info", "--", "main.agcb"],
    }.items():
        result = agentica(cwd, *words)
        assert result.code == 0, (name, result.stderr)
        assert (cwd / words[words.index("--coverage") + 1]).read_text() == GOLDEN, name


def test_the_profile_and_coverage_in_one_run_both_count_and_coverage_alone_writes_no_profile(tmp_path):
    cwd = program(tmp_path)
    for category, profiled in (("profile", True), ("sched", False)):
        trace = cwd / (category + ".trace")
        env = vm_environment({"AGENTICA_VM_TRACE": category, "AGENTICA_VM_TRACE_FILE": trace})
        # The profile trace runs on one scheduler.
        result = run(cli() + ["--schedulers", "1", "--coverage", "out.info", "main.agc"], env=env, cwd=cwd)
        assert result.code == 0, result.stderr
        assert (cwd / "out.info").read_text() == GOLDEN, category
        text = trace.read_text()
        assert (" profile fn calls=3 " in text and "name=classify" in text) == profiled, text[-2000:]
        assert (" profile " in text) == profiled


def test_an_old_report_is_removed_when_the_run_starts(tmp_path):
    (tmp_path / "out.info").write_text("SF:stale.agc\nend_of_record\n")
    (tmp_path / "look.agc").write_text('def main() -> Void\n  puts(File.stat("out.info").ok?)\nend\n')
    result = agentica(tmp_path, "--coverage", "out.info", "look.agc")
    assert (result.code, result.stdout) == (0, "false\n"), result.stderr
    assert list(records((tmp_path / "out.info").read_text())) == ["look.agc"]


def test_a_failing_run_still_writes_its_coverage(tmp_path):
    (tmp_path / "fail.agc").write_text('def main() -> Void\n  puts("a")\n  x = [1][3]\n  puts(x)\nend\n')
    result = agentica(tmp_path, "--json", "--coverage", "out.info", "fail.agc")
    assert result.code == 1
    assert '"RUNTIME-' in result.stderr
    lines = records((tmp_path / "out.info").read_text())["fail.agc"]["lines"]
    assert lines[2] == 1 and lines[4] == 0


def test_a_file_that_cannot_be_written_fails_the_run_or_adds_a_notice_to_its_failure(tmp_path):
    cwd = program(tmp_path)
    result = agentica(cwd, "--json", "--coverage", "missing/out.info", "main.agc")
    assert result.code == 1
    assert '"code":"RUNTIME-INTERNAL"' in result.stderr.replace(" ", "")
    (cwd / "fail.agc").write_text('def main() -> Void\n  x = [1][3]\n  puts(x)\nend\n')
    result = agentica(cwd, "--json", "--coverage", "missing/out.info", "fail.agc")
    assert result.code == 1
    lines = result.stderr.splitlines()
    assert '"RUNTIME-INTERNAL"' not in lines[0] and '"RUNTIME-' in lines[0]
    assert lines[1:] == ['{"warning":"cannot write the coverage file"}']


def test_coverage_needs_a_file_name_and_the_test_runner_refuses_it(tmp_path):
    cwd = program(tmp_path)
    assert agentica(cwd, "--coverage", "", "main.agc").code == 2
    assert agentica(cwd, "test", "--coverage", "out.info").code == 2
    assert not (cwd / "out.info").exists()
