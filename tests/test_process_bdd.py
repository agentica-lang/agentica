"""`Process` inside `agentica test`: handlers and programs under test can both start programs.

A module of its own: the case runs `agentica test`, which the Wine check of the Windows job cannot do (Wine makes no
owner-only folder, which the run directory of the driver is), so the Wine list leaves it out.
"""
import json

from tests.agentica_test import tool
from tests.test_process import cli_run, program, spawn


def test_bdd_handlers_and_programs_under_test_can_spawn(tmp_path):
    node = tool("node")
    directory = tmp_path
    feature = directory / "process.feature"
    steps = directory / "steps.agc"
    feature.write_text(
        'Feature: Process capability\nScenario: child\nGiven the Agentica program "child.agc"\n'
        'Then I receive a JSON line within 30000 milliseconds:\n  """\n  ["child"]\n  """\n'
        'And the program exits with code 0 within 30000 milliseconds\nScenario: handler\nThen the handler can spawn\n')
    (directory / "child.agc").write_text(program(
        node, "args", "  puts(Result.unwrap!(Process.read_line(p, 5000)))\n  Result.unwrap!(Process.wait(p, 5000))",
        "", ', "child"'))
    steps.write_text(
        'import BDD from "std/bdd"\n\ndef handler(ctx: BDD.Context, args: List[String]) -> BDD.Context\n'
        + spawn(node, "args", ', "handler"')
        + '  checked = BDD.assert(ctx, Result.unwrap!(Process.read_line(p, 5000)) == "[\\"handler\\"]", "argv")\n'
        + "  Result.unwrap!(Process.wait(p, 5000))\n  return checked\nend\n\n"
        + 'def main() -> Void\n  BDD.run([BDD.step("the handler can spawn", &handler)])\nend\n')
    result = cli_run("test", feature, "--steps", steps, "--json")
    assert result.code == 0, (result.stdout, result.stderr)
    assert json.loads(result.stdout)["passed"] == 2
    # --deny-run reaches the step program's VM, not the runner: the step that starts a program under test fails.
    denied = cli_run("test", feature, "--steps", steps, "--json", "--deny-run")
    assert denied.code == 1, (denied.stdout, denied.stderr)
    scenarios = {item["name"]: item for item in json.loads(denied.stdout)["files"][0]["scenarios"]}
    error = scenarios["child"]["error"]
    assert error["code"] == "RUNTIME-BDD-IO"
    assert error["message"].startswith("denied: --deny-run")
    assert scenarios["handler"]["status"] == "failed"
