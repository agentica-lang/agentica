#!/usr/bin/env python3
"""Check the Spanish pages against their English pages (`make site-translations`; pages.yml).

    site_translations.py check [--strict] [--built DIR] [--root DIR]
    site_translations.py stamp FILE... [--root DIR]
    site_translations.py status [--root DIR]

Each page of site/content.es/ translates the page at the same path in site/content/. `check` fails when a Spanish page
breaks a structure rule, and warns when a page is stale: its source_hash (the first 12 hex digits of the SHA-256 of the
English file's bytes) is not the hash of the English file now. `--strict` makes a stale page a failure. `--built DIR`
(a built site root, such as build/site-versions/public/dev) checks that the Spanish pages Hugo marks stale, with
data-translation="stale" from the site's page-notice partial, are exactly the stale pages here. So the two SHA-256
implementations agree. `stamp` writes the hash into the front matter; `status` prints the coverage.
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
FENCE = re.compile(r"^(`{3,})(.*)$")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*$")
EXPLICIT_ID = re.compile(r"^(.*?)\s*\{#([\w-]+)\}$")
LIST_ITEM = re.compile(r"^\s*(?:[-*+]|\d+[.)])\s")
TABLE_ROW = re.compile(r"^\s*\|")
SHORTCODE = re.compile(r"\{\{[<%]\s*(/?)\s*([\w.-]+)")
STALE_MARK = re.compile(r'data-translation=["\']?stale\b')


@dataclass
class Body:
    code: list = field(default_factory=list)
    headings: list = field(default_factory=list)
    spans: Counter = field(default_factory=Counter)
    links: list = field(default_factory=list)
    shortcodes: list = field(default_factory=list)
    items: int = 0
    rows: int = 0
    paragraphs: list = field(default_factory=list)


def split_front(text):
    """(front matter lines, body), or (None, text) for a page without front matter."""
    if not text.startswith("---\n"):
        return None, text
    end = text.find("\n---\n", 3)
    if end < 0:
        return None, text
    return text[4:end].split("\n"), text[end + 5:]


def front_values(lines):
    values, key = {}, None
    for line in lines:
        match = re.match(r"^([A-Za-z_][\w-]*):(.*)$", line)
        if match:
            key = match.group(1)
            values[key] = match.group(2).strip()
        elif key and line[:1] in (" ", "\t", "-"):
            values[key] += "\n" + line
    return values


def set_hash(lines, digest):
    out = [line for line in lines if not re.match(r"^source_hash:", line)]
    return out + [f"source_hash: {digest}"]


def anchor(text):
    """The id that Hugo's GitHub-style heading ids give a heading text, for a heading with no {#id} of its own."""
    text = text.replace("`", "").replace("*", "").lower()
    kept = "".join(c for c in text if c.isalnum() or c in "-_ ")
    return kept.replace(" ", "-")


def scan(body):
    result = Body()
    fence, info, code_lines = None, "", []
    prose = []
    for line in body.split("\n"):
        if fence is None:
            match = FENCE.match(line)
            if match:
                fence, info, code_lines = match.group(1), match.group(2).strip(), []
            else:
                prose.append(line)
        elif line.strip() == fence:
            result.code.append((info, "\n".join(code_lines)))
            fence = None
        else:
            code_lines.append(line)
    seen, paragraph = Counter(), []
    for line in prose:
        result.spans.update(re.findall(r"`([^`]+)`", line))
        result.links += re.findall(r"\]\(([^)\s]+)", line)
        result.shortcodes += [("/" if closing else "") + name for closing, name in SHORTCODE.findall(line)]
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
        plain = line.strip()
        if plain and not (heading or LIST_ITEM.match(line) or TABLE_ROW.match(line) or plain.startswith("{{")):
            paragraph.append(plain)
        elif paragraph:
            result.paragraphs.append(len(paragraph))
            paragraph = []
    if paragraph:
        result.paragraphs.append(len(paragraph))
    return result


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()[:12]


def english_of(root, es_path):
    return root / "site" / ENGLISH / es_path.relative_to(root / "site" / SPANISH)


def is_stale(root, es_path):
    """True when the page's source_hash is not the hash of its English file now."""
    front, _ = split_front(es_path.read_text(encoding="utf-8"))
    stamp = front_values(front or []).get("source_hash")
    return bool(stamp) and stamp != digest(english_of(root, es_path))


