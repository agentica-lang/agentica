---
name: documentation-writing
description: >-
  Decide whether a change needs documentation at all and, when it does, write
  the smallest correct edit in the right place. Use whenever about to write or
  update docs/, site/content/, a skill, a README, a CHANGELOG entry, a doc
  comment or a PR body in the Agentica repository, or when reviewing such an
  edit. Not for shrinking or consolidating docs that already exist (use
  documentation-pruning).
---

# Documentation writing

**Document only when strictly necessary.** The default is no doc change.
Change docs only when a reader would otherwise be wrong or blocked. To
shrink grown docs, use `documentation-pruning`.

## 1. Is a doc change needed?

Ask what changed and who reads about it:

- **User-visible behavior** (syntax, builtin, CLI): for the language, the
  grammar, the site page and the programming skill together; for a builtin or
  a `std/` module, its `site/content/library/` page and the programming skill
  (the AGENTS.md rule); plus a CHANGELOG entry.
- **A design decision or contract:** the design doc (built: `docs/vm/`;
  planned: the roadmap phase file). Write the decision and its reason, not
  the recipe.
- **An implementation detail:** a code comment where the code is not obvious,
  or nothing.
- **Progress or evidence:** the PR body, the roadmap tick or the CHANGELOG.
- **Anything else:** nothing.

Do not restate what code, tests or CLI help already say. If you are unsure,
leave it out and mention the gap in the PR body.

## 2. One home per topic

Each fact lives in one file. Edit that file in place; other places hold only
a pointer. The homes are in the lifecycle table and the Agentica map of
`documentation-pruning` (§2); follow them, do not copy them here or into new
docs. Do not create files under `docs/` unless the user asks for one
(AGENTS.md).

## 3. Provable claims

- Every claim maps to code, a test or a CI run you can name.
- No "always", "every", "never" or "all" until you checked each case
  (`rg` the sites and count them).
- Put the conditions in the sentence: "when libuv can assign its job object",
  not a bare "children die with the job".
- Keep built and planned apart. Describe a rule in the grammar or the site
  only once the code that enforces it has merged.
- No numbers (speed, size, counts) without a source the reader can rerun: the
  command, the benchmark file and the machine. No "faster" without a
  measurement.

## 4. Minimal diff

- Change only the sentences that became wrong; keep the rest byte for byte.
- No history in docs: no "now", "previously", "new", "this PR". Docs
  describe the current state; git keeps the history. Only the CHANGELOG and
  the PR body may say "new" or "added".
- No per-PR progress logs in design docs. An "As built" or status section
  that every PR rewrites causes merge conflicts; progress goes in the PR body
  and the roadmap.
- A CHANGELOG entry is one line about what users see, not how it was done.
- A PR body says what changed, why, and how it was checked. It is the place
  for evidence, so docs do not need it.

## 5. Verify

- `rg` the old names, removed symbols and changed numbers across `docs/`,
  `.agents/`, `site/` and `CHANGELOG.md`; fix every stale hit.
- When you move or delete a section, apply the reference fan-out protocol of
  `documentation-pruning` (§7).
- Prose wrap (AGENTS.md): 80 columns in `docs/` and `.agents/skills/`; one
  line per paragraph in `site/content/`. Run `git diff --check`.
- Run `make site` only when `site/content/` changed.
- Reread each new sentence against §3 before committing.

## Gotchas

Real overclaims, each caught only by a critic (see §3 for the rules they
break):

- "Descendants die with the job object": only direct children do, under
  `JOB_OBJECT_LIMIT_SILENT_BREAKAWAY_OK`.
- "A stopped Windows child exits with code 1": it is 128 + signal.
- "`agc_sync_assert` in every mutator": it was in some mutators, not all.
