"""`agentica lint` through the product CLI (issue #970): the style-guide suggestions, one rule per LINT- code. The cases
read the JSON form and assert codes, spans and exit statuses, never message text; one case reads the text form. A lint
suggestion is not an error, so every run exits 0 unless a file does not parse, cannot be read or `--strict` is given."""
import json
import os

import pytest

from tests.agentica_test import cli, run, unreadable, vm_environment
from tests.span_support import end, problem, start, where

# Every rule once. The file does not need to check: lint only parses, so `upcase_it` and `Db` need not exist.
BAD = '''import Db from "db"

## A private declaration with a doc.
def helper(flag: Bool, text: String, n: Int) -> String
  out = ""
  for i in 0...3
    out = out + text
  end

  if flag == true
    out = "yes"
  end

  label = "n=" + n.to_s + "!"
  shout = text |> upcase_it()
  boxed = wrap(trim_it(pad_it(text)), "*")
  total = items.map(->(x) { x * 2 }).select(->(x) { x > 2 }).sum
  if not flag
    out = "a"
  else
    out = "b"
  end

  if n == 1
    out = "one"
  elsif n == 2
    out = "two"
  else
    out = "many"
  end

  missing = err.is_a?("io.notfound")
  return out
end
''' + "".join(f'\nexport def make{i}() -> Db.Value\n  return Db.Value.Text("a")\nend\n' for i in range(20))

# The good form of each rule, and the near misses that must stay quiet: a pipe of two steps, a String built outside a
# loop, a List grown in a loop, a `+` of two Strings with no to_s, two branches, a doc on public code, a qualified name
# used a few times, two nested calls, a nest that is not in first position, nests whose outer calls are builtins or
# methods of a constant, and method chains of two steps, of blocks in braces, or whose names after the lambda may be
# fields.
GOOD = """import Db from "db"

## Returns the label of the count.
def label(flag: Bool, text: String, n: Int) -> String
  parts: List[String] = []
  for i in 0...3
    parts = parts.push(text)
    n = n + 1
  end

  joined = parts.join("")
  greeting = "hello " + text
  note = "n=#{n}"
  shout = (
    text
    |> upcase_it()
    |> upcase_it()
  )

  if flag
    joined = "yes"
  elsif n == 1
    joined = "one"
  else
    joined = "many"
  end

  case n
    1 -> joined = "one"
    2 -> joined = "two"
    _ -> joined = "many"
  end

  if flag
    joined = "a"
  else
    joined = "b"
  end

  value = Db.Value.Text("a")
  twice = wrap(trim_it(text), "*")
  later = wrap(text, trim_it(pad_it(text)))
  methods = String.upcase(String.strip(pad_it(text)))
  builtins = puts(ok(pad_it(text)))
  rows = ROWS.concat(MORE.concat(pad_it(text)))
  total = (
    items
    |> map(->(x) { x * 2 })
    |> select(->(x) { x > 2 })
    |> sum()
  )
  pair = items.map(->(x) { x * 2 }).sum
  braces = items.map { |x| x * 2 }.select { |x| x > 2 }.sum
  fields = items.map(->(x) { x * 2 }).first.size
  return "#{joined}#{greeting}#{note}#{shout}"
end

private

# Near misses: a String made fresh in the body of a loop, `if not` with no else, and a Bool compared with a name.
def near_misses(flag: Bool, done: Bool, text: String) -> Int
  total = ""
  for i in 0...3
    fresh = ""
    fresh = fresh + text
    total = total.concat(fresh)
  end

  if not flag
    total = "a"
  end

  if not flag
    total = "a"
  elsif done
    total = "c"
  else
    total = "b"
  end

  if flag == done
    total = "b"
  end

  return total.length
end

# A note that is not a doc.
def helper() -> Int
  return 1
end
"""


def lint(*words, cwd=None):
    return run(cli() + ["lint", *words], env=vm_environment(), cwd=cwd)


