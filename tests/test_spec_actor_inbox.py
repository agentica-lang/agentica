"""ActorInbox, the std-only rows behind `Actor.inbox`, through the CLI: user code cannot name them, and inside std/ the
type of `ActorInbox.get` comes from the expected `Optional[Channel[T]]`.

The std/ cases check a program against a copy of stdlib/ with one more module, through the front end of the binary.
"""
import json
import shutil

from tests.agentica_test import ROOT, STAGE2, agentica_version, cli, require, run, vm_command, vm_environment


def check_json(argv):
    result = run(argv, env=vm_environment())
    assert result.code == 1, result
    return json.loads(result.stderr.strip().splitlines()[-1])


def span(found):
    start, end = found["range"]["start"], found["range"]["end"]
    return (start["line"], start["column"]), (end["line"], end["column"])


def check_in_std(tmp_path, body):
    require(STAGE2.is_file(), "the front end is not built (%s): run make" % STAGE2)
    std = tmp_path / "std"
    shutil.copytree(ROOT / "stdlib", std)
    (std / "probe.agc").write_text("def probe() -> Bool\n" + body + "end\n", encoding="utf-8")
    with (std / "MODULES").open("a", encoding="utf-8") as modules:
        modules.write("probe\n")
    program = tmp_path / "main.agc"
    program.write_text('import Probe from "std/probe"\n\ndef main() -> Void\n  puts(Probe.probe())\nend\n',
                       encoding="utf-8")
    return check_json([*vm_command(), "--", STAGE2, "--version", agentica_version(), "--stdlib", std,
                       "--self", ROOT / "dist" / "agentica", "--", "--json", "check", program])


def test_user_code_cannot_name_actor_inbox(tmp_path):
    program = tmp_path / "main.agc"
    program.write_text("def main() -> Void\n  y: Optional[Channel[Int]] = ActorInbox.get\n  puts(y.some?)\nend\n",
                       encoding="utf-8")
    found = check_json(cli() + ["--json", "check", str(program)])
    assert (found["code"], span(found)) == ("CHECK-UNKNOWN-NAME", ((2, 31), (2, 45)))


def test_get_needs_an_expected_type(tmp_path):
    found = check_in_std(tmp_path, "  ActorInbox.get.some?\n")
    assert (found["code"], found["file"], span(found)) == ("CHECK-EXPECTED-TYPE", "std/probe.agc", ((2, 3), (2, 17)))


def test_get_gives_an_optional_channel(tmp_path):
    found = check_in_std(tmp_path, "  inbox: Optional[Int] = ActorInbox.get\n  inbox.some?\n")
    assert (found["code"], found["file"], span(found)) == ("CHECK-TYPE-MISMATCH", "std/probe.agc", ((2, 26), (2, 40)))
