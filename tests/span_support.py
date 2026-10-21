"""Readers of the JSON that `agentica doc` and `agentica outline` print, shared by their tests."""


def items_by_name(report):
    return {item["name"]: item for item in report["items"]}


def start(span):
    return span["range"]["start"]["line"], span["range"]["start"]["column"]


def end(span):
    return span["range"]["end"]["line"], span["range"]["end"]["column"]
