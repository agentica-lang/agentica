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
correctness, essential knowledge, and navigability.

Short, precise instructions beat exhaustive explanations. Do not optimize file
count at the expense of context efficiency.

## 1. Discover

Read repository instructions and inspect documentation structure before
editing. Discover three things, in order:

1. **The lifecycle rules of this repository.** Find the indexes and
   conventions that already say where content lives when it is built, pending,
   done or an idea, and adopt them instead of inventing a parallel system. Look
   for: index files that assign a home per topic, rules about moving content
   when a plan lands, and archived-history policies (what git keeps, what the
   doc keeps).
2. **The structure and generators.** Actual paths, build system, site
   generators, tests that validate docs, and cross-tree wiring (an index that
   concatenates files, an adapter with a hard file count). Never assume a
   specific repository layout.
3. **Size outliers.** Record Markdown file count, bytes, lines, and estimated
   tokens by area (measure with `scripts/tokens.sh`, tiktoken `o200k_base`), and rank the largest files. Treat the top outliers as the
   first candidates: a big always-loaded index or a big plan document is where
   pruning pays most.

Identify these roles by purpose, not fixed paths:

| Role | Purpose | Rule |
| --- | --- | --- |
| Agent skills (`SKILL.md`) | Task instructions | Minimal, self-contained |
| Skill resources (`references/`) | Supporting detail | Load on demand |
| Internal docs (`docs/`, etc.) | Specs, decisions, design | Authoritative |
| Public docs (Hugo, MkDocs) | Product docs | Include only when in scope |
| Code, tests, CLI | Executable behavior, APIs | Prefer over repeated facts |

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
each navigation path reaches the relevant section without loading its siblings.

Inspect indexes, links, agent-loading instructions, and actual skill
dependencies.

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
decided (the API surface, the semantics, one-way choices, rejected
alternatives, open questions) and drops how it will be implemented step by
step: which files to touch, which tests to write, which fixtures to rename.
That fine design is decided again when the implementation PR happens, and
written plan detail rots (it cites files and paths that later PRs delete).
Keep the contract; cut the recipe. Never drop an owner decision.

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
- Verbose explanations, repeated introductions, obvious context, excessive
  examples, and oversized indexes.
- Stale plans, obsolete behavior, completed TODOs, outdated paths (for example
  files or modules that no longer exist), and historical notes without
  ongoing value.
- Documentation describing information easily discoverable from code, types,
  tests, CLI help, schemas, or generated APIs.
- References loaded unnecessarily, overlapping skills, and instructions
  repeated across agent entry points.

Classify candidates as `keep`, `shorten`, `merge`, `delete`, or `investigate`.

For each nontrivial candidate, record the exact location, claim, repository
evidence, confidence (high/medium/low), and proposed disposition. Verify
factual claims against current code, tests, config, history, or a later
decision. "Already implemented" needs evidence, not memory:

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
2. **Activated skills:** minimize `SKILL.md`; keep triggers, procedure,
   critical constraints, and validation.
3. **Skill resources:** remove redundant references; preserve only genuinely
   useful, selectively loaded detail.
4. **Internal docs:** consolidate specifications, decisions, and architecture
   without losing authority; start from the size outliers of §1.
5. **Public docs:** simplify relevant pages when the site is in scope, while
   preserving useful reader-facing content.

Prefer instructions over explanations, pointers over copies, and commands over
static inventories.

Do not replace a small, frequently needed instruction with a dependency on a
large document.

## 5. Controlled duplication

Duplication is acceptable when it reduces expected context tokens or preserves
distinct audiences.

Keep short, self-contained facts in skills when they prevent loading large
documentation.

Keep detailed technical specifications in internal docs and user-oriented
explanations in public docs.

Avoid copying entire specifications, API catalogs, tutorials, or implementation
details into skills.

A skill should guide the agent to the correct source, not reproduce that
source.

