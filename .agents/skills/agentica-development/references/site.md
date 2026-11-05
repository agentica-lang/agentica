# Documentation site

The site's design rules are in `site/DESIGN.md`.

Read this before changing `site/`, a site page, or a builtin or language
rule that a site page shows.

## Build

- `make site` builds `site/public` (Hugo extended; the Hugo and Dart Sass
  versions are pinned in `pages.yml`; `mk/site.mk` says where `sass` must be).
  Warnings fail the build. `make site-serve` serves it. Styles are SCSS partials
  in `site/assets/scss/` (custom properties in `_tokens.scss`).
- `make site` also needs Node: after Hugo, `site/highlight/highlight.mjs` colors
  every `agentica` block with the TextMate grammar of agc-tmlanguage (copied to
  `site/highlight/agentica.tmLanguage.json`; its `package.json` `grammar` field
  is the source commit). `render-codeblock.html` wraps each block in
  `div.agc-code` for it and fails the build on Hugo highlight options
  (`linenos`, `hl_lines`); the script fails on a block of another shape, an
  unknown HTML entity or a `CLASSES` entry that colors no token.
  `make site-serve` skips the script. The same script colors the `signature`
  blocks with a small tokenizer and fails on a line of another shape.
- To update the grammar, copy `syntaxes/agentica.tmLanguage.json` from
  agc-tmlanguage, set the `grammar` field to its commit and run `make site`.
- The site shows the version of the `VERSION` file (header, footer, `llms.txt`,
  `llms-full.txt`, Getting started). `make site` passes it to Hugo as
  `HUGO_PARAMS_VERSION`, and `_partials/version.html` fails a plain `hugo`
  build without it. Never type the version in `site/`. The Getting started text
  comes from the `release` shortcode (`layouts/_shortcodes/release.md`).
- `/search.json` is built from `layouts/home.search.json` (never edit it by
  hand).

## Content

- The Library is grouped by topic: `library/TOPIC/_index.md` (a short intro
  that says which form fits which job) and one page per builtin module in
  `library/TOPIC/NAME.md`. A new module page goes into a topic folder. Order and
  titles come from front matter (`title`, `weight`); the sidebar, the list
  pages, `llms.txt` and `search.json` follow the tree.
- `docs/grammar/*.md` is the language specification (`/reference/`). The
  index is `content/reference/_index.md`. The content adapter
  `content/_content.gotmpl` adds one page per file at `/reference/<slug>/`,
  the file name without its number (`04-lexical.md` is `lexical`). Every file
  needs an entry in the adapter's `$info` table (short title and one-line
  description), and every entry needs a file; the build fails otherwise. A
  file's first heading is the page's own heading and is removed from the body;
  the other headings move up one level.
- The adapter rewrites the links between parts: `](NN-name.md#anchor)` (or
  `./NN-name.md`) becomes `](/reference/<slug>/#anchor)`, and
  `](../../site/content/library/TOPIC/NAME.md)` becomes
  `](/library/TOPIC/NAME/)` (also `TOPIC/_index.md`, `library/_index.md` and
  nested folders). Write these links inline, not as `[text][ref]`
  definitions, which the adapter does not rewrite. A link to a removed heading
  goes to the page top, `/reference/<slug>/`. Other relative links stay as
  written.
- The programming skill is for agents and is not published.
- Links to the GitHub repo are shown only when `params.repoPublic` is true.
- When the language changes, update the matching site page too. A builtin or
  `std/` module is documented only in its `library/` page; `docs/grammar/`
  keeps the rules the checker enforces and points to that page.
- Do not hard-wrap prose in `site/content/`: one line per paragraph or list
  item. Hugo joins the lines anyway. Code blocks keep their own line breaks.

## Markdown and llms.txt

Every page is also published as Markdown (`layouts/all.markdown.md`;
`_partials/markdown-links.html` rewrites links to `.md` URLs, and
`home.llms.txt` fails the build if that rewrite changes). It skips top-level
``` fences, code spans and images, but not `~~~` or 4-backtick fences. Fence
attributes become plain text: `{expect="CHECK-X"}` adds ``Does not compile:
`error[CHECK-X]` `` after the block, `{file="a.agc"}` adds ``File `a.agc`:``
before it. `/llms.txt` and `/llms-full.txt` come from
`_partials/llms-groups.html`.

## Examples are tests

Every `agentica` code block in `site/content` must be a complete program.
`tests/test_site_examples.py` checks each one and runs it with the CLI (stdin
from an optional `input` block right after it), and compares stdout with the
`output` block that follows. `make test` runs the `SMOKE_PAGES` of that file as
a smoke; the whole site runs in the slow tier (`make test-slow`).
`.github/workflows/site-examples.yml` runs both tiers of this file alone on
pull requests that change only `site/content` (CI skips those).

Fence attributes:

- `{mode="check"}` only checks. Use it for examples that touch files,
  processes, the network or other outside state.
- `{expect="CODE"}` expects that diagnostic. `render-codeblock.html` shows
  `error[CODE]` in a box below the code, labeled "Runtime error" for
  `RUNTIME-` codes and "Does not compile" otherwise. It shows only the code,
  so the page cannot drift from the diagnostic message.
- `{file="name.agc"}` is a module that the page's other blocks can import.
- `{fmt="off"}` leaves the block out of the format check (below). Use it only
  for a block that is wrong or partial on purpose: a style rule shown by
  hand, a program that does not parse (`PARSE-` codes), or syntax that `fmt`
  rewrites but the page teaches.

Every other `agentica` block must already be in the layout of `agentica fmt`
(the `agentica.toml` of the test sets `blank_line_after_end`).
`test_every_site_example_is_formatted` writes the blocks to files and runs
`fmt --check` once; it is in the fast tier, so `make test` runs it. To fix a
failure, run `dist/agentica fmt` on the block (paste it into a file in a folder
with `[style]` `blank_line_after_end = true`), then put the result back; do not
hand-edit. The comment that `fmt` moves to another line may then say the wrong
thing: put it on a line of its own above the code first. Bond's and
agentica-db's docs sites are in their repositories, with their own checks.

A function signature (`Name.fn(a: T) -> R`) goes in a `signature` fence, not
`text` or `agentica`: the test skips it and the site colors it.

## Deploy

`.github/workflows/pages.yml` runs `make site` on pull requests and `master`
pushes that touch the site or its sources; only a `master` push deploys it to
GitHub Pages.

Never cancel a Pages run while its `deploy-pages` step runs: GitHub keeps that
Pages deployment "in progress", every later deploy fails with "due to in
progress deployment", and only time (about half an hour) or Settings → Pages →
Source clears it.
