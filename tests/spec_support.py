"""Shared assertions for language-spec tests."""


def covered(text, span):
    """Return the source text from a diagnostic range's start to its exclusive end."""
    lines = text.split("\n")

    def offset(point):
        return sum(len(line) + 1 for line in lines[:point["line"] - 1]) + point["column"] - 1

    return text[offset(span["start"]):offset(span["end"])]
