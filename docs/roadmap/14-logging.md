## Phase 14: Logging and debugging

**Done**, on the VM only: VM tracing (14a), always-on stack traces (14b, order
row 7.2.5) and `std/logger` (14c, order step 7.5) on the std-only
`LogRegistry`. 14c follows the library rule (after the order table): the module
is Agentica code, and its native part is the std-only registry `LogRegistry`, a
new exception to the std-first rule (decided on 2026-10-15; the rule lists it).
Its two builtin types, the record `LogEvent` and the enum `LogLevel`, are
builtins too. Record: the grammar's logging section
(`docs/grammar/06d-io-and-network.md`), the tracing rules in
`docs/vm/08-loader-and-cli.md` §9, and the stack-line shape in
`docs/vm/02-reference-behavior.md`.
