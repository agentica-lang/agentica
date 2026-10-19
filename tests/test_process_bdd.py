"""`Process` inside `agentica test`: handlers always spawn, programs under test need --allow-run.

A module of its own: the case runs `agentica test`, which the Wine check of the Windows job cannot do (Wine makes no
owner-only folder, which the run directory of the driver is), so the Wine list leaves it out.
"""
import json

from tests.agentica_test import tool
from tests.test_process import cli_run, program, spawn


def test_bdd_handlers_can_always_spawn_and_programs_under_test_need_allow_run(tmp_path):
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
    args = ["test", feature, "--steps", steps, "--json"]
    denied = cli_run(*args)
    assert denied.code == 1, (denied.stdout, denied.stderr)
    report = json.loads(denied.stdout)
    assert report["passed"] == 1, report
    assert [item["status"] for item in report["files"][0]["scenarios"]] == ["failed", "passed"], report
    allowed = cli_run(*args, "--allow-run")
    assert allowed.code == 0, (allowed.stdout, allowed.stderr)
    assert json.loads(allowed.stdout)["passed"] == 2
