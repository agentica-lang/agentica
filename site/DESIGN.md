# Agentica docs site: design

This file sets the design rules for `site/`, the Hugo theme of the Agentica
docs. Each section names its source files. If this file and the code disagree,
the code is right: fix this file in the same change.

## Visual Theme & Atmosphere

Source: `site/hugo.toml`, `site/layouts/`.

- Purpose and voice: docs for Agentica, "Ruby with static types". Simple words,
  short sentences, and examples with short comments do the work.
- Look: plain and flat. One dark red accent for the brand, the current page and
  errors. Four Lucide icons. No web fonts.

## Color Palette & Roles

Source: `site/assets/scss/_tokens.scss`. Light values are on `:root`. Dark
values are in the `dark` mixin. They apply when the reader picks dark, or when
the system prefers dark and the reader has not picked light.

| Token | Light | Dark | Used for |
|---|---|---|---|
| `--bg` | `#ffffff` | `#0f1217` | page and header |
| `--fg` | `#1f2328` | `#e6edf3` | text |
| `--muted` | `#59636e` | `#9198a1` | captions, labels, tree toggles |
| `--border` | `#d8dee4` | `#2d333b` | rules, box edges, drawer edge |
| `--code-bg` | `#f6f8fa` | `#161b22` | code, buttons, hover |
| `--mark-bg` | `#fdf1f1` | `#2a1a1c` | current page, selected search hit |
| `--accent` | `#b4232a` | `#ff7b72` | brand mark, current page, errors |
| `--link` | `#0b5cad` | `#6cb6ff` | links, pager titles, focus ring |
| `--search-hit-bg` | `#fff3b0` | `#5c4a00` | search match |
| `--search-hit-fg` | `#1f2328` | `#fff8d6` | search match text |

- `--shadow`: light `0 6px 18px rgb(31 35 40 / 12%)`, dark
  `0 6px 18px rgb(0 0 0 / 45%)`. Used by the drawer, the search panel and the
  page menu.
- `--scrim`: light `rgb(31 35 40 / 45%)`, dark `rgb(0 0 0 / 60%)`. Behind the
  open drawer.
- Contrast: `--fg`, `--muted`, `--link` and `--accent` are at least 4.5:1 on
  `--bg`, `--code-bg` and `--mark-bg` in both themes. Recheck when one changes.

Syntax classes (`site/assets/scss/_code.scss`). The highlighter
`site/highlight/highlight.mjs` emits the same classes for `agentica` blocks.

- `--syn-keyword` `#cf222e` / `#ff7b72`: `.k .kc .kd .kn .kp .kr .ow`
- `--syn-string` `#0a3069` / `#a5d6ff`: `.s .s1 .s2 .sa .sb .sc .se .sh .sx`
- `--syn-number` `#0550ae` / `#79c0ff`: `.si .ss .m .mf .mi .mh`
- `--syn-name` `#8250df` / `#d2a8ff`: `.nf .nb .bp`
- `--syn-type` `#953800` / `#ffa657`: `.no .nc .nn .kt`
- `--syn-comment` `#6e7781` / `#8b949e`: `.c .c1 .cm`, in italic

## Typography Rules

Source: `_tokens.scss`, `_base.scss`, `_content.scss`, `_code.scss`.

- `--font` is the system UI stack (`system-ui`, `-apple-system`, `Segoe UI`,
  Roboto, Arial). `--mono` is the system monospace stack (`ui-monospace`,
  Menlo, Consolas).
- Body text is 1rem with a line height of 1.65. Headings have a line height of
  1.25.
- Headings: h1 2.1rem, h2 1.5rem with a rule under it, h3 1.2rem, h4 1.05rem.
  At 50rem and below, h1 is 1.7rem and h2 is 1.3rem.
- Small text: tree 0.95rem, TOC 0.875rem, code 0.875em, labels 0.75rem in
  capitals, pager labels 0.8rem, footer 0.9rem. These are rem literals in each
  partial. There is no size token.
- Code blocks keep their line breaks and scroll sideways. They do not wrap.

## Layout, Spacing & Radius

Source: `_tokens.scss`, `_layout.scss`, `_header.scss`, `_content.scss`.

