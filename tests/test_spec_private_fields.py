"""`private` in a struct body (docs/grammar/05-syntax.md and 06-semantics.md), through the CLI.

Each case is checked with `--json check` on main.agc: a program that is refused gives its code and the start and end
of its span; message and help text are not asserted (AGENTS.md). The fields after the `private` line belong to the
module that declares the struct (its file, or its module block): outside it they cannot be read, given in a
constructor, set with `with` or reach a JSON codec, and the struct cannot be built.
"""
import json
import os

import pytest

from tests.agentica_test import cli, run
from tests.spec_support import check_many

LIB = """## A connection.
struct Conn
  id: Int
  peer: String

  private

  ## The socket.
  secret: String
  timeout_ms: Int = 5
end

struct Job
  name: String

  private

  run: Fn[Int, Int]
end

enum Slot
  Empty
  Held(Conn)
end

struct Box[T]
  label: String

  private

  value: T
end

def open(id: Int) -> Conn = Conn(id: id, peer: "p", secret: "s#{id}")

def secret_of(c: Conn) -> String = c.with(secret: c.secret + "!", timeout_ms: 1).secret

def codec() -> Codec[Conn] = Conn.codec

def encode(c: Conn) -> String = JSON.encode(c) + Conn.members.size.to_s

def job() -> Job = Job(name: "j", run: ->(x: Int) { x + 1 })

def box[T](value: T) -> Box[T] = Box(label: "b", value: value)

def dump[T](value: T) -> String = JSON.encode(value)
"""

USES = """import L from "lib"

def main() -> Void
  c = L.open(1)
  ch: Channel[L.Conn] = Channel.new(1)
  ch.send(c, 1000).unwrap!
  got = ch.recv(1000).unwrap!
  stored = {"a": [got]}
  puts("#{c.id} #{c.peer} #{c.with(peer: "q").peer} #{L.secret_of(c)} #{stored["a"][0] == c}")
  puts(L.encode(c))
  puts(L.codec().decode("{\\"id\\":2,\\"peer\\":\\"x\\",\\"secret\\":\\"y\\",\\"timeout_ms\\":3}").unwrap!.inspect)
  puts("#{c} #{c.to_s == c.inspect}")
  puts(L.box(4).label + L.dump(c.peer))
end
"""

BLOCK = """module Net
  struct Sock
    fd: Int

    private

    key: String
  end

  def make() -> Sock = Sock(fd: 1, key: "k")

  def key_of(s: Sock) -> String = s.with(key: "z").key + JSON.encode(s) + Sock.codec.members.size.to_s
end

def main() -> Void
  s = Net.make()
  puts(Net.key_of(s) + s.fd.to_s)
  %s
end
"""


# A struct at the top of a file, which the file's blocks see whole, and one inside a block, which the other blocks of
# the file do not.
FILE_STRUCT = """struct Conn
  id: Int

  private

  secret: String
end

module Inner
  struct Key
    id: Int

    private

    key: String
  end

  def make() -> Key = Key(id: 1, key: "k")
end

module Pool
  def peek(c: Conn) -> String = %s
end

def main() -> Void
  puts(Pool.peek(Conn(id: 1, secret: "s")))
end
"""


def outside(line):
    return {"main.agc": f'import L from "lib"\n\ndef main() -> Void\n  c = L.open(1)\n  {line}\nend\n', "lib.agc": LIB}


def block(line):
    return BLOCK % line


