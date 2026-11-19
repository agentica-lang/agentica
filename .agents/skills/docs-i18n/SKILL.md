---
name: docs-i18n
description: >-
  Translate a page of site/content into Spanish under site/content.es/, update
  a Spanish page after its English page changed, or review such a translation.
  Use for any Spanish docs work: the rules, the glossary, the workflow and the
  review checklist. Not for English docs (use documentation-writing).
---

# Translating the docs

A Spanish page lives in `site/content.es/`, at the same path as its English
page in `site/content/`. The English page is the source. A change to the
meaning goes into English first, then into Spanish.

Terms come from `references/glossary-es.md`. Read it before you translate.

## The rules

1. Names of products and projects are never translated: Agentica, Finn,
   OpenSSL, libgc, Hugo, GitHub, Node, Python, ripgrep.
2. Code is always English: identifiers, comments, strings, file names, CLI
   commands and flags, program output. Translate only the prose around a
   block.
3. Never translate: diagnostic codes (`CHECK-...`), API, builtin and `std/`
   names, keywords, types, config keys, env vars, and anything in backticks.
   Shortcode names stay. In an `example` shortcode, translate only the
   `title`; every other attribute stays.
4. Use the glossary. A new term goes into the glossary in the PR that first
   uses it, in sorted order. A rename is one PR that changes the glossary and
   every Spanish page that uses the term.
5. Keep the structure 1:1: the same headings in the same order, the same
   lists, tables and shortcodes. One line per paragraph and per list item,
   line for line where possible (`site/content/` rule in AGENTS.md).
6. Links: keep every target as it is in English, including external ones.
   Translate the words inside the brackets. From P2 on, a link to a page with
   no Spanish version goes to the English page. Before P2, do not link to an
   untranslated page. Every Spanish heading ends with `{#id}`, the id its
   English heading gets: the heading's own `{#id}` if it has one, else the id
   Hugo makes from its text (`render-heading.html` prints it as `.Anchor`).
   `make site-translations` checks it.
7. Front matter: translate `title` and `description`. Copy `weight`, `slug`,
   `aliases` and `url` unchanged. Add `source_hash` (see the workflow).
8. Tone: neutral international Spanish, *tú*, never *vosotros*. Simple words
   and short sentences (AGENTS.md, "Working style"). Add no sentence and drop
   no sentence. A sentence that is wrong in English is fixed in English first.
9. Checks: `make site` is green, `make site-translations` is green, and a
   reviewer agent approves the PR with the checklist below. The
   owner samples the published pages; a problem found there becomes a rule
   here.
10. Interface strings (the theme's `i18n/es.toml` keys, button labels, search
    and banner messages) follow the same glossary.

## Workflow

1. Pick the English page. To update one, read what changed:
   `git log -p -- site/content/X`.
2. Copy it to the same path: `mkdir -p site/content.es/DIR` then
   `cp site/content/X site/content.es/X`.
3. Translate the prose: front matter, headings, paragraphs, list items, table
   cells and the `title` attribute of an `example` shortcode. Leave the code
   and the other shortcode attributes alone.
4. Add `source_hash` to the front matter: the first 12 hex digits of the
   SHA-256 of the English file bytes. Run
   `python3 -I tools/site_translations.py stamp site/content.es/X`; it writes
   the hash of `site/content/X` into the front matter.
5. Check: run `make site-translations`. It reports the structure errors and
   the stale pages. `python3 -I tools/site_translations.py status` prints the
   coverage: the missing and the stale pages.

6. Run `make site`. It builds with `--panicOnWarning`, so a broken link fails.
7. Open the PR. The body says which English page and which commit you
   translated, and which terms you added to the glossary.

## What CI checks and what a reviewer checks

`make site-translations` checks these and fails the job:

- the English page exists (no orphan);
- front matter: `title`, `description` and `source_hash` exist; `weight`,
  `slug`, `aliases` and `url` equal the English ones;
- fenced code blocks are byte-identical to English, info string included;
- same number of headings, same levels in the same order, same anchors;
- the backticked spans are the same, with the same count of each;
- the same link targets in the same order, and the same shortcode names;
- the same number of list items, table rows and shortcodes.

It warns, and does not fail, when a paragraph has another number of lines
than English, and when `source_hash` no longer matches the English file
(a stale page). `--strict` turns the stale warning into a failure. A stale
page shows its readers a note that links to the English page. CI checks that
the note is on exactly the stale pages (`check --built`). `make site` checks
the links.

A reviewer agent checks what no tool can:

- Terms: for each glossary term in the English page, find the same place in
  the Spanish page. Check that its Spanish form is the one in the glossary
  row, or "stays". A term with no row is a new term: this PR adds it to the
  glossary.
- Code blocks and backticked spans are identical to the English page.
- The same headings, order, lists, tables and shortcodes. Shortcode
  attributes are identical, except the `title` of `example`.
- Each Spanish heading ends with `{#id}`, equal to the id its English heading
  gets (rule 6).
- Front matter: the rules of rule 7. `source_hash` equals the first 12 hex
  digits of the SHA-256 of the English file. Example, with a made-up hash:

  ```yaml
  ---
  title: Cadenas e interpolación
  description: Literales de cadena, escapes, interpolación y métodos.
  weight: 3
  source_hash: 9c1e4f0a7b2d
  ---
  ```

- No added or dropped sentences: compare the two pages sentence by sentence.
- Tone: neutral Spanish, *tú*, no *vosotros*, simple words.
- Links: the targets are the English ones, and the labels are Spanish.
- Width: the skill files and the glossary have no line over 80 columns. Run
  `awk 'length > 80' FILE` on each one; it must print nothing. The
  `test_style_line_width.py` test covers only `.agc` files. Site pages keep one
  line per paragraph, so they are not checked for width.
- Product names, interface strings, and the terms of rules 1, 4 and 10.

A reviewer approves when every point passes. Otherwise the reviewer says
"changes requested" and gives the line of each problem. The owner samples the
published pages, and a problem found there becomes a rule here.
