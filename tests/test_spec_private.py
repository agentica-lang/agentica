"""`private` in a module file and in a module block (docs/grammar/05b-modules.md), through the CLI.

Each case is a folder of files checked with `--json check` on main.agc: a program that is refused gives its code and
the start of its span; message and help text are not asserted (AGENTS.md), only whether a help is there. A file or
block with a `private` line makes everything above it public and everything after it private; one without keeps the
rule of `export`.
"""
import json

import pytest

from tests.agentica_test import cli, run
from tests.spec_support import check_many

LIB = """## A library with a public part and a private part.

LIMIT = 10

struct Box
  value: Int
end

enum Shape
  Dot
  Line(Int)
end

type Boxes = List[Box]

module Counter
  def start() -> Int = step(1) + helper(0)

  private

  def step(n: Int) -> Int = n
end

def open(value: Int) -> Box = Box(value: value)

def size(boxes: Boxes) -> Int = boxes.size + helper(BUFFER)

def make(n: Int) -> Secret = Secret(n: n)

def reveal(secret: Secret) -> Int = secret.n

private

BUFFER = 4096

struct Secret
  n: Int
end

enum State
  Idle
end

type Waits = List[Secret]

module Hidden
  export def twice(x: Int) -> Int = x * 2
end

def helper(x: Int) -> Int = x + 1
"""

USES_PUBLIC = """import L from "lib"
import {LIMIT, Box, Shape, Boxes, open, size, make, reveal, Counter} from "lib"

def main() -> Void
  boxes: Boxes = [open(L.LIMIT)]
  shape: L.Shape = Shape.Line(2)
  box: L.Box = L.open(LIMIT)
  puts("#{size(boxes)} #{L.size([box])} #{shape} #{reveal(make(1))} #{L.reveal(L.make(2))}")
  puts("#{Counter.start()} #{L.Counter.start()} #{box.value} #{Box(value: 1).value}")
end
"""


def program(main, lib=LIB, **more):
    return {"main.agc": main, "lib.agc": lib, **more}


def importing(name):
    return f'import {{{name}}} from "lib"\n\ndef main() -> Void\n  puts(1)\nend\n'


def calling(expression):
    return f'import L from "lib"\n\ndef main() -> Void\n  puts({expression})\nend\n'


FACADE = """import L from "lib"

export L.open

def wrap() -> Int = L.size([])

private

def inner() -> Int = 1
"""

