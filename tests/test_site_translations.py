"""tools/site_translations.py: the structure rules of the Spanish pages, the stale marker and its built cross-check.

Fixture trees hold one English page and its Spanish copy; the tool runs on them through its CLI (`main`), without Hugo.
"""
import hashlib
import importlib.util

import pytest

from tests.agentica_test import ROOT

ENGLISH = """---
title: Lists
description: A page for the tests.
weight: 2
---

# Lists

Intro paragraph.

## Reading lists

A list of items:

- one
- two

| a | b |
| - | - |
| 1 | 2 |

```agentica
let x = 1
```

See [the tour](/tour/) and `x`.
"""

SPANISH = """---
title: Listas
description: Una página para las pruebas.
weight: 2
source_hash: {hash}
---

# Listas {#lists}

Párrafo de introducción.

## Lectura de listas {#reading-lists}

Una lista de elementos:

- uno
- dos

| a | b |
| - | - |
| 1 | 2 |

```agentica
let x = 1
```

Mira [el tour](/tour/) y `x`.
"""


def load_tool():
    spec = importlib.util.spec_from_file_location("agentica_site_translations", ROOT / "tools" / "site_translations.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = load_tool()


def write_pages(root, english=ENGLISH, spanish=SPANISH):
    """The English page and its Spanish copy, with the hash of the English file as the Spanish source_hash."""
    en = root / "site" / "content" / "lists.md"
    es = root / "site" / "content.es" / "lists.md"
    en.parent.mkdir(parents=True, exist_ok=True)
    es.parent.mkdir(parents=True, exist_ok=True)
    en.write_text(english, encoding="utf-8")
    es.write_text(spanish.replace("{hash}", hashlib.sha256(english.encode()).hexdigest()[:12]), encoding="utf-8")
    return en, es


def run(capsys, root, *args):
    code = tool.main(["--root", str(root), *args])
    return code, capsys.readouterr().out


def codes(out, level="error"):
    return {line.split()[1] for line in out.splitlines() if line.startswith(level + " ")}


def newer(english=ENGLISH):
    """The English page after an edit that keeps its paragraphs: a new sentence in the first one."""
    return english.replace("Intro paragraph.", "Intro paragraph. A new sentence.")


def test_a_translation_with_the_same_structure_passes(tmp_path, capsys):
    write_pages(tmp_path)
    assert run(capsys, tmp_path, "check") == (0, "1 Spanish pages, 0 errors\n")


@pytest.mark.parametrize("rule, edit", [
    ("front-matter", lambda s: s.replace("title: Listas\n", "")),
    ("front-matter", lambda s: s.replace("weight: 2", "weight: 3")),
    ("front-matter", lambda s: s.replace("source_hash:", "source_stamp:")),
    ("front-matter", lambda s: s.replace("source_hash: ", "source_hash: AB")),
    ("code", lambda s: s.replace("let x = 1", "let x = 2")),
    ("code", lambda s: s.replace("```agentica", "```text")),
    ("heading", lambda s: s.replace("## Lectura de listas {#reading-lists}", "### Lectura de listas {#reading-lists}")),
    ("heading", lambda s: s.replace(" {#reading-lists}", "")),
    ("heading", lambda s: s.replace("{#reading-lists}", "{#lectura}")),
    ("span", lambda s: s.replace("`x`", "`y`")),
    ("links", lambda s: s.replace("(/tour/)", "(/library/)")),
    ("shape", lambda s: s.replace("- dos\n", "")),
])
def test_a_broken_rule_is_an_error_with_its_code(tmp_path, capsys, rule, edit):
    write_pages(tmp_path, spanish=edit(SPANISH))
    code, out = run(capsys, tmp_path, "check")
    assert code == 1 and codes(out) == {rule}, out


def test_a_page_with_no_english_page_is_an_orphan(tmp_path, capsys):
    write_pages(tmp_path)
    (tmp_path / "site" / "content" / "lists.md").unlink()
    code, out = run(capsys, tmp_path, "check")
    assert code == 1 and codes(out) == {"orphan"}, out


def test_a_split_paragraph_is_only_a_warning(tmp_path, capsys):
    write_pages(tmp_path, spanish=SPANISH.replace("Párrafo de introducción.", "Párrafo de\nintroducción."))
    code, out = run(capsys, tmp_path, "check")
    assert code == 0 and codes(out, "warning") == {"lines"}, out


def test_a_stale_page_warns_and_strict_fails(tmp_path, capsys):
    en, _ = write_pages(tmp_path)
    en.write_text(newer(), encoding="utf-8")
    code, out = run(capsys, tmp_path, "check")
    assert code == 0 and codes(out, "warning") == {"stale"}, out
    code, out = run(capsys, tmp_path, "check", "--strict")
    assert code == 1 and codes(out) == {"stale"}, out
    assert run(capsys, tmp_path, "status")[1].splitlines()[0] == "English pages: 1; Spanish pages: 1; stale: 1"


def test_stamp_writes_the_hash_of_the_english_bytes_and_the_check_is_clean(tmp_path, capsys):
    en, es = write_pages(tmp_path, spanish=SPANISH.replace("source_hash: {hash}\n", ""))
    en.write_text(newer(), encoding="utf-8")
    assert tool.main(["--root", str(tmp_path), "stamp", str(es)]) == 0
    capsys.readouterr()
    stamped = es.read_text(encoding="utf-8")
    assert "source_hash: " + hashlib.sha256(en.read_bytes()).hexdigest()[:12] + "\n---" in stamped
    assert run(capsys, tmp_path, "check") == (0, "1 Spanish pages, 0 errors\n")


def built_page(root, marked):
    page = root / "built" / "es" / "lists" / "index.html"
    page.parent.mkdir(parents=True, exist_ok=True)
    page.write_text("<body>" + ('<aside data-translation=stale>' if marked else "") + "</body>", encoding="utf-8")
    return root / "built"


def test_the_built_site_marks_exactly_the_stale_pages(tmp_path, capsys):
    en, _ = write_pages(tmp_path)
    en.write_text(newer(), encoding="utf-8")
    built = built_page(tmp_path, marked=True)
    assert run(capsys, tmp_path, "check", "--built", str(built))[0] == 0
    built_page(tmp_path, marked=False)
    code, out = run(capsys, tmp_path, "check", "--built", str(built))
    assert code == 1 and codes(out) == {"built"}, out


def test_a_fresh_page_must_not_be_marked_stale_in_the_build(tmp_path, capsys):
    write_pages(tmp_path)
    built = built_page(tmp_path, marked=True)
    code, out = run(capsys, tmp_path, "check", "--built", str(built))
    assert code == 1 and codes(out) == {"built"}, out
