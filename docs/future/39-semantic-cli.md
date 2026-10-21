## 39. Semantic CLI for agents

**Status:** built (row 7.2b, issue #506, PRs #525 to #543): `outline`,
`symbol`, `refs`, `type-at`, `--stdin`, the opt-in `--partial` and
`std/analysis` with `Analysis.refresh`. Pending: the measurement of the 6c
round (§39.12). The contract of each built part lives in its home, not here:

- commands, options and the answers:
  [`docs/grammar/06b-builtins.md`](../grammar/06b-builtins.md) and
  `.agents/skills/agentica-programming/references/queries.md`;
- `QUERY-` codes and exit codes:
  [`docs/grammar/07-diagnostics.md`](../grammar/07-diagnostics.md) and
  `.agents/skills/agentica-programming/references/diagnostics.md`;
- the library: `site/content/library/analysis.md` and
  `.agents/skills/agentica-programming/references/analysis.md`;
- the stages: `.agents/skills/agentica-development/references/frontend.md`;
- the tests: `tests/test_spec_outline.py`, `tests/test_spec_type_at.py`,
  `tests/test_spec_symbol.py`, `tests/test_spec_refs.py` and
  `tests/test_spec_partial.py`.

Agreed with the owner on 2026-10-13: agents program better when they can ask
the compiler about the code, not only read the docs. No language change: front
end and CLI only, nothing reaches lowering or the VM.

Only what is pending, what no home records, and the section numbers that
`compiler/` and `tests/` cite (39.2 to 39.8) stay here.

### 39.2 Shape

Built. The text and JSON forms are in `queries.md`. The options may come before
the command, as for every command; after it they are parsed by hand, as `help`
and `doc` do. The streams and `--ai` rules are in the programming skill
(`references/queries.md`).

### 39.3 Commands

Built. `type-at` answers a type name too (an annotation, a type argument, a
field or payload type, an alias target).

### 39.4 Names, paths and files

Built. The name forms, `PATH...`, file names and the order of results are in
`queries.md`.

- Rejected: names qualified by the module path (`models.agc:User.email`). It
  does not depend on the alias, but agents do not see it in the code, and a
  path inside a name is hard to quote. It can be a second form if aliases
  confuse agents in 6c.

### 39.5 JSON

Built. The shapes and the compatibility rule are in the programming skill
(`references/queries.md`).

### 39.6 Programs that do not check

Built. Owner decision, 2026-10-21: partial answers are opt-in (`--partial`),
with recovery per function and none in the parser. Without the option a command
answers only when what it needs is free of errors; otherwise it prints the
first diagnostic and exits 1, as `check` does. A root that does not link is
skipped, not an error, for `symbol` and `refs` (`queries.md`). What each command
needs:

- `outline`: a parse of `FILE`.
- `symbol`: a parse and a link.
- `refs` on a function, struct, enum, alias, constant or variant: a link, with
  `--partial`; else a check.
- `refs` on a field, a builtin or a local: a check. With `--partial`, a local
  needs only the function that holds it; a field or a builtin is never
  answered partially.
- `type-at`: a check of `FILE` and its imports. With `--partial`, the function
  that holds the position, else the link.

Rejected: answering from a partly checked program without the option, and a
checker that recovers inside a function. The recovery is per function, because
each stage stops at the first error (`AGENTS.md`). The option is opt-in,
because an exit 0 with a missing type is not what `check` users expect.

### 39.7 Diagnostics and exit codes

Built. The codes are in the grammar and the skill (see the homes above).
Exit 1 means "fix the program", exit 2 "fix the question"; a program with an
error is checked first, so its diagnostic wins over a bad position. A usage
error is a diagnostic, not a plain line as `help` prints, so `--json` always
gives JSON.

Rejected: `CHECK-` codes for a bad question (the program is fine, the question
is wrong), and a plain stderr line as `help` prints (agents parse JSON, and a
diagnostic has a span and a help).

### 39.8 Linking, checking and performance

Built. The linker and the query stages are described in `frontend.md`, and the
linker's rules in the doc comments of `compiler/modules/linker.agc`. Decided
against, and kept here because no home has them:

- Origins and uses: the linker keeps no table of uses. A table filled while the
  names are rewritten would repeat the walk that `query/sites.agc` makes over
  the linked trees.
- A daemon, a cache or a watch mode in the command line: none. Start-up is the
  single binary's (§18). A long-lived process first appears in the language
  server (§43), which can use `Analysis.refresh` for its cache.

### 39.11 Decided against

- **LSP, not in this phase.** A language server needs a long-lived process,
  incremental checking and an editor protocol. Agents call commands in a shell,
  and JSON on stdout is enough. See [§43](43-language-server.md) (not
  scheduled).
- **Rename and refactor commands.** Agents edit files well; what they lack is
  the list of places to edit, which `refs` gives.
- **Partial answers by default.** Opt-in, see 39.6.
- **Editor integration, a daemon, a cache.** See 39.8.

### 39.12 Measuring it: the 6c round

Pending. It runs in the full 6c round (roadmap row 10, phase 6c in
[`06-validation.md`](../roadmap/06-validation.md)).

- Count the command calls of each run, next to the file reads (`cat`, `rg`,
  `sed`) and the `agentica check` calls (`tests/eval/run.py`).
- Run one extra Agentica arm without the commands, on the tasks that cross a
  program (a field type, an enum variant, a Result in place of a plain value),
  with the same model and budget. The arm cannot use them: its skill has no
  reference to them, and a wrapper `agentica` first on the workspace `PATH`
  answers the four commands with exit 2. Each refused call is counted. The
  usage text still names them; that is recorded, not hidden.
- Compare hidden tests passed, tokens, repair attempts and time to a correct
  solution.
- Keep the commands in the skill if agents call them and the arm with them is
  not worse. If agents never call them, change how the skill presents them
  before the next round, not the commands.