# (name, program, code or None, (line, column) of the span start, whether a help is due)
CASES = [
    ("public names by alias and by name", program(USES_PUBLIC), None, None, False),
    ("a private constant by name", program(importing("BUFFER")), "CHECK-IMPORT-NAME", (1, 9), True),
    ("a private struct by name", program(importing("Secret")), "CHECK-IMPORT-NAME", (1, 9), True),
    ("a private enum by name", program(importing("State")), "CHECK-IMPORT-NAME", (1, 9), True),
    ("a private type alias by name", program(importing("Waits")), "CHECK-IMPORT-NAME", (1, 9), True),
    ("a private function by name", program(importing("helper")), "CHECK-IMPORT-NAME", (1, 9), True),
    ("a private block by name", program(importing("Hidden")), "CHECK-IMPORT-NAME", (1, 9), True),
    ("a private function by alias", program(calling("L.helper(1)")), "CHECK-IMPORT-NAME", (4, 8), True),
    ("a private constant by alias", program(calling("L.BUFFER")), "CHECK-IMPORT-NAME", (4, 8), True),
    ("a private name of a public block", program(calling("L.Counter.step(1)")), "CHECK-IMPORT-NAME", (4, 8), True),
    ("a private block by alias", program(calling("L.Hidden.twice(1)")), "CHECK-IMPORT-NAME", (4, 8), True),
    ("a private type in a public signature",
     program('import L from "lib"\n\ndef main() -> Void\n  secret: L.Secret = L.make(1)\n  puts(1)\nend\n'),
     "CHECK-IMPORT-NAME", (4, 11), True),
    ("a re-export above private",
     program('import F from "facade"\n\ndef main() -> Void\n  puts("#{F.open(1).value} #{F.wrap()}")\nend\n',
             **{"facade.agc": FACADE}), None, None, False),
    ("a name the facade only imports",
     program('import F from "facade"\n\ndef main() -> Void\n  puts(F.size([]))\nend\n', **{"facade.agc": FACADE}),
     "CHECK-IMPORT-NAME", (4, 8), True),
    ("a private name of the facade",
     program('import {inner} from "facade"\n\ndef main() -> Void\n  puts(1)\nend\n', **{"facade.agc": FACADE}),
     "CHECK-IMPORT-NAME", (1, 9), True),
    ("a re-export after private",
     program('import F from "facade"\n\ndef main() -> Void\n  puts(1)\nend\n',
             **{"facade.agc": 'import L from "lib"\n\ndef wrap() -> Int = 1\n\nprivate\n\nexport L.open\n'}),
     "CHECK-DECL-ORDER", (7, 1), True),
    ("a private name of a block in its own file",
     "module Counter\n  def start() -> Int = step()\n\n  private\n\n  def step() -> Int = 1\nend\n\n"
     "def main() -> Void\n  puts(Counter.step())\nend\n", "CHECK-IMPORT-NAME", (10, 8), True),
    ("a file without private keeps the export rule",
     program(calling("L.a()"), "LIMIT = 1\n\ndef a() -> Int = 1\n"), "CHECK-IMPORT-NAME", (4, 8), True),
    ("a file without private exports its export declarations",
     program(calling("L.a()"), "export def a() -> Int = 1\n"), None, None, False),
    ("a private std name keeps its code",
     'import Queue from "std/queue"\n\ndef main() -> Void\n  puts(Queue.no_such_name())\nend\n',
     "CHECK-IMPORT-NAME", (4, 8), False),
    ("export above private", "export def a() -> Int = 1\n\nprivate\n\ndef main() -> Void\n  puts(a())\nend\n",
     "PARSE-UNEXPECTED-TOKEN", (1, 1), True),
    ("export after private", "def a() -> Int = 1\n\nprivate\n\nexport LIMIT = 1\n\ndef main() -> Void\n  puts(a())\nend\n",
     "PARSE-UNEXPECTED-TOKEN", (5, 1), True),
    ("export in a block with private",
     "module X\n  export def a() -> Int = 1\n\n  private\n\n  def b() -> Int = 1\nend\n\n"
     "def main() -> Void\n  puts(X.a())\nend\n", "PARSE-UNEXPECTED-TOKEN", (2, 3), True),
    ("export module in a file with private",
     "export module X\n  export def a() -> Int = 1\nend\n\nprivate\n\ndef main() -> Void\n  puts(X.a())\nend\n",
     "PARSE-UNEXPECTED-TOKEN", (1, 1), True),
    ("a second private", "def a() -> Int = 1\n\nprivate\n\ndef main() -> Void\n  puts(a())\nend\n\nprivate\n",
     "PARSE-SECOND-PRIVATE", (9, 1), True),
    ("private needs a blank line before", "def a() -> Int = 1\nprivate\n\ndef main() -> Void\n  puts(a())\nend\n",
     "PARSE-MISSING-BLANK-LINE", (2, 1), False),
    ("private needs a blank line after", "def a() -> Int = 1\n\nprivate\ndef main() -> Void\n  puts(a())\nend\n",
     "PARSE-MISSING-BLANK-LINE", (4, 1), False),
    ("private before a def on its line", "private def a() -> Int = 1\n\ndef main() -> Void\n  puts(a())\nend\n",
     "PARSE-TOP-LEVEL-STATEMENT", (1, 1), True),
    ("private is a plain name in a body",
     "def private() -> Int = 1\n\ndef main() -> Void\n  private = 2\n  puts(private + private())\nend\n",
     None, None, False),
    ("a constant after a public function",
     "def a() -> Int = 1\n\nLIMIT = 2\n\nprivate\n\ndef main() -> Void\n  puts(a())\nend\n",
     "CHECK-DECL-ORDER", (3, 1), True),
    ("a private struct after a private function",
     "private\n\nLIMIT = 2\n\ndef main() -> Void\n  puts(LIMIT)\nend\n\nstruct T\n  b: Int\nend\n",
     "CHECK-DECL-ORDER", (9, 1), True),
    ("an import after private", 'private\n\nimport L from "lib"\n\ndef main() -> Void\n  puts(L.LIMIT)\nend\n',
     "CHECK-DECL-ORDER", (3, 1), True),
    ("each part in order",
     "LIMIT = 1\n\nstruct S\n  a: Int\nend\n\ndef a() -> Int = LIMIT\n\nprivate\n\nBUFFER = 2\n\n"
     "struct T\n  b: Int\nend\n\ndef main() -> Void\n  puts(a() + BUFFER)\nend\n", None, None, False),
]


@pytest.fixture(scope="module")
def checked(tmp_path_factory):
    return check_many([case[1] for case in CASES], tmp_path_factory.mktemp("private"))


@pytest.mark.parametrize("name, files, code, start, helped", CASES, ids=[case[0] for case in CASES])
def test_private_rule(checked, name, files, code, start, helped):
    problem = checked(files)
    if code is None:
        assert problem is None, problem
        return
    assert problem is not None, name
    assert problem["code"] == code
    found = problem["range"]["start"]
    assert (found["line"], found["column"]) == start
    assert bool(problem.get("help")) == helped, problem


def test_a_program_with_private_runs_and_formats_to_itself(tmp_path):
    (tmp_path / "lib.agc").write_text(LIB, encoding="utf-8")
    (tmp_path / "main.agc").write_text(USES_PUBLIC, encoding="utf-8")
    result = run(cli() + [str(tmp_path / "main.agc")], cwd=tmp_path)
    assert result.code == 0, result.stderr
    assert result.stdout == "4098 4098 Shape.Line(2) 1 2\n2 2 10 1\n"
    formatted = run(cli() + ["fmt", "--check", str(tmp_path / "lib.agc")], cwd=tmp_path)
    assert formatted.code == 0, formatted.stdout + formatted.stderr


def test_doc_and_outline_show_the_part_above_private_as_the_api(tmp_path):
    (tmp_path / "lib.agc").write_text(LIB, encoding="utf-8")
    documented = run(cli() + ["doc", str(tmp_path / "lib.agc"), "--json"], cwd=tmp_path)
    assert documented.code == 0, documented.stderr
    outlined = run(cli() + ["outline", str(tmp_path / "lib.agc"), "--json"], cwd=tmp_path)
    assert outlined.code == 0, outlined.stderr
    api = [item["name"] for item in json.loads(documented.stdout)["items"]]
    assert api == ["LIMIT", "Box", "Shape", "Boxes", "Counter", "open", "size", "make", "reveal"]
    exported = {item["name"]: item["exported"] for item in json.loads(outlined.stdout)["items"]}
    assert [name for name, public in exported.items() if public] == api
    assert not any(exported[name] for name in ("BUFFER", "Secret", "State", "Waits", "Hidden", "helper"))
