# Documentation site

Read this before changing `site/`, a site page, or a builtin or language
rule that a site page shows.

## Build

- The site is in `site/` and uses Hugo extended 0.167.
- `make site` builds `site/public`. Warnings fail the build.
- `make site-serve` serves it at `http://localhost:1313/agentica/`.
- Styles are SCSS partials in `site/assets/scss/` (custom properties in
  `_tokens.scss`). Dart Sass compiles them through Hugo Pipes; they are
  minified with the JS and HTML.
- `make site` needs Dart Sass's `sass` on PATH or in
  `~/.local/opt/dart-sass`. The pinned version and sha256 are in
  `pages.yml`.

## Search

- `layouts/home.search.json` builds `/search.json` at build time (the
  `search` output format of the home page in `hugo.toml`). It has one entry
  per page (title, section, URL, summary) with the plain text split at each
  `h2`/`h3`, so results link to the heading anchor. It changes with the
  content; never edit it by hand.
- `_partials/search.html` (in the header), `assets/js/search.js` and
  `assets/scss/_search.scss` are the UI: plain JS, no library. The index
  loads on first focus. `/` or Ctrl/Cmd+K focuses, arrows choose, Enter
  opens, Escape closes.

## Content

- The user docs live in `site/content`: Getting started, the Language tour
  in `tour/`, one Library page per builtin module in `library/`, and
  `vm.md`, a top-level page on the Aurora VM and its libraries.
- Order and titles come from front matter (`title`, `weight`).
- `docs/grammar/*.md` is the language specification (`/reference/`): the
  content adapter `content/_content.gotmpl` reads the files through an assets
  mount (`hugo.toml`) and joins them, in file-name order, into one page. A new
  file in `docs/grammar/` appears there by itself; the adapter fails the build
  when fewer than 9 files are found, so change that number with the files.
- The programming skill is for agents and is not published.
- Links to the GitHub repo are shown only when `params.repoPublic` is true.
- When the language or a builtin changes, update the matching site page too.
- Do not hard-wrap prose in `site/content/`: one line per paragraph or list
  item. Hugo joins the lines anyway. Code blocks keep their own line breaks.

## Markdown and llms.txt

- Every page is also published as Markdown next to its HTML
  (`/tour/variables/index.md`), through Hugo's built-in `markdown` output
  format and `layouts/all.markdown.md`. `_partials/page-markdown.html` builds
  it from the page source.
- `_partials/markdown-links.html` points links at the other pages' `.md` URLs
  (and `#anchor` links at the page's own `.md`), sharing
  `_partials/link-target.html` with `render-link.html`. It skips top-level
  ``` fences and backtick code spans, and images (not `~~~` fences, fences of
  4 or more backticks, or indented fences). `home.llms.txt` runs
  `_partials/markdown-links-check.html`, which fails the build if that
  rewrite changes.
- Fence attributes become plain text. `{expect="CHECK-X"}` adds
  ``Does not compile: `error[CHECK-X]` `` after the block,
  `{expect="RUNTIME-X"}` adds ``Runtime error: `error[RUNTIME-X]` ``, and
  `{file="a.agc"}` adds ``File `a.agc`:`` before it unless the prose right
  above already ends with `` `a.agc`: ``. A section lists its pages.
- The home page also renders `/llms.txt` (`home.llms.txt`, an index) and
  `/llms-full.txt` (`home.llmsfull.txt`, every page's Markdown with its source
  URL), both in the order of `_partials/llms-groups.html`, with absolute URLs
  from `baseURL`.
- `_partials/page-actions.html` is the "Copy page" split button next to each
  page's `<h1>` (both in a `.page-head`). Its menu has View Source (the `.md`)
  and links that open ChatGPT or Claude with a prompt to read the `.md` URL.
  `assets/js/page-actions.js` fetches the `.md` for the clipboard and adds
  the `ready` class that shows the button, so it stays hidden without the
  script. Without the Clipboard API it removes the copy items.

## Examples are tests

Every `agentica` code block in `site/content` must be a complete program.
`tests/site-examples-test.rkt` checks each one and runs it (stdin from an
optional `input` block right after it), and compares stdout with the
`output` block that follows. `make test` runs it.
`.github/workflows/site-examples.yml` runs it alone on pull requests that
change only `site/content` (CI skips those).

Fence attributes:

- `{mode="check"}` only checks. Use it for examples that touch files,
  processes, the network or other outside state.
- `{expect="CODE"}` expects that diagnostic. `render-codeblock.html` shows
  `error[CODE]` in a box below the code, labeled "Runtime error" for
  `RUNTIME-` codes and "Does not compile" otherwise. It shows only the code,
  so the page cannot drift from the diagnostic message.
- `{file="name.agc"}` is a module that the page's other blocks can import.

## Deploy

The site is built only after a merge: `.github/workflows/pages.yml` runs
`make site` on `master` pushes that touch the site or its sources and
deploys it to GitHub Pages. So run `make site` locally before merging a
site change.