def lint_json(*words, cwd=None):
    return run(cli() + ["--json", "lint", *words], env=vm_environment(), cwd=cwd)


def report(result, status):
    """The JSON document of a run, after its exit status and empty stderr."""
    assert (result.code, result.stderr) == (status, "")
    return json.loads(result.stdout)


def suggested(path, text):
    """code -> the start (line, column) of each of its suggestions, for the file `path` holding `text`."""
    path.write_text(text, encoding="utf-8")
    document = report(lint_json(path.name, cwd=path.parent), 0)
    found = {}
    for suggestion in document["files"][0].get("suggestions", []):
        assert suggestion["file"] == path.name
        found.setdefault(suggestion["code"], []).append(start(suggestion))
    return found


def test_every_rule_reports_its_code_at_its_place(tmp_path):
    found = suggested(tmp_path / "bad.agc", BAD)
    assert found == {
        "LINT-PRIVATE-DOC": [where(BAD, "helper")],
        "LINT-STRING-APPEND-IN-LOOP": [where(BAD, "out = out + text")],
        "LINT-BOOL-COMPARE": [where(BAD, "flag == true")],
        "LINT-TO-S-CONCAT": [where(BAD, '"n=" + n.to_s')],
        "LINT-SINGLE-PIPE": [where(BAD, "upcase_it()")],
        "LINT-NESTED-CALL": [where(BAD, "wrap(trim_it")],
        "LINT-LAMBDA-CHAIN": [where(BAD, "items.map")],
        "LINT-NEGATED-ELSE": [where(BAD, "not flag")],
        "LINT-IF-CHAIN": [where(BAD, "n == 1")],
        "LINT-REPEATED-QUALIFIED-NAME": [where(BAD, "Db.Value", nth=2)],
        "LINT-ERROR-KIND": [where(BAD, '"io.notfound"')],
    }


def test_a_local_enum_variant_is_not_a_qualified_name_to_import(tmp_path):
    local = "import Db from \"db\"\n\nenum Answer\n  SignedOut\nend\n\ndef f() -> Answer\n" + "  Answer.SignedOut\n" * 25 + "end\n"
    assert suggested(tmp_path / "local.agc", local) == {}
    imported = local.replace("Answer.SignedOut", "Db.Value", 25)
    found = suggested(tmp_path / "imported.agc", imported)
    assert found == {"LINT-REPEATED-QUALIFIED-NAME": [where(imported, "Db.Value", nth=1)]}


def test_a_qualified_name_counts_from_twenty_mentions(tmp_path):
    def text(count):
        return 'import Db from "db"\n\ndef f() -> Int\n' + "  Db.Value.Null\n" * count + "  return 1\nend\n"

    assert suggested(tmp_path / "nineteen.agc", text(19)) == {}
    twenty = text(20)
    assert suggested(tmp_path / "twenty.agc", twenty) == {"LINT-REPEATED-QUALIFIED-NAME": [where(twenty, "Db.Value")]}


def test_the_help_of_a_name_that_is_imported_already_is_not_the_import_line(tmp_path):
    body = "def f() -> Int\n" + "  Db.Value.Null\n" * 20 + "  return 1\nend\n"
    helps = {}
    for name, header in {"plain": 'import Db from "db"\n', "both": 'import Db from "db"\nimport {Value} from "db"\n'}.items():
        path = tmp_path / f"{name}.agc"
        path.write_text(header + "\n" + body, encoding="utf-8")
        found = report(lint_json(path.name, cwd=tmp_path), 0)["files"][0]["suggestions"]
        helps[name] = [suggestion["help"] for suggestion in found if suggestion["code"] == "LINT-REPEATED-QUALIFIED-NAME"]

    assert len(helps["plain"]) == len(helps["both"]) == 1 and helps["plain"] != helps["both"]


