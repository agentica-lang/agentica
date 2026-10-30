"""The agentica code blocks of site/content.

Each block is checked or run with the product CLI, in a folder of its own. A fenced block may carry attributes:
`mode="check"` only checks the program, `expect="CODE"` says the program is rejected or fails with that diagnostic code,
`file="name.agc"` makes the block a module file that the programs of the page import. An `input` block after a program
is its standard input, and an `output` block is the exact standard output of its run. The fast tier covers the start
pages, two tour pages and the BDD page; the slow tier covers the whole site (the site-examples workflow runs it).
"""
import json
import re
import shutil
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass

import pytest

from tests.agentica_test import ROOT, cli, run, vm_environment

CONTENT = ROOT / "site" / "content"
FENCE_OPEN = re.compile(r"^```([A-Za-z0-9_-]+)[ \t]*(?:\{([^}]*)\})?[ \t]*$")
FENCE_CLOSE = re.compile(r"^```[ \t]*$")
KNOWN_ATTRIBUTES = ("mode", "file", "expect")
SMOKE_PAGES = ["getting-started.md", "cli.md", "tour/modules.md", "tour/results-and-try.md", "library/testing/bdd.md"]
JOBS = 4
# The codes of the stages before the run: a program that fails with one of them was rejected, not run.
STATIC_PREFIXES = ("LEX-", "PARSE-", "CHECK-")


@dataclass
class Block:
    lang: str
    attributes: dict
    text: str
    line: int


def parse_attributes(text):
    return dict(re.findall(r'([a-z]+)="([^"]*)"', text or ""))


def blocks_of(path):
    lines = re.split(r"\r\n|\n|\r", path.read_text(encoding="utf-8"))
    if lines and lines[-1] == "":
        lines.pop()
    found = []
    index = 0
    while index < len(lines):
        opening = FENCE_OPEN.match(lines[index])
        if opening:
            start = index + 1
            end = start
            while end < len(lines) and not FENCE_CLOSE.match(lines[end]):
                end += 1
            body = lines[start:end]
            found.append(Block(opening.group(1), parse_attributes(opening.group(2)),
                               "".join(line + "\n" for line in body), index + 1))
            index = end + 1
        elif lines[index].startswith("```"):
            raise RuntimeError("%s:%d: unsupported code fence" % (path, index + 1))
        else:
            index += 1
    return found


def is_program(block):
    return block.lang in ("agentica", "agc")


def following(blocks, index):
    """The input and output blocks that belong to the program at `index`."""
    found = {}
    for block in blocks[index + 1:]:
        if block.lang == "sh":
            continue
        if block.lang == "input" and "input" not in found and "output" not in found:
            found["input"] = block.text
        elif block.lang == "output" and "output" not in found:
            found["output"] = block.text
        else:
            break
    return found


def site_pages():
    return sorted(path for path in CONTENT.rglob("*.md"))


def diagnostic_code(result):
    """The code of the JSON diagnostic on the last stderr line of an exit 1, else None."""
    lines = [line for line in result.stderr.split("\n") if line]
    if result.code != 1 or not lines:
        return None
    try:
        data = json.loads(lines[-1])
    except ValueError:
        return None
    return data.get("code") if isinstance(data, dict) else None


def agentica(directory, *arguments, stdin=""):
    return run(cli() + [str(argument) for argument in arguments], stdin=stdin.encode("utf-8"),
               cwd=directory, env=vm_environment())


