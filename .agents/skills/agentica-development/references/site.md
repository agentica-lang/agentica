# Documentation site

The look, the layouts, the outputs and the highlighter come from the docs
theme, the submodule `site/themes/docs-theme` (agentica-lang/docs-theme). Its
README says how it works and lists its params; its `DESIGN.md` has the design
rules. A change of style is a docs-theme PR, then a submodule bump here.

Read this before changing `site/`, a site page, or a builtin or language
rule that a site page shows.

## Build

- `make site` builds `site/public` (Hugo extended; the Hugo and Dart Sass
  versions are pinned in `pages.yml`; `mk/site.mk` says where `sass` must be).
  It needs the theme (`git submodule update --init site/themes/docs-theme`).
  Warnings fail the build. `make site-serve` serves it.
- `make site` also needs Node: after Hugo, the theme's
  `highlight/highlight.mjs --strict` colors every `agentica` and `signature`
  block, and fails on a block of another shape or a color class that no token
  matches.
- The grammar is the theme's `highlight/agentica.tmLanguage.json`; it must
  color exactly `RESERVED_TYPE_NAMES` (`tests/test_frontend_catalog.py`). A
  change to that list needs a docs-theme PR, merged first, then a submodule
  bump here. The `grammarChanges` field of the theme's
  `highlight/package.json` says where the copy differs from agc-tmlanguage
  (agentica-lang/agc-tmlanguage#13).
- The site's own templates override the theme: `layouts/reference/list.html`
  (the spec index) and `layouts/_shortcodes/release.md`. `site/hugo.toml` sets
  the params and `_merge = "deep"`, which takes the theme's outputs.
- The site shows the version of the `VERSION` file (header, footer, `llms.txt`,
  `llms-full.txt`, Getting started). `make site` passes it to Hugo as
  `HUGO_PARAMS_VERSION`; the `release` shortcode (Getting started) fails a
  plain `hugo` build without it. Never type the version in `site/`.
- To take a newer theme: `git -C site/themes/docs-theme checkout <commit>`,
  `git add site/themes/docs-theme`, `make site`. `<commit>` is a commit on the
  theme's default branch (never one from a PR branch): a deleted or squashed
  branch breaks `git submodule update`. `tools/site_versions.py`
  builds each tag with the theme commit that tag pins.

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

## Markdown and llms.txt

Every page is also published as Markdown (the theme's `layouts/all.markdown.md`;
its `_partials/markdown-links.html` rewrites links to `.md` URLs, and
`home.llms.txt` fails the build if that rewrite changes). It skips top-level ```
fences, code spans and images, but not `~~~` or 4-backtick fences. Fence
attributes become plain text: `{expect="CHECK-X"}` adds ``Does not compile:
`error[CHECK-X]` `` after the block, `{file="a.agc"}` adds ``File `a.agc`:``
before it. `/llms.txt` and `/llms-full.txt` come from the theme's
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
- `{expect="CODE"}` expects that diagnostic. The theme's code block shows
  `error[CODE]` in a box below the code, labeled "Runtime error" for `RUNTIME-`
  codes and "Does not compile" otherwise. It shows only the code, so the page
  cannot drift from the diagnostic message.
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

## Versions

Pages serves one site per final release (`/0.24.3/`, ...), `/dev/` (the tree
that runs: `master`) and the latest release again at the root.
`tools/site_versions.py` (`make site-versions`) builds them all:

- Each `X.Y.Z` tag is built from its own tree with its own `make site`, using
  the Hugo and Dart Sass pinned in that tag's `pages.yml` (keep the four `env`
  names of the `build` job). Only a tree with no site (`0.1.0`) that is older
  than every built tag is left out, and the job summary names it. Any other
  failure of a tag (or a no-site tag newer than a built one) is tried once more
  and then fails the run, as does a run in which no tag built: a release must
  not vanish from a deploy. Pre-releases and `bootstrap-racket` are not
  versions.
- The output of a tag is cached by commit sha and base URL (Hugo bakes the
  base URL into every link, so the root copy of the latest release is a
  second build). `dev` is never cached. Locally the cache is in
  `build/site-versions/cache`, pruned to the current builds each run; in CI
  `actions/cache` restores the newest entry, and a run that is not a pull
  request saves one only when it built something new.
- The selector and the banner (`site/versions/selector.{js,css}`) are not part
  of a build. The assembly copies them to `/_versions/` and adds their
  `<link>` and `<script>` tags to every HTML page, so a cached old build loads
  the current ones;
  they read `/versions.json`, which the assembly writes. A fix to them applies
  to every version at the next deploy. They use only the `.site-header`, its
  `.version` link and the color tokens (`_tokens.scss` of the docs theme);
  each old release carries its own copy of them.
- `make site-versions` writes `build/site-versions/public`; serve it with
  `python3 -m http.server 8000 -d build/site-versions/public`.

A new release shows up in the next run of `pages.yml`.

## Deploy

`.github/workflows/pages.yml` builds all versions on pull requests and
`master` pushes that touch the site or its sources, and on a manual run; only
a `master` push or a manual run from `master` deploys it to GitHub Pages.

Never cancel a Pages run while its `deploy-pages` step runs: GitHub keeps that
Pages deployment "in progress", every later deploy fails with "due to in
progress deployment", and only time (about half an hour) or Settings → Pages →
Source clears it.
