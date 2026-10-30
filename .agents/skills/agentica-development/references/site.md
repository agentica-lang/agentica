# Documentation site

The site's design rules are in `site/DESIGN.md`.

Read this before changing `site/`, a site page, or a builtin or language
rule that a site page shows.

## Build

- The site is in `site/` and uses Hugo extended (the version and the Dart Sass
  version, with their sha256, are pinned in `pages.yml`).
- `make site` builds `site/public`. Warnings fail the build.
- `make site-serve` serves it at `http://localhost:1313/agentica/`.
- Styles are SCSS partials in `site/assets/scss/` (custom properties in
  `_tokens.scss`). Dart Sass compiles them through Hugo Pipes; they are
  minified with the JS and HTML.
- `make site` needs Dart Sass's `sass` on PATH or in
  `~/.local/opt/dart-sass`.
- `make site` also needs Node; it installs `site/highlight/node_modules` with
  `npm ci` when the package files change. After Hugo,
  `site/highlight/highlight.mjs` colors every `agentica` block with the
  TextMate grammar of agc-tmlanguage, copied to
  `site/highlight/agentica.tmLanguage.json` (the source commit is the
  `grammar` field of its `package.json`). Each token gets the Chroma class
  whose color it should have, so `_code.scss` styles both. The script fails
  when it finds no block. `render-codeblock.html` wraps each block in
  `div.agc-code` for it and fails the build when such a block has Hugo
  highlight options (`linenos`, `hl_lines`); the script fails on a block of
  another shape or an unknown HTML entity, or when an entry of `CLASSES`
  colors no token. `make site-serve` skips the script, so there the blocks
  keep Hugo's Ruby colors.
- To update the grammar, copy `syntaxes/agentica.tmLanguage.json` from
  agc-tmlanguage, set the `grammar` field to its commit and run `make site`.

## Version

- The site shows the version of the `VERSION` file in the header, the footer,
  `llms.txt`, `llms-full.txt` and the Install section of Getting started, with
  links to the GitHub release of that tag and to all releases.
- `make site` and `make site-serve` read it (`AGC_VERSION`) and pass it to Hugo
  as `HUGO_PARAMS_VERSION`; `pages.yml` builds with `make site`, so it follows.
  `_partials/version.html` fails the build when it is missing (plain `hugo`
  without the variable). Never type the version in `site/`.
- The Getting started text comes from the `release` shortcode
  (`layouts/_shortcodes/release.md`).

## Search

- `layouts/home.search.json` builds `/search.json` at build time (the
  `search` output format of the home page in `hugo.toml`), with one entry per
  page and the plain text split at each `h2`/`h3`, so results link to the
  heading anchor. Never edit it by hand.
- The UI is `_partials/search.html`, `assets/js/search.js` and
  `assets/scss/_search.scss`: plain JS, no library; the index loads on first
  focus.

## Content

- The user docs live in `site/content`: Getting started, the command line in
  `cli.md`, the Language tour in `tour/`, the Library in `library/`, `vm.md`
  (the Aurora VM and its libraries) and `design.md` (the main design decisions
  and why each was taken).
- The Library is grouped by topic: `library/TOPIC/_index.md` (a short intro
  that says which form fits which job) and one page per builtin module in
  `library/TOPIC/NAME.md`, plus the `algorithms.md` page of runnable recipes.
  A new module page goes into a topic folder, so its URL is
  `/library/TOPIC/NAME/`. Order and titles come from front matter (`title`,
  `weight`); the sidebar, the list pages, `llms.txt` and `search.json` follow
  the tree.
- `docs/grammar/*.md` is the language specification (`/reference/`). The
  index is `content/reference/_index.md`. The content adapter
  `content/_content.gotmpl` adds one page per file at `/reference/<slug>/`,
  the file name without its number (`04-lexical.md` is `lexical`), read through
  an assets mount (`hugo.toml`). Weights follow the sorted file names. Every
  file needs an entry in the adapter's `$info` table (short title and one-line
  description), and every entry needs a file; the build fails otherwise. A
  file's first heading is the page's own heading: it is removed from the body
  so no heading shows twice. The other headings move up so the top sections are
  h2, which the in-page TOC lists. The adapter fails the build when fewer than
  10 files are found. `layouts/reference/list.html` lists the parts with their
  descriptions.
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

- Every page is also published as Markdown next to its HTML
  (`/tour/variables/index.md`, Hugo's `markdown` output format and
  `layouts/all.markdown.md`). `_partials/markdown-links.html` points links at
  the other pages' `.md` URLs; it skips top-level ``` fences, backtick code
  spans and images, but not `~~~` fences, fences of 4 or more backticks, or
  indented fences, and `home.llms.txt` fails the build if that rewrite changes
  (`markdown-links-check.html`).
- Fence attributes become plain text: `{expect="CHECK-X"}` adds ``Does not
  compile: `error[CHECK-X]` `` after the block (`RUNTIME-X`: ``Runtime error:
  ...``), and `{file="a.agc"}` adds ``File `a.agc`:`` before it unless the
  prose right above already ends with `` `a.agc`: ``.
- The home page also renders `/llms.txt` (an index) and `/llms-full.txt` (every
  page's Markdown with its source URL), in the order of
  `_partials/llms-groups.html`, with absolute URLs from `baseURL`.

## Examples are tests

Every `agentica` code block in `site/content` must be a complete program.
`tests/test_site_examples.py` checks each one and runs it with the CLI (stdin
from an optional `input` block right after it), and compares stdout with the
`output` block that follows. `make test` runs the `SMOKE_PAGES` of that file as
a smoke; the whole site runs in the slow tier (`make test-slow`).
`.github/workflows/site-examples.yml` runs the slow tier of this file alone on
pull requests that change only `site/content` (CI skips those).

Fence attributes:

- `{mode="check"}` only checks. Use it for examples that touch files,
  processes, the network or other outside state.
- `{expect="CODE"}` expects that diagnostic. `render-codeblock.html` shows
  `error[CODE]` in a box below the code, labeled "Runtime error" for
  `RUNTIME-` codes and "Does not compile" otherwise. It shows only the code,
  so the page cannot drift from the diagnostic message.
- `{file="name.agc"}` is a module that the page's other blocks can import.

## Deploy

`.github/workflows/pages.yml` runs `make site` on pull requests and `master`
pushes that touch the site or its sources; only a `master` push deploys it to
GitHub Pages.

Never cancel a Pages run while its `deploy-pages` step runs: GitHub keeps that
Pages deployment "in progress", every later deploy fails with "due to in
progress deployment", and only time (about half an hour) or Settings → Pages →
Source clears it.
