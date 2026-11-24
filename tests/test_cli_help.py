"""`agentica COMMAND --help` and `-h` (issue #1928) through the product CLI: every command prints its usage and the part
of the summary that describes it, on standard output with exit code 0. The usage lines are the ones of the usage error,
so each form of the help must be found in that text, which is how the two cannot drift."""
import pytest

from tests.agentica_test import cli, run, vm_environment

COMMANDS = ["test", "help", "doc", "fmt", "lint", "install", "init", "add", "update", "native", "outline", "type-at",
            "symbol", "refs", "run", "check", "compile", "repl"]


def usage_error():
    return run(cli(), env=vm_environment()).stderr


@pytest.mark.parametrize("flag", ["--help", "-h"])
@pytest.mark.parametrize("command", COMMANDS)
def test_a_command_with_help_prints_its_usage_and_exits_0(command, flag, tmp_path):
    result = run(cli() + [command, flag], env=vm_environment(), cwd=tmp_path)
    assert (result.code, result.stderr) == (0, "")
    assert result.stdout.startswith("usage: agentica %s" % command)
    if command == "run":
        return
    # Each form is one of the usage error, with or without the options that go before the command.
    usage = usage_error()
    forms = [line.split("agentica ", 1)[1] for line in result.stdout.split("\n\n")[0].split("\n")]
    assert forms and all(form in usage for form in forms)
    # The description is the part of the summary that `agentica --help` prints for the command.
    assert "  agentica %s" % command in result.stdout and "  agentica %s" % command in run(
        cli() + ["--help"], env=vm_environment()).stdout


def test_help_after_other_words_and_options_still_answers_and_a_program_keeps_its_own_flag(tmp_path):
    answered = run(cli() + ["--json", "check", "a.agc", "--help"], env=vm_environment(), cwd=tmp_path)
    assert (answered.code, answered.stdout.startswith("usage: agentica check")) == (0, True)

    program = tmp_path / "echo.agc"
    program.write_text("def main() -> Void\n  puts(System.args().join(\" \"))\nend\n", encoding="utf-8")
    ran = run(cli() + [str(program), "--help", "-h"], env=vm_environment(), cwd=tmp_path)
    assert (ran.code, ran.stdout) == (0, "--help -h\n"), ran.stderr
