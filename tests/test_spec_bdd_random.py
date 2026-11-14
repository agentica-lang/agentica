"""BddRandom.srand, the std-only row behind the scenarios of an `agentica test` worker, through the CLI: user code
cannot name it, and inside std/ it starts the running task's random numbers again from the seed, as main's under
--seed.

The std/ case compiles a program against a copy of stdlib/ with one more module, through the front end of the binary.
"""
import json
import shutil

from tests.agentica_test import ROOT, STAGE2, agentica_version, cli, require, run, vm_command, vm_environment


def test_user_code_cannot_name_bdd_random(tmp_path):
    program = tmp_path / "main.agc"
    program.write_text("def main() -> Void\n  BddRandom.srand(1)\nend\n", encoding="utf-8")
    result = run(cli() + ["--json", "check", str(program)], env=vm_environment())
    assert result.code == 1, result
    found = json.loads(result.stderr.strip().splitlines()[-1])
    start = found["range"]["start"]
    assert (found["code"], start["line"], start["column"]) == ("CHECK-UNKNOWN-NAME", 2, 3)


def test_srand_in_a_task_draws_what_main_draws_first_under_the_same_seed(tmp_path):
    require(STAGE2.is_file(), "the front end is not built (%s): run make" % STAGE2)
    std = tmp_path / "std"
    shutil.copytree(ROOT / "stdlib", std)
    (std / "probe.agc").write_text(
        "def reseeded(seed: Int) -> Int\n  BddRandom.srand(seed)\n  Random.int(0, 1000000000)\nend\n",
        encoding="utf-8")
    with (std / "MODULES").open("a", encoding="utf-8") as modules:
        modules.write("probe\n")
    program = tmp_path / "main.agc"
    program.write_text(
        'import Probe from "std/probe"\n\n'
        "def main() -> Void\n"
        "  first = Random.int(0, 1000000000)\n"
        "  second = Random.int(0, 1000000000)\n"
        "  task = Task.spawn do Probe.reseeded(Random.seed) end\n"
        '  puts("#{first} #{second} #{Task.await(task)}")\n'
        "end\n",
        encoding="utf-8")
    compiled = tmp_path / "main.agcb"
    built = run([*vm_command(), "--", STAGE2, "--version", agentica_version(), "--stdlib", std,
                 "--self", ROOT / "dist" / "agentica", "--", "compile", program, "-o", compiled],
                env=vm_environment())
    assert built.code == 0, built
    for seed in ("7", "2147483647"):
        result = run([*vm_command(), "--seed", seed, "--", compiled], env=vm_environment())
        assert result.code == 0, result
        first, second, reseeded = result.stdout.split()
        assert reseeded == first != second, result