def test_suggestions_come_in_source_order_with_a_span(tmp_path):
    (tmp_path / "bad.agc").write_text(BAD, encoding="utf-8")
    document = report(lint_json("bad.agc", cwd=tmp_path), 0)
    suggestions = document["files"][0]["suggestions"]
    places = [start(suggestion) for suggestion in suggestions]
    assert places == sorted(places)
    assert all(start(suggestion) < end(suggestion) for suggestion in suggestions)
    assert (document["ok"], document["checked"], document["suggestions"]) == (False, 1, len(suggestions))


def test_the_good_form_of_each_rule_is_quiet(tmp_path):
    assert suggested(tmp_path / "good.agc", GOOD) == {}
    document = report(lint_json("good.agc", cwd=tmp_path), 0)
    assert (document["ok"], document["suggestions"], document["files"][0]["ok"]) == (True, 0, True)


def test_a_suggestion_exits_zero_and_strict_exits_one(tmp_path):
    (tmp_path / "bad.agc").write_text(BAD, encoding="utf-8")
    (tmp_path / "good.agc").write_text(GOOD, encoding="utf-8")
    plain = lint("bad.agc", cwd=tmp_path)
    assert (plain.code, plain.stderr) == (0, "")
    assert "bad.agc:7:5 LINT-STRING-APPEND-IN-LOOP" in plain.stdout
    assert plain.stdout.rstrip().endswith("in 1 of 1 file")
    assert (lint("--strict", "bad.agc", cwd=tmp_path).code, lint("bad.agc", "--strict", cwd=tmp_path).code) == (1, 1)
    assert report(lint_json("--strict", "bad.agc", cwd=tmp_path), 1)["suggestions"] > 0
    clean = lint("--strict", "good.agc", cwd=tmp_path)
    assert (clean.code, clean.stdout, clean.stderr) == (0, "lint ok: 1 file\n", "")


def test_a_folder_and_no_path_lint_every_file(tmp_path):
    (tmp_path / "src").mkdir()
    (tmp_path / "a.agc").write_text(GOOD, encoding="utf-8")
    (tmp_path / "src" / "b.agc").write_text(BAD, encoding="utf-8")
    (tmp_path / "notes.txt").write_text("not a source", encoding="utf-8")
    document = report(lint_json(cwd=tmp_path), 0)
    assert [entry["file"] for entry in document["files"]] == ["a.agc", "src/b.agc"]
    assert [entry["ok"] for entry in document["files"]] == [True, False]
    assert report(lint_json("src", cwd=tmp_path), 0)["checked"] == 1


GROWN = "def f(text: String) -> String\n{body}\n  return text\nend\n"


@pytest.mark.parametrize(
    "name, body, grown",
    [
        ("fresh_in_the_only_loop", '  for i in 0...3\n    s = ""\n    s = s + text\n  end', None),
        ("before_the_loop", '  s = ""\n  for i in 0...3\n    s += text\n  end', "s += text"),
        (
            "fresh_in_the_outer_body",
            '  for i in 0...3\n    s = ""\n    for j in 0...3\n      s = s + text\n    end\n  end',
            "s = s + text",
        ),
        ("set_again_in_the_body", '  s = ""\n  for i in 0...3\n    s = ""\n    s = s + text\n  end', None),
        ("bound_after_the_loop", '  for i in 0...3\n    s = s + "x"\n  end\n  s = ""', None),
        ("a_parameter", '  for i in 0...3\n    text += "x"\n  end', 'text += "x"'),
        ("a_while_loop", '  s = ""\n  while s.size < 3\n    s = s + text\n  end', "s = s + text"),
        ("a_block_starts_again", '  s = ""\n  for i in 0...3\n    text.each do |c: String|\n      s = s + c\n    end\n  end', None),
    ],
)
def test_a_string_grows_in_a_loop_only_when_it_was_set_outside_that_loop(tmp_path, name, body, grown):
    source = GROWN.format(body=body)
    expected = {"LINT-STRING-APPEND-IN-LOOP": [where(source, grown)]} if grown else {}
    assert suggested(tmp_path / f"{name}.agc", source) == expected


