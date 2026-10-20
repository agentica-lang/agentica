"""Programs of several files, run with the product CLI.

Each case writes a few modules into a temporary folder and runs the root program with `--json`, or runs a CLI command
that shows how imports resolve. The diagnostics of the linker and the checker for such programs are tested through
`check` in the tests/test_spec_*.py modules and the frozen goldens. The cases run on dist/agentica, or on the
executable that AGENTICA_TEST_EXECUTABLE names.
"""
import itertools
import json
import os
import shutil
from pathlib import Path

import pytest

from tests.agentica_test import ROOT, cli, report_cases, run, vm_environment

EXAMPLE = ROOT / "examples" / "json-modules.agc"


@pytest.fixture
def workspace(tmp_path):
    """The writer of a fresh folder of modules (name -> text) for each call; the original gave each call its own dir."""
    count = itertools.count()

    def write(files):
        directory = (tmp_path / ("modules-%d" % next(count))).resolve()
        for name, text in files.items():
            path = directory / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text, encoding="utf-8")
        return directory

    return write


@pytest.fixture
def scratch(tmp_path):
    """A folder to run in that holds none of the program's files."""
    directory = (tmp_path / "cwd").resolve()
    directory.mkdir()
    return directory


def agentica(scratch, *arguments, env=None, cwd=None):
    return run(cli() + [str(argument) for argument in arguments], env=vm_environment(env), cwd=cwd or scratch)


def run_root(scratch, directory, name="root.agc", max_steps=None, env=None):
    """Run a program; returns (stdout, the JSON diagnostic of a failed run or None, stderr)."""
    arguments = ["--json"] + (["--max-steps", str(max_steps)] if max_steps else []) + [directory / name]
    result = agentica(scratch, *arguments, env=env)
    if result.code == 0:
        return result.stdout, None, result.stderr
    return result.stdout, json.loads(result.stderr.strip().split("\n")[-1]), result.stderr


def output_of(workspace, scratch, files, name="root.agc", env=None):
    """The stdout of a program that runs to its end."""
    out, problem, errors = run_root(scratch, workspace(files), name, env=env)
    assert problem is None, errors
    return out


def test_methods_work_on_values_whose_types_come_from_another_file(workspace, scratch):
    assert output_of(workspace, scratch, {
        "lib.agc": "export struct Box\n  label: String\nend\n\nexport def make(text: String) -> Box\n  return Box(label: text)\nend\n\n",
        "root.agc": "import Lib from \"lib\"\ndef main() -> Void\n  b = Lib.make(\" hi \")\n  IO.inspect(b.label.strip.upcase.size)\nend\n\n"}) == "2\n"


def test_blocks_in_an_imported_file_call_that_files_private_helpers_and_types(workspace, scratch):
    assert output_of(workspace, scratch, {
        "lib.agc": "struct Pair\n  n: Int\nend\n\nexport def doubled(xs: List[Int]) -> List[Int]\n  pairs = xs.map do |x| Pair(n: twice(x)) end\n  return pairs.map do |p: Pair| p.n end\nend\n\ndef twice(n: Int) -> Int\n  return n * 2\nend\n\n",
        "root.agc": "import Lib from \"lib\"\ndef main() -> Void\n  IO.inspect(Lib.doubled([1, 2]))\nend\n\n"}) == "[2, 4]\n"


def test_interpolation_in_an_imported_function_reaches_that_files_private_helpers(workspace, scratch):
    assert output_of(workspace, scratch, {
        "lib.agc": "export def label(n: Int) -> String\n  return \"n=#{twice(n)}\"\nend\n\ndef twice(n: Int) -> Int\n  return n * 2\nend\n\n",
        "root.agc": "import Lib from \"lib\"\ndef main() -> Void\n  puts(Lib.label(3))\nend\n\n"}) == "n=6\n"


