"""tools/shard_tests.py: the shards of `make test SHARD=I/N` together run each module once, the same way every time."""
import importlib.util
import subprocess
import sys

import pytest

from tests.agentica_test import ROOT


def load_tool():
    spec = importlib.util.spec_from_file_location("agentica_shard_tests", ROOT / "tools" / "shard_tests.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


shards = load_tool()
MODULES = sorted(path.relative_to(ROOT).as_posix() for path in (ROOT / "tests").glob("test_*.py"))


@pytest.mark.parametrize("column", shards.COLUMNS)
@pytest.mark.parametrize("count", [1, 2, 3, 5])
def test_every_module_is_in_exactly_one_shard_and_the_split_is_stable(count, column):
    weights = shards.load_weights(shards.WEIGHTS, column)
    first = shards.split(MODULES, count, weights)
    assert first == shards.split(list(reversed(MODULES)), count, weights)
    assert sorted(m for shard in first for m in shard) == MODULES


def test_the_weights_file_names_only_modules_that_exist():
    assert set(shards.load_weights(shards.WEIGHTS, "fast")) <= set(MODULES)


def test_the_command_prints_one_shard_and_refuses_a_bad_one():
    def run(*arguments):
        return subprocess.run([sys.executable, str(ROOT / "tools" / "shard_tests.py"), *arguments],
                              capture_output=True, text=True, timeout=60)

    both = [run(f"{i}/2", "tests/test_a.py", "tests/test_b.py", "tests/test_c.py").stdout.split() for i in (1, 2)]
    assert sorted(both[0] + both[1]) == ["tests/test_a.py", "tests/test_b.py", "tests/test_c.py"]
    for bad in ("0/2", "3/2", "x", "1/0"):
        assert run(bad, "tests/test_a.py").returncode == 2
    assert run("--weights", "nothing", "1/2", "tests/test_a.py").returncode == 2
    assert run("--weights", "tsan", "1/1", "tests/test_a.py").stdout.split() == ["tests/test_a.py"]
