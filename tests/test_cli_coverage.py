"""`agentica --coverage FILE`: the line coverage of a run as LCOV. The fixture program has a branch that never runs, a
function that is never called, a block, a file it imports and a std/ module; the golden is its report. The report is
also read back by a small LCOV reader here, which checks the totals of each record against its lines."""
import shutil

from tests.agentica_test import ROOT, cli, run, vm_environment

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
    assert sources["helper.agc"]["functions"] == {"size_of": (4, 3)}


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


def test_the_counts_are_the_same_on_four_schedulers_with_the_jit_and_from_bytecode(tmp_path):
    cwd = program(tmp_path)
    assert agentica(cwd, "compile", "main.agc", "-o", "main.agcb").code == 0
    for name, words in {
        "schedulers": ["--schedulers", "4", "--coverage", "s.info", "main.agc"],
        "jit": ["--jit", "always", "--coverage", "j.info", "main.agc"],
        "bytecode": ["run", "--coverage", "b.info", "--", "main.agcb"],
    }.items():
        result = agentica(cwd, *words)
        assert result.code == 0, (name, result.stderr)
        assert (cwd / words[words.index("--coverage") + 1]).read_text() == GOLDEN, name


def test_a_failing_run_still_writes_its_coverage(tmp_path):
    (tmp_path / "fail.agc").write_text('def main() -> Void\n  puts("a")\n  x = [1][3]\n  puts(x)\nend\n')
    result = agentica(tmp_path, "--json", "--coverage", "out.info", "fail.agc")
    assert result.code == 1
    assert '"RUNTIME-' in result.stderr
    lines = records((tmp_path / "out.info").read_text())["fail.agc"]["lines"]
    assert lines[2] == 1 and lines[4] == 0


def test_a_file_that_cannot_be_written_fails_the_run(tmp_path):
    cwd = program(tmp_path)
    result = agentica(cwd, "--json", "--coverage", "missing/out.info", "main.agc")
    assert result.code == 1
    assert '"code":"RUNTIME-INTERNAL"' in result.stderr.replace(" ", "")


def test_coverage_needs_a_file_name_and_the_test_runner_refuses_it(tmp_path):
    cwd = program(tmp_path)
    assert agentica(cwd, "--coverage", "", "main.agc").code == 2
    assert agentica(cwd, "test", "--coverage", "out.info").code == 2
    assert not (cwd / "out.info").exists()