def test_the_embedded_string_queue_preserves_fifo_and_old_values_without_local_std_files(workspace, scratch):
    directory = workspace({
        "std/queue.agc": "this local file must not be loaded\n",
        "root.agc": "import Queue from \"std/queue\"\nimport Again from \"std/queue\"\ndef main() -> Void\n  original = Queue.new()\n  q: Again.QueueState = Queue.push(original, \"\")\n  q = Queue.push(q, \"same\")\n  q = Queue.push(q, \"same\")\n  IO.inspect(Queue.size(q))\n  IO.inspect(Queue.empty?(original))\n  IO.inspect(not Result.ok?(Queue.pop(original)))\n  IO.inspect(not Result.ok?(Queue.peek(original)))\n  IO.inspect(Result.unwrap!(Queue.peek(q)))\n  while not Queue.empty?(q)\n    item = Result.unwrap!(Queue.pop(q))\n    puts(item.value)\n    q = item.remaining\n  end\n  IO.inspect(Queue.size(q))\nend\n\n"})
    expected = "3\ntrue\ntrue\ntrue\n\"\"\n\nsame\nsame\n0\n"
    assert run_root(scratch, directory)[0] == expected
    # Without --json, as a user runs it, from a folder that has no std/ either.
    plain = agentica(scratch, directory / "root.agc")
    assert (plain.code, plain.stdout, plain.stderr) == (0, expected, "")


def test_pkg_roots_search_project_environment_then_user_data_independent_of_cwd(workspace, scratch):
    directory = workspace({
        "root.agc": "import Value from \"pkg/value\"\ndef main() -> Void\n  puts(Value.read())\nend\n\n",
        "agc_libs/value.agc": "export def read() -> String\n  return \"project\"\nend\n\n",
        "first/value.agc": "import Helper from \"helper\"\nexport def read() -> String\n  return Helper.read()\nend\n\n",
        "first/helper.agc": "export def read() -> String\n  return \"first\"\nend\n\n",
        "second/value.agc": "export def read() -> String\n  return \"second\"\nend\n\n",
        "data/agentica/lib/value.agc": "export def read() -> String\n  return \"user\"\nend\n\n"})
    env = {"AGENTICA_PATH": os.pathsep.join(str(directory / name) for name in ["absent", "first", "second"]),
           "XDG_DATA_HOME": str(directory / "data")}
    for expected, removed in [("project\n", "agc_libs"), ("first\n", "first"), ("second\n", "second"),
                              ("user\n", None)]:
        out, problem, errors = run_root(scratch, directory, env=env)
        assert problem is None, errors
        assert out == expected
        if removed:
            shutil.rmtree(directory / removed)


def test_imports_share_canonical_identities_and_resolve_relative_to_each_file(workspace, scratch):
    assert output_of(workspace, scratch, {
        "library/models.agc": "export struct Value\n  n: Int\nend\n\nexport def read(value: Value) -> Int\n  return value.n\nend\n\ndef main() -> Void\n  puts(\"must not run\")\nend\n\n",
        "library/outer.agc": "import Models from \"models\"\nexport def make(n: Int) -> Models.Value\n  return Models.Value(n: n)\nend\n\n",
        "root.agc": "import First from \"library/models\"\nimport Second from \"library/../library/models\"\nimport Outer from \"library/outer\"\ndef main() -> Void\n  value: Second.Value = Outer.make(42)\n  IO.inspect(First.read(value))\n  IO.inspect(Second.read(First.Value(n: 7)))\nend\n\n"}) == "42\n7\n"


def test_private_helpers_and_same_names_in_different_modules_stay_separate(workspace, scratch):
    assert output_of(workspace, scratch, {
        "a.agc": "export def apply(n: Int) -> Int\n  return helper(n)\nend\n\ndef helper(n: Int) -> Int\n  return n + 1\nend\n\n",
        "b.agc": "export def apply(n: Int) -> Int\n  return helper(n)\nend\n\ndef helper(n: Int) -> Int\n  return n + 10\nend\n\n",
        "root.agc": "import A from \"a\"\nimport B from \"b\"\ndef main() -> Void\n  IO.inspect(List.map([1, 2], &A.apply))\n  IO.inspect(List.map([1, 2], &B.apply))\nend\n\n"}) == "[2, 3]\n[11, 12]\n"


