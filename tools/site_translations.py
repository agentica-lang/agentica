#!/usr/bin/env python3
"""Check the Spanish pages against their English pages (`make site-translations`; pages.yml).

    site_translations.py check [--strict] [--built DIR] [--root DIR]
    site_translations.py stamp FILE... [--root DIR]
    site_translations.py status [--root DIR]

A page of site/content.es/ translates the page at the same path in site/content/. Its front matter is `key: value`
lines, with continuation lines for lists. `source_hash` is quoted, so Hugo reads it as a string.
"""
import argparse
import hashlib
import os
import re
import sys
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENGLISH, SPANISH = "content", "content.es"
REQUIRED = ("title", "description", "source_hash")
COPIED = ("weight", "slug", "aliases", "url")
STALE = "the English page changed after this translation (source_hash differs)"
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
CLOSE = re.compile(r"^ {0,3}(`{3,}|~{3,})\s*$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
EXPLICIT_ID = re.compile(r"^(.*?)\s*\{#([\w-]+)\}$")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")
TABLE_ROW = re.compile(r"^\s*\|")
KEY = re.compile(r"^([A-Za-z_][\w-]*):(.*)$")
SPAN = re.compile(r"(`+)(.+?)\1")
LINK = re.compile(r"\]\(([^)\s]+)")
SHORTCODE = re.compile(r"\{\{[<%]\s*(/?)\s*([\w.-]+)([^}]*?)\s*[>%]\}\}")
EXAMPLE_TITLE = re.compile(r'\btitle="[^"]*"')
STALE_MARK = re.compile(r'<aside[^>]*data-translation=["\']?stale\b')


@dataclass
class Body:
    code: list[tuple[str, str]] = field(default_factory=list)
    headings: list[tuple[int, str | None, str]] = field(default_factory=list)
    spans: Counter[str] = field(default_factory=Counter)
    links: list[str] = field(default_factory=list)
    shortcodes: list[str] = field(default_factory=list)
    items: int = 0
    rows: int = 0
    paragraphs: list[int] = field(default_factory=list)


def split_front(text: str) -> tuple[list[str] | None, str]:
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 3)
    if end < 0:
        return None, text
    return text[4:end].split("\n"), text[end + 5:]


def front_values(lines: list[str]) -> dict[str, str]:
    """The raw value of each key, quotes kept; see plain."""
    values: dict[str, str] = {}
    key = None
    for line in lines:
        match = KEY.match(line)
        if match:
            key = match.group(1)
            values[key] = match.group(2).strip()
        elif key and line[:1] in (" ", "\t", "-"):
            values[key] += "\n" + line
    return values


def plain(value: str) -> str:
    if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
        return value[1:-1]
    return value


def spans_in(text: str) -> Counter[str]:
    return Counter(match.group(2) for match in SPAN.finditer(text))


def front_spans(values: dict[str, str]) -> Counter[str]:
    spans: Counter[str] = Counter()
    for value in values.values():
        spans += spans_in(value)
    return spans


def set_hash(lines: list[str], digest: str) -> list[str]:
    return [line for line in lines if not line.startswith("source_hash:")] + [f'source_hash: "{digest}"']


def anchor(text: str) -> str:
    """The id that Hugo's GitHub-style heading ids give a heading text with no {#id} of its own."""
    text = text.replace("`", "").replace("*", "").lower()
    kept = "".join(c for c in text if c.isalnum() or c in "-_ ")
    return kept.replace(" ", "-")


def shortcodes_in(line: str) -> list[str]:
    """Each shortcode as its name and attributes; an example's title is translated, so it is left out."""
    found = []
    for closing, name, attrs in SHORTCODE.findall(line):
        if name == "example":
            attrs = EXAMPLE_TITLE.sub("", attrs)
        found.append(f"{closing}{name} {' '.join(attrs.split())}".rstrip())
    return found