def check_program(where, directory, block, input_text, output_text):
    """Check or run one program block in `directory`; returns (kind, problems)."""
    attributes = block.attributes
    problems = []
    for key in attributes:
        if key not in KNOWN_ATTRIBUTES:
            problems.append("%s: unknown attribute %s" % (where, key))
    mode = attributes.get("mode", "run")
    if mode not in ("run", "check"):
        problems.append("%s: unknown mode %s" % (where, mode))
    expect = attributes.get("expect")
    program = directory / "main.agc"
    program.write_text(block.text, encoding="utf-8")
    if mode == "check":
        result = agentica(directory, "--json", "check", program)
        code = diagnostic_code(result)
        if result.code == 0:
            if expect:
                problems.append("%s: expected %s, but the program checks" % (where, expect))
            if output_text is not None:
                problems.append("%s: a check-only block has an output block" % where)
            return "check", problems
        if expect and code == expect:
            return "rejected", problems
        return "check", problems + ["%s: %s" % (where, result.stderr)]
    result = agentica(
        directory, "--json", "--max-steps", "5000000", "--seed", "1", program,
        stdin=input_text or "",
    )
    code = diagnostic_code(result)
    rejected = code is not None and code.startswith(STATIC_PREFIXES)
    if expect:
        if result.code != 1:
            problems.append("%s: expected exit 1, stderr: %s" % (where, result.stderr))
        if code != expect:
            problems.append("%s: expected %s, stderr: %s" % (where, expect, result.stderr))
    else:
        if not (result.code == 0 or result.stderr == ""):
            problems.append("%s: exit %s, stderr: %s" % (where, result.code, result.stderr))
        if code:
            problems.append("%s: %s" % (where, result.stderr))
    if not expect and output_text is None:
        problems.append("%s: a run block needs an output block" % where)
    if (not expect or output_text is not None) and not rejected:
        if result.stdout != (output_text or ""):
            problems.append("%s, stderr: %s\nstdout %r is not %r" % (where, result.stderr, result.stdout,
                                                                     output_text or ""))
    return ("rejected" if rejected else "run"), problems


def check_page(path, counts, tmp_path):
    blocks = blocks_of(path)
    scratch = tmp_path.resolve()
    scratch.mkdir(parents=True, exist_ok=True)
    modules = {}
    for block in blocks:
        if is_program(block) and "file" in block.attributes:
            modules[block.attributes["file"]] = block.text
    jobs = []
    previous = None
    for index, block in enumerate(blocks):
        where = "%s:%d" % (path, block.line)
        if block.lang in ("input", "output"):
            assert previous is not None, "%s: %s block without a program before it" % (where, block.lang)
            previous = previous if block.lang == "input" else None
        elif is_program(block) and "file" in block.attributes:
            counts["module"] += 1
            previous = None
        elif is_program(block):
            directory = scratch / ("block-%d" % block.line)
            directory.mkdir()
            for name, text in modules.items():
                (directory / name).parent.mkdir(parents=True, exist_ok=True)
                (directory / name).write_text(text, encoding="utf-8")
            after = following(blocks, index)
            jobs.append((where, directory, block, after.get("input"), after.get("output")))
            previous = block
        elif block.lang != "sh":
            previous = None
    with ThreadPoolExecutor(JOBS) as pool:
        outcomes = list(pool.map(lambda job: check_program(*job), jobs))
    for (where, directory, *_rest), (kind, problems) in zip(jobs, outcomes):
        counts[kind] += 1
        assert problems == [], where
        shutil.rmtree(directory, ignore_errors=True)


def check_pages(pages, tmp_path):
    counts = Counter()
    for index, page in enumerate(pages):
        check_page(page, counts, tmp_path / str(index))
    return counts


def test_the_smoke_pages_run_their_examples(tmp_path):
    pages = [page for page in site_pages() if str(page.relative_to(CONTENT)) in SMOKE_PAGES]
    counts = check_pages(pages, tmp_path)
    assert len(pages) == len(SMOKE_PAGES)
    assert counts["run"] > 0, "the smoke pages should have run examples"
    assert counts["module"] > 0, "the smoke pages should have module files"


@pytest.mark.slow
def test_every_site_page_runs_its_examples(tmp_path):
    counts = check_pages(site_pages(), tmp_path)
    assert counts["run"] > 100, "the site should have many run examples"
    print("site examples: %d run, %d checked only, %d rejected by the checker, %d module files"
          % (counts["run"], counts["check"], counts["rejected"], counts["module"]))