# (name, program, code or None, (line, column) of the span start, (line, column) of its end)
CASES = [
    ("the module's functions and the public fields", {"main.agc": USES, "lib.agc": LIB}, None, None, None),
    ("read", outside("puts(c.secret)"), "CHECK-PRIVATE-FIELD", (5, 10), (5, 16)),
    ("read of a private field with a default", outside("puts(c.timeout_ms)"), "CHECK-PRIVATE-FIELD", (5, 10), (5, 20)),
    ("construct naming a private field", outside('puts(L.Conn(id: 1, peer: "p", secret: "s").id)'),
     "CHECK-PRIVATE-FIELD", (5, 33), (5, 39)),
    ("construct without the private fields", outside('puts(L.Conn(id: 1, peer: "p").id)'),
     "CHECK-PRIVATE-FIELD", (5, 8), (5, 14)),
    ("with of a private field", outside('puts(c.with(secret: "s").id)'), "CHECK-PRIVATE-FIELD", (5, 15), (5, 21)),
    ("codec", outside("puts(L.Conn.codec.members.size)"), "CHECK-PRIVATE-FIELD", (5, 8), (5, 14)),
    ("members", outside("puts(L.Conn.members.size)"), "CHECK-PRIVATE-FIELD", (5, 8), (5, 14)),
    ("JSON.from", outside("puts(JSON.from(c))"), "CHECK-PRIVATE-FIELD", (5, 18), (5, 19)),
    ("JSON.schema", outside("puts(JSON.schema(L.Conn))"), "CHECK-PRIVATE-FIELD", (5, 20), (5, 26)),
    ("an enum payload", outside("puts(JSON.encode(L.Slot.Held(c)))"), "CHECK-PRIVATE-FIELD", (5, 20), (5, 34)),
    ("a call of an Fn field", outside("puts(L.job().run(1))"), "CHECK-PRIVATE-FIELD", (5, 16), (5, 19)),
    ("a typo names no private field", outside("puts(c.secrt)"), "CHECK-UNKNOWN-FIELD", (5, 8), (5, 15)),
    ("a typo in with names no private field", outside('puts(c.with(secrt: "s").id)'), "CHECK-UNKNOWN-FIELD",
     (5, 15), (5, 25)),
    ("JSON.encode", outside("puts(JSON.encode([c]))"), "CHECK-PRIVATE-FIELD", (5, 20), (5, 23)),
    ("JSON.decode", outside('puts(JSON.decode("{}", L.Conn).ok?)'), "CHECK-PRIVATE-FIELD", (5, 26), (5, 32)),
    ("a generic encoder of the module", outside("puts(L.dump(c))"), "CHECK-PRIVATE-FIELD", (5, 15), (5, 16)),
    ("a generic struct", outside("puts(L.box(1).value)"), "CHECK-PRIVATE-FIELD", (5, 17), (5, 22)),
    ("a module block from its own module", block("puts(s.fd)"), None, None, None),
    ("a module block: read", block("puts(s.key)"), "CHECK-PRIVATE-FIELD", (18, 10), (18, 13)),
    ("a module block: construct", block("puts(Net.Sock(fd: 1).fd)"), "CHECK-PRIVATE-FIELD", (18, 8), (18, 16)),
    ("a module block: with", block('puts(s.with(key: "k").fd)'), "CHECK-PRIVATE-FIELD", (18, 15), (18, 18)),
    ("a module block: encode", block("puts(JSON.encode(s))"), "CHECK-PRIVATE-FIELD", (18, 20), (18, 21)),
    ("a block reads a struct of its file", FILE_STRUCT % "c.secret", None, None, None),
    ("a struct of a block is private to the block", FILE_STRUCT % "Inner.make().key", "CHECK-PRIVATE-FIELD",
     (22, 53), (22, 56)),
    ("a re-export keeps the declaring module",
     {"main.agc": 'import F from "facade"\n\ndef main() -> Void\n  puts(F.open(1).secret)\nend\n', "lib.agc": LIB,
      "facade.agc": 'import L from "lib"\n\nexport L.Conn\nexport L.open\n'},
     "CHECK-PRIVATE-FIELD", (4, 18), (4, 24)),
    ("a field named private is public",
     "struct S\n  private: Int\n\n  private\n\n  hidden: Int = 0\nend\n\n"
     "def main() -> Void\n  puts(S(private: 1).private)\nend\n", None, None, None),
    ("private as the first and the last line",
     "struct A\n  private\n\n  a: Int\nend\n\nstruct B\n  b: Int\n\n  private\nend\n\n"
     "def main() -> Void\n  puts(A(a: 1).a + B(b: 2).b)\nend\n", None, None, None),
    ("a second private", "struct A\n  a: Int\n\n  private\n\n  b: Int\n\n  private\n\n  c: Int\nend\n",
     "PARSE-SECOND-PRIVATE", (8, 3), (8, 10)),
    ("private needs a blank line before", "struct A\n  a: Int\n  private\n\n  b: Int\nend\n",
     "PARSE-MISSING-BLANK-LINE", (3, 3), (3, 10)),
    ("private needs a blank line after", "struct A\n  a: Int\n\n  private\n  b: Int\nend\n",
     "PARSE-MISSING-BLANK-LINE", (5, 3), (5, 4)),
]


