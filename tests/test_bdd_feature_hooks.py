"""The feature hooks of `std/bdd` (`BDD.run(steps, hooks:)`), through `agentica test`.

The hook starts a Python peer (tests/fixtures/bdd-feature-peer.py), a counter over HTTP that logs each start, and the
steps talk to it by the port that `before_all` returned. Marks in a file give the order of the hooks; the peer's log
gives its starts and pids, so a test can tell that a server was started once and is gone after its feature.
"""
import tempfile
from pathlib import Path

import pytest

from tests.agentica_test import FIXTURES, PYTHON, agc_literal, cli, process_alive, run, vm_environment, wait_until, write_files

STEPS = """\
import BDD from "std/bdd"
import HTTP from "std/http"

def mark(name: String, text: String) -> Void
  File.append_text("marks.log", "#{name} #{text}\\n", 5000).unwrap!
end

def start(feature: BDD.Feature) -> Result[JSON.Value]
  p = try Process.spawn(%(python)s, [%(peer)s, "peer.log"], Process.Options(timeout_ms: 20000))
  port = try Process.read_line(p, 5000)
  %(before)s
  mark("before_all", feature.name)
  ok(JSON.object({"port": JSON.from(port.to_i!)}))
end

def stop(feature: BDD.Feature, state: JSON.Value) -> Result[Void]
  mark("after_all", feature.name)
  %(after)s
  ok()
end

def url(ctx: BDD.Context, path: String) -> String
  port = JSON.int(JSON.get(BDD.feature_state(ctx), "port").unwrap!).unwrap!
  "http://127.0.0.1:#{port}#{path}"
end

def hit(ctx: BDD.Context, path: String) -> Int
  answer = HTTP.get_response(url(ctx, path)).unwrap!
  HTTP.text(answer.body).unwrap!.to_i!
end

def main() -> Void
  BDD.run([
    BDD.step("the server is reset") do |ctx, _args|
      _ = hit(ctx, "/reset")
      ctx
    end,
    BDD.step("I hit the server") do |ctx, _args|
      _ = hit(ctx, "/hit")
      ctx
    end,
    BDD.step("the server counted {int}") do |ctx, args|
      counted = hit(ctx, "/count")
      BDD.assert(ctx, counted == args[0].to_i!, "counted #{counted}")
    end,
  ], hooks: some(BDD.Hooks(before_all: &start, after_all: &stop)))
end
"""

TWO_HITS = "Scenario: %s\nGiven the server is reset\nWhen I hit the server\nAnd I hit the server\nThen the server counted 2\n"
ONE_HIT = "Scenario: %s\nGiven the server is reset\nWhen I hit the server\nThen the server counted 1\n"
NO_HIT = "Scenario: %s\nGiven the server is reset\nThen the server counted 5\n"


def feature(name, *scenarios):
    return "Feature: %s\n%s" % (name, "\n".join(scenarios))


class Suite:
    def __init__(self, tmp_path, before="", after=""):
        self.directory = Path(tempfile.mkdtemp(prefix="agentica-bdd-hooks-", dir=tmp_path)).resolve()
        self.tmp = tmp_path
        steps = STEPS % {"python": agc_literal(PYTHON), "peer": agc_literal(FIXTURES / "bdd-feature-peer.py"),
                         "before": before, "after": after}
        write_files(self.directory, {"steps.agc": steps})

    def add(self, **features):
        write_files(self.directory, {name + ".feature": text for name, text in features.items()})

    def run(self, *flags, names):
        paths = [self.directory / (name + ".feature") for name in names]
        env = {"TMPDIR": tempfile.mkdtemp(prefix="agentica-bdd-run-tmp-", dir=self.tmp)}
        result = run(cli() + ["test", "--json", "--steps", self.directory / "steps.agc", *flags, *paths],
                     env=vm_environment(env), cwd=self.directory)
        assert result.stderr == "", result
        return result.code, result.json()

    def marks(self):
        path = self.directory / "marks.log"
        return path.read_text(encoding="utf-8").splitlines() if path.exists() else []

    def peers(self):
        path = self.directory / "peer.log"
        lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
        return [int(line.split()[2]) for line in lines]

    def assert_peers_gone(self):
        for pid in self.peers():
            assert wait_until(lambda: not process_alive(pid)), "the server %d is still running" % pid