Evaluate duplication by **expected tokens loaded per task**, not just
repository size.

## 6. Prefer executable truth

Before keeping manually maintained technical documentation, check whether the
information can be retrieved reliably from:

- Source code, types, schemas, and symbol search.
- Tests, examples, and assertions.
- CLI help, introspection, and generated API references.
- Build scripts, configuration, and CI definitions.

Replace redundant inventories with precise discovery commands or pointers when
cheaper and reliable.

Preserve non-derivable knowledge: design rationale, security invariants,
compatibility promises, intentional tradeoffs, rejected alternatives likely to
recur, and unresolved decisions.

Code describes behavior; it does not automatically explain intent.

**Site coverage check:** before deleting or moving built user-facing content,
verify a site page already covers it for readers. If it does not and the site
is in scope, add the page in the same PR. Internal runtime docs need no site
coverage; the code, tests and skill references are their readers.

## 7. Edit safely

- Respect scope, repository rules, existing changes, and user authorization.
- Work incrementally by topic. Prefer deletion and consolidation over
  rewriting.
- Preserve normative contracts, unfinished work, important decisions, and
  stable links.
- Update in-scope indexes and cross-references together. For an in-scope
  user-facing language change, update its relevant site page and navigation if
  needed.
- Do not move entire documents into skill resources merely to hide duplication.
- Do not create replacement summaries unless they reduce actual maintenance or
  context cost.
- Do not change product behavior to accommodate documentation cleanup.

**Reference fan-out protocol.** Deleting or moving a document breaks its
references. Before the edit, search for them all — by file name and by section
number or anchor — in internal docs, skills, site content and the changelog.
Typical cost here: a single built-spec drop touched 10 to 13 files. Update
every reference in the same commit; a deleted spec that still has a link is a
failed edit. Never renumber surviving sections; keep numbering gaps.

**No replacement summaries.** When merging two documents, keep the richer one
and delete the other; do not leave a summary of what was deleted unless it
reduces actual maintenance or context cost.

Handle source conflicts as in §3; never invent consensus.

## 8. Validate and report

Validation is the only gate when the repository skips CI for docs-only PRs:
nothing else checks the change, so run the checks that CI would have run.

- Check `git diff --check` (whitespace) and the repo's Markdown prose rules
  (for Agentica: 80-column wrap for `docs/` and `.agents/skills/`; the site
  keeps one line per paragraph).
- Scan for dangling references: `§N` anchors, section titles, and deleted file
  names across `docs/`, `.agents/`, and `site/`.
- Check index consistency: every index row matches a file on disk, and every
  file has a row; index counts that a generator hardcodes (a file count, an
  adapter) still match.
- Run relevant generators or documentation builds only when they are in
  scope; for Agentica run `make site` only when site content changed, and do
  not crawl the site otherwise.
- Run targeted tests if examples or executable documentation changed.

Report:

- For each material edit, its location, claim, evidence, confidence and
  disposition; list unresolved findings separately.
- A disposition table: deleted, merged, shortened, retained, and moved, with
  bytes freed per tree (internal docs, skills, site), not just totals.
- Pairs unified into one home, and intentional duplication kept, with its
  context-loading justification.
- Before/after files, lines, bytes, and estimated tokens, using the same
  scope (`scripts/tokens.sh`). Always-loaded and activated-skill token savings separately.
- Broken references found and fixed, unresolved conflicts, and validation
  results.
- This skill itself: activated tokens and the references a task pulls in.

Estimate task-level savings using representative workflows when possible.
Distinguish measured results from estimates.

## Success criteria

- Minimum practical tokens per agent task.
- Short skills with selective resource loading.
- Minimal redundant maintenance.
- One home per topic; every other location holds only a pointer.
- Clear separation of agent, internal, and public documentation.
- Built content lives where its readers are; plans hold decisions, not
  recipes.
- No loss of essential technical knowledge.
- No broken navigation or critical workflows.
