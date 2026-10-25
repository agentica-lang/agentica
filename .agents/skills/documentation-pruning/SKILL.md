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

Minimize **tokens loaded per agent task**, then total maintained text. Preserve
correctness, essential knowledge, and navigability. Do not optimize file count
at the expense of context efficiency.

To decide whether a change needs new docs at all, use `documentation-writing`.

## 1. Discover

Before editing, discover, in order:

1. **The lifecycle rules.** The indexes that assign a home per topic, the
   rules for moving content when a plan lands, and archived-history policies
   (what git keeps, what the doc keeps). Adopt them instead of inventing a
   parallel system.
2. **The structure and generators.** Actual paths, build system, site
   generators, tests that validate docs, and cross-tree wiring. Never assume
   a specific repository layout.
3. **Size outliers.** Record Markdown file count, bytes, lines, and estimated
   tokens by area (measure with `scripts/tokens.sh`, tiktoken `o200k_base`),
   and rank the largest files. Start with the top outliers: a big
   always-loaded index or plan document is where pruning pays most.

Identify roles by purpose, not path: skills (`SKILL.md`: minimal,
self-contained), resources (`references/`: on demand), internal docs
(authoritative), public docs (only when in scope), code, tests and CLI
(prefer over repeated facts).

For Agentica, do not crawl `site/content/` during a general docs audit. Include
Hugo pages when requested or explicitly in scope, and inspect only relevant
pages. Any in-scope user-facing language or builtin change must update its
corresponding site page.

Two classes of information decide what stays loaded:

- **Know before acting:** conventions, critical constraints, essential
  commands, success criteria. Keep them in always-loaded files and in the
  skill itself.
- **Discover on demand:** implementation detail, signatures, extended examples,
  specifications, public documentation. Keep them behind a pointer, a
  reference file, or a discovery command.

Load a document because the task needs it, not because it exists. Check that
each navigation path reaches its section without loading siblings.

## 2. Lifecycle dispositions

Every candidate gets a **home**, not just a verdict. Use this table as the
starting point; the repository's own lifecycle rules (§1) override it.

| State | Disposition |
| --- | --- |
| Built, language | Rules to the grammar; delete the spec; keep the index row as a gap; no renumbering |
| Built, runtime/VM | Design and rationale to the runtime docs; delete the spec file |
| Built, user-facing | Site page (add it if missing, same PR) and the programming skill; internal copy deleted |
| Built, roadmap row | Condense to a one-line complete row; phase file deleted or only open items |
| Pending, planned | **One home**: a single plan file; every other location holds only a pointer |
| Pending, idea only | One row in the ideas index |
| Decided against | One index line linking the rationale; no file |

**Plan documents keep decisions, not recipes.** A plan file holds what was
decided (API surface, semantics, one-way choices, rejected alternatives, open
questions) and drops the implementation recipe (files to touch, tests to
write, fixtures to rename). Recipe detail rots; it is re-decided at
implementation. Keep the contract; cut the recipe. Never drop an owner
decision.

**Agentica map (verify before use):** `docs/grammar/` is the current language
contract (the site renders it; one line per paragraph). `docs/vm/` is the VM
design. `docs/future/` is an index of language proposals; when a phase lands,
its syntax moves to the grammar and the file is deleted with its section
number preserved as a gap. `docs/roadmap/README.md` holds the order table and
the general rules; **pending work unifies in the roadmap phase file** (owner
decision 2026-10-18): the `docs/future/` section becomes the spec it points
to, and the roadmap file stops restating it. Built VM records that still sit
in `docs/future/` (for example small-value sharing, value representation, JIT,
SIMD) move to `docs/vm/`. `docs/bdd.md` is the contract for BDD. Site pages
are the user-facing home of built features.

## 3. Identify waste

Find:

- Exact and semantic duplication across skills, resources, internal docs, and
  public docs — including the same topic living in two trees (spec plus
  derived plan) and the same rule restated in two indexes.
- Verbose explanations, repeated introductions, excessive examples, and
  oversized indexes.
- Stale plans, obsolete behavior, completed TODOs, paths of files that no
  longer exist, and historical notes without ongoing value.
- Information easily discoverable from code, types, tests, CLI help, schemas,
  or generated APIs.
- References loaded unnecessarily, overlapping skills, and instructions
  repeated across agent entry points.

Classify candidates as `keep`, `shorten`, `merge`, `delete`, or `investigate`.

For each nontrivial candidate, record the exact location, claim, evidence,
confidence (high/medium/low), and proposed disposition. Verify claims against
current code, tests, config, history, or a later decision. "Already
implemented" needs evidence, not memory:

- the construct appears in the current contract (grammar, library reference,
  or VM docs), with its rules;