def statuses(report, name):
    return {file["path"].rsplit("/", 1)[-1]: [case["status"] for case in file["scenarios"]] for file in report["files"]}[name]


def test_a_feature_starts_one_server_for_its_scenarios_resets_it_between_them_and_stops_it_after_them(tmp_path):
    suite = Suite(tmp_path)
    suite.add(one=feature("one", TWO_HITS % "a", ONE_HIT % "b", TWO_HITS % "c"), two=feature("two", ONE_HIT % "d"))
    code, report = suite.run(names=["one", "two"])
    assert code == 0, report
    assert statuses(report, "one.feature") == ["passed"] * 3 and statuses(report, "two.feature") == ["passed"]
    assert suite.marks() == ["before_all one", "after_all one", "before_all two", "after_all two"]
    assert len(suite.peers()) == 2
    suite.assert_peers_gone()


def test_a_failed_scenario_ends_its_worker_and_the_next_one_gets_a_server_of_its_own(tmp_path):
    suite = Suite(tmp_path)
    suite.add(bad=feature("bad", NO_HIT % "x", ONE_HIT % "y", ONE_HIT % "z"))
    code, report = suite.run(names=["bad"])
    assert code == 1
    assert statuses(report, "bad.feature") == ["failed", "passed", "passed"]
    assert suite.marks() == ["before_all bad", "before_all bad", "after_all bad"]
    assert len(suite.peers()) == 2
    suite.assert_peers_gone()


@pytest.mark.parametrize("before", ['return error("no server")', "_boom = 1 / (feature.name.length - 3)"],
                         ids=["an error", "a crash"])
def test_a_failing_before_all_fails_its_scenario_at_the_step_and_leaves_the_others_of_the_feature_not_executed(
        tmp_path, before):
    suite = Suite(tmp_path, before="if feature.name == \"bad\"\n    %s\n  end" % before)
    suite.add(bad=feature("bad", ONE_HIT % "x", ONE_HIT % "y"), good=feature("good", ONE_HIT % "z"))
    code, report = suite.run(names=["bad", "good"])
    assert code == 1
    assert statuses(report, "bad.feature") == ["failed", "not_executed"]
    assert statuses(report, "good.feature") == ["passed"]
    problem = report["files"][0]["scenarios"][0]["error"]
    assert problem["code"] == "RUNTIME-BDD-BEFORE-ALL"
    assert (problem["range"]["start"]["line"], problem["range"]["start"]["column"]) == (3, 1)
    assert suite.marks() == ["before_all good", "after_all good"]
    suite.assert_peers_gone()


@pytest.mark.parametrize("after", ['return error("cannot clean")', "_boom = 1 / (feature.name.length - 3)"],
                         ids=["an error", "a crash"])
def test_a_failing_after_all_is_an_error_of_the_feature_file_at_its_feature_line(tmp_path, after):
    suite = Suite(tmp_path, after="if feature.name == \"one\"\n    %s\n  end" % after)
    suite.add(one=feature("one", ONE_HIT % "a"))
    code, report = suite.run(names=["one"])
    assert code == 1
    assert statuses(report, "one.feature") == ["passed"]
    problem = report["files"][0]["error"]
    assert problem["code"] == "RUNTIME-BDD-AFTER-ALL"
    assert (problem["range"]["start"]["line"], problem["range"]["end"]["column"]) == (1, 13)
    suite.assert_peers_gone()


def test_each_job_lane_sets_a_feature_up_and_each_isolated_scenario_does(tmp_path):
    suite = Suite(tmp_path)
    suite.add(one=feature("one", ONE_HIT % "a", ONE_HIT % "b"), two=feature("two", ONE_HIT % "c"))
    code, report = suite.run("--jobs", "2", names=["one", "two"])
    assert code == 0, report
    assert sorted(suite.marks()).count("before_all two") == 1 and sorted(suite.marks()).count("after_all two") == 1
    assert 2 <= len(suite.peers()) <= 3
    suite.assert_peers_gone()
    isolated = Suite(tmp_path)
    isolated.add(one=feature("one", ONE_HIT % "a", ONE_HIT % "b"))
    code, report = isolated.run("--isolate", names=["one"])
    assert code == 0, report
    assert isolated.marks() == ["before_all one", "after_all one"] * 2
    isolated.assert_peers_gone()
