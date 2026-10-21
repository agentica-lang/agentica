"""Readers of the JSON that `agentica doc`, `outline` and `type-at` print, shared by their tests."""
import json


def items_by_name(report):
    return {item["name"]: item for item in report["items"]}


def start(span):
    return span["range"]["start"]["line"], span["range"]["start"]["column"]


def end(span):
    return span["range"]["end"]["line"], span["range"]["end"]["column"]


def problem(result, code, status):
    """The diagnostic a command printed on stderr as JSON, after checking its code, exit status and empty stdout."""
    assert (result.code, result.stdout) == (status, "")
    diagnostic = json.loads(result.stderr)
    assert diagnostic["code"] == code
    return diagnostic