def test_imported_structs_and_enums_print_their_declared_names(workspace, scratch):
    directory = workspace({
        "a.agc": "export struct Point\n  x: Int\nend\n\nexport enum Shape\n  Dot(Point)\n  Empty\nend\n\nexport def show() -> Void\n  puts(\"#{Point(x: 2)} #{Shape.Empty}\")\nend\n\n",
        "b.agc": "export struct Point\n  y: Int\nend\n\n",
        "root.agc": "import A from \"a\"\nimport B from \"b\"\n\nstruct Both\n  a: A.Point\n  b: B.Point\nend\n\ndef main() -> Void\n  A.show()\n  p = A.Point(x: 3)\n  puts(p)\n  puts(B.Point(y: 4).inspect)\n  puts([A.Shape.Dot(p)].to_s)\n  puts({\"k\": ok(A.Shape.Empty)})\n  IO.warn(p)\n  IO.warn(JSON.schema(Both))\nend\n\n"})
    out, problem, errors = run_root(scratch, directory)
    assert problem is None, errors
    assert out == "Point(x: 2) Shape.Empty\nPoint(x: 3)\nPoint(y: 4)\n[Shape.Dot(Point(x: 3))]\n{\"k\": ok(Shape.Empty)}\n"
    warnings = errors.strip().split("\n")
    assert warnings[0] == "Point(x: 3)"
    assert len(json.loads(warnings[1])["$defs"]) == 2


def test_import_paths_name_modules_without_an_extension(workspace, scratch):
    assert output_of(workspace, scratch, {
        "lib/util.agc": "export def read() -> String\n  return \"util\"\nend\n\n",
        "app/root.agc": "import Util from \"../lib/util\"\ndef main() -> Void\n  puts(Util.read())\nend\n\n"}, "app/root.agc") == "util\n"


def test_nullary_variants_need_no_parentheses_locally_and_through_an_alias(workspace, scratch):
    assert output_of(workspace, scratch, {
        "shapes.agc": "export enum Shape\n  Dot\n  Box(Int)\nend\n\n",
        "root.agc": "import S from \"shapes\"\n\nenum Command\n  Show\n  Add(Int)\nend\n\ndef main() -> Void\n  c = Command.Show\n  case c\n    Command.Show -> puts(\"show\")\n    Command.Add(n) -> puts(n.to_s)\n  end\n  s = S.Shape.Dot\n  case s\n    S.Shape.Dot -> puts(\"dot\")\n    _ -> puts(\"other\")\n  end\nend\n\n"}) == "show\ndot\n"


def test_a_struct_update_follows_the_rules_of_construction_across_files(workspace, scratch):
    # An exported struct can be updated by an importer; a module may update its own private structs.
    assert output_of(workspace, scratch, {
        "lib.agc": "export struct Box\n  label: String\n  size: Int\nend\n\nstruct Hidden\n  n: Int\nend\n\nexport def make() -> Box\n  return Box(label: \"a\", size: 1)\nend\n\nexport def grow(b: Box) -> Box\n  return b.with(size: b.size + 1)\nend\n\nexport def hidden() -> Hidden\n  return Hidden(n: 1).with(n: 2)\nend\n\n",
        "root.agc": "import Lib from \"lib\"\n\ndef main() -> Void\n  b = Lib.make().with(label: \"b\")\n  puts(Lib.grow(b))\n  puts(Lib.hidden().n)\nend\n\n"}) == "Box(label: \"b\", size: 2)\n2\n"
    # A builtin record of std/http is updated without importing a module that declares it.
    assert output_of(workspace, scratch, {
        "root.agc": "import Http from \"std/http\"\n\ndef main() -> Void\n  o = Http.client_options()\n  p = o.with(timeout_ms: 5000, ca_file: \"ca.pem\")\n  puts(p.timeout_ms)\n  puts(o.timeout_ms)\nend\n\n"}) == "5000\n30000\n"
    # Alias.with(...) is a call of the module's function named with, not an update.
    assert output_of(workspace, scratch, {
        "lib.agc": "export def with(n: Int) -> Int\n  return n + 1\nend\n\n",
        "root.agc": "import Lib from \"lib\"\n\ndef main() -> Void\n  puts(Lib.with(1))\nend\n\n"}) == "2\n"


