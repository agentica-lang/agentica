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
editing.

Identify these roles by purpose, not fixed paths:

| Role | Purpose | Rule |
| --- | --- | --- |
| Agent skills (`SKILL.md`) | Task instructions | Minimal, self-contained |
| Skill resources (`references/`) | Supporting detail | Load on demand |
| Internal docs (`docs/`, etc.) | Specs, decisions, design | Authoritative |
| Public docs (Hugo, MkDocs) | Product docs | For readers, not agents |
| Code, tests, CLI | Executable behavior, APIs | Prefer over repeated facts |

Discover the actual paths, generators, build system, and conventions. Never
assume a specific repository layout.

Two classes of information decide what stays loaded:

- **Know before acting:** conventions, critical constraints, essential
  commands, success criteria. Keep them in always-loaded files and in the
  skill itself.
- **Discover on demand:** implementation detail, signatures, extended examples,
  specifications, public documentation. Keep them behind a pointer, a
  reference file, or a discovery command.

Load a document because the task needs it, not because it exists. Check that
each navigation path reaches the relevant section without loading its siblings.

Record Markdown file count, bytes, lines, and estimated tokens by area. Inspect
indexes, links, agent-loading instructions, and actual skill dependencies.

## 2. Identify waste

Find:

- Exact and semantic duplication across skills, resources, internal docs, and
  public docs.
- Verbose explanations, repeated introductions, obvious context, excessive
  examples, and oversized indexes.
- Stale plans, obsolete behavior, completed TODOs, outdated paths, and
  historical notes without ongoing value.
- Documentation describing information easily discoverable from code, types,
  tests, CLI help, schemas, or generated APIs.
- References loaded unnecessarily, overlapping skills, and instructions
  repeated across agent entry points.

Classify candidates as `keep`, `shorten`, `merge`, `delete`, or `investigate`.

For each nontrivial candidate, record the exact location, claim, repository
evidence, confidence (high/medium/low), and proposed disposition. Verify factual
claims against current code, tests, config, history, or a later decision. If
intent and implementation conflict without a clear superseding authority, mark
it unresolved; do not silently rewrite it. Similar topics alone do not prove
duplication.

## 3. Optimize for token efficiency

Prioritize in this order:

1. **Always-loaded context:** global agent instructions, skill metadata,
   automatically injected files.
2. **Activated skills:** minimize `SKILL.md`; keep triggers, procedure,
   critical constraints, and validation.
3. **Skill resources:** remove redundant references; preserve only genuinely
   useful, selectively loaded detail.
4. **Internal docs:** consolidate specifications, decisions, and architecture
   without losing authority.
5. **Public docs:** remove unnecessary maintenance duplication while retaining
   useful human-facing explanations.

Prefer instructions over explanations, pointers over copies, and commands over
static inventories.

Do not replace a small, frequently needed instruction with a dependency on a
large document.

## 4. Controlled duplication

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

## 5. Prefer executable truth

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

## 6. Edit safely

- Respect scope, repository rules, existing changes, and user authorization.
- Work incrementally by topic. Prefer deletion and consolidation over
  rewriting.
- Preserve normative contracts, unfinished work, important decisions, and
  stable links.
- Update indexes, cross-references, skill paths, anchors, and site navigation
  together.
- Do not move entire documents into skill resources merely to hide duplication.
- Do not create replacement summaries unless they reduce actual maintenance or
  context cost.
- Do not change product behavior to accommodate documentation cleanup.

Handle source conflicts as in §2; never invent consensus.

## 7. Validate and report

Check git diff, local links, skill references, relevant generators, and
documentation builds. Run targeted tests if examples or executable
documentation changed.

Report:

- For each material edit, its location, claim, evidence, confidence and
  disposition; list unresolved findings separately.
- Before/after files, lines, bytes, and estimated tokens, using the same scope.
- Always-loaded and activated-skill token savings separately.
- Deleted, merged, shortened, and retained documents.
- Intentional duplication and its context-loading justification.
- Broken references, unresolved conflicts, and validation results.
- This skill itself: activated tokens and the references a task pulls in.

Estimate task-level savings using representative workflows when possible.
Distinguish measured results from estimates.

## Success criteria

- Minimum practical tokens per agent task.
- Short skills with selective resource loading.
- Minimal redundant maintenance.
- Clear separation of agent, internal, and public documentation.
- No loss of essential technical knowledge.
- No broken navigation or critical workflows.
