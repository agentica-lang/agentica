---
name: documentation-pruning
description: >-
  Minimize repository documentation and AI-agent context tokens. Audit and
  consolidate docs, agent skills, references, and public-site documentation.
  Remove redundant, stale, or code-derivable content while preserving
  essential contracts, decisions, and workflows. Use for documentation
  cleanup, skill optimization, and token reduction.
---

# Documentation pruning

Minimize **tokens loaded per agent task**, then total maintained text. Keep
correctness, essential knowledge and navigability; file count does not matter
more than context cost. To decide whether a change needs new docs at all, use
`documentation-writing`.

## 1. Discover

Before editing, find, in order:

1. **The lifecycle rules:** the indexes that assign a home per topic, the
   rules for moving content when a plan lands, the archived-history policies.
   Adopt them; do not invent a parallel system.
2. **The structure and generators:** real paths, build system, site
   generators, tests that validate docs. Assume no layout.
3. **Size outliers:** measure Markdown by area with `scripts/tokens.sh`
   (tiktoken `o200k_base`) and start with the largest files; a big
   always-loaded index or plan is where pruning pays most.

Identify roles by purpose, not path: skills (`SKILL.md`: minimal,
self-contained), resources (`references/`: on demand), internal docs
(authoritative), public docs, and code, tests and CLI (prefer them over
repeated facts).

For Agentica, do not crawl `site/content/` in a general audit; include Hugo
pages when requested, and inspect only the relevant ones. An in-scope
user-facing language or builtin change must update its site page.

What stays loaded: **know before acting** (conventions, critical constraints,
essential commands, success criteria) lives in always-loaded files and the
skill; **discover on demand** (implementation detail, signatures, extended
examples, specifications) sits behind a pointer, a reference file or a
discovery command. Load a document because the task needs it; check that each
navigation path reaches its section without loading siblings.

## 2. Lifecycle dispositions

Every candidate gets a **home**, not just a verdict. Use this table as the
starting point; the repository's own lifecycle rules (§1) override it.

| State | Disposition |
| --- | --- |
| Built, language | Rules to the grammar; delete the spec; keep the index row as a gap; no renumbering |
| Built, runtime/VM | Design and rationale to the runtime docs; delete the spec file |
| Built, user-facing | Site page (add it if missing, same PR) and the programming skill; internal copy deleted |
| Built, plan row or section | Delete it; the CHANGELOG and the merged PR hold the record |
| Pending, planned | **One home**: its GitHub issue. A plan's decisions may stay in `docs/future/` when the issue points there; every other location holds only a pointer |
| Decided against | One index line linking the rationale; no file |

**Plan documents keep decisions, not recipes.** A plan file holds what was
decided (API surface, semantics, one-way choices, rejected alternatives, open
questions) and drops the implementation recipe (files to touch, tests to
write, fixtures to rename). Recipe detail rots; it is re-decided at
implementation. Keep the contract; cut the recipe. Never drop an owner
decision.

**Agentica map (verify before use):** `docs/grammar/` is the current language
contract (the site renders it; one line per paragraph); the builtin library
reference lives only in `site/content/library/`. `docs/vm/` is the VM
design. Pending work lives in GitHub issues; `docs/future/` keeps only the
decisions of planned features whose issue points there, and what was decided
against (its README lists the files). Shipped work is in `CHANGELOG.md` and the
merged PR. `docs/bdd.md` is the contract for BDD.
Site pages are the user-facing home of built features.

## 3. Identify waste

Find:

- Exact and semantic duplication across skills, resources, internal docs and
  public docs, including a topic living in two trees and a rule restated in
  two indexes.
- Verbose text, repeated introductions, excessive examples, oversized indexes.
- Stale plans, obsolete behavior, completed TODOs, paths of files that no
  longer exist, historical notes without ongoing value.
- Facts discoverable from code, types, tests, CLI help, schemas or generated
  APIs.
- References loaded unnecessarily and instructions repeated across agent entry
  points.

Classify each candidate `keep`, `shorten`, `merge`, `delete` or `investigate`.
For a nontrivial one, record the location, claim, evidence, confidence and
disposition. "Already implemented" needs evidence, not memory:

- the construct appears in the current contract (grammar, library reference or
  VM docs), with its rules;
- spec or behavior tests exercise it (`tests/test_spec_*.py` and peers);
- a closed issue with its milestone, or a CHANGELOG entry; when cheap,
  `dist/agentica check` demonstrates it.

Grammar plus tests gives high confidence; only a closed issue gives medium. If
intent and implementation conflict with no clear superseding authority, mark it
unresolved; do not rewrite it silently. Similar topics
alone do not prove duplication.

## 4. Token efficiency

Prioritize in this order: always-loaded context (global instructions, skill
metadata), activated skills (triggers, procedure, critical constraints,
validation), skill resources (selectively loaded detail), internal docs
(consolidate without losing authority; start from the size outliers of §1),
public docs (only when in scope).

Prefer instructions over explanations, pointers over copies, and commands over
static inventories. Do not replace a small, frequently needed instruction with
a dependency on a large document.

Duplication is acceptable only when it lowers the expected tokens loaded per
task or serves distinct audiences: a short, self-contained fact in a skill that
saves loading a large doc. A skill points to the source; it does not copy
specifications, API catalogs, tutorials or implementation detail.

## 5. Prefer executable truth

Before keeping a hand-maintained fact, check whether code, types, tests, CLI
help, schemas, build scripts or CI definitions already say it; replace
inventories with a discovery command or a pointer when that is reliable.
Preserve what code does not say: design rationale, security invariants,
compatibility promises, intentional tradeoffs, rejected alternatives likely to
recur, unresolved decisions.

Before deleting or moving built user-facing content, verify a site page covers
it; if not and the site is in scope, add the page in the same PR. Internal
runtime docs need no site coverage.

## 6. Edit safely

- Respect scope, repo rules and existing changes. Work by topic; prefer
  deletion and consolidation over rewriting.
- Preserve normative contracts, unfinished work, decisions and stable links.
- Update in-scope indexes and cross-references together.
- Do not move whole documents into skill resources to hide duplication.
- When merging two documents, keep the richer one and delete the other; no
  summary of what was deleted unless it lowers real cost.
- Never change product behavior for a docs cleanup.

**Reference fan-out.** Before deleting or moving a document, search for every
reference, by file name and by section number or anchor, in docs, skills, site
content and the changelog (one built-spec drop touched 10 to 13 files). Update
them all in the same commit. Never renumber surviving sections.

## 7. Validate and report

A docs-only PR skips CI, so run what CI would have run:

- `git diff --check`; 80 columns for `docs/` and `.agents/skills/`, one line
  per paragraph in the site.
- Dangling references: `§N` anchors, section titles and deleted file names
  across `docs/`, `.agents/` and `site/`.
- Index consistency: every index row has a file and every file a row; counts a
  generator hardcodes still match.
- `make site` only when site content changed; targeted tests when examples or
  executable documentation changed.

Report: per material edit its location, claim, evidence and disposition
(unresolved findings apart); a disposition table with bytes freed per tree;
pairs unified and duplication kept, with the reason; before/after files, lines,
bytes and tokens from `scripts/tokens.sh`, same scope (activated-skill savings
apart); broken references fixed. Label measured results apart from estimates.

## Success criteria

Minimum tokens per agent task; short skills with selective resource loading;
one home per topic, every other location a pointer; built content where its
readers are; no loss of essential knowledge; no broken navigation.