- Spacing: `--gutter` (1rem) is the side gutter of the header, tree, footer and
  drawer. Other spacing is rem literals: the page body has 2rem 2.5rem 4rem
  padding wide, and 1.25rem `--gutter` 3rem at 50rem and below.
- Widths: `--layout-width` (80rem) caps the grid. `--sidebar-width` (16rem) is
  the tree column. `--content-width` (50rem) caps text and pager. `--header`
  (3.25rem) is the sticky bar. The drawer is `min(20rem, 85vw)` wide.
- Breakpoint: `$narrow` is 50rem, from `params.narrow` in `site/hugo.toml`. Sass
  and `nav.js` read it. A second one, 30rem, hides the header version.
- `--nav-row` is set on `.sidebar`, not on `:root`: 2rem wide, and 2.75rem at
  50rem and below.
- Radius: `--radius-sm` (4px) for small parts: inline code, tree links, search
  keys, section tags. `--radius` (6px) for buttons, inputs, code blocks, the
  pager, the search panel and the page menu.
- Depth: the page is flat. Borders split the areas. Floating layers use
  `--shadow`, with z-index: page menu 5, scrim 8, drawer 9, header 10, search
  panel 20.
- Phone width: 16px side gutters. Long text wraps. Code and tables scroll in
  their own box. The goal is no sideways scroll on the page itself.

## Motion & Focus

Source: `_tokens.scss`, `_layout.scss`, `_header.scss`, `_pager.scss`,
`_search.scss`.

- `--motion-base` (200ms) and `--ease` (`cubic-bezier(0.2, 0, 0, 1)`) are used
  by three transitions: the drawer slide, the scrim fade and the section chevron
  turn.
- Reduced motion: `--motion-base` is 0ms under `prefers-reduced-motion: reduce`.
  The drawer and the scrim then switch at once.
- `--focus-ring` is `2px solid var(--link)`. Header buttons, the tree and the
  pager draw it on `:focus-visible`. The search box draws it on `:focus`.
  Offsets differ by control: 2px, -2px or -1px.
- Page actions have no ring. Their buttons keep the browser outline, and their
  menu items change only the background.

## Components

### Header

Source: `_partials/header.html`, `theme-toggle.html`, `_header.scss`.

- Order: skip links, menu button, brand, version, search, theme button. A GitHub
  link shows only when `params.repoPublic` is true. It is false in
  `site/hugo.toml`.
- A sticky bar, `--header` high, with a `--border` line under it.
- Menu button: a native `<button>` with `aria-controls="sidebar"` and
  `aria-expanded`. It shows only with JS, at 50rem and below. Its icon turns
  from menu to x.
- Theme button: JS only. It shows the moon on a light page and the sun on a dark
  one. `theme.js` sets its label and saves the choice under the `theme` key of
  `localStorage`. The head script in `baseof.html` applies a saved choice before
  the body renders. Without a choice, the system setting decides.

### Sidebar tree and TOC

Source: `_partials/sidebar.html`, `sidebar-item.html`, `toc.html`,
`_layout.scss`.

- `<nav id="sidebar">` starts with a Home link, then the top pages in weight
  order.
- A section is a `<details>`. It is open when it is the current page or one of
  its ancestors. The browser keeps that state, so no JS is needed.
- Each section has two tab stops: its link and its toggle. The toggle sits over
  the right end of the link row.
- Current page: `aria-current="page"`, with `--mark-bg` background, `--accent`
  text and weight 600. Hover: `--code-bg` background.
- The TOC of the current page (its h2 headings) shows under its link.

### Mobile drawer

Source: `_layout.scss` (50rem and below), `site/assets/js/nav.js`.

- With JS, the tree is a drawer on the left, under the header, over a scrim. It
  is hidden with `visibility`, not `display`. So the slide runs both ways, and a
  closed tree is out of the tab order.
- Open: focus moves to the tree, and the current page scrolls to the middle.
  `main` and the footer get `inert`. The `nav-open` class on `html` locks page
  scroll.
- Close: Escape, a click on the scrim, or the menu button. Escape and the scrim
  return focus to the menu button. A plain click on a tree link closes the
  drawer. Growing past 50rem closes it.
- Without JS, the tree is a plain list after the page. On a narrow page, a
  "Skip to navigation" link leads to it.

### Pager

Source: `_partials/pager.html`, `nav-order.html`, `_pager.scss`.

