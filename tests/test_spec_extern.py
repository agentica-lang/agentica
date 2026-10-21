"""The extern blocks of docs/grammar/05-syntax.md through `agentica --json check`: what the parser accepts, the
PARSE-EXTERN-* codes and their spans, and the checker's view of an extern function as an ordinary one with Agentica
types. `check` loads no library, so these cases hold on every system. Tests assert codes and spans, never messages.
"""
import json

import pytest

from tests.agentica_test import cli, run

VALID = """extern "libm.so.6"
  ## The cosine of x.
  export def cos(x: C.Double) -> C.Double

  def labs(n: C.Int64) -> C.Int64
end

extern "./lib/peer.so"
  def peer(a: C.Int, b: C.Bool, s: C.String) -> Void
end

def main() -> Void
  peer(labs(-1), cos(0.0) > 0.5, "x")
end
"""


def source(tmp_path, text, name="program.agc"):
    path = tmp_path / name
    path.write_text(text, encoding="utf-8")
    return str(path)


def check(path):
    return run(cli() + ["--json", "check", path])


def problem_of(result):
    assert result.code == 1, result.stdout + result.stderr
    return json.loads(result.stderr.strip().split("\n")[-1])


def at(problem):
    start, end = problem["range"]["start"], problem["range"]["end"]
    return problem["code"], (start["line"], start["column"]), (end["line"], end["column"])


def test_an_extern_block_declares_functions_that_check_like_any_other(tmp_path):
    result = check(source(tmp_path, VALID))
    assert (result.code, result.stdout) == (0, '{"ok":true}\n')


def test_an_exported_extern_function_is_imported_with_its_agentica_types(tmp_path):
    source(tmp_path, 'extern "libm.so.6"\n  export def cos(x: C.Double) -> C.Double\nend\n', "raw.agc")
    good = 'import Raw from "./raw"\n\ndef main() -> Void\n  puts(Raw.cos(1.0) + 1.5)\nend\n'
    assert check(source(tmp_path, good)).code == 0
    bad = 'import Raw from "./raw"\n\ndef main() -> Void\n  puts(Raw.cos("x"))\nend\n'
    assert at(problem_of(check(source(tmp_path, bad))))[0] == "CHECK-TYPE-MISMATCH"


def test_a_private_extern_function_is_not_exported(tmp_path):
    source(tmp_path, 'extern "libm.so.6"\n  def cos(x: C.Double) -> C.Double\nend\n', "raw.agc")
    text = 'import Raw from "./raw"\n\ndef main() -> Void\n  puts(Raw.cos(1.0))\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[0].startswith("CHECK-")


@pytest.mark.parametrize("signature, start, stop", [
    ("def f(x: Float) -> C.Int", (2, 12), (2, 17)),
    ("def f(x: C.Int) -> Int", (2, 22), (2, 25)),
    ("def f(x: C.Pointer) -> Void", (2, 12), (2, 21)),
    ("def f(x: Void) -> Void", (2, 12), (2, 16)),
    ("def f(x: List[C.Int]) -> Void", (2, 12), (2, 23)),
])
def test_only_c_types_cross_an_extern_signature(tmp_path, signature, start, stop):
    text = 'extern "libc.so.6"\n  %s\nend\n' % signature
    assert at(problem_of(check(source(tmp_path, text)))) == ("PARSE-EXTERN-TYPE", start, stop)


def test_an_extern_function_has_a_c_name(tmp_path):
    text = 'extern "libc.so.6"\n  def ready?() -> C.Bool\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-EXTERN-NAME", (2, 7))


def test_an_extern_parameter_has_no_default(tmp_path):
    text = 'extern "libc.so.6"\n  def abs(n: C.Int = 1) -> C.Int\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-EXTERN-DEFAULT", (2, 11))


@pytest.mark.parametrize("text, start", [
    ('extern "libc.so.6"\n  def abs(n: C.Int) -> C.Int\n    return 1\n  end\nend\n', (3, 5)),
    ('extern "libc.so.6"\n  struct S\n  end\nend\n', (2, 3)),
    ('extern "libc.so.6"\n  def abs(n: C.Int) -> C.Int\n', (3, 1)),
    ('extern "libc.so.6" def abs(n: C.Int) -> C.Int\nend\n', (1, 20)),
    ('extern <<~A\n  a\n  b\nA\n  def abs(n: C.Int) -> C.Int\nend\n', (1, 8)),
])
def test_an_extern_block_holds_only_signatures(tmp_path, text, start):
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-UNEXPECTED-TOKEN", start)


def test_an_extern_block_follows_the_blank_line_rule(tmp_path):
    text = 'def main() -> Void\nend\nextern "libc.so.6"\n  def abs(n: C.Int) -> C.Int\nend\n'
    assert at(problem_of(check(source(tmp_path, text))))[:2] == ("PARSE-MISSING-BLANK-LINE", (3, 1))


def test_extern_is_still_a_name_outside_the_top_level(tmp_path):
    text = 'def main() -> Void\n  extern = 1\n  puts(extern)\nend\n'
    assert check(source(tmp_path, text)).code == 0