PRIVATE_DOCS = """## A doc on a private struct.
struct Point
  x: Int
end

## A doc on a private enum.
enum Mode
  On
  Off
end

## A doc on an exported function, struct and enum.
def shown() -> Int
  return 1
end

## A doc on an exported struct.
struct Pair
  x: Int
end

## A doc on an exported enum.
enum Side
  Left
  Right
end

extern "demo"
  struct DemoPair
    x: C.Int32
  end
  ## A doc on a C function.
  def demo_make(x: C.Int32) -> DemoPair
end
"""


def test_a_doc_is_private_only_on_a_function_struct_or_enum_that_is_not_exported_or_extern(tmp_path):
    found = suggested(tmp_path / "docs.agc", PRIVATE_DOCS)
    assert found == {"LINT-PRIVATE-DOC": [where(PRIVATE_DOCS, "Point"), where(PRIVATE_DOCS, "Mode")]}


def test_a_plus_chain_is_judged_once_and_a_nested_one_on_its_own(tmp_path):
    source = (
        "def f(n: Int, m: Int) -> String\n"
        '  one = "a=" + n.to_s + "!" + ("b=" + m.to_s)\n'
        '  two = (try ("c=" + m.to_s)) + "?"\n'
        "  return one + two\n"
        "end\n"
    )
    found = suggested(tmp_path / "nested.agc", source)
    assert found == {"LINT-TO-S-CONCAT": [where(source, '"a="'), where(source, '"b="'), where(source, '"c="')]}


def test_a_chain_of_the_other_kind_is_not_hidden_by_the_chain_around_it(tmp_path):
    source = (
        "def f(n: Int, a: String) -> String\n"
        '  one = ("n=" + n.to_s + "!") |> shout()\n'
        '  two = (a |> shout()) + "x"\n'
        "  return one + two\n"
        "end\n"
    )
    found = suggested(tmp_path / "other.agc", source)
    assert found == {
        "LINT-TO-S-CONCAT": [where(source, '"n="')],
        "LINT-SINGLE-PIPE": [where(source, "shout()", nth=1), where(source, "shout()", nth=2)],
    }


def test_a_nest_of_calls_is_judged_once_from_its_outer_step_and_a_nest_in_a_later_argument_on_its_own(tmp_path):
    """A step is a call of the file's own function or of a module it imports: a builtin around a nest breaks it, and
    a method of a constant or of a module's constant, or a variant of an imported module, is no step. A pipe of one
    step inside a nest is two suggestions, one for each rule."""
    source = (
        'import OP from "op"\n'
        'import Mod from "mod"\n'
        'import Domain from "domain"\n'
        "\n"
        "def f(text: String) -> String\n"
        "  one = d(c(b(a(text))))\n"
        "  two = d(text, c(b(a(text))))\n"
        "  three = d(c(text |> b() |> a()))\n"
        "  four = puts(d(c(b(text))))\n"
        "  five = OP.a(OP.b(c(text)))\n"
        "  six = Mod.LIMIT.concat(Mod.LIMIT.concat(c(text)))\n"
        "  seven = d(c(text |> b()))\n"
        "  eight = Domain.Some(Domain.Wrap(c(text)))\n"
        "  nine = ROWS.concat(ROWS.concat(c(text)))\n"
        "  return one\n"
        "end\n"
    )
    found = suggested(tmp_path / "nested_calls.agc", source)
    nests = ["d(c(b(a(", "c(b(a(text))))\n  three", "d(c(text |> b() |>", "d(c(b(text", "OP.a(", "d(c(text |> b()))"]
    assert found == {
        "LINT-NESTED-CALL": [where(source, needle) for needle in nests],
        "LINT-SINGLE-PIPE": [where(source, "b()))")],
    }