def scan(body: str) -> Body:
    result = Body()
    fence: str | None = None
    info, code_lines = "", []
    prose = []
    for line in body.split("\n"):
        if fence is None:
            match = FENCE.match(line)
            if match:
                fence, info, code_lines = match.group(1), match.group(2).strip(), []
            else:
                prose.append(line)
            continue
        close = CLOSE.match(line)
        if close and close.group(1)[0] == fence[0] and len(close.group(1)) >= len(fence):
            result.code.append((info, "\n".join(code_lines)))
            fence = None
        else:
            code_lines.append(line)
    seen: Counter[str] = Counter()
    paragraph: list[str] = []
    for line in prose:
        result.spans += spans_in(line)
        result.links += LINK.findall(line)
        result.shortcodes += shortcodes_in(line)
        heading = HEADING.match(line)
        if heading:
            text, explicit = heading.group(2), None
            id_match = EXPLICIT_ID.match(text)
            if id_match:
                text, explicit = id_match.group(1), id_match.group(2)
            base = explicit or anchor(text)
            seen[base] += 1
            unique = base if seen[base] == 1 else f"{base}-{seen[base] - 1}"
            result.headings.append((len(heading.group(1)), explicit, unique))
        if LIST_ITEM.match(line):
            result.items += 1
        if TABLE_ROW.match(line):
            result.rows += 1
        text_line = line.strip()
        if text_line and not (heading or LIST_ITEM.match(line) or TABLE_ROW.match(line) or text_line.startswith("{{")):
            paragraph.append(text_line)
        elif paragraph:
            result.paragraphs.append(len(paragraph))
            paragraph = []
    if paragraph:
        result.paragraphs.append(len(paragraph))
    return result


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()[:12]


def english_of(root: Path, es_path: Path) -> Path:
    return root / "site" / ENGLISH / es_path.relative_to(root / "site" / SPANISH)


def is_stale(root: Path, es_path: Path) -> bool:
    en_path = english_of(root, es_path)
    if not en_path.is_file():
        return False
    front, _ = split_front(es_path.read_text(encoding="utf-8"))
    stamp = plain(front_values(front or []).get("source_hash", ""))
    return bool(stamp) and stamp != digest(en_path)


def check_page(root: Path, es_path: Path) -> tuple[list[tuple[str, str]], list[tuple[str, str]], bool]:
    """The (code, message) errors and warnings of one Spanish page, and whether the page is stale.

    A stale page keeps the front matter checks; the body is compared with the English page only when it is fresh."""
    en_path = english_of(root, es_path)
    if not en_path.is_file():
        return [("orphan", f"no English page {en_path.relative_to(root)}")], [], False
    en_front, en_body = split_front(en_path.read_text(encoding="utf-8"))
    es_front, es_body = split_front(es_path.read_text(encoding="utf-8"))
    if es_front is None:
        return [("front-matter", "the page has no front matter")], [], False
    errors: list[tuple[str, str]] = []
    warnings: list[tuple[str, str]] = []
    es_vals = front_values(es_front)
    en_vals = front_values(en_front or [])
    for key in REQUIRED:
        if not es_vals.get(key):
            errors.append(("front-matter", f"front matter has no {key}"))
    stamp = es_vals.get("source_hash", "")
    if stamp and not (stamp.startswith('"') and re.fullmatch(r"[0-9a-f]{12}", plain(stamp))):
        errors.append(("front-matter", "source_hash must be 12 lowercase hex digits in double quotes"))
    if set(es_vals) - {"source_hash"} != set(en_vals):
        errors.append(("front-matter", "the front matter keys differ from the English page"))
    for key in COPIED:
        if plain(en_vals.get(key, "")) != plain(es_vals.get(key, "")):
            errors.append(("front-matter", f"{key} differs from the English page"))
    stale = is_stale(root, es_path)
    if stale:
        return errors, warnings, True
    en, es = scan(en_body), scan(es_body)
    if en.code != es.code:
        errors.append(("code", "the fenced code blocks differ from the English page (info string included)"))
    if [h[0] for h in en.headings] != [h[0] for h in es.headings]:
        errors.append(("heading", "the headings differ in count or level from the English page"))
    else:
        for (_, _, en_anchor), (_, es_id, _) in zip(en.headings, es.headings):
            if es_id is None:
                errors.append(("heading", "a heading has no {#id} (the id of its English heading)"))
                break
            if es_id != en_anchor:
                errors.append(("heading", f"heading id {es_id} should be {en_anchor}"))
                break
    if en.spans + front_spans(en_vals) != es.spans + front_spans(es_vals):
        errors.append(("span", "the backticked spans differ from the English page"))
    if en.links != es.links or en.shortcodes != es.shortcodes:
        errors.append(("links", "the link targets or shortcodes differ from the English page"))
    if len(en.paragraphs) != len(es.paragraphs) or en.items != es.items or en.rows != es.rows:
        errors.append(("shape", "the paragraphs, list items or table rows differ in count from the English page"))
    elif en.paragraphs != es.paragraphs:
        warnings.append(("lines", "a paragraph has another number of lines than the English page"))
    return errors, warnings, False


