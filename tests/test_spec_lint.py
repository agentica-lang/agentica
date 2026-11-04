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
''' + "".join(f'\nexport def make{i}() -> Db.Value\n  return Db.Value.Text("a")\nend\n' for i in range(10))

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


def test_a_file_that_does_not_parse_is_a_diagnostic_and_the_others_still_lint(tmp_path):
    (tmp_path / "a.agc").write_text(BAD, encoding="utf-8")
    (tmp_path / "broken.agc").write_text("x = 1\n", encoding="utf-8")
    document = report(lint_json(".", cwd=tmp_path), 1)
    entries = {entry["file"]: entry for entry in document["files"]}
    assert entries["broken.agc"]["diagnostic"]["code"] == "PARSE-TOP-LEVEL-STATEMENT"
    assert entries["a.agc"]["suggestions"]
    text = lint(".", cwd=tmp_path)
    assert text.code == 1 and "PARSE-TOP-LEVEL-STATEMENT" in text.stderr and "LINT-BOOL-COMPARE" in text.stdout


@pytest.mark.skipif(hasattr(os, "geteuid") and os.geteuid() == 0, reason="host-only: root reads any file")
def test_an_unreadable_file_is_status_two(tmp_path):
    path = tmp_path / "locked.agc"
    path.write_text(GOOD, encoding="utf-8")
    with unreadable(path):
        document = report(lint_json("locked.agc", cwd=tmp_path), 2)
    assert document["files"][0]["diagnostic"]["code"] == "QUERY-USAGE"


@pytest.mark.parametrize("words", [["absent.agc"], ["--bogus"], ["--stdin", "a.agc"], ["empty"]])
def test_a_mistake_in_the_call_is_a_usage_error_and_lints_nothing(tmp_path, words):
    (tmp_path / "empty").mkdir()
    (tmp_path / "empty" / "readme.txt").write_text("x", encoding="utf-8")
    (tmp_path / "bad.agc").write_text(BAD, encoding="utf-8")
    assert problem(lint_json(*words, cwd=tmp_path), "QUERY-USAGE", 2)["file"] == "<arguments>"
