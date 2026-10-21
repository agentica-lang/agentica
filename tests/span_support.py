"""Readers of the JSON that `agentica doc`, `outline`, `type-at`, `refs` and `symbol` print, and the positions they are
asked about, shared by their tests."""
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


def where(source, needle, inside=0, nth=1):
    """The (line, column) of the character `inside` characters into the `nth` occurrence of `needle`."""
    at = -1
    for _ in range(nth):
        at = source.index(needle, at + 1)
    at += inside
    before = source[:at]
    return before.count("\n") + 1, at - (before.rfind("\n") + 1) + 1
