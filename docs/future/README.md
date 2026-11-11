# Agentica: planned designs

Plans live in [GitHub issues](https://github.com/agentica-lang/agentica/issues)
(labels, milestones); shipped work is in `CHANGELOG.md` and the merged PR. The
current language contract is in [`grammar.md`](../grammar.md).

These files keep the design decisions (API, semantics, rejected alternatives,
open questions) of planned features whose issue points here, and the list of
what was decided against. They hold no recipes and nothing that shipped. When a
feature lands, move its rules to `docs/grammar/`, `docs/vm/` or the site and
delete its section; section numbers are never renumbered, so gaps stay.

- `15-adapters-and-json-inspection.md`: the enum form of `JSON.kind`
  (`JsonValue`, #1115).
- `16-cbor.md`: typed `Term.encode` and `Term.decode` (#994).
- `19-simd.md`: SIMD in the VM (#996).
- `25-ruby-typed-idioms.md`: `format` (#982), and what was decided against.
- `27-iteration-and-concurrency.md`: what was decided against in tasks and
  streams, and `Process.poll_line` (#997).
- `28-vm-metrics.md`: VM metrics in Prometheus text (#992).
- `29-tls-context.md`: later TLS options (#993).
- `41-dates-and-times.md`: builtin `Time` types (#985).
- `42-sized-numeric-types.md`: sized numeric types (#984).
- `46-signals.md`: signals (#991).
- `48-regex.md`: Unicode classes for regex (#990), and the decisions that bound
  it.