- spec or behavior tests exercise it (`tests/test_spec_*.py` and peers);
- the roadmap row or index says complete, with the phase date;
- a CHANGELOG entry exists; when cheap, the binary demonstrates it
  (`dist/agentica check`).

Grammar plus tests gives high confidence; only a roadmap tick gives medium.
If intent and implementation conflict without a clear superseding authority,
mark it unresolved; do not silently rewrite it. Similar topics alone do not
prove duplication.

## 4. Optimize for token efficiency

Prioritize in this order:

1. **Always-loaded context:** global agent instructions, skill metadata,
   automatically injected files.
2. **Activated skills:** keep triggers, procedure, critical constraints, and
   validation.
3. **Skill resources:** keep only genuinely useful, selectively loaded detail.
4. **Internal docs:** consolidate without losing authority; start from the
   size outliers of §1.
5. **Public docs:** simplify relevant pages when the site is in scope, keeping
   useful reader-facing content.

Prefer instructions over explanations, pointers over copies, and commands over
static inventories. Do not replace a small, frequently needed instruction with
a dependency on a large document.

## 5. Controlled duplication

Duplication is acceptable when it reduces **expected tokens loaded per task**
(not repository size) or preserves distinct audiences.

Keep short, self-contained facts in skills when they prevent loading large
documentation. Keep detailed specifications in internal docs and
user-oriented explanations in public docs. A skill guides the agent to the
source; it does not copy entire specifications, API catalogs, tutorials, or
implementation details.

## 6. Prefer executable truth

Before keeping manually maintained documentation, check whether the
information is reliably retrievable from code, types, tests, examples, CLI
help, introspection, schemas, build scripts, config, or CI definitions.
Replace redundant inventories with discovery commands or pointers when cheaper
and reliable. Preserve non-derivable knowledge (code describes behavior, not
intent): design rationale, security invariants, compatibility promises,
intentional tradeoffs, rejected alternatives likely to recur, and unresolved
decisions.

**Site coverage check:** before deleting or moving built user-facing content,
verify a site page already covers it for readers. If it does not and the site
is in scope, add the page in the same PR. Internal runtime docs need no site
coverage; the code, tests and skill references are their readers.

## 7. Edit safely

- Respect scope, repo rules, existing changes, and user authorization.
- Work incrementally by topic. Prefer deletion and consolidation over
  rewriting.
- Preserve normative contracts, unfinished work, important decisions, and
  stable links.
- Update in-scope indexes and cross-references together; an in-scope
  user-facing language change also updates its site page and navigation.
- Do not move entire documents into skill resources merely to hide duplication.
- Do not change product behavior to accommodate documentation cleanup.

**Reference fan-out protocol.** Deleting or moving a document breaks its
references. Before the edit, search for them all — by file name and by section
number or anchor — in internal docs, skills, site content and the changelog.
Typical cost here: a single built-spec drop touched 10 to 13 files. Update
every reference in the same commit; a deleted spec that still has a link is a
failed edit. Never renumber surviving sections; keep numbering gaps.

**No replacement summaries.** When merging two documents, keep the richer one
and delete the other; leave a summary of what was deleted only if it reduces
actual maintenance or context cost.

Handle source conflicts as in §3; never invent consensus.

## 8. Validate and report

For docs-only PRs the repository skips CI, so validation is the only gate:
run the checks that CI would have run.

- `git diff --check` and the repo's Markdown prose rules (for Agentica: 80
  columns for `docs/` and `.agents/skills/`; the site keeps one line per
  paragraph).
- Scan for dangling references: `§N` anchors, section titles, and deleted file
  names across `docs/`, `.agents/`, and `site/`.
- Check index consistency: every index row matches a file on disk, and every
  file has a row; counts that a generator hardcodes (a file count, an adapter)
  still match.
- Run generators or builds only when in scope; for Agentica, `make site` only
  when site content changed.
- Run targeted tests if examples or executable documentation changed.

Report:

- For each material edit, its location, claim, evidence, confidence and
  disposition; unresolved findings separately.
- A disposition table (deleted, merged, shortened, retained, moved) with bytes
  freed per tree (internal docs, skills, site).
- Pairs unified into one home, and intentional duplication kept, with its
  context-loading justification.
- Before/after files, lines, bytes, and estimated tokens, same scope
  (`scripts/tokens.sh`); always-loaded and activated-skill savings separately
  (this skill's own activated tokens included).
- Broken references fixed, unresolved conflicts, and validation results.

Estimate task-level savings with representative workflows when possible, and
label measured results apart from estimates.

## Success criteria

Minimum practical tokens per agent task; short skills with selective resource
loading; one home per topic, every other location a pointer; built content
where its readers are; no loss of essential technical knowledge; no broken
navigation or critical workflows.
