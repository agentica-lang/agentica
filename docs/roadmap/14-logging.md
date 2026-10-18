## Phase 14: Logging and debugging

Three small PRs, on the VM only; all three are done. The behavior is in the
grammar's logging section (`docs/grammar/06d-io-and-network.md`), the tracing
rules in `docs/vm/08-loader-and-cli.md` §9, and the stack-line shape in
`docs/vm/02-reference-behavior.md`. 14a is in order step 7.1, right after 7h
processes and before TCP and
TLS, to speed up debugging of the rest of 7h; 14b is order row 7.2.5 (taken out
of row 7.5 by the owner on 2026-10-14, before the freeze of row 7.2.7), and it
goes first: it adds no API, and agents get the most from it. 14c is order step
7.5, a new feature after 7i. It no longer waits for default parameter values
(15a, row 7.5a): until then its API had two functions per level (decided on
2026-10-15); 15a landed afterwards and the `_meta` functions are gone. 14c
follows the library rule (after the order table): the module is Agentica code,
and its native part is the std-only registry `LogRegistry`, a new exception to
the std-first rule (decided on 2026-10-15; the rule lists it now). Its two
builtin types, the record `LogEvent` and the enum `LogLevel`, are builtins
too.

**Done:** VM tracing (14a), always-on stack traces (14b), and
`std/logger` (14c) on the std-only `LogRegistry`. Record: the grammar's
logging section (`docs/grammar/06d-io-and-network.md`),
`docs/vm/08-loader-and-cli.md` §9, and
`docs/vm/02-reference-behavior.md`.