def check_page(root, es_path):
    """(errors, warnings, stale) of one Spanish page: errors and warnings are (code, message) pairs."""
    en_path = english_of(root, es_path)
    errors, warnings = [], []
    if not en_path.is_file():
        return [("orphan", f"no English page {en_path.relative_to(root)}")], [], False
    en_front, en_body = split_front(en_path.read_text(encoding="utf-8"))
    es_front, es_body = split_front(es_path.read_text(encoding="utf-8"))
    if es_front is None:
        return [("front-matter", "the page has no front matter")], [], False
    es_vals = front_values(es_front)
    en_vals = front_values(en_front or [])
    for key in REQUIRED:
        if not es_vals.get(key):
            errors.append(("front-matter", f"front matter has no {key}"))
    if es_vals.get("source_hash") and not re.fullmatch(r"[0-9a-f]{12}", es_vals["source_hash"]):
        errors.append(("front-matter", "source_hash is not 12 lowercase hex digits"))
    for key in COPIED:
        if (key in en_vals or key in es_vals) and en_vals.get(key) != es_vals.get(key):
            errors.append(("front-matter", f"{key} differs from the English page"))
    en, es = scan(en_body), scan(es_body)
    if len(en.code) != len(es.code) or any(a != b for a, b in zip(en.code, es.code)):
        errors.append(("code", "the fenced code blocks differ from the English page (info string included)"))
    if [h[0] for h in en.headings] != [h[0] for h in es.headings]:
        errors.append(("heading", "the headings differ in count or level from the English page"))
    else:
        for (_, en_id, en_anchor), (_, es_id, _) in zip(en.headings, es.headings):
            if es_id is None:
                errors.append(("heading", "a heading has no {#id} (the id of its English heading)"))
                break
            if es_id != en_anchor:
                errors.append(("heading", f"heading id {es_id} should be {en_anchor}"))
                break
    if en.spans != es.spans:
        errors.append(("span", "the backticked spans differ from the English page"))
    if en.links != es.links or en.shortcodes != es.shortcodes:
        errors.append(("links", "the link targets or shortcodes differ from the English page"))
    if en.items != es.items or en.rows != es.rows:
        errors.append(("shape", "the list items or table rows differ from the English page"))
    if en.paragraphs != es.paragraphs:
        warnings.append(("lines", "a paragraph has another number of lines than the English page"))
    return errors, warnings, is_stale(root, es_path)


def spanish_pages(root):
    folder = root / "site" / SPANISH
    return sorted(folder.rglob("*.md")) if folder.is_dir() else []


def write_summary(rows):
    target = os.environ.get("GITHUB_STEP_SUMMARY")
    if not target:
        return
    lines = ["| page | status |", "| --- | --- |"] + [f"| {page} | {status} |" for page, status in rows]
    with open(target, "a", encoding="utf-8") as out:
        out.write("\n".join(lines) + "\n")


def check_built(root, built, stale_pages):
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


def run_check(root, strict, built):
    failures, rows, stale_pages = 0, [], {}
    for es_path in spanish_pages(root):
        rel = str(es_path.relative_to(root))
        errors, warnings, stale = check_page(root, es_path)
        stale_pages[str(es_path.relative_to(root / "site" / SPANISH))] = stale
        for code, message in errors:
            print(f"error {code} {rel}: {message}")
            if os.environ.get("GITHUB_ACTIONS"):
                print(f"::error file={rel}::{message}")
        for code, message in warnings:
            print(f"warning {code} {rel}: {message}")
            if os.environ.get("GITHUB_ACTIONS"):
                print(f"::warning file={rel}::{message}")
        if stale:
            message = "the English page changed after this translation (source_hash differs)"
            if strict:
                print(f"error stale {rel}: {message}")
                errors.append(("stale", message))
            else:
                print(f"warning stale {rel}: {message}")
                if os.environ.get("GITHUB_ACTIONS"):
                    print(f"::warning file={rel}::{message}")
        failures += len(errors)
        rows.append((rel, "error" if errors else "stale" if stale else "ok"))
    if built is not None:
        for code, message in check_built(root, built, stale_pages):
            print(f"error {code} {built}: {message}")
            failures += 1
    write_summary(rows)
    print(f"{len(rows)} Spanish pages, {failures} errors")
    return 1 if failures else 0


def run_stamp(root, files):
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


def run_status(root):
    english = sorted(p.relative_to(root / "site" / ENGLISH) for p in (root / "site" / ENGLISH).rglob("*.md"))
    spanish = [p.relative_to(root / "site" / SPANISH) for p in spanish_pages(root)]
    missing = [str(p) for p in english if p not in spanish]
    stale = [str(p) for p in spanish if is_stale(root, root / "site" / SPANISH / p)]
    print(f"English pages: {len(english)}; Spanish pages: {len(spanish)}; stale: {len(stale)}")
    for name in missing:
        print(f"missing {name}")
    for name in stale:
        print(f"stale {name}")
    return 0


def main(argv=None):
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