def test_the_if_chain_help_asks_for_an_underscore_arm_only_without_an_else(tmp_path):
    def help_of(tail):
        source = "def f(n: Int) -> Int\n  if n == 1\n    return 1\n  elsif n == 2\n    return 2\n" + tail + "  return 0\nend\n"
        path = tmp_path / f"chain{len(tail)}.agc"
        path.write_text(source, encoding="utf-8")
        found = report(lint_json(path.name, cwd=tmp_path), 0)["files"][0]["suggestions"]
        return [suggestion["help"] for suggestion in found if suggestion["code"] == "LINT-IF-CHAIN"]

    without = help_of("  elsif n == 3\n    return 3\n  end\n")
    with_else = help_of("  else\n    return 3\n  end\n")
    assert len(without) == len(with_else) == 1 and "`_` arm" in without[0] and "`_` arm" not in with_else[0]


def test_a_file_that_does_not_parse_is_a_diagnostic_and_the_others_still_lint(tmp_path):
    (tmp_path / "a.agc").write_text(BAD, encoding="utf-8")
    (tmp_path / "broken.agc").write_text("x = 1\n", encoding="utf-8")
    document = report(lint_json(".", cwd=tmp_path), 1)
    entries = {entry["file"]: entry for entry in document["files"]}
    assert entries["broken.agc"]["diagnostic"]["code"] == "PARSE-TOP-LEVEL-STATEMENT"
    assert entries["a.agc"]["suggestions"]
    text = lint(".", cwd=tmp_path)
    assert text.code == 1 and "PARSE-TOP-LEVEL-STATEMENT" in text.stderr and "LINT-BOOL-COMPARE" in text.stdout
    suggestions = document["suggestions"]
    assert text.stdout.splitlines()[-1] == f"lint failed: 1 of 2 files could not be parsed; {suggestions} suggestions in 1 file"


def test_the_last_line_says_that_a_file_failed(tmp_path):
    (tmp_path / "good.agc").write_text(GOOD, encoding="utf-8")
    (tmp_path / "broken.agc").write_text("x = 1\n", encoding="utf-8")
    failed = lint(".", cwd=tmp_path)
    assert (failed.code, failed.stdout) == (1, "lint failed: 1 of 2 files could not be parsed\n")
    ai = run(cli() + ["--ai", "lint", "broken.agc"], env=vm_environment(), cwd=tmp_path)
    assert ai.code == 1 and ai.stderr.startswith("broken.agc:") and "check failed: 1 error" not in ai.stderr


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0, reason="host-only: root reads any file")
def test_an_unreadable_file_is_status_two(tmp_path):
    path = tmp_path / "locked.agc"
    path.write_text(GOOD, encoding="utf-8")
    with unreadable(path):
        document = report(lint_json("locked.agc", cwd=tmp_path), 2)
    assert document["files"][0]["diagnostic"]["code"] == "QUERY-USAGE"
    with unreadable(path):
        text = lint("locked.agc", cwd=tmp_path)
        assert (text.code, text.stdout) == (2, "lint failed: 1 of 1 file could not be read\n")
        (tmp_path / "broken.agc").write_text("x = 1\n", encoding="utf-8")
        both = lint(".", cwd=tmp_path)
    assert (both.code, both.stdout) == (2, "lint failed: 2 of 2 files could not be parsed or read\n")


@pytest.mark.parametrize("words", [["absent.agc"], ["--bogus"], ["--stdin", "a.agc"], ["empty"]])
def test_a_mistake_in_the_call_is_a_usage_error_and_lints_nothing(tmp_path, words):
    (tmp_path / "empty").mkdir()
    (tmp_path / "empty" / "readme.txt").write_text("x", encoding="utf-8")
    (tmp_path / "bad.agc").write_text(BAD, encoding="utf-8")
    assert problem(lint_json(*words, cwd=tmp_path), "QUERY-USAGE", 2)["file"] == "<arguments>"