def spanish_pages(root: Path) -> list[Path]:
    folder = root / "site" / SPANISH
    return sorted(folder.rglob("*.md")) if folder.is_dir() else []


def report(level: str, path: str, code: str, message: str) -> None:
    print(f"{level} {code} {path}: {message}")
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::{level} file={path}::{message}")


def write_summary(rows: list[tuple[str, str]]) -> None:
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if not target:
        return
    lines = ["| page | status |", "| --- | --- |"] + [f"| {page} | {status} |" for page, status in rows]
    with open(target, "a", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")


def check_built(built: Path, stale_pages: dict[str, bool]) -> list[tuple[str, str]]:
    errors = []
    for rel, stale in stale_pages.items():
        page = Path(rel).parent if Path(rel).name == "_index.md" else Path(rel).with_suffix("")
        out = built / "es" / page / "index.html"
        if not out.is_file():
            errors.append(("built", f"no built page {out}"))
            continue
        marked = STALE_MARK.search(out.read_text(encoding="utf-8")) is not None
        if marked != stale:
            errors.append(("built", f"{rel}: Python says stale={stale}, the built page says {marked}"))
    return errors


def run_check(root: Path, strict: bool, built: Path | None) -> int:
    failures, rows, stale_pages = 0, [], {}
    for es_path in spanish_pages(root):
        rel = str(es_path.relative_to(root))
        errors, warnings, stale = check_page(root, es_path)
        stale_pages[str(es_path.relative_to(root / "site" / SPANISH))] = stale
        if stale:
            (errors if strict else warnings).append(("stale", STALE))
        for code, message in errors:
            report("error", rel, code, message)
        for code, message in warnings:
            report("warning", rel, code, message)
        failures += len(errors)
        rows.append((rel, "error" if errors else "stale" if stale else "ok"))
    if built is not None:
        for code, message in check_built(built, stale_pages):
            report("error", str(built), code, message)
            failures += 1
    write_summary(rows)
    print(f"{len(rows)} Spanish pages, {failures} errors")
    return 1 if failures else 0


def run_stamp(root: Path, files: list[str]) -> int:
    for name in files:
        es_path = Path(name).resolve()
        if not es_path.is_relative_to(root / "site" / SPANISH):
            print(f"error orphan {name}: not a page of site/{SPANISH}/", file=sys.stderr)
            return 1
        front, body = split_front(es_path.read_text(encoding="utf-8"))
        if front is None:
            print(f"error front-matter {name}: the page has no front matter", file=sys.stderr)
            return 1
        en_path = english_of(root, es_path)
        if not en_path.is_file():
            print(f"error orphan {name}: no English page {en_path.relative_to(root)}", file=sys.stderr)
            return 1
        text = "\n".join(["---"] + set_hash(front, digest(en_path)) + ["---"]) + "\n" + body
        es_path.write_text(text, encoding="utf-8")
        print(f"stamped {name} with {digest(en_path)}")
    return 0


def run_status(root: Path) -> int:
    english = sorted(p.relative_to(root / "site" / ENGLISH) for p in (root / "site" / ENGLISH).rglob("*.md"))
    spanish = [p.relative_to(root / "site" / SPANISH) for p in spanish_pages(root)]
    missing = [str(p) for p in english if p not in spanish]
    orphans = [str(p) for p in spanish if p not in english]
    stale = [str(p) for p in spanish if p in english and is_stale(root, root / "site" / SPANISH / p)]
    print(f"English pages: {len(english)}; Spanish pages: {len(spanish)}; stale: {len(stale)}")
    for label, names in (("missing", missing), ("orphan", orphans), ("stale", stale)):
        for name in names:
            print(f"{label} {name}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    sub = parser.add_subparsers(dest="command", required=True)
    check = sub.add_parser("check")
    check.add_argument("--strict", action="store_true")
    check.add_argument("--built", type=Path)
    stamp = sub.add_parser("stamp")
    stamp.add_argument("files", nargs="+")
    sub.add_parser("status")
    args = parser.parse_args(argv)
    root = args.root.resolve()
    if args.command == "check":
        return run_check(root, args.strict, args.built)
    if args.command == "stamp":
        return run_stamp(root, args.files)
    return run_status(root)


if __name__ == "__main__":
    sys.exit(main())