@pytest.fixture(scope="module")
def checked(tmp_path_factory):
    return check_many([case[1] for case in CASES], tmp_path_factory.mktemp("private-fields"))


@pytest.mark.parametrize("name, files, code, start, stop", CASES, ids=[case[0] for case in CASES])
def test_private_field_rule(checked, name, files, code, start, stop):
    problem = checked(files)
    if code is None:
        assert problem is None, problem
        return
    assert problem is not None, name
    assert problem["code"] == code
    found = problem["range"]
    assert (found["start"]["line"], found["start"]["column"]) == start
    assert (found["end"]["line"], found["end"]["column"]) == stop


@pytest.mark.parametrize("line", ["puts(c.secrt)", 'puts(c.with(secrt: "s").id)'])
def test_a_typo_outside_does_not_suggest_a_private_field(checked, line):
    help_text = checked(outside(line))["help"]
    assert "peer" in help_text and "secret" not in help_text, help_text


def test_a_warm_check_cache_gives_the_same_answers(tmp_path):
    (tmp_path / "lib.agc").write_text(LIB, encoding="utf-8")
    main = tmp_path / "main.agc"
    build = tmp_path / "build"
    env = {**os.environ, "AGENTICA_BUILD_DIR": str(build)}
    for line in ["puts(c.id)", "puts(c.secret)", 'puts(L.Conn(id: 1, peer: "p").id)', "puts(c.id)"]:
        main.write_text(outside(line)["main.agc"], encoding="utf-8")
        cold, warm, again = (run(cli() + ["--json", *flags, "check", str(main)], cwd=tmp_path, env=env)
                             for flags in (["--no-cache"], [], []))
        assert (cold.code, cold.stdout, cold.stderr) == (warm.code, warm.stdout, warm.stderr), line
        assert (warm.code, warm.stdout, warm.stderr) == (again.code, again.stdout, again.stderr), line
    assert any(build.rglob("*")), "the warm runs wrote no check cache"


def test_a_struct_with_private_fields_travels_outside_its_module(tmp_path):
    (tmp_path / "lib.agc").write_text(LIB, encoding="utf-8")
    (tmp_path / "main.agc").write_text(USES, encoding="utf-8")
    result = run(cli() + [str(tmp_path / "main.agc")], cwd=tmp_path)
    assert result.code == 0, result.stderr
    shown = 'Conn(id: 1, peer: "p", secret: "s1", timeout_ms: 5)'
    assert result.stdout == (
        "1 p q s1! true\n"
        '{"id":1,"peer":"p","secret":"s1","timeout_ms":5}4\n'
        'Conn(id: 2, peer: "x", secret: "y", timeout_ms: 3)\n'
        f"{shown} true\n"
        'b"p"\n'
    )
    formatted = run(cli() + ["fmt", "--check", str(tmp_path / "lib.agc")], cwd=tmp_path)
    assert formatted.code == 0, formatted.stdout + formatted.stderr


def test_doc_and_outline_list_the_public_fields(tmp_path):
    (tmp_path / "lib.agc").write_text(LIB, encoding="utf-8")
    documented = run(cli() + ["doc", str(tmp_path / "lib.agc")], cwd=tmp_path)
    assert documented.code == 0, documented.stderr
    assert "- `id: Int`\n- `peer: String`\n- and private fields\n" in documented.stdout
    assert "secret:" not in documented.stdout
    outlined = run(cli() + ["outline", str(tmp_path / "lib.agc"), "--json"], cwd=tmp_path)
    assert outlined.code == 0, outlined.stderr
    conn = json.loads(outlined.stdout)["items"][0]
    assert [field["name"] for field in conn["fields"]] == ["id", "peer"]
    assert conn["private_fields"] is True
