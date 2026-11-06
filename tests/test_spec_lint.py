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

  return out
end
''' + "".join(f'\nexport def make{i}() -> Db.Value\n  return Db.Value.Text("a")\nend\n' for i in range(20))

# The good form of each rule, and the near misses that must stay quiet: a pipe of two steps, a String built outside a
# loop, a List grown in a loop, a `+` of two Strings with no to_s, two branches, a doc on public code and a qualified
# name used a few times.
GOOD = '''import Db from "db"

## Returns the label of the count.
export def label(flag: Bool, text: String, n: Int) -> String
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
  return "#{joined}#{greeting}#{note}#{shout}"
end

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
'''


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
        "LINT-NEGATED-ELSE": [where(BAD, "not flag")],
        "LINT-IF-CHAIN": [where(BAD, "n == 1")],
        "LINT-REPEATED-QUALIFIED-NAME": [where(BAD, "Db.Value", nth=2)],
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


PRIVATE_DOCS = '''## A doc on a private struct.
struct Point
  x: Int
end

## A doc on a private enum.
enum Mode
  On
  Off
end

## A doc on an exported function, struct and enum.
export def shown() -> Int
  return 1
end

## A doc on an exported struct.
export struct Pair
  x: Int
end

## A doc on an exported enum.
export enum Side
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
'''


def test_a_doc_is_private_only_on_a_function_struct_or_enum_that_is_not_exported_or_extern(tmp_path):
    found = suggested(tmp_path / "docs.agc", PRIVATE_DOCS)
    assert found == {"LINT-PRIVATE-DOC": [where(PRIVATE_DOCS, "Point"), where(PRIVATE_DOCS, "Mode")]}


def test_a_plus_chain_is_judged_once_and_a_nested_one_on_its_own(tmp_path):
    source = (
        "def f(n: Int, m: Int) -> String\n"
        '  one = "a=" + n.to_s + "!" + ("b=" + m.to_s)\n'
        "  return one\n"
        "end\n"
    )
    found = suggested(tmp_path / "nested.agc", source)
    assert found == {"LINT-TO-S-CONCAT": [where(source, '"a="'), where(source, '"b="')]}


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