def test_a_lambda_chain_is_judged_once_at_its_last_link_and_a_chain_in_an_argument_on_its_own(tmp_path):
    source = (
        "def f(xs: List[Int]) -> Int\n"
        "  one = xs.map(->(x) { x }).select(->(x) { x > 0 }).map(->(x) { x + 1 }).size\n"
        "  two = xs.take(xs.map(->(x) { x }).select(->(x) { x > 0 }).size).reverse.first\n"
        "  return one + two\n"
        "end\n"
    )
    found = suggested(tmp_path / "chains.agc", source)
    assert found == {"LINT-LAMBDA-CHAIN": [where(source, "xs.map"), where(source, "xs.map", nth=2)]}


def test_a_lambda_chain_after_a_field_is_judged_below_it_and_a_chain_through_a_file_function_is_not(tmp_path):
    """A name without arguments ends the part of a chain that a pipe writes, so the method calls below it are judged as
    a chain of their own; a link named as a function of the file would call that function in a pipe, so its chain is
    left alone."""
    source = (
        "def f(xs: List[Int]) -> String\n"
        "  one = xs.map(->(x) { x * 2 }).select(->(x) { x > 2 }).sum.to_s\n"
        "  return one\n"
        "end\n"
    )
    assert suggested(tmp_path / "field.agc", source) == {"LINT-LAMBDA-CHAIN": [where(source, "xs.map")]}
    clash = "def select(xs: List[Int], f: Fn[Int, Bool]) -> List[Int] = xs\n\n" + source
    assert suggested(tmp_path / "clash.agc", clash) == {}


def test_the_help_of_a_one_step_pipe_into_a_method_is_the_method_call(tmp_path):
    source = (
        "def shout(text: String) -> String = text\n\n"
        "def f(xs: List[Int], text: String) -> Bool\n"
        "  loud = text |> shout()\n"
        "  return xs |> any?(->(x) { x > 0 })\n"
        "end\n"
    )
    path = tmp_path / "single.agc"
    path.write_text(source, encoding="utf-8")
    found = report(lint_json(path.name, cwd=tmp_path), 0)["files"][0]["suggestions"]
    assert [(s["code"], start(s)) for s in found] == [
        ("LINT-SINGLE-PIPE", where(source, "shout()")),
        ("LINT-SINGLE-PIPE", where(source, "any?(")),
    ]
    assert found[0]["help"] != found[1]["help"]


def test_a_function_imported_by_name_counts_as_a_function_of_the_file(tmp_path):
    """The linker sends a piped bare name to a function the file imports by name, so lint treats it as the file's own:
    a chain through it is left alone, and a one-step pipe into it gets the plain-call help."""
    (tmp_path / "m2.agc").write_text(
        ("def select(xs: List[Int], f: Fn[Int, Bool]) -> List[Int] = xs\n\n"
         "def double(n: Int) -> Int = n * 2\n"),
        encoding="utf-8",
    )
    chain = (
        'import {select} from "m2"\n\n'
        "def f(xs: List[Int]) -> Int\n"
        "  return xs.map(->(x) { x * 2 }).select(->(x) { x > 2 }).sum\n"
        "end\n"
    )
    assert suggested(tmp_path / "chain.agc", chain) == {}
    helps = []
    for name, header, call in [("plain", "", "shout()"), ("named", '{double}', "double()"),
                               ("renamed", '{double as twice}', "twice()")]:
        source = (f'import {header} from "m2"\n\n' if header else "") + (
            "def shout(n: Int) -> Int = n\n\n"
            f"def f() -> Int\n  return 3 |> {call}\nend\n"
        )
        path = tmp_path / f"{name}.agc"
        path.write_text(source, encoding="utf-8")
        found = report(lint_json(path.name, cwd=tmp_path), 0)["files"][0]["suggestions"]
        assert [(s["code"], start(s)) for s in found] == [("LINT-SINGLE-PIPE", where(source, call))]
        helps.append(found[0]["help"])
    assert helps[0] == helps[1] == helps[2]


