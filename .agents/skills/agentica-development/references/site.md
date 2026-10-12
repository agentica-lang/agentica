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

## Content

- The user docs live in `site/content`: Getting started, the Language tour
  in `tour/`, and one Library page per builtin module in `library/`.
- Order and titles come from front matter (`title`, `weight`).
- `docs/grammar.md` is mounted as the language specification
  (`/reference/`).
- The programming skill is for agents and is not published.
- Links to the GitHub repo are shown only when `params.repoPublic` is true.
- When the language or a builtin changes, update the matching site page too.

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
- `{expect="CODE"}` expects that diagnostic.
- `{file="name.agc"}` is a module that the page's other blocks can import.

## Deploy

The site is built only after a merge: `.github/workflows/pages.yml` runs
`make site` on `master` pushes that touch the site or its sources and
deploys it to GitHub Pages. So run `make site` locally before merging a
site change.