def test_a_runtime_failure_in_a_dependency_keeps_the_original_file_span(workspace, scratch):
    directory = workspace({
        "root.agc": "import A from \"a\"\ndef main() -> Void\n  IO.inspect(A.fail(0))\nend\n\n",
        "a.agc": "export def fail(n: Int) -> Int\n  return 1 / n\nend\n\n"})
    _out, problem, errors = run_root(scratch, directory)
    assert problem is not None, errors
    assert problem["code"] == "RUNTIME-DIVISION-BY-ZERO"
    assert problem["range"]["start"]["line"] == 2
    assert Path(problem["file"]) == directory / "a.agc"


def test_imported_task_callbacks_keep_the_execution_budget(workspace, scratch):
    directory = workspace({
        "root.agc": "import Worker from \"worker\"\ndef main() -> Void\n  task = Task.spawn(&Worker.run, 0)\n  IO.inspect(Task.await(task))\nend\n\n",
        "worker.agc": "export def run(n: Int) -> Int\n  while n < 100\n    n = n + 1\n  end\n  return n\nend\n\n"})
    out, problem, errors = run_root(scratch, directory)
    assert problem is None, errors
    assert out == "100\n"
    _out, limited, _errors = run_root(scratch, directory, max_steps=30)
    assert limited["code"] == "RUNTIME-STEP-LIMIT"


def test_a_bdd_step_program_imports_its_handlers_which_share_std_bdd(workspace, scratch):
    directory = workspace({
        "steps.agc": "import BDD from \"std/bdd\"\nimport Assertions from \"assertions\"\n\ndef main() -> Void\n  BDD.run([BDD.step(\"it works\", &Assertions.verify)])\nend\n\n",
        "assertions.agc": "import Spec from \"std/bdd\"\nimport Queue from \"std/queue\"\n\nexport def verify(ctx: Spec.Context, args: List[String]) -> Spec.Context\n  q = Queue.push(Queue.new(), \"imported handler\")\n  return Spec.assert(ctx, Result.unwrap!(Queue.peek(q)) == \"imported handler\", \"imported handler\")\nend\n\n",
        "test.feature": "Feature: Modules\nScenario: Imported handler\nThen it works\n"})
    result = agentica(scratch, "test", "--json", directory / "test.feature", "--steps", directory / "steps.agc")
    assert result.code == 0, result.stderr
    report = json.loads(result.stdout)
    assert report["ok"] is True
    assert len(report_cases(report)) == 1


def test_the_combined_json_module_example_runs_through_the_cli(scratch):
    result = agentica(scratch, EXAMPLE)
    assert result.code == 0
    assert result.stderr == ""
    lines = result.stdout.split("\n")
    assert json.loads(lines[0]) == {"result": 42}
    assert lines[1] == "[2, 4]"
    assert json.loads(lines[2])["required"] == ["left", "right"]


def test_imported_generic_enums_resolve_constructors_and_exhaustive_patterns(workspace, scratch):
    assert output_of(workspace, scratch, {
        "option.agc": "export enum Option[T]\n  Some(T)\n  None\nend\n\n",
        "root.agc": "import Domain from \"option\"\ndef main() -> Void\n  value: Domain.Option[Int] = Domain.Option.Some(7)\n  case value do\n    Domain.Option.Some(item) ->\n      puts(String.from_int(item))\n    Domain.Option.None ->\n      puts(\"empty\")\n  end\n  empty: Domain.Option[String] = Domain.Option.None()\n  case empty do\n    Domain.Option.Some(item) ->\n      puts(item)\n    Domain.Option.None ->\n      puts(\"none\")\n  end\nend\n\n"}) == "7\nnone\n"


def test_help_does_not_know_the_internal_http_wire_builtins(scratch):
    for arguments in [["help", "HttpWire.service"], ["help", "HttpWire.jobs", "--json"], ["help", "HttpWire.servic"]]:
        result = agentica(scratch, *arguments)
        assert result.code == 2, str(arguments)
        assert result.stderr == "agentica: unknown builtin %s\n" % arguments[1]