# Each is_a? form with its literal, and whether LINT-ERROR-KIND marks the literal: a builtin family (of a C kind or a
# std/ kind) takes the family and its kinds only; a library's family, a computed kind and the default kind are quiet.
KIND_CASES = [
    ('e.is_a?("io.notfound")', True),
    ('e.kind_of?("net.timeot")', True),
    ('Error.is_a?(e, "toml.prase")', True),
    ('e.is_a?(family: "io.notfound")', True),
    ('Error.is_a?(e, family: "io.notfound")', True),
    ('Error.is_a?(error: e, family: "io.notfound")', True),
    ('Error.is_a?("io.notfound", error: e)', True),
    ('e.is_a?(family: "io.not_found")', False),
    ('e.is_a?("error.other")', True),
    ('e.is_a?("io")', False),
    ('e.is_a?("io.not_found")', False),
    ('e.is_a?("http.too_large")', False),
    ('e.is_a?("archive.unsafe")', False),
    ('e.kind_of?("option_parser.help")', False),
    ('e.is_a?("error")', False),
    ('e.is_a?("db.constraint")', False),
    ('e.is_a?(name)', False),
    ('e.is_a?("io.#{name}")', False),
    ('e.include?("io.notfound")', False),
]


@pytest.mark.parametrize(("call", "marked"), KIND_CASES)
def test_an_is_a_literal_of_a_builtin_family_must_name_one_of_its_kinds(tmp_path, call, marked):
    source = f"def f(e: Error, name: String) -> Bool\n  {call}\nend\n"
    literal = call[call.index('"'):call.rindex('"') + 1] if '"' in call else ""
    expected = {"LINT-ERROR-KIND": [where(source, literal)]} if marked else {}
    assert suggested(tmp_path / "kind.agc", source) == expected


def test_the_kind_help_is_the_nearest_kind_or_the_kinds_of_the_family(tmp_path):
    source = 'def f(e: Error) -> List[Bool]\n  [e.is_a?("io.notfound"), e.is_a?("io.zzzzzzzz")]\nend\n'
    path = tmp_path / "help.agc"
    path.write_text(source, encoding="utf-8")
    found = report(lint_json(path.name, cwd=tmp_path), 0)["files"][0]["suggestions"]
    assert [(s["code"], start(s), end(s)) for s in found] == [
        ("LINT-ERROR-KIND", where(source, '"io.notfound"'), where(source, '), e.is_a')),
        ("LINT-ERROR-KIND", where(source, '"io.zzzzzzzz"'), where(source, ')]')),
    ]
    assert found[0]["help"] != found[1]["help"]


def test_a_piped_is_a_in_a_file_that_defines_one_is_its_own_and_the_method_form_still_lints(tmp_path):
    source = (
        "def is_a?(box: Int, label: String) -> Bool = true\n\n"
        "def f(e: Error, n: Int) -> List[Bool]\n"
        '  [n |> is_a?("io.x"), e.is_a?("io.y")]\n'
        "end\n"
    )
    found = suggested(tmp_path / "own.agc", source)
    assert found["LINT-ERROR-KIND"] == [where(source, '"io.y"')]


def test_a_kind_that_the_file_creates_in_a_builtin_family_is_known(tmp_path):
    source = (
        "def f(n: Int) -> Result[Int]\n"
        '  return error("negative", kind: "number.negative") if n < 0\n\n'
        "  ok(n)\n"
        "end\n\n"
        "def g(e: Error) -> List[Bool]\n"
        '  [e.is_a?("number.negative"), e.is_a?("number.positive")]\n'
        "end\n"
    )
    assert suggested(tmp_path / "made.agc", source) == {"LINT-ERROR-KIND": [where(source, '"number.positive"')]}
