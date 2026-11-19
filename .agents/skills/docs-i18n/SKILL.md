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
   Shortcode names and their other attributes stay too.
4. Use the glossary. A new term goes into the glossary in the PR that first
   uses it, in sorted order. A rename is one PR that changes the glossary and
   every Spanish page that uses the term.
5. Keep the structure 1:1: the same headings in the same order, the same
   lists, tables and shortcodes. One line per paragraph and per list item,
   line for line where possible (`site/content/` rule in AGENTS.md).
6. Links: keep every target as it is in English, including external ones.
   Translate the words inside the brackets. The build sends a reader to the
   Spanish page when it exists, else to the English one. Anchors are set by
   hand: `## Texto {#english-id}`, with the id the English heading has.
7. Front matter: translate `title` and `description`. Copy `weight`, `slug`,
   `aliases` and `url` unchanged. Add `source_hash` (see the workflow).
8. Tone: neutral international Spanish, *tú*, never *vosotros*. Simple words
   and short sentences, as in documentation-writing. Add no sentence and drop
   no sentence. A sentence that is wrong in English is fixed in English first.
9. Checks: `make site` is green, `make site-translations` is green (once P4
   lands), and a reviewer agent approves the PR with the checklist below. The
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
   cells and the `title` of an example shortcode. Leave the code alone.
4. Add `source_hash` to the front matter: the first 12 hex digits of the
   SHA-256 of the English file bytes:
   `sha256sum site/content/X | cut -c1-12`. Once P4 lands, use
   `python3 tools/site_translations.py stamp site/content.es/X`.
5. Check. Once P4 lands, run `make site-translations`. Before that, check the
   code blocks by hand. No output means they match:

   ```sh
   diff <(awk '/^```/{f=!f} f' site/content/X) \
     <(awk '/^```/{f=!f} f' site/content.es/X)
   ```

6. Run `make site`. It builds with `--panicOnWarning`, so a broken link fails.
7. Open the PR. The body says which English page and which commit you
   translated, and which terms you added to the glossary.

## What CI checks and what a reviewer checks

Once P4 lands, `make site-translations` checks these and fails the job:

- the English page exists (no orphan);
- front matter: `title`, `description` and `source_hash` exist; `weight`,
  `slug`, `aliases` and `url` equal the English ones;
- fenced code blocks are byte-identical to English, info string included;
- same number of headings, same levels in the same order, same anchors;
- the backticked spans are the same, as a multiset;
- the same link targets in the same order, and the same shortcode names;
- the same number of list items, table rows and shortcodes.

It warns, and does not fail, when a paragraph has another number of lines
than English, and when `source_hash` no longer matches the English file
(a stale page). `--strict` turns the stale warning into a failure. `make site`
checks the links.

A reviewer agent checks what no tool can:

- every term matches the glossary, and a new term is in the glossary;
- code blocks and backticked spans are identical to the English page;
- the same headings, order, lists, tables and shortcodes;
- each Spanish heading has the English `{#id}` anchor when the English
  heading has one;
- front matter: the rules of rule 7;
- no added or dropped sentences: compare the two pages sentence by sentence;
- the tone: neutral Spanish, *tú*, no *vosotros*, simple words;
- links: the targets are the English ones, and the labels are Spanish;
- product names, interface strings and the glossary terms of rules 1, 4
  and 10.

A reviewer says "changes requested" with the line numbers of each problem.
