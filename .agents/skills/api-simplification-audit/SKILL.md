---
name: api-simplification-audit
description: >-
  Audit Agentica's builtins and std/ modules for APIs that can be simpler,
  mainly parameters that could take a default value (a required timeout_ms,
  a max_bytes, an options struct with a common answer), in passes from a quick
  signature scan to a full per-function proposal, and report the result as a
  GitHub tracking issue split into small PRs. Use when asked to simplify
  builtin or std signatures, find required arguments that should be optional,
  or run an API defaults campaign. Only the audit and its report: adding a
  default is agentica-development work, a general plan is
  iterative-issue-planning, style is agentica-code-guidelines.
---

# API simplification audit

A campaign in three steps, **analyze, diagnose, report**, run as passes from
the lightest to the most complete. Stop after the pass the request asks for
(default: all three). Change nothing in `compiler/`, `stdlib/` or docs: the
output is a report; PRs come later, one per issue item, after the owner
agrees.

## What a default may be

Check every proposal against these rules first; they decide its cost.

- A default is a constant: an `Int`, `Float` or `String` literal, `true`,
  `false`, `nil`, `[]`, `{}` or a nullary enum variant. It cannot read another
  parameter or a module constant (docs/grammar/06-semantics.md, "Default
  parameter values").
- After a parameter with a default, every parameter has one, except a last
  `Fn` parameter (so a block still fills it).
- A **builtin** row takes defaults only when its rule is `Plain` or `Prelude`
  and it has no alternative form (`default_problem` and `takes_defaults?` in
  `compiler/catalog/builtins.agc`). A builtin with its own rule (for example
  `Channel.send` with `Rule.ChannelSend`) needs a checker change first: a
  bigger PR, and the cost line of the proposal says so.
- A **std struct** field may have a default (`NAME: type = expr`), so a
  `*_options()` function that only returns defaults may become field defaults.
  A builtin record (such as `HttpClientOptions`) cannot: only builtin
  parameters take defaults (`compiler/catalog/builtin_model.agc`).
- "Nothing waits forever" stays true: a timeout default is a finite number,
  never "no timeout". Precedent: `File.chunks(path, size = 65536,
  timeout_ms = 30000)`.
- One way per thing, Ruby form: a default must not create a second way to do
  something, and its name follows the Ruby rule of the development skill.
- Adding a default to a trailing parameter is not breaking. Reordering,
  renaming or removing a parameter is `**Breaking:**` in the CHANGELOG.

## Pass 1: signatures (minutes)

Use a binary built from the checkout you audit (a worktree's
`dist/agentica`; the main checkout's `dist/` may be stale). An older binary
skips the newer std/ modules and makes pass 2 read the wrong lines. Then:

```bash
python3 .agents/skills/api-simplification-audit/scripts/signatures.py \
  <binary> --root . --tsv <scratch>/signatures.tsv
```

It lists the most repeated parameters without a default, the tuning-like
ones (`timeout_ms`, `max_*`, `size`, `count`, `mode`, `options`...) and the
defaults that exist today, and names the builtins with overloads
(`Task.await`...), which take no defaults and are read by hand.
`help --json` does not show a row's rule; read it from the golden
`tests/fixtures/frontend/catalog/catalog.text`. Group the candidates by
family (all `timeout_ms` of `File.*`, of `Channel.*`...), not one by one. Drop the ones that are the subject of the
call (`List.take(count)`: the count is the point).

## Pass 2: real usage (an hour)

For each family, count how callers pass the argument:

```bash
python3 .agents/skills/api-simplification-audit/scripts/arg_usage.py \
  <binary> File.read_text examples compiler --root .
```

Run it on `examples`, `compiler`, and on the sibling repos when present
(`../bond`, `../agentica-db` next to the checkout). `refs` stops at the
first check error of any file, so pass folders that check (bare `stdlib`
and test fixtures do not; `site/content` has no `.agc`). Many `stdlib/*.agc`
files do not check alone, so take the `std/...` calls from a run whose
programs import them (`compiler`, `../bond`), once, and read the rest of
`stdlib/` with `rg`. The script lists the files `refs` skipped because they
do not link: read their calls by hand. Count the site samples with `rg`, compare the total with
`rg -c 'read_text\('`, and read the unparsed sites by hand. A value used
in most calls is the default candidate; a spread of values means keep it
required. Note the values in tests apart: tests pick small timeouts on
purpose.

## Pass 3: proposal (the full report)

For each family that survives, write one entry (the numbers here are
invented):

```text
### File.* timeout_ms (N builtins)
Now:      File.read_text(path: String, timeout_ms: Int) -> Result[String]
Proposal: timeout_ms: Int = 30000
Usage:    M calls; 30000 in most, a few 5000, test values apart
Rule:     Plain, no alternatives: default allowed as is
Risk:     not breaking; programs that pass it keep working
Ruby:     File.read(path) has no timeout; the default keeps the call Ruby-like
Cost:     S: catalog rows + goldens + docs (grammar, site, skill, CHANGELOG)
```

## Report

Write the report as one GitHub tracking issue on agentica-lang/agentica:

- title `API simplification: <scope>`, a short summary with the counts of
  pass 1, then one checklist item per PR, smallest and safest first (plain
  rows before checker rule changes, non-breaking before breaking);
- each item links its pass 3 entry and names the docs it must update
  (AGENTS.md: grammar, site page, programming skill, CHANGELOG);
- check for an existing issue first (`gh issue list --search "API
  simplification"`) and update it rather than open a second one.

Give the owner the issue link and the top three items. Open no PR until the
owner picks items.