- Previous and Next links end each page. Their order is the tree flattened depth
  first (`nav-order.html`), so the pager follows the sidebar.
- The home page is not in that order, so the pager starts at its first child. A
  page outside the tree gets no pager.
- Wide: two columns. Next stays on the right, even when it is alone. At 50rem
  and below: one column, Next aligned left. Each link is at least 2.75rem (44px)
  tall. The pager is hidden in print.

### Code blocks and samples

Source: `_markup/render-codeblock.html`, `_code.scss`,
`site/highlight/highlight.mjs`.

- `agentica` and `agc` blocks are colored at build time by the TextMate grammar.
  Other languages use Hugo's Chroma. Both use the `--syn-*` tokens.
- `input` and `output` blocks are samples: dashed boxes labeled Input or Output.
- `expect="CODE"` adds an accent box under the code. It says "Does not compile",
  or "Runtime error" for `RUNTIME-` codes, and shows `error[CODE]`.
- Code and tables scroll sideways in their own box.

### Skip links

Source: `_partials/header.html`, `_base.scss`, `_layout.scss`.

- "Skip to content" (`#main`) is the first tab stop. It stays off screen until
  it has focus.
- "Skip to navigation" (`#sidebar`) shows only on a narrow page without JS.

### Search, page actions and headings

- Search (`search.js`, `_search.scss`): plain JS, and the index loads on the
  first focus of the box. `/` focuses the box unless focus is in a text field.
  Ctrl+K and Cmd+K also focus it, even in a text field. Arrow keys move through
  the results, and Enter opens the active one. Escape closes the list, the next
  Escape clears the box, and the one after leaves it. On narrow pages the panel
  is fixed under the header.
- Page actions (`page-actions.js`, `_actions.scss`): a "Copy page" button and a
  menu (View Source, Open in ChatGPT, Open in Claude). JS only. Without a
  clipboard, the copy items are removed. Escape closes the menu, and focus
  returns to its toggle if it was inside.
- Headings (`render-heading.html`): each heading below h1 has a `#` link, shown
  on hover or keyboard focus. Headings stop under the sticky header when a link
  jumps to them.

## Accessibility

- Native first: `<button>` for controls, `<details>` and `<summary>` for the
  tree, `<a>` for links.
- Escape closes the search list, the drawer or the page menu. `nav.js` leaves
  Escape in the search box to `search.js`.
- While the drawer is open below 50rem, `inert` on `main` and the footer keeps
  focus in the drawer.
- Targets are at least 24px square. The menu button and the pager links are
  2.75rem (44px) on wide and narrow pages alike. Tree rows are 2rem (32px)
  wide and 2.75rem narrow. The theme button and the search box are 2.1rem
  (about 34px) on wide and narrow pages alike, under the 44px goal on narrow
  pages. Heading `#` links are small inline text and are the exception.
- Forced colors: the chevron is a mask. Under `forced-colors: active` it uses
  `CanvasText`, and focus outlines stay. Reduced motion: see Motion & Focus.
- Without JS the page works. The content comes first, the tree is a list, and
  the system color setting applies. The menu button, theme button, search and
  page actions stay hidden.

## Rules for Changes

- Reuse tokens. Add one only when a value repeats or changes with the theme. A
  color token needs a light value on `:root` and a dark value in the `dark`
  mixin, in the same change. Check each color, shadow and scrim in both themes.
- Colors live in `_tokens.scss`, with two exceptions. The favicon in
  `baseof.html` repeats the light `--accent`, so change both. The chevron
  mask in `_layout.scss` uses black, which sets only the mask shape.
- No runtime dependency. Hugo, Dart Sass and the Node highlighter run at build
  time (`mk/site.mk`). The browser loads only the built CSS and JS. No CDN, web
  font or outside script.
- Vanilla JS: one small file per feature in `site/assets/js/`, bundled by Hugo's
  `js.Build`, loaded with `defer` and an `integrity` hash. No framework and no
  library.
- `make site` must pass. It runs Hugo with `--panicOnWarning`, then the
  highlighter (`mk/site.mk`). A PR that touches `site/` runs `pages.yml`.
- Describe the current state here. Progress goes in the PR body. Update this
  file in the same PR as the change it describes.
- Content rules (prose wrap, fences, links) are in
  `.agents/skills/agentica-development/references/site.md`.
